import AVFoundation
import CoreVideo

/// Records two simultaneous portrait videos — one from the front camera and one from
/// the rear camera — using AVCaptureMultiCamSession.
///
/// Both outputs are portrait (9:16). The front camera is the "primary" output;
/// the rear camera is the "secondary" output.  Audio is written to both files.
final class FrontBackRecorder: NSObject {

    // MARK: - Properties

    private let settings: RecordingSettings
    private let videoProcessor: VideoProcessor
    private let audioManager: AudioManager

    // Writers
    private var frontWriter: AVAssetWriter?
    private var rearWriter:  AVAssetWriter?
    private var frontVideoInput: AVAssetWriterInput?
    private var rearVideoInput:  AVAssetWriterInput?
    private var frontAudioInput: AVAssetWriterInput?
    private var rearAudioInput:  AVAssetWriterInput?
    private var frontAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var rearAdaptor:  AVAssetWriterInputPixelBufferAdaptor?

    // File URLs
    private var frontURL: URL?
    private var rearURL:  URL?

    // Pixel buffer pools
    private var frontPool: CVPixelBufferPool?
    private var rearPool:  CVPixelBufferPool?

    // Pending frames (back-pressure buffer while encoder catches up)
    private var frontPendingFrames: [(CVPixelBuffer, CMTime)] = []
    private var rearPendingFrames:  [(CVPixelBuffer, CMTime)] = []

    // Queues
    private let frontVideoQueue = DispatchQueue(label: "com.evershot.frontback.front.video", qos: .userInitiated)
    private let rearVideoQueue  = DispatchQueue(label: "com.evershot.frontback.rear.video",  qos: .userInitiated)
    private let writerQueue     = DispatchQueue(label: "com.evershot.frontback.writer",      qos: .userInitiated)

    // State
    private var isRecording    = false
    private var sessionStarted = false
    private var sessionStartTimestamp: CMTime = .invalid

    // Per-writer session state (mirrors DualLensRecorder pattern)
    private var frontSessionStarted:   Bool   = false
    private var rearSessionStarted:    Bool   = false
    private var frontSessionTimestamp: CMTime = .invalid
    private var rearSessionTimestamp:  CMTime = .invalid

    // Pause state — wall-clock based, checked without queue sync in captureOutput
    private var isPaused:      Bool   = false
    private var pauseWallStart: Double = 0
    private var pauseOffset:   CMTime = .zero

    // MARK: - AEC Stabilisation Gate
    //
    // Same three-layer defence as DualLensRecorder:
    // 1. KVO gate  — defer startWriting() until both cameras are AEC-stable
    // 2. Exposure lock — lock both cameras simultaneously
    // 3. Frame skip — discard kLeadingFrameSkipCount frames already in pipeline

    private static let kLeadingFrameSkipCount = 5

    private var cameraStabilized = false
    private var frontExposureObservation: NSKeyValueObservation?
    private var rearExposureObservation:  NSKeyValueObservation?
    private var stabilizationTimeoutItem: DispatchWorkItem?

    private var frontDeviceForLock: AVCaptureDevice?
    private var rearDeviceForLock:  AVCaptureDevice?
    private var exposureUnlockItem: DispatchWorkItem?

    private var frontLeadFrameCount = 0
    private var rearLeadFrameCount  = 0

    // Timelapse counters
    private var frontTotalFrames   = 0
    private var rearTotalFrames    = 0
    private var frontWrittenFrames = 0
    private var rearWrittenFrames  = 0

    // Diagnostic: log buffer dims once per session
    private var hasLoggedFrontBufferInfo = false
    private var hasLoggedRearBufferInfo  = false

    // Outputs
    private var frontOutput: AVCaptureVideoDataOutput?
    private var rearOutput:  AVCaptureVideoDataOutput?

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

    func setOutputs(frontOutput: AVCaptureVideoDataOutput, rearOutput: AVCaptureVideoDataOutput) {
        self.frontOutput = frontOutput
        self.rearOutput  = rearOutput
        frontOutput.setSampleBufferDelegate(self, queue: frontVideoQueue)
        rearOutput.setSampleBufferDelegate(self,  queue: rearVideoQueue)
    }

    // MARK: - Recording Control

    func startRecording(frontDevice: AVCaptureDevice?, rearDevice: AVCaptureDevice?) {
        writerQueue.async { [weak self] in
            guard let self = self else { return }
            self.setupWriters()
            self.setupAudioCallback()

            self.isRecording          = true
            self.sessionStarted       = false
            self.sessionStartTimestamp = .invalid
            self.frontSessionStarted  = false
            self.rearSessionStarted   = false
            self.frontSessionTimestamp = .invalid
            self.rearSessionTimestamp  = .invalid
            self.cameraStabilized     = false
            self.frontDeviceForLock   = frontDevice
            self.rearDeviceForLock    = rearDevice
            self.frontLeadFrameCount  = 0
            self.rearLeadFrameCount   = 0
            self.frontTotalFrames     = 0
            self.rearTotalFrames      = 0
            self.frontWrittenFrames   = 0
            self.rearWrittenFrames    = 0
            self.frontPendingFrames.removeAll()
            self.rearPendingFrames.removeAll()
            self.isPaused       = false
            self.pauseWallStart = 0
            self.pauseOffset    = .zero
            self.hasLoggedFrontBufferInfo = false
            self.hasLoggedRearBufferInfo  = false

            let checkBothStable = { [weak self] in
                let frontStable = frontDevice.map { !$0.isAdjustingExposure } ?? true
                let rearStable  = rearDevice.map  { !$0.isAdjustingExposure } ?? true
                if frontStable && rearStable { self?.triggerWriterStart() }
            }

            if let fd = frontDevice {
                self.frontExposureObservation = fd.observe(
                    \.isAdjustingExposure, options: [.initial, .new]
                ) { _, _ in checkBothStable() }
            }
            if let rd = rearDevice {
                self.rearExposureObservation = rd.observe(
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

            self.frontExposureObservation = nil
            self.rearExposureObservation  = nil
            self.stabilizationTimeoutItem?.cancel()
            self.stabilizationTimeoutItem = nil

            for device in [self.frontDeviceForLock, self.rearDeviceForLock].compactMap({ $0 }) {
                do {
                    try device.lockForConfiguration()
                    if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
                    device.unlockForConfiguration()
                } catch {
                    print("FrontBackRecorder: Could not lock exposure on \(device.localizedName): \(error)")
                }
            }

            self.frontWriter?.startWriting()
            self.rearWriter?.startWriting()
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
        for device in [frontDeviceForLock, rearDeviceForLock].compactMap({ $0 }) {
            do {
                try device.lockForConfiguration()
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                device.unlockForConfiguration()
            } catch {
                print("FrontBackRecorder: Could not unlock exposure on \(device.localizedName): \(error)")
            }
        }
        frontDeviceForLock = nil
        rearDeviceForLock  = nil
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
        let fURL = settings.frontFileURL()
        let rURL = settings.rearFileURL()
        frontURL = fURL
        rearURL  = rURL

        let pDims = settings.resolution.portraitDimensions

        do {
            // Front writer (portrait)
            let fWriter     = try AVAssetWriter(outputURL: fURL, fileType: settings.fileFormat.fileType)
            let fVideoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings.portraitVideoSettings)
            fVideoInput.expectsMediaDataInRealTime = true

            let fAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings.audioSettings)
            fAudioInput.expectsMediaDataInRealTime = true

            let fAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: fVideoInput,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey  as String: pDims.width,
                    kCVPixelBufferHeightKey as String: pDims.height
                ]
            )

            if fWriter.canAdd(fVideoInput) { fWriter.add(fVideoInput) }
            if fWriter.canAdd(fAudioInput) { fWriter.add(fAudioInput) }

            frontWriter      = fWriter
            frontVideoInput  = fVideoInput
            frontAudioInput  = fAudioInput
            frontAdaptor     = fAdaptor

            // Rear writer (also portrait)
            let rWriter     = try AVAssetWriter(outputURL: rURL, fileType: settings.fileFormat.fileType)
            let rVideoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings.portraitVideoSettings)
            rVideoInput.expectsMediaDataInRealTime = true

            let rAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings.audioSettings)
            rAudioInput.expectsMediaDataInRealTime = true

            let rAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: rVideoInput,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey  as String: pDims.width,
                    kCVPixelBufferHeightKey as String: pDims.height
                ]
            )

            if rWriter.canAdd(rVideoInput) { rWriter.add(rVideoInput) }
            if rWriter.canAdd(rAudioInput) { rWriter.add(rAudioInput) }

            rearWriter      = rWriter
            rearVideoInput  = rVideoInput
            rearAudioInput  = rAudioInput
            rearAdaptor     = rAdaptor

            frontPool = VideoProcessor.createPixelBufferPool(width: pDims.width, height: pDims.height)
            rearPool  = VideoProcessor.createPixelBufferPool(width: pDims.width, height: pDims.height)

        } catch {
            print("FrontBackRecorder: Failed to create writers: \(error)")
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

                if let a = self.frontAudioInput, a.isReadyForMoreMediaData, self.frontWriter?.status == .writing { a.append(sampleBuffer) }
                if let a = self.rearAudioInput,  a.isReadyForMoreMediaData, self.rearWriter?.status  == .writing { a.append(sampleBuffer) }
            }
        }
    }

    // MARK: - Per-Writer Session Management

    private func startFrontSessionIfNeeded(at timestamp: CMTime) {
        guard !frontSessionStarted, frontWriter?.status == .writing else { return }
        frontWriter?.startSession(atSourceTime: timestamp)
        frontSessionTimestamp = timestamp
        frontSessionStarted   = true
        checkBothSessionsStarted()
    }

    private func startRearSessionIfNeeded(at timestamp: CMTime) {
        guard !rearSessionStarted, rearWriter?.status == .writing else { return }
        rearWriter?.startSession(atSourceTime: timestamp)
        rearSessionTimestamp = timestamp
        rearSessionStarted   = true
        checkBothSessionsStarted()
    }

    private func checkBothSessionsStarted() {
        guard frontSessionStarted && rearSessionStarted else { return }
        sessionStarted = true
        sessionStartTimestamp = CMTIME_IS_VALID(frontSessionTimestamp) && CMTIME_IS_VALID(rearSessionTimestamp)
            ? CMTimeMinimum(frontSessionTimestamp, rearSessionTimestamp)
            : (CMTIME_IS_VALID(frontSessionTimestamp) ? frontSessionTimestamp : rearSessionTimestamp)
    }

    private func clampedFrontTimestamp(_ pts: CMTime) -> CMTime {
        guard frontSessionStarted, CMTIME_IS_VALID(frontSessionTimestamp) else { return pts }
        return CMTimeMaximum(pts, frontSessionTimestamp)
    }

    private func clampedRearTimestamp(_ pts: CMTime) -> CMTime {
        guard rearSessionStarted, CMTIME_IS_VALID(rearSessionTimestamp) else { return pts }
        return CMTimeMaximum(pts, rearSessionTimestamp)
    }

    // MARK: - Process Frames

    private func processFrontFrame(_ sampleBuffer: CMSampleBuffer) {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        var shouldWrite = false
        var skipTimelapse = false
        writerQueue.sync {
            guard isRecording, cameraStabilized else { return }
            frontLeadFrameCount += 1
            guard frontLeadFrameCount > FrontBackRecorder.kLeadingFrameSkipCount else { return }
            startFrontSessionIfNeeded(at: timestamp)
            shouldWrite = frontSessionStarted
            if shouldWrite && settings.isTimelapse {
                frontTotalFrames += 1
                skipTimelapse = (frontTotalFrames % settings.timelapseSpeed.skipInterval != 0)
            }
        }

        guard shouldWrite && !skipTimelapse else { return }
        guard let rawPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Orientation normalisation (defensive — front cam usually delivers portrait)
        let bufW = CVPixelBufferGetWidth(rawPixelBuffer)
        let bufH = CVPixelBufferGetHeight(rawPixelBuffer)
        if !hasLoggedFrontBufferInfo {
            hasLoggedFrontBufferInfo = true
            print("🎥 FrontBackRecorder [FRONT] first frame: \(bufW)×\(bufH) — " +
                  (bufW > bufH ? "NATIVE LANDSCAPE — rotating 90° CCW" : "PORTRAIT ✓"))
        }

        let pixelBuffer: CVPixelBuffer
        if bufW > bufH {
            guard let rotated = videoProcessor.rotatedCCW90(rawPixelBuffer) else { return }
            pixelBuffer = rotated
        } else {
            pixelBuffer = rawPixelBuffer
        }

        let dims = settings.resolution.portraitDimensions
        guard let croppedBuffer = videoProcessor.cropAndScale(
            pixelBuffer: pixelBuffer, toWidth: dims.width, toHeight: dims.height, pool: frontPool
        ) else { return }

        writerQueue.async { [weak self] in
            guard let self = self,
                  let input = self.frontVideoInput,
                  self.frontWriter?.status == .writing else { return }

            let pts: CMTime
            if self.settings.isTimelapse {
                let fps = CMTimeScale(self.settings.frameRate.rawValue)
                pts = CMTimeAdd(self.frontSessionTimestamp,
                                CMTime(value: CMTimeValue(self.frontWrittenFrames), timescale: fps))
                self.frontWrittenFrames += 1
            } else {
                pts = CMTimeSubtract(self.clampedFrontTimestamp(timestamp), self.pauseOffset)
            }

            var flushed = 0
            while flushed < self.frontPendingFrames.count, input.isReadyForMoreMediaData {
                let (buf, t) = self.frontPendingFrames[flushed]
                self.frontAdaptor?.append(buf, withPresentationTime: t); flushed += 1
            }
            if flushed > 0 { self.frontPendingFrames.removeFirst(flushed) }

            if input.isReadyForMoreMediaData {
                self.frontAdaptor?.append(croppedBuffer, withPresentationTime: pts)
            } else if self.frontPendingFrames.count < 60 {
                self.frontPendingFrames.append((croppedBuffer, pts))
            }
        }
    }

    private func processRearFrame(_ sampleBuffer: CMSampleBuffer) {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        var shouldWrite = false
        var skipTimelapse = false
        writerQueue.sync {
            guard isRecording, cameraStabilized else { return }
            rearLeadFrameCount += 1
            guard rearLeadFrameCount > FrontBackRecorder.kLeadingFrameSkipCount else { return }
            startRearSessionIfNeeded(at: timestamp)
            shouldWrite = rearSessionStarted
            if shouldWrite && settings.isTimelapse {
                rearTotalFrames += 1
                skipTimelapse = (rearTotalFrames % settings.timelapseSpeed.skipInterval != 0)
            }
        }

        guard shouldWrite && !skipTimelapse else { return }
        guard let rawPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Rear camera in MultiCam may deliver native landscape — normalise
        let bufW = CVPixelBufferGetWidth(rawPixelBuffer)
        let bufH = CVPixelBufferGetHeight(rawPixelBuffer)
        if !hasLoggedRearBufferInfo {
            hasLoggedRearBufferInfo = true
            print("🎥 FrontBackRecorder [REAR] first frame: \(bufW)×\(bufH) — " +
                  (bufW > bufH ? "NATIVE LANDSCAPE — rotating 90° CCW" : "PORTRAIT ✓"))
        }

        let pixelBuffer: CVPixelBuffer
        if bufW > bufH {
            guard let rotated = videoProcessor.rotatedCCW90(rawPixelBuffer) else { return }
            pixelBuffer = rotated
        } else {
            pixelBuffer = rawPixelBuffer
        }

        let dims = settings.resolution.portraitDimensions
        guard let croppedBuffer = videoProcessor.cropAndScale(
            pixelBuffer: pixelBuffer, toWidth: dims.width, toHeight: dims.height, pool: rearPool
        ) else { return }

        writerQueue.async { [weak self] in
            guard let self = self,
                  let input = self.rearVideoInput,
                  self.rearWriter?.status == .writing else { return }

            let pts: CMTime
            if self.settings.isTimelapse {
                let fps = CMTimeScale(self.settings.frameRate.rawValue)
                pts = CMTimeAdd(self.rearSessionTimestamp,
                                CMTime(value: CMTimeValue(self.rearWrittenFrames), timescale: fps))
                self.rearWrittenFrames += 1
            } else {
                pts = CMTimeSubtract(self.clampedRearTimestamp(timestamp), self.pauseOffset)
            }

            var flushed = 0
            while flushed < self.rearPendingFrames.count, input.isReadyForMoreMediaData {
                let (buf, t) = self.rearPendingFrames[flushed]
                self.rearAdaptor?.append(buf, withPresentationTime: t); flushed += 1
            }
            if flushed > 0 { self.rearPendingFrames.removeFirst(flushed) }

            if input.isReadyForMoreMediaData {
                self.rearAdaptor?.append(croppedBuffer, withPresentationTime: pts)
            } else if self.rearPendingFrames.count < 60 {
                self.rearPendingFrames.append((croppedBuffer, pts))
            }
        }
    }

    // MARK: - Finish Writing

    private func finishWriting() {
        let anySessionStarted = frontSessionStarted || rearSessionStarted
        guard anySessionStarted else {
            stabilizationTimeoutItem?.cancel()
            stabilizationTimeoutItem = nil
            frontExposureObservation = nil
            rearExposureObservation  = nil
            exposureUnlockItem?.cancel()
            unlockExposure()
            frontWriter?.cancelWriting()
            rearWriter?.cancelWriting()
            cleanupWriters()
            errorHandler?("Recording stopped before it could start.")
            return
        }

        exposureUnlockItem?.cancel()
        unlockExposure()

        let group = DispatchGroup()
        var finalFrontURL: URL?
        var finalRearURL:  URL?

        if let writer = frontWriter {
            switch writer.status {
            case .writing:
                group.enter()
                frontVideoInput?.markAsFinished()
                frontAudioInput?.markAsFinished()
                let url = frontURL
                writer.finishWriting {
                    if writer.status == .completed { finalFrontURL = url }
                    group.leave()
                }
            case .failed:
                print("FrontBackRecorder: front writer interrupted — attempting to salvage")
                finalFrontURL = frontURL
            default: break
            }
        }

        if let writer = rearWriter {
            switch writer.status {
            case .writing:
                group.enter()
                rearVideoInput?.markAsFinished()
                rearAudioInput?.markAsFinished()
                let url = rearURL
                writer.finishWriting {
                    if writer.status == .completed { finalRearURL = url }
                    group.leave()
                }
            case .failed:
                print("FrontBackRecorder: rear writer interrupted — attempting to salvage")
                finalRearURL = rearURL
            default: break
            }
        }

        group.notify(queue: .main) { [weak self] in
            if let fURL = finalFrontURL, let rURL = finalRearURL {
                self?.completionHandler?(fURL, rURL)
            } else {
                let fErr = self?.frontWriter?.error?.localizedDescription ?? ""
                let rErr = self?.rearWriter?.error?.localizedDescription  ?? ""
                self?.errorHandler?("Recording failed. Front: \(fErr) Rear: \(rErr)")
            }
            self?.cleanupWriters()
        }
    }

    private func cleanupWriters() {
        stabilizationTimeoutItem?.cancel()
        stabilizationTimeoutItem = nil
        frontExposureObservation = nil
        rearExposureObservation  = nil
        exposureUnlockItem?.cancel()
        unlockExposure()
        frontWriter      = nil
        rearWriter       = nil
        frontVideoInput  = nil
        rearVideoInput   = nil
        frontAudioInput  = nil
        rearAudioInput   = nil
        frontAdaptor     = nil
        rearAdaptor      = nil
        frontPool        = nil
        rearPool         = nil
        frontPendingFrames.removeAll()
        rearPendingFrames.removeAll()
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension FrontBackRecorder: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard !isPaused else { return }

        if output === frontOutput {
            processFrontFrame(sampleBuffer)
        } else if output === rearOutput {
            processRearFrame(sampleBuffer)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {}
}
