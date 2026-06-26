import AVFoundation
import CoreVideo

/// Records two synchronized video files from two separate camera inputs
/// using AVCaptureMultiCamSession. Each camera feeds its own AVAssetWriter.
final class DualLensRecorder: NSObject {

    // MARK: - Properties

    private let settings: RecordingSettings
    private let videoProcessor: VideoProcessor
    private let audioManager: AudioManager
    // Writers
    private var portraitWriter: AVAssetWriter?
    private var landscapeWriter: AVAssetWriter?
    private var portraitVideoInput: AVAssetWriterInput?
    private var landscapeVideoInput: AVAssetWriterInput?
    private var portraitAudioInput: AVAssetWriterInput?
    private var landscapeAudioInput: AVAssetWriterInput?
    private var portraitPixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var landscapePixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?

    // File URLs
    private var portraitURL: URL?
    private var landscapeURL: URL?

    // Pixel buffer pools
    private var portraitPool: CVPixelBufferPool?
    private var landscapePool: CVPixelBufferPool?

    // Pending frames — buffered while the encoder's isReadyForMoreMediaData is false
    // (happens briefly on the very first frame of a new H.264 context).
    private var portraitPendingFrames:  [(CVPixelBuffer, CMTime)] = []
    private var landscapePendingFrames: [(CVPixelBuffer, CMTime)] = []

    // Queues
    private let portraitVideoQueue  = DispatchQueue(label: "com.evershot.dual.portrait.video",  qos: .userInitiated)
    private let landscapeVideoQueue = DispatchQueue(label: "com.evershot.dual.landscape.video", qos: .userInitiated)
    private let writerQueue         = DispatchQueue(label: "com.evershot.dual.writer",          qos: .userInitiated)

    // State — combined flag used for audio gating (both writers must be ready)
    private var isRecording = false
    private var sessionStarted = false
    private var sessionStartTimestamp: CMTime = .invalid  // earliest of the two per-writer timestamps

    // Per-writer session state.
    // Each AVAssetWriter starts its own session at its own first-frame PTS so that
    // portrait and landscape are each anchored to their actual first video frame.
    // Using a single shared timestamp caused a visible jump in the first ~0.05 s:
    // whichever camera's frame arrived first set the origin for BOTH writers, so the
    // other writer's first real frame appeared at a non-zero offset inside the file
    // and iOS Photos would display wrong content at position 0.
    private var portraitSessionStarted:   Bool    = false
    private var landscapeSessionStarted:  Bool    = false
    private var portraitSessionTimestamp:  CMTime = .invalid
    private var landscapeSessionTimestamp: CMTime = .invalid

    // MARK: - Pause State
    //
    // isPaused is the single gate checked in captureOutput (on the video queues)
    // WITHOUT going through writerQueue.sync.  Reading a Bool on ARM64 is
    // naturally atomic; the worst case is a single extra frame written at the
    // pause boundary, which is imperceptible.  Keeping the video queues
    // completely unblocked while paused is what prevents the preview freeze.
    //
    // Pause offset is computed from wall-clock time rather than per-frame PTS so
    // that no frame tracking is needed in the capture callback path.
    //
    // Both portrait and landscape share one offset because they come from the
    // same AVCaptureMultiCamSession and their clocks are in lockstep.

    private var isPaused      = false
    private var pauseWallStart: Double = 0   // CACurrentMediaTime() snapshot
    private var pauseOffset:    CMTime = .zero  // accumulated pause duration

    // MARK: - AEC Stabilisation Gate
    //
    // Every lens-assignment change rebuilds AVCaptureMultiCamSession from scratch,
    // cold-starting both cameras' AEC.  Recording before AEC converges captures the
    // exposure ramp — the "lights off and on" flash visible at the start of the clip.
    //
    // Three-layer defence:
    //  1. KVO gate   — defer startWriting() until both cameras report isAdjustingExposure == false
    //  2. Exposure lock — lock both cameras simultaneously at that moment so neither can make
    //                   further micro-adjustments (sub-threshold changes that don't set the flag)
    //  3. Frame skip  — discard the first kLeadingFrameSkipCount frames whose pixel buffers were
    //                   already in the hardware pipeline when the lock fired
    //
    // A 2-second fallback timeout prevents indefinite blocking (extreme lighting change, etc.).

    private static let kLeadingFrameSkipCount = 5

    private var cameraStabilized = false
    private var wideExposureObservation:      NSKeyValueObservation?
    private var ultraWideExposureObservation: NSKeyValueObservation?
    private var stabilizationTimeoutItem:     DispatchWorkItem?

    private var wideDeviceForLock:      AVCaptureDevice?
    private var ultraWideDeviceForLock: AVCaptureDevice?
    private var exposureUnlockItem:     DispatchWorkItem?

    private var portraitLeadFrameCount  = 0
    private var landscapeLeadFrameCount = 0

    // Timelapse counters — accessed exclusively on writerQueue
    private var portraitTotalFrames    = 0
    private var landscapeTotalFrames   = 0
    private var portraitWrittenFrames  = 0
    private var landscapeWrittenFrames = 0

    // Diagnostic: log buffer dimensions once per recording session to verify
    // that each camera is delivering frames and at the expected orientation.
    private var hasLoggedPortraitBufferInfo  = false
    private var hasLoggedLandscapeBufferInfo = false

    // Debug frame counters — accessed on their respective capture queues (no lock needed)
    private var _portraitFrameCounter  = 0
    private var _landscapeFrameCounter = 0

    // Outputs
    private var portraitOutput:  AVCaptureVideoDataOutput?
    private var landscapeOutput: AVCaptureVideoDataOutput?

    // Completion handlers
    private var completionHandler: ((URL, URL) -> Void)?
    private var errorHandler: ((String) -> Void)?

    // MARK: - Init

    init(settings: RecordingSettings, videoProcessor: VideoProcessor, audioManager: AudioManager) {
        self.settings = settings
        self.videoProcessor = videoProcessor
        self.audioManager = audioManager
        super.init()
    }

    // MARK: - Output Assignment

    func setOutputs(portraitOutput: AVCaptureVideoDataOutput, landscapeOutput: AVCaptureVideoDataOutput) {
        self.portraitOutput  = portraitOutput
        self.landscapeOutput = landscapeOutput
        portraitOutput.setSampleBufferDelegate(self,  queue: portraitVideoQueue)
        landscapeOutput.setSampleBufferDelegate(self, queue: landscapeVideoQueue)
    }

    // MARK: - Recording Control

    func startRecording(wideDevice: AVCaptureDevice, ultraWideDevice: AVCaptureDevice?) {
        print("DualLensRecorder DIAG: startRecording called — wide=\(wideDevice.localizedName), ultraWide=\(ultraWideDevice?.localizedName ?? "nil")")
        writerQueue.async { [weak self] in
            guard let self = self else { return }
            print("DualLensRecorder DIAG: startRecording block running on writerQueue")
            self.setupWriters()
            self.setupAudioCallback()

            self.isRecording            = true
            self.sessionStarted         = false
            self.sessionStartTimestamp  = .invalid
            self.portraitSessionStarted  = false
            self.landscapeSessionStarted = false
            self.portraitSessionTimestamp  = .invalid
            self.landscapeSessionTimestamp = .invalid
            self.cameraStabilized       = false
            self.wideDeviceForLock      = wideDevice
            self.ultraWideDeviceForLock = ultraWideDevice
            self.portraitLeadFrameCount  = 0
            self.landscapeLeadFrameCount = 0
            self.portraitTotalFrames     = 0
            self.landscapeTotalFrames    = 0
            self.portraitWrittenFrames   = 0
            self.landscapeWrittenFrames  = 0
            // Reset pending frame buffers so stale frames from a previous recording
            // can never bleed into a fresh one (defensive: cleanupWriters normally
            // clears these, but reset here too to cover any race at recording start).
            self.portraitPendingFrames.removeAll()
            self.landscapePendingFrames.removeAll()
            self.isPaused       = false
            self.pauseWallStart = 0
            self.pauseOffset    = .zero
            self.hasLoggedPortraitBufferInfo  = false
            self.hasLoggedLandscapeBufferInfo = false

            let checkBothStable = { [weak self] in
                let wideStable      = !wideDevice.isAdjustingExposure
                let ultraWideStable = ultraWideDevice.map { !$0.isAdjustingExposure } ?? true
                if wideStable && ultraWideStable { self?.triggerWriterStart() }
            }

            self.wideExposureObservation = wideDevice.observe(
                \.isAdjustingExposure, options: [.initial, .new]
            ) { _, _ in checkBothStable() }

            if let uwDevice = ultraWideDevice {
                self.ultraWideExposureObservation = uwDevice.observe(
                    \.isAdjustingExposure, options: [.initial, .new]
                ) { _, _ in checkBothStable() }
            }

            let timeout = DispatchWorkItem { [weak self] in self?.triggerWriterStart() }
            self.stabilizationTimeoutItem = timeout
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2.0, execute: timeout)
        }
    }

    private func triggerWriterStart() {
        writerQueue.async { [weak self] in
            guard let self = self, self.isRecording, !self.cameraStabilized else { return }

            self.wideExposureObservation      = nil
            self.ultraWideExposureObservation = nil
            self.stabilizationTimeoutItem?.cancel()
            self.stabilizationTimeoutItem = nil

            // Lock both cameras in the same serial block to prevent cross-camera ISP
            // compensation (locking one while the other is in continuous-auto mode
            // causes the unlocked camera to compensate).
            for device in [self.wideDeviceForLock, self.ultraWideDeviceForLock].compactMap({ $0 }) {
                do {
                    try device.lockForConfiguration()
                    if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
                    device.unlockForConfiguration()
                } catch {
                    print("DualLensRecorder: Could not lock exposure on \(device.localizedName): \(error)")
                }
            }

            let pStatus = self.portraitWriter?.startWriting()
            let lStatus = self.landscapeWriter?.startWriting()
            print("DualLensRecorder: triggerWriterStart — portraitWriter startWriting=\(String(describing: pStatus)), status=\(String(describing: self.portraitWriter?.status.rawValue)), error=\(String(describing: self.portraitWriter?.error))")
            print("DualLensRecorder: triggerWriterStart — landscapeWriter startWriting=\(String(describing: lStatus)), status=\(String(describing: self.landscapeWriter?.status.rawValue)), error=\(String(describing: self.landscapeWriter?.error))")
            self.cameraStabilized = true

            let unlockItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.writerQueue.async { self.unlockExposure() }
            }
            self.exposureUnlockItem = unlockItem
            DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 3.0, execute: unlockItem)
        }
    }

    private func unlockExposure() {
        for device in [wideDeviceForLock, ultraWideDeviceForLock].compactMap({ $0 }) {
            do {
                try device.lockForConfiguration()
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                device.unlockForConfiguration()
            } catch {
                print("DualLensRecorder: Could not unlock exposure on \(device.localizedName): \(error)")
            }
        }
        wideDeviceForLock      = nil
        ultraWideDeviceForLock = nil
        exposureUnlockItem     = nil
    }

    func stopRecording(completion: @escaping (URL, URL) -> Void, error: @escaping (String) -> Void) {
        writerQueue.async { [weak self] in
            guard let self = self else { return }
            self.isRecording = false
            self.isPaused    = false
            self.completionHandler = completion
            self.errorHandler = error
            self.audioManager.onAudioBuffer = nil
            self.finishWriting()
        }
    }

    func pause() {
        writerQueue.async { [weak self] in
            guard let self = self, self.isRecording, !self.isPaused else { return }
            self.pauseWallStart = CACurrentMediaTime()
            self.isPaused = true   // checked without sync in captureOutput
        }
    }

    func resume() {
        writerQueue.async { [weak self] in
            guard let self = self, self.isRecording, self.isPaused else { return }
            // Accumulate wall-clock pause duration before clearing the flag so the
            // offset is ready before the next frame reaches the write block.
            let pausedSeconds = CACurrentMediaTime() - self.pauseWallStart
            self.pauseOffset = CMTimeAdd(
                self.pauseOffset,
                CMTime(seconds: pausedSeconds, preferredTimescale: 600)
            )
            self.isPaused = false
        }
    }

    // MARK: - Writer Setup

    private func setupWriters() {
        let pURL = settings.portraitFileURL()
        let lURL = settings.landscapeFileURL()
        portraitURL  = pURL
        landscapeURL = lURL

        do {
            // MARK: Portrait writer
            let pWriter     = try AVAssetWriter(outputURL: pURL, fileType: settings.fileFormat.fileType)
            let pVideoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings.portraitVideoSettings)
            pVideoInput.expectsMediaDataInRealTime = true

            let pAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings.audioSettings)
            pAudioInput.expectsMediaDataInRealTime = true

            let pDims    = settings.resolution.portraitDimensions
            let pAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: pVideoInput,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey  as String: pDims.width,
                    kCVPixelBufferHeightKey as String: pDims.height
                ]
            )

            if pWriter.canAdd(pVideoInput) { pWriter.add(pVideoInput) }
            if pWriter.canAdd(pAudioInput) { pWriter.add(pAudioInput) }

            portraitWriter             = pWriter
            portraitVideoInput         = pVideoInput
            portraitAudioInput         = pAudioInput
            portraitPixelBufferAdaptor = pAdaptor

            // MARK: Landscape writer
            let lWriter     = try AVAssetWriter(outputURL: lURL, fileType: settings.fileFormat.fileType)
            let lVideoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings.landscapeVideoSettings)
            lVideoInput.expectsMediaDataInRealTime = true

            let lAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings.audioSettings)
            lAudioInput.expectsMediaDataInRealTime = true

            let lDims    = settings.resolution.landscapeDimensions
            let lAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: lVideoInput,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey  as String: lDims.width,
                    kCVPixelBufferHeightKey as String: lDims.height
                ]
            )

            if lWriter.canAdd(lVideoInput) { lWriter.add(lVideoInput) }
            if lWriter.canAdd(lAudioInput) { lWriter.add(lAudioInput) }

            landscapeWriter             = lWriter
            landscapeVideoInput         = lVideoInput
            landscapeAudioInput         = lAudioInput
            landscapePixelBufferAdaptor = lAdaptor

            portraitPool  = VideoProcessor.createPixelBufferPool(width: pDims.width, height: pDims.height)
            landscapePool = VideoProcessor.createPixelBufferPool(width: lDims.width, height: lDims.height)

            print("DualLensRecorder DIAG: setupWriters succeeded — pURL=\(pURL.lastPathComponent) lURL=\(lURL.lastPathComponent) pDims=\(pDims.width)×\(pDims.height) lDims=\(lDims.width)×\(lDims.height) portraitPool=\(portraitPool != nil) landscapePool=\(landscapePool != nil)")

        } catch {
            print("DualLensRecorder: Failed to create writers: \(error)")
        }
    }

    private func setupAudioCallback() {
        audioManager.onAudioBuffer = { [weak self] sampleBuffer in
            guard let self = self else { return }
            var shouldAppend = false
            self.writerQueue.sync {
                shouldAppend = self.isRecording && !self.isPaused
                            && self.sessionStarted && !self.settings.isTimelapse
            }
            guard shouldAppend else { return }

            self.writerQueue.async {
                let audioPts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                guard CMTIME_IS_VALID(self.sessionStartTimestamp),
                      CMTimeCompare(audioPts, self.sessionStartTimestamp) >= 0 else { return }

                if let a = self.portraitAudioInput,  a.isReadyForMoreMediaData, self.portraitWriter?.status  == .writing { a.append(sampleBuffer) }
                if let a = self.landscapeAudioInput, a.isReadyForMoreMediaData, self.landscapeWriter?.status == .writing { a.append(sampleBuffer) }
            }
        }
    }

    // MARK: - Per-Writer Session Management
    //
    // Each writer starts its own AVAssetWriter session at its own first-frame PTS.
    // This prevents the frame-jump artifact that occurred when a shared timestamp
    // was used: if landscape's frame arrived first it set the origin for both writers,
    // causing portrait's session to begin before any portrait frame existed there —
    // iOS then displayed wrong (landscape) content at portrait position 0.

    private func startPortraitSessionIfNeeded(at timestamp: CMTime) {
        guard !portraitSessionStarted, portraitWriter?.status == .writing else { return }
        portraitWriter?.startSession(atSourceTime: timestamp)
        portraitSessionTimestamp = timestamp
        portraitSessionStarted   = true
        checkBothSessionsStarted()
    }

    private func startLandscapeSessionIfNeeded(at timestamp: CMTime) {
        guard !landscapeSessionStarted, landscapeWriter?.status == .writing else { return }
        landscapeWriter?.startSession(atSourceTime: timestamp)
        landscapeSessionTimestamp = timestamp
        landscapeSessionStarted   = true
        checkBothSessionsStarted()
    }

    /// Called after either per-writer session starts.  Once both are started, sets the
    /// combined `sessionStarted` flag (used to gate audio) and records the earliest of
    /// the two timestamps as the audio filter boundary.
    private func checkBothSessionsStarted() {
        guard portraitSessionStarted && landscapeSessionStarted else { return }
        sessionStarted = true
        // Audio must not start before the earlier of the two video streams.
        sessionStartTimestamp = CMTIME_IS_VALID(portraitSessionTimestamp) && CMTIME_IS_VALID(landscapeSessionTimestamp)
            ? CMTimeMinimum(portraitSessionTimestamp, landscapeSessionTimestamp)
            : (CMTIME_IS_VALID(portraitSessionTimestamp) ? portraitSessionTimestamp : landscapeSessionTimestamp)
    }

    private func clampedPortraitTimestamp(_ pts: CMTime) -> CMTime {
        guard portraitSessionStarted, CMTIME_IS_VALID(portraitSessionTimestamp) else { return pts }
        return CMTimeMaximum(pts, portraitSessionTimestamp)
    }

    private func clampedLandscapeTimestamp(_ pts: CMTime) -> CMTime {
        guard landscapeSessionStarted, CMTIME_IS_VALID(landscapeSessionTimestamp) else { return pts }
        return CMTimeMaximum(pts, landscapeSessionTimestamp)
    }

    // MARK: - Process Video Frame

    private func processPortraitFrame(_ sampleBuffer: CMSampleBuffer) {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        var shouldWrite = false
        var skipTimelapse = false
        var diagIsRecording = false
        var diagStabilized = false
        var diagLeadCount = 0
        var diagWriterStatus: AVAssetWriter.Status = .unknown
        writerQueue.sync {
            diagIsRecording   = isRecording
            diagStabilized    = cameraStabilized
            diagLeadCount     = portraitLeadFrameCount
            diagWriterStatus  = portraitWriter?.status ?? .unknown

            guard isRecording, cameraStabilized else { return }

            portraitLeadFrameCount += 1
            guard portraitLeadFrameCount > DualLensRecorder.kLeadingFrameSkipCount else { return }

            startPortraitSessionIfNeeded(at: timestamp)
            shouldWrite = portraitSessionStarted
            if shouldWrite && settings.isTimelapse {
                portraitTotalFrames += 1
                skipTimelapse = (portraitTotalFrames % settings.timelapseSpeed.skipInterval != 0)
            }
        }

        // Log once when a frame arrives while recording is active, to confirm this path runs
        if diagIsRecording && !hasLoggedPortraitBufferInfo {
            print("DualLensRecorder DIAG: processPortraitFrame — isRecording=\(diagIsRecording) stabilized=\(diagStabilized) leadCount=\(diagLeadCount) writerStatus=\(diagWriterStatus.rawValue) shouldWrite=\(shouldWrite)")
        }

        guard shouldWrite && !skipTimelapse else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // The wide recording connection uses .landscapeRight, delivering native 1920×1080
        // frames. Rotate CW90 to produce an upright 1080×1920 portrait frame.
        // (For rear cameras, CW90 maps the landscape-right "up" direction to the top of
        // the portrait frame. Front cameras use CCW90 due to the mirrored sensor axis.)
        // If the exported portrait appears upside-down, swap rotatedCW90 → rotatedCCW90.
        let sourceBuffer: CVPixelBuffer
        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)
        if srcW > srcH {
            // Native landscape from the recording connection — rotate to portrait.
            guard let rotated = videoProcessor.rotatedCW90(pixelBuffer) else { return }
            sourceBuffer = rotated
        } else {
            // Already portrait-shaped (shouldn't happen with .landscapeRight, but safe fallback).
            sourceBuffer = pixelBuffer
        }

        if !hasLoggedPortraitBufferInfo {
            hasLoggedPortraitBufferInfo = true
            print("🎥 DualLensRecorder [PORTRAIT] raw frame: \(srcW)×\(srcH) → rotated to \(CVPixelBufferGetWidth(sourceBuffer))×\(CVPixelBufferGetHeight(sourceBuffer))")
        }

        let dims = settings.resolution.portraitDimensions
        guard let croppedBuffer = videoProcessor.cropAndScale(
            pixelBuffer: sourceBuffer, toWidth: dims.width, toHeight: dims.height, pool: portraitPool
        ) else { return }

        writerQueue.async { [weak self] in
            guard let self = self,
                  let input = self.portraitVideoInput,
                  self.portraitWriter?.status == .writing else { return }

            let pts: CMTime
            if self.settings.isTimelapse {
                let fps = CMTimeScale(self.settings.frameRate.rawValue)
                pts = CMTimeAdd(self.portraitSessionTimestamp,
                                CMTime(value: CMTimeValue(self.portraitWrittenFrames), timescale: fps))
                self.portraitWrittenFrames += 1
            } else {
                // Subtract wall-clock-computed pause duration for a gapless timeline.
                let rawPTS = self.clampedPortraitTimestamp(timestamp)
                pts = CMTimeSubtract(rawPTS, self.pauseOffset)
            }

            var flushed = 0
            while flushed < self.portraitPendingFrames.count, input.isReadyForMoreMediaData {
                let (buf, pendingPts) = self.portraitPendingFrames[flushed]
                self.portraitPixelBufferAdaptor?.append(buf, withPresentationTime: pendingPts)
                flushed += 1
            }
            if flushed > 0 { self.portraitPendingFrames.removeFirst(flushed) }

            if input.isReadyForMoreMediaData {
                self.portraitPixelBufferAdaptor?.append(croppedBuffer, withPresentationTime: pts)
            } else if self.portraitPendingFrames.count < 60 {
                self.portraitPendingFrames.append((croppedBuffer, pts))
            }
        }
    }

    private func processLandscapeFrame(_ sampleBuffer: CMSampleBuffer) {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        var shouldWrite = false
        var skipTimelapse = false
        writerQueue.sync {
            guard isRecording, cameraStabilized else { return }

            landscapeLeadFrameCount += 1
            guard landscapeLeadFrameCount > DualLensRecorder.kLeadingFrameSkipCount else { return }

            startLandscapeSessionIfNeeded(at: timestamp)
            shouldWrite = landscapeSessionStarted
            if shouldWrite && settings.isTimelapse {
                landscapeTotalFrames += 1
                skipTimelapse = (landscapeTotalFrames % settings.timelapseSpeed.skipInterval != 0)
            }
        }

        guard shouldWrite && !skipTimelapse else { return }
        guard let rawPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // ── Orientation ──────────────────────────────────────────────────────────────
        // The ultrawide recording connection delivers native-landscape 1920×1080 frames
        // (.landscapeRight) with the scene rotated 90° — a standing person lies on their
        // side. The phone is held in PORTRAIT, so to produce an UPRIGHT horizontal 16:9
        // export we must physically rotate the pixels upright FIRST, then centre-crop the
        // 16:9 region from the upright frame.
        //
        // Why not a writer display-transform (the trick SingleLensRecorder uses)? A
        // transform rotates the WHOLE frame on playback, which would turn this into a
        // vertical 1080×1920 display. Physically rotating the pixels is the only way to
        // keep an upright subject inside a genuinely horizontal frame.
        //
        // rotatedCW90 matches processPortraitFrame (same rear sensor, same .landscapeRight
        // source), so the subject ends up upright. If the export ever appears upside-down,
        // swap rotatedCW90 → rotatedCCW90 on the line below — nothing else changes.
        //
        // Framing note: from a portrait hold the 16:9 result is necessarily a centre crop
        // of the ultrawide frame (top/bottom trimmed). At 1080p the crop upscales ~1.78×;
        // recording in 4K eliminates the upscale and keeps the landscape export sharp.
        guard let uprightBuffer = videoProcessor.rotatedCW90(rawPixelBuffer) else { return }

        if !hasLoggedLandscapeBufferInfo {
            hasLoggedLandscapeBufferInfo = true
            let rawW = CVPixelBufferGetWidth(rawPixelBuffer)
            let rawH = CVPixelBufferGetHeight(rawPixelBuffer)
            print("🎥 DualLensRecorder [LANDSCAPE/ULTRAWIDE] first frame: \(rawW)×\(rawH) → " +
                  "rotated upright \(CVPixelBufferGetWidth(uprightBuffer))×\(CVPixelBufferGetHeight(uprightBuffer)) → centre-crop 16:9")
        }

        let dims = settings.resolution.landscapeDimensions

        guard let croppedBuffer = videoProcessor.cropAndScale(
            pixelBuffer: uprightBuffer, toWidth: dims.width, toHeight: dims.height,
            pool: landscapePool
        ) else { return }

        writerQueue.async { [weak self] in
            guard let self = self,
                  let input = self.landscapeVideoInput,
                  self.landscapeWriter?.status == .writing else { return }

            let pts: CMTime
            if self.settings.isTimelapse {
                let fps = CMTimeScale(self.settings.frameRate.rawValue)
                pts = CMTimeAdd(self.landscapeSessionTimestamp,
                                CMTime(value: CMTimeValue(self.landscapeWrittenFrames), timescale: fps))
                self.landscapeWrittenFrames += 1
            } else {
                let rawPTS = self.clampedLandscapeTimestamp(timestamp)
                pts = CMTimeSubtract(rawPTS, self.pauseOffset)
            }

            var flushed = 0
            while flushed < self.landscapePendingFrames.count, input.isReadyForMoreMediaData {
                let (buf, pendingPts) = self.landscapePendingFrames[flushed]
                self.landscapePixelBufferAdaptor?.append(buf, withPresentationTime: pendingPts)
                flushed += 1
            }
            if flushed > 0 { self.landscapePendingFrames.removeFirst(flushed) }

            if input.isReadyForMoreMediaData {
                self.landscapePixelBufferAdaptor?.append(croppedBuffer, withPresentationTime: pts)
            } else if self.landscapePendingFrames.count < 60 {
                self.landscapePendingFrames.append((croppedBuffer, pts))
            }
        }
    }

    // MARK: - Finish Writing

    private func finishWriting() {
        let anySessionStarted = portraitSessionStarted || landscapeSessionStarted
        guard anySessionStarted else {
            stabilizationTimeoutItem?.cancel()
            stabilizationTimeoutItem = nil
            wideExposureObservation      = nil
            ultraWideExposureObservation = nil
            exposureUnlockItem?.cancel()
            unlockExposure()
            portraitWriter?.cancelWriting()
            landscapeWriter?.cancelWriting()
            cleanupWriters()
            errorHandler?("Recording stopped before it could start.")
            return
        }

        exposureUnlockItem?.cancel()
        unlockExposure()

        let group = DispatchGroup()
        var finalPortraitURL: URL?
        var finalLandscapeURL: URL?

        // Portrait writer
        if let writer = portraitWriter {
            switch writer.status {
            case .writing:
                group.enter()
                portraitVideoInput?.markAsFinished()
                portraitAudioInput?.markAsFinished()
                let url = portraitURL
                writer.finishWriting {
                    if writer.status == .completed { finalPortraitURL = url }
                    group.leave()
                }
            case .failed:
                // Interrupted (e.g. app backgrounded) — partial file is often still playable.
                print("DualLensRecorder: portrait writer interrupted — attempting to salvage file")
                finalPortraitURL = portraitURL
            default:
                break
            }
        }

        // Landscape writer
        if let writer = landscapeWriter {
            switch writer.status {
            case .writing:
                group.enter()
                landscapeVideoInput?.markAsFinished()
                landscapeAudioInput?.markAsFinished()
                let url = landscapeURL
                writer.finishWriting {
                    if writer.status == .completed { finalLandscapeURL = url }
                    group.leave()
                }
            case .failed:
                print("DualLensRecorder: landscape writer interrupted — attempting to salvage file")
                finalLandscapeURL = landscapeURL
            default:
                break
            }
        }

        group.notify(queue: .main) { [weak self] in
            // DIAGNOSTIC: inspect the written files to see what dimensions/transform they have.
            func inspectFile(_ url: URL, label: String) {
                Task {
                    let asset = AVURLAsset(url: url)
                    do {
                        let tracks = try await asset.loadTracks(withMediaType: .video)
                        if let track = tracks.first {
                            let ns = try await track.load(.naturalSize)
                            let tf = try await track.load(.preferredTransform)
                            print("🔬 \(label) POST-WRITE: naturalSize=\(Int(ns.width))×\(Int(ns.height)), transform=[a=\(tf.a) b=\(tf.b) c=\(tf.c) d=\(tf.d) tx=\(tf.tx) ty=\(tf.ty)]")
                        } else {
                            print("🔬 \(label) POST-WRITE: NO VIDEO TRACK FOUND in \(url.lastPathComponent)")
                        }
                    } catch {
                        print("🔬 \(label) POST-WRITE inspect failed: \(error)")
                    }
                }
            }
            if let pURL = finalPortraitURL  { inspectFile(pURL, label: "Portrait file") }
            if let lURL = finalLandscapeURL { inspectFile(lURL, label: "Landscape file") }

            if let pURL = finalPortraitURL, let lURL = finalLandscapeURL {
                self?.completionHandler?(pURL, lURL)
            } else {
                let pErr = self?.portraitWriter?.error?.localizedDescription  ?? ""
                let lErr = self?.landscapeWriter?.error?.localizedDescription ?? ""
                self?.errorHandler?("Recording failed. Portrait: \(pErr) Landscape: \(lErr)")
            }
            self?.cleanupWriters()
        }
    }

    private func cleanupWriters() {
        stabilizationTimeoutItem?.cancel()
        stabilizationTimeoutItem = nil
        wideExposureObservation      = nil
        ultraWideExposureObservation = nil
        exposureUnlockItem?.cancel()
        unlockExposure()
        portraitWriter             = nil
        landscapeWriter            = nil
        portraitVideoInput         = nil
        landscapeVideoInput        = nil
        portraitAudioInput         = nil
        landscapeAudioInput        = nil
        portraitPixelBufferAdaptor = nil
        landscapePixelBufferAdaptor = nil
        portraitPool               = nil
        landscapePool              = nil
        portraitPendingFrames.removeAll()
        landscapePendingFrames.removeAll()
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension DualLensRecorder: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Diagnostic: log every 300th frame so we can confirm the delegate is active
        // and verify output identity. Remove after debugging.
        if output === portraitOutput {
            _portraitFrameCounter += 1
            if _portraitFrameCounter == 1 || _portraitFrameCounter % 300 == 0 {
                var rec = false; writerQueue.sync { rec = self.isRecording }
                print("DualLensRecorder DIAG: portraitOutput frame #\(_portraitFrameCounter), isRecording=\(rec), isPaused=\(isPaused)")
            }
        } else if output === landscapeOutput {
            _landscapeFrameCounter += 1
            if _landscapeFrameCounter == 1 || _landscapeFrameCounter % 300 == 0 {
                var rec = false; writerQueue.sync { rec = self.isRecording }
                print("DualLensRecorder DIAG: landscapeOutput frame #\(_landscapeFrameCounter), isRecording=\(rec), isPaused=\(isPaused)")
            }
        } else {
            print("DualLensRecorder DIAG: captureOutput called with UNKNOWN output — not portrait or landscape!")
        }

        // Check isPaused WITHOUT a writerQueue.sync so the video capture queues
        // are never blocked while recording is paused.  Preview layers have their
        // own direct session connections and stay live independently.
        guard !isPaused else { return }

        if output === portraitOutput {
            processPortraitFrame(sampleBuffer)
        } else if output === landscapeOutput {
            processLandscapeFrame(sampleBuffer)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {}
}
