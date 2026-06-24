import AVFoundation
import CoreImage
import CoreVideo

/// Records two video files (portrait and landscape) from a single camera
/// by cropping the same sensor feed into two different aspect ratios.
final class SingleLensRecorder: NSObject {

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

    private var portraitPendingFrames:  [(CVPixelBuffer, CMTime)] = []
    private var landscapePendingFrames: [(CVPixelBuffer, CMTime)] = []

    // Queues
    private let videoQueue  = DispatchQueue(label: "com.evershot.single.video",  qos: .userInitiated)
    private let writerQueue = DispatchQueue(label: "com.evershot.single.writer", qos: .userInitiated)

    // State
    private var isRecording = false
    private var sessionStarted = false
    private var sessionStartTimestamp: CMTime = .invalid
    private var cameraStabilized = false

    // Pause state — wall-clock based, checked without queue sync in captureOutput
    private var isPaused      = false
    private var pauseWallStart: Double = 0
    private var pauseOffset:    CMTime = .zero
    private var exposureObservation:      NSKeyValueObservation?
    private var stabilizationTimeoutItem: DispatchWorkItem?

    private static let kLeadingFrameSkipCount = 5
    private var deviceForLock:      AVCaptureDevice?
    private var exposureUnlockItem: DispatchWorkItem?
    private var leadFrameCount = 0

    // Timelapse counters
    private var totalFrames   = 0
    private var writtenFrames = 0

    // Output
    private var videoOutput: AVCaptureVideoDataOutput?

    // Native landscape output — when set (front camera path), landscape frames arrive
    // pre-rotated at .landscapeRight orientation so no crop/upscale is needed.
    // When nil (rear wide-only path), landscape is derived by cropping the portrait buffer.
    private var nativeLandscapeOutput: AVCaptureVideoDataOutput?

    // Lead-frame skip for the native landscape path (mirrors the portrait path skip).
    private var landscapeLeadFrameCount = 0
    private var hasLoggedLandscapeBufferInfo = false

    // Completion handlers
    private var completionHandler: ((URL, URL) -> Void)?
    private var errorHandler: ((String) -> Void)?

    // Diagnostic: log buffer dimensions once per recording session.
    private var hasLoggedBufferInfo = false

    var onPreviewFrame: ((CGImage) -> Void)?

    private var previewFrameCounter = 0
    // Deliver a preview frame every 2nd frame (~15 fps at 30 fps) — enough for
    // a smooth-looking thumbnail without the full per-frame CGImage overhead.
    private static let kPreviewFrameInterval = 2

    // MARK: - Init

    init(settings: RecordingSettings, videoProcessor: VideoProcessor, audioManager: AudioManager) {
        self.settings = settings
        self.videoProcessor = videoProcessor
        self.audioManager = audioManager
        super.init()
    }

    // MARK: - Output Assignment

    func setOutput(_ output: AVCaptureVideoDataOutput) {
        videoOutput = output
        output.setSampleBufferDelegate(self, queue: videoQueue)
    }

    /// Assigns a separate native-landscape output (front camera only).
    /// Frames arriving on this output are already in landscapeRight orientation
    /// (1920×1080) — no rotation or upscale needed — giving full-FOV landscape.
    func setNativeLandscapeOutput(_ output: AVCaptureVideoDataOutput) {
        nativeLandscapeOutput = output
        output.setSampleBufferDelegate(self, queue: videoQueue)
    }

    // MARK: - Recording Control

    func startRecording(device: AVCaptureDevice) {
        writerQueue.async { [weak self] in
            guard let self = self else { return }
            self.setupWriters()
            self.setupAudioCallback()

            self.isRecording           = true
            self.sessionStarted        = false
            self.sessionStartTimestamp = .invalid
            self.cameraStabilized      = false
            self.deviceForLock         = device
            self.leadFrameCount        = 0
            self.landscapeLeadFrameCount = 0
            self.totalFrames           = 0
            self.writtenFrames         = 0
            // Defensive reset — cleanupWriters normally clears these but reset here
            // too to prevent stale frames from a previous recording bleeding in.
            self.portraitPendingFrames.removeAll()
            self.landscapePendingFrames.removeAll()
            self.isPaused       = false
            self.pauseWallStart = 0
            self.pauseOffset    = .zero
            self.hasLoggedBufferInfo         = false
            self.hasLoggedLandscapeBufferInfo = false

            self.exposureObservation = device.observe(
                \.isAdjustingExposure, options: [.initial, .new]
            ) { [weak self] dev, _ in
                if !dev.isAdjustingExposure { self?.triggerWriterStart() }
            }

            let timeout = DispatchWorkItem { [weak self] in self?.triggerWriterStart() }
            self.stabilizationTimeoutItem = timeout
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 2.0, execute: timeout)
        }
    }

    private func triggerWriterStart() {
        writerQueue.async { [weak self] in
            guard let self = self, self.isRecording, !self.cameraStabilized else { return }

            self.exposureObservation = nil
            self.stabilizationTimeoutItem?.cancel()
            self.stabilizationTimeoutItem = nil

            if let device = self.deviceForLock {
                do {
                    try device.lockForConfiguration()
                    if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
                    device.unlockForConfiguration()
                } catch {
                    print("SingleLensRecorder: Could not lock exposure: \(error)")
                }
            }

            self.portraitWriter?.startWriting()
            self.landscapeWriter?.startWriting()
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
        guard let device = deviceForLock else { return }
        do {
            try device.lockForConfiguration()
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.unlockForConfiguration()
        } catch {
            print("SingleLensRecorder: Could not unlock exposure: \(error)")
        }
        deviceForLock      = nil
        exposureUnlockItem = nil
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
            self.isPaused = true
        }
    }

    func resume() {
        writerQueue.async { [weak self] in
            guard let self = self, self.isRecording, self.isPaused else { return }
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

            let lWriter     = try AVAssetWriter(outputURL: lURL, fileType: settings.fileFormat.fileType)
            let lVideoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings.landscapeVideoSettings)
            lVideoInput.expectsMediaDataInRealTime = true

            // When using native landscape output (front camera dual-output path), the raw
            // .landscapeRight frames arrive with the person rotated 90° CW (head on right).
            // Rather than paying the cost of rotating every pixel buffer, we set a display
            // transform on the writer input.  Media players (iOS Photos, QuickTime, etc.)
            // read this transform and rotate the video CCW90 on playback so the person
            // appears upright — exactly the same mechanism iOS uses for selfie portrait videos.
            if nativeLandscapeOutput != nil {
                lVideoInput.transform = CGAffineTransform(rotationAngle: .pi / 2)
            }

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

        } catch {
            print("SingleLensRecorder: Failed to create writers: \(error)")
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

    // MARK: - Session
    //
    // SingleLensRecorder derives both portrait and landscape from the same source
    // sample buffer, so both writers always share the same first-frame PTS.
    // A single shared startSession call is correct here (unlike DualLensRecorder
    // where two physically separate cameras can deliver their first frames at
    // slightly different times).

    private func startSessionIfNeeded(at timestamp: CMTime) {
        guard !sessionStarted else { return }
        guard portraitWriter?.status == .writing, landscapeWriter?.status == .writing else { return }
        portraitWriter?.startSession(atSourceTime: timestamp)
        landscapeWriter?.startSession(atSourceTime: timestamp)
        sessionStartTimestamp = timestamp
        sessionStarted = true
    }

    private func clampedTimestamp(_ pts: CMTime) -> CMTime {
        guard sessionStarted, CMTIME_IS_VALID(sessionStartTimestamp) else { return pts }
        return CMTimeMaximum(pts, sessionStartTimestamp)
    }

    // MARK: - Process Frame

    private func processFrame(_ sampleBuffer: CMSampleBuffer) {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        var shouldWrite = false
        var skipTimelapse = false
        writerQueue.sync {
            guard isRecording, cameraStabilized else { return }

            leadFrameCount += 1
            guard leadFrameCount > SingleLensRecorder.kLeadingFrameSkipCount else { return }

            startSessionIfNeeded(at: timestamp)
            shouldWrite = sessionStarted
            if shouldWrite && settings.isTimelapse {
                totalFrames += 1
                skipTimelapse = (totalFrames % settings.timelapseSpeed.skipInterval != 0)
            }
        }

        guard shouldWrite && !skipTimelapse else { return }
        guard let rawPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Normalise buffer orientation (same logic as DualLensRecorder).
        // A standard AVCaptureSession with videoOrientation = .portrait normally
        // delivers physically-rotated portrait buffers, but log + normalise defensively.
        let bufW = CVPixelBufferGetWidth(rawPixelBuffer)
        let bufH = CVPixelBufferGetHeight(rawPixelBuffer)
        if !hasLoggedBufferInfo {
            hasLoggedBufferInfo = true
            print("🎥 SingleLensRecorder first frame: \(bufW)×\(bufH) — " +
                  (bufW > bufH ? "NATIVE LANDSCAPE — rotating 90° CCW" : "PORTRAIT ✓"))
        }

        let pixelBuffer: CVPixelBuffer
        if bufW > bufH {
            guard let rotated = videoProcessor.rotatedCCW90(rawPixelBuffer) else { return }
            pixelBuffer = rotated
        } else {
            pixelBuffer = rawPixelBuffer
        }

        let pDims = settings.resolution.portraitDimensions
        let portraitBuffer = videoProcessor.cropAndScale(
            pixelBuffer: pixelBuffer, toWidth: pDims.width, toHeight: pDims.height, pool: portraitPool
        )

        // When a native landscape output is connected (front camera dual-output path),
        // landscape frames are written from processNativeLandscapeFrame instead.
        // Skip the crop-from-portrait path to avoid writing landscape twice.
        let lDims = settings.resolution.landscapeDimensions
        let landscapeBuffer: CVPixelBuffer?
        if nativeLandscapeOutput == nil {
            landscapeBuffer = videoProcessor.cropAndScale(
                pixelBuffer: pixelBuffer, toWidth: lDims.width, toHeight: lDims.height,
                pool: landscapePool
            )
        } else {
            landscapeBuffer = nil
        }

        writerQueue.async { [weak self] in
            guard let self = self else { return }

            let pts: CMTime
            if self.settings.isTimelapse {
                let fps = CMTimeScale(self.settings.frameRate.rawValue)
                pts = CMTimeAdd(self.sessionStartTimestamp,
                                CMTime(value: CMTimeValue(self.writtenFrames), timescale: fps))
                self.writtenFrames += 1
            } else {
                pts = CMTimeSubtract(self.clampedTimestamp(timestamp), self.pauseOffset)
            }

            if let buf = portraitBuffer, let pInput = self.portraitVideoInput,
               self.portraitWriter?.status == .writing {
                var flushed = 0
                while flushed < self.portraitPendingFrames.count, pInput.isReadyForMoreMediaData {
                    let (b, t) = self.portraitPendingFrames[flushed]
                    self.portraitPixelBufferAdaptor?.append(b, withPresentationTime: t); flushed += 1
                }
                if flushed > 0 { self.portraitPendingFrames.removeFirst(flushed) }
                if pInput.isReadyForMoreMediaData { self.portraitPixelBufferAdaptor?.append(buf, withPresentationTime: pts) }
                else if self.portraitPendingFrames.count < 60 { self.portraitPendingFrames.append((buf, pts)) }
            }

            if let buf = landscapeBuffer, let lInput = self.landscapeVideoInput,
               self.landscapeWriter?.status == .writing {
                var flushed = 0
                while flushed < self.landscapePendingFrames.count, lInput.isReadyForMoreMediaData {
                    let (b, t) = self.landscapePendingFrames[flushed]
                    self.landscapePixelBufferAdaptor?.append(b, withPresentationTime: t); flushed += 1
                }
                if flushed > 0 { self.landscapePendingFrames.removeFirst(flushed) }
                if lInput.isReadyForMoreMediaData { self.landscapePixelBufferAdaptor?.append(buf, withPresentationTime: pts) }
                else if self.landscapePendingFrames.count < 60 { self.landscapePendingFrames.append((buf, pts)) }
            }
        }
    }

    // MARK: - Native Landscape Frame Processing
    //
    // Called when frames arrive on the separate landscapeOutput (front camera path).
    // Those frames are already in landscapeRight orientation (1920×1080) so no rotation
    // or upscale is needed — we just crop/scale to the exact target landscape dimensions.

    private func processNativeLandscapeFrame(_ sampleBuffer: CMSampleBuffer) {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        var shouldWrite = false
        var skipTimelapse = false
        writerQueue.sync {
            guard isRecording, cameraStabilized else { return }
            landscapeLeadFrameCount += 1
            guard landscapeLeadFrameCount > SingleLensRecorder.kLeadingFrameSkipCount else { return }
            // Start both writer sessions (portrait + landscape) from whichever output
            // delivers its first usable frame first — they're in perfect lockstep.
            startSessionIfNeeded(at: timestamp)
            shouldWrite = sessionStarted
            if shouldWrite && settings.isTimelapse {
                // Timelapse skip is gated on the portrait counter; landscape skips the
                // same frames by checking divisibility at the same total-frame index.
                skipTimelapse = (totalFrames % settings.timelapseSpeed.skipInterval != 0)
            }
        }

        guard shouldWrite && !skipTimelapse else { return }
        guard let rawPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        if !hasLoggedLandscapeBufferInfo {
            hasLoggedLandscapeBufferInfo = true
            let w = CVPixelBufferGetWidth(rawPixelBuffer)
            let h = CVPixelBufferGetHeight(rawPixelBuffer)
            print("🎥 SingleLensRecorder [LANDSCAPE] first frame: \(w)×\(h) — " +
                  (w >= h ? "LANDSCAPE ✓ (native .landscapeRight, full FOV — rotating CW90 to upright)" :
                            "PORTRAIT ⚠️ — check landscapeOutput connection orientation"))
        }

        // Frames from .landscapeRight are already 1920×1080 landscape — no pixel rotation
        // needed.  The writer has a CCW90 display transform so players show person upright.
        let lDims = settings.resolution.landscapeDimensions
        guard let landscapeBuffer = videoProcessor.cropAndScale(
            pixelBuffer: rawPixelBuffer, toWidth: lDims.width, toHeight: lDims.height,
            pool: landscapePool
        ) else { return }

        writerQueue.async { [weak self] in
            guard let self = self,
                  let lInput = self.landscapeVideoInput,
                  self.landscapeWriter?.status == .writing else { return }

            let pts: CMTime
            if self.settings.isTimelapse {
                // Use portrait writtenFrames as the reference so both files stay in sync.
                let fps = CMTimeScale(self.settings.frameRate.rawValue)
                pts = CMTimeAdd(self.sessionStartTimestamp,
                                CMTime(value: CMTimeValue(self.writtenFrames - 1), timescale: fps))
            } else {
                pts = CMTimeSubtract(self.clampedTimestamp(timestamp), self.pauseOffset)
            }

            var flushed = 0
            while flushed < self.landscapePendingFrames.count, lInput.isReadyForMoreMediaData {
                let (b, t) = self.landscapePendingFrames[flushed]
                self.landscapePixelBufferAdaptor?.append(b, withPresentationTime: t)
                flushed += 1
            }
            if flushed > 0 { self.landscapePendingFrames.removeFirst(flushed) }

            if lInput.isReadyForMoreMediaData {
                self.landscapePixelBufferAdaptor?.append(landscapeBuffer, withPresentationTime: pts)
            } else if self.landscapePendingFrames.count < 60 {
                self.landscapePendingFrames.append((landscapeBuffer, pts))
            }
        }
    }

    // MARK: - Finish Writing

    private func finishWriting() {
        guard sessionStarted else {
            stabilizationTimeoutItem?.cancel()
            stabilizationTimeoutItem = nil
            exposureObservation = nil
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
                print("SingleLensRecorder: portrait writer interrupted — attempting to salvage file")
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
                print("SingleLensRecorder: landscape writer interrupted — attempting to salvage file")
                finalLandscapeURL = landscapeURL
            default:
                break
            }
        }

        group.notify(queue: .main) { [weak self] in
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
        exposureObservation = nil
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

extension SingleLensRecorder: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Native landscape output (front camera dual-output path).
        // These frames use the full sensor width — the widest available FOV —
        // because the .landscapeRight connection captures the entire ultrawide sensor
        // horizontally (whereas the .portrait connection only captures a vertical
        // center-crop of that same sensor, which is inherently narrower).
        //
        // We generate the PiP thumbnail here so it shows the maximum FOV rather
        // than the cropped portrait view.  The person arrives lying on their side
        // (head on the right in the 1920×1080 frame, matching the .pi/2 writer
        // display transform below).  We apply the same CCW90 CIImage rotation
        // used by the writer-transform logic so the person appears upright, then
        // crop the centre 16:9 strip to produce a landscape thumbnail.
        if output === nativeLandscapeOutput {
            // PiP generation runs even while paused — keep the thumbnail live.
            previewFrameCounter += 1
            if let callback = onPreviewFrame,
               previewFrameCounter % SingleLensRecorder.kPreviewFrameInterval == 0,
               let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {

                let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
                let srcW = ciImage.extent.width   // landscape width  (e.g. 1920)
                let srcH = ciImage.extent.height  // landscape height (e.g. 1080)

                if srcW >= srcH {
                    // Landscape frame — rotate CCW90 so the person's head, which is
                    // on the RIGHT of the landscape frame, moves to the TOP.
                    // CIImage uses bottom-left origin; .pi/2 = 90° CCW in math coords.
                    // After the rotation all x values are negative; translate right by
                    // srcH to restore positive coordinates.
                    let rotated = ciImage
                        .transformed(by: CGAffineTransform(rotationAngle: .pi / 2))
                        .transformed(by: CGAffineTransform(translationX: srcH, y: 0))
                    // Rotated extent: (0, 0, srcH, srcW) — portrait-shaped, person upright.
                    let rW = srcH  // portrait width  = landscape height (e.g. 1080)
                    let rH = srcW  // portrait height = landscape width  (e.g. 1920)

                    // The ultrawide front camera delivers frames that are horizontally
                    // mirrored relative to the standard front camera.  Flip so the
                    // PiP thumbnail matches what the recorded landscape file looks like.
                    // scaleX: -1 flips around x=0; translate right by rW to restore
                    // positive coordinate space. Extent remains (0, 0, rW, rH).
                    let flipped = rotated
                        .transformed(by: CGAffineTransform(scaleX: -1, y: 1)
                            .concatenating(CGAffineTransform(translationX: rW, y: 0)))

                    // Crop the centre 16:9 strip for a landscape PiP thumbnail.
                    let cropH   = (rW * 9.0 / 16.0).rounded()
                    let offsetY = ((rH - cropH) / 2.0).rounded()
                    let cropRect = CGRect(x: 0, y: offsetY, width: rW, height: cropH)
                    let cropped = flipped
                        .cropped(to: cropRect)
                        .transformed(by: CGAffineTransform(translationX: 0, y: -offsetY))

                    // Scale to 621 px wide (≈3× the PiP display width at 3× scale).
                    let scale  = 621.0 / rW
                    let scaled = cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    if let cgImage = videoProcessor.ciContext.createCGImage(scaled, from: scaled.extent) {
                        callback(cgImage)
                    }
                }
            }

            guard !isPaused else { return }
            processNativeLandscapeFrame(sampleBuffer)
            return
        }

        // Portrait output — used for portrait file recording only.
        // PiP is generated from the landscape output above (wider FOV).
        // For the rear-camera single-lens mode (no nativeLandscapeOutput), we do
        // still generate a PiP here as a fallback.
        if onPreviewFrame != nil && nativeLandscapeOutput == nil {
            previewFrameCounter += 1
            if let callback = onPreviewFrame,
               previewFrameCounter % SingleLensRecorder.kPreviewFrameInterval == 0,
               let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
                let srcW = ciImage.extent.width
                let srcH = ciImage.extent.height
                if srcH > srcW {
                    // Portrait frame: crop centre 16:9 strip for landscape PiP.
                    let cropH   = (srcW * 9.0 / 16.0).rounded()
                    let offsetY = ((srcH - cropH) / 2.0).rounded()
                    let cropRect = CGRect(x: 0, y: offsetY, width: srcW, height: cropH)
                    let cropped  = ciImage
                        .cropped(to: cropRect)
                        .transformed(by: CGAffineTransform(translationX: 0, y: -offsetY))
                    let scale  = 621.0 / srcW
                    let scaled = cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    if let cgImage = videoProcessor.ciContext.createCGImage(scaled, from: scaled.extent) {
                        callback(cgImage)
                    }
                } else {
                    // Landscape or square frame (rear single-lens mode).
                    let scale  = 621.0 / srcW
                    let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    if let cgImage = videoProcessor.ciContext.createCGImage(scaled, from: scaled.extent) {
                        callback(cgImage)
                    }
                }
            }
        }

        // Skip writing when paused — checked without writerQueue.sync so the
        // video queue stays unblocked and the main preview layer stays live.
        guard !isPaused else { return }
        processFrame(sampleBuffer)
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {}
}
