import AVFoundation
import CoreVideo
import CoreImage
import UIKit

/// Records Front/Back mode as a SINGLE composited portrait video.
///
/// The "main" camera fills the 9:16 canvas and the other camera is rendered as a
/// rounded picture-in-picture in the top-right corner (Apple multicam-PiP style).
/// Front is main by default; the main/PiP roles can be swapped LIVE at any time —
/// including mid-recording — via `setMainIsFront(_:)`.
///
/// The front camera's frames drive the output cadence; the most recent rear frame is
/// cached and composited into each output frame. One AVAssetWriter → one file.
final class FrontBackRecorder: NSObject {

    // MARK: - Dependencies

    private let settings: RecordingSettings
    private let videoProcessor: VideoProcessor
    private let audioManager: AudioManager

    // MARK: - Single Writer

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var url: URL?

    // Pools
    private var compositePool: CVPixelBufferPool?
    private var frontNormPool: CVPixelBufferPool?
    private var rearNormPool:  CVPixelBufferPool?

    private var pendingFrames: [(CVPixelBuffer, CMTime)] = []

    // MARK: - Queues

    private let frontVideoQueue = DispatchQueue(label: "com.evershot.fb.front.video", qos: .userInitiated)
    private let rearVideoQueue  = DispatchQueue(label: "com.evershot.fb.rear.video",  qos: .userInitiated)
    private let writerQueue     = DispatchQueue(label: "com.evershot.fb.writer",      qos: .userInitiated)

    // Latest rear frame (normalized portrait full) — produced on the rear queue,
    // consumed on the front (driver) queue. Guarded by a small lock.
    private let rearLock = NSLock()
    private var latestRearBuffer: CVPixelBuffer?

    /// Which camera is fullscreen. true = front main / rear PiP. Bool reads/writes are
    /// atomic on ARM64; at worst one frame around a live swap uses the previous role,
    /// which is imperceptible.
    private var _mainIsFront = true
    func setMainIsFront(_ value: Bool) { _mainIsFront = value }

    // MARK: - State

    private var isRecording = false
    private var sessionStarted = false
    private var sessionStartTimestamp: CMTime = .invalid

    // Pause (wall-clock based)
    private var isPaused = false
    private var pauseWallStart: Double = 0
    private var pauseOffset: CMTime = .zero

    // MARK: - AEC stabilisation gate (mirrors DualLensRecorder)

    private static let kLeadingFrameSkipCount = 5

    private var cameraStabilized = false
    private var frontExposureObservation: NSKeyValueObservation?
    private var rearExposureObservation:  NSKeyValueObservation?
    private var stabilizationTimeoutItem: DispatchWorkItem?
    private var frontDeviceForLock: AVCaptureDevice?
    private var rearDeviceForLock:  AVCaptureDevice?
    private var exposureUnlockItem: DispatchWorkItem?
    private var leadFrameCount = 0

    private var hasLoggedInfo = false

    // MARK: - PiP geometry / cached overlays (built in setupWriter)

    private var pipRect: CGRect = .zero
    private var pipMaskImage: CIImage?     // white rounded rect (alpha mask), translated to pipRect
    private var pipBorderImage: CIImage?   // white rounded stroke, translated to pipRect

    // MARK: - Outputs

    private var frontOutput: AVCaptureVideoDataOutput?
    private var rearOutput:  AVCaptureVideoDataOutput?

    // MARK: - Completion

    private var completionHandler: ((URL) -> Void)?
    private var errorHandler: ((String) -> Void)?

    private let deviceRGB = CGColorSpaceCreateDeviceRGB()

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
            self.setupWriter()
            self.setupAudioCallback()

            self.isRecording           = true
            self.sessionStarted        = false
            self.sessionStartTimestamp = .invalid
            self.cameraStabilized      = false
            self.frontDeviceForLock    = frontDevice
            self.rearDeviceForLock     = rearDevice
            self.leadFrameCount        = 0
            self.pendingFrames.removeAll()
            self.isPaused       = false
            self.pauseWallStart = 0
            self.pauseOffset    = .zero
            self.hasLoggedInfo  = false
            self.rearLock.lock(); self.latestRearBuffer = nil; self.rearLock.unlock()

            let checkBothStable = { [weak self] in
                let fStable = frontDevice.map { !$0.isAdjustingExposure } ?? true
                let rStable = rearDevice.map  { !$0.isAdjustingExposure } ?? true
                if fStable && rStable { self?.triggerWriterStart() }
            }
            if let fd = frontDevice {
                self.frontExposureObservation = fd.observe(\.isAdjustingExposure, options: [.initial, .new]) { _, _ in checkBothStable() }
            }
            if let rd = rearDevice {
                self.rearExposureObservation = rd.observe(\.isAdjustingExposure, options: [.initial, .new]) { _, _ in checkBothStable() }
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
                } catch { print("FrontBackRecorder: Could not lock exposure on \(device.localizedName): \(error)") }
            }

            self.writer?.startWriting()
            self.cameraStabilized = true

            let unlock = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.writerQueue.async { self.unlockExposure() }
            }
            self.exposureUnlockItem = unlock
            DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 3.0, execute: unlock)
        }
    }

    private func unlockExposure() {
        for device in [frontDeviceForLock, rearDeviceForLock].compactMap({ $0 }) {
            do {
                try device.lockForConfiguration()
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                device.unlockForConfiguration()
            } catch { print("FrontBackRecorder: Could not unlock exposure on \(device.localizedName): \(error)") }
        }
        frontDeviceForLock = nil
        rearDeviceForLock  = nil
        exposureUnlockItem = nil
    }

    func stopRecording(completion: @escaping (URL) -> Void, error: @escaping (String) -> Void) {
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
            let paused = CACurrentMediaTime() - self.pauseWallStart
            self.pauseOffset = CMTimeAdd(self.pauseOffset, CMTime(seconds: paused, preferredTimescale: 600))
            self.isPaused = false
        }
    }

    // MARK: - Writer Setup

    private func setupWriter() {
        let outURL = settings.frontFileURL()   // reused as the single composite output file
        url = outURL
        let dims = settings.resolution.portraitDimensions

        do {
            let w = try AVAssetWriter(outputURL: outURL, fileType: settings.fileFormat.fileType)

            let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings.portraitVideoSettings)
            vInput.expectsMediaDataInRealTime = true

            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings.audioSettings)
            aInput.expectsMediaDataInRealTime = true

            let adapt = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: vInput,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey  as String: dims.width,
                    kCVPixelBufferHeightKey as String: dims.height
                ]
            )

            if w.canAdd(vInput) { w.add(vInput) }
            if w.canAdd(aInput) { w.add(aInput) }

            writer = w
            videoInput = vInput
            audioInput = aInput
            adaptor = adapt

            compositePool = VideoProcessor.createPixelBufferPool(width: dims.width, height: dims.height)
            frontNormPool = VideoProcessor.createPixelBufferPool(width: dims.width, height: dims.height)
            rearNormPool  = VideoProcessor.createPixelBufferPool(width: dims.width, height: dims.height)

            buildPiPOverlays(canvasW: dims.width, canvasH: dims.height)

        } catch {
            print("FrontBackRecorder: Failed to create writer: \(error)")
        }
    }

    private func setupAudioCallback() {
        audioManager.onAudioBuffer = { [weak self] sampleBuffer in
            guard let self = self else { return }
            var ok = false
            self.writerQueue.sync { ok = self.isRecording && !self.isPaused && self.sessionStarted }
            guard ok else { return }
            self.writerQueue.async {
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                guard CMTIME_IS_VALID(self.sessionStartTimestamp),
                      CMTimeCompare(pts, self.sessionStartTimestamp) >= 0 else { return }
                if let a = self.audioInput, a.isReadyForMoreMediaData, self.writer?.status == .writing {
                    a.append(sampleBuffer)
                }
            }
        }
    }

    // MARK: - PiP Overlays

    /// Builds the rounded-corner alpha mask and the white border, pre-translated to the
    /// top-right PiP rect, so each composited frame just reuses them.
    private func buildPiPOverlays(canvasW: Int, canvasH: Int) {
        let cw = CGFloat(canvasW), ch = CGFloat(canvasH)
        let pipW = (cw * 0.32).rounded()
        let pipH = (pipW * 16.0 / 9.0).rounded()   // portrait PiP (9:16)
        let pad  = (cw * 0.04).rounded()
        let originX = cw - pipW - pad
        let originY = ch - pipH - pad               // CIImage origin is bottom-left → top = high y
        pipRect = CGRect(x: originX, y: originY, width: pipW, height: pipH)

        let radius = pipW * 0.14
        let border = max(3.0, pipW * 0.018)
        let size   = CGSize(width: pipW, height: pipH)
        let full   = CGRect(origin: .zero, size: size)

        // Force 1:1 pixel scale. The default renderer scale is the screen's (e.g. 3×),
        // which would make these overlays 3× the PiP's pixel size and misalign the mask
        // and border against the (1×) pixel-buffer geometry — the "weird border".
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false

        // Alpha mask — opaque white rounded rect on a clear background.
        let maskImg = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIColor.white.setFill()
            UIBezierPath(roundedRect: full, cornerRadius: radius).fill()
        }
        if let cg = maskImg.cgImage {
            pipMaskImage = CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: originX, y: originY))
        }

        // Border — white rounded stroke on a clear background.
        let borderImg = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIColor.white.setStroke()
            let path = UIBezierPath(
                roundedRect: full.insetBy(dx: border / 2, dy: border / 2),
                cornerRadius: radius
            )
            path.lineWidth = border
            path.stroke()
        }
        if let cg = borderImg.cgImage {
            pipBorderImage = CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: originX, y: originY))
        }
    }

    // MARK: - Compositing

    /// Normalises a raw camera buffer to an upright portrait frame at the target resolution.
    private func normalizedPortrait(_ raw: CVPixelBuffer, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(raw)
        let h = CVPixelBufferGetHeight(raw)
        let dims = settings.resolution.portraitDimensions
        let src: CVPixelBuffer
        if w > h {
            guard let rotated = videoProcessor.rotatedCCW90(raw) else { return nil }
            src = rotated
        } else {
            src = raw
        }
        return videoProcessor.cropAndScale(pixelBuffer: src, toWidth: dims.width, toHeight: dims.height, pool: pool)
    }

    /// Composites the PiP camera (rounded, top-right) over the fullscreen main camera.
    private func makeComposite(mainFull: CVPixelBuffer, pipFull: CVPixelBuffer?) -> CVPixelBuffer? {
        let dims = settings.resolution.portraitDimensions
        guard let pool = compositePool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess,
              let output = out else { return nil }

        var result = CIImage(cvPixelBuffer: mainFull)

        if let pipFull = pipFull {
            let scale = pipRect.width / CGFloat(CVPixelBufferGetWidth(pipFull))
            let pipImg = CIImage(cvPixelBuffer: pipFull)
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: pipRect.origin.x, y: pipRect.origin.y))

            let shaped: CIImage
            if let mask = pipMaskImage {
                // "Source In": keep the PiP only where the rounded mask is opaque.
                shaped = pipImg.applyingFilter("CISourceInCompositing",
                                               parameters: [kCIInputBackgroundImageKey: mask])
            } else {
                shaped = pipImg
            }
            result = shaped.composited(over: result)

            if let border = pipBorderImage {
                result = border.composited(over: result)
            }
        }

        videoProcessor.ciContext.render(
            result, to: output,
            bounds: CGRect(x: 0, y: 0, width: dims.width, height: dims.height),
            colorSpace: deviceRGB
        )
        return output
    }

    // MARK: - Frame Processing

    /// Rear frames only update the cache — the front output drives composition.
    /// Runs even while paused so a resume composites a fresh frame.
    private func processRearFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let raw = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard let norm = normalizedPortrait(raw, pool: rearNormPool) else { return }
        rearLock.lock(); latestRearBuffer = norm; rearLock.unlock()
    }

    /// Front frames are the driver: composite with the latest rear and write one file.
    private func processFrontFrame(_ sampleBuffer: CMSampleBuffer) {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        var shouldWrite = false
        writerQueue.sync {
            guard isRecording, cameraStabilized else { return }
            leadFrameCount += 1
            guard leadFrameCount > FrontBackRecorder.kLeadingFrameSkipCount else { return }
            if !sessionStarted, writer?.status == .writing {
                writer?.startSession(atSourceTime: timestamp)
                sessionStartTimestamp = timestamp
                sessionStarted = true
            }
            shouldWrite = sessionStarted
        }
        guard shouldWrite else { return }

        guard let rawFront = CMSampleBufferGetImageBuffer(sampleBuffer),
              let frontFull = normalizedPortrait(rawFront, pool: frontNormPool) else { return }

        rearLock.lock(); let rearFull = latestRearBuffer; rearLock.unlock()

        let mainIsFront = _mainIsFront
        let mainFull = mainIsFront ? frontFull : (rearFull ?? frontFull)
        let pipFull  = mainIsFront ? rearFull  : frontFull

        guard let composite = makeComposite(mainFull: mainFull, pipFull: pipFull) else { return }

        if !hasLoggedInfo {
            hasLoggedInfo = true
            print("🎥 FrontBackRecorder composite \(CVPixelBufferGetWidth(composite))×\(CVPixelBufferGetHeight(composite)) mainIsFront=\(mainIsFront)")
        }

        writerQueue.async { [weak self] in
            guard let self = self,
                  let input = self.videoInput,
                  self.writer?.status == .writing else { return }

            let pts = CMTimeSubtract(CMTimeMaximum(timestamp, self.sessionStartTimestamp), self.pauseOffset)

            var flushed = 0
            while flushed < self.pendingFrames.count, input.isReadyForMoreMediaData {
                let (b, t) = self.pendingFrames[flushed]
                self.adaptor?.append(b, withPresentationTime: t); flushed += 1
            }
            if flushed > 0 { self.pendingFrames.removeFirst(flushed) }

            if input.isReadyForMoreMediaData {
                self.adaptor?.append(composite, withPresentationTime: pts)
            } else if self.pendingFrames.count < 60 {
                self.pendingFrames.append((composite, pts))
            }
        }
    }

    // MARK: - Finish Writing

    private func finishWriting() {
        guard sessionStarted else {
            stabilizationTimeoutItem?.cancel()
            stabilizationTimeoutItem = nil
            frontExposureObservation = nil
            rearExposureObservation  = nil
            exposureUnlockItem?.cancel()
            unlockExposure()
            writer?.cancelWriting()
            cleanup()
            errorHandler?("Recording stopped before it could start.")
            return
        }

        exposureUnlockItem?.cancel()
        unlockExposure()

        guard let writer = writer else { cleanup(); errorHandler?("No writer."); return }

        switch writer.status {
        case .writing:
            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
            let outURL = url
            writer.finishWriting { [weak self] in
                DispatchQueue.main.async {
                    if writer.status == .completed, let u = outURL {
                        self?.completionHandler?(u)
                    } else {
                        self?.errorHandler?("Recording failed. \(writer.error?.localizedDescription ?? "")")
                    }
                    self?.cleanup()
                }
            }
        case .failed:
            // Interrupted — try to salvage the partial file.
            print("FrontBackRecorder: writer interrupted — attempting to salvage")
            DispatchQueue.main.async { [weak self] in
                if let u = self?.url { self?.completionHandler?(u) } else { self?.errorHandler?("Recording failed.") }
                self?.cleanup()
            }
        default:
            DispatchQueue.main.async { [weak self] in
                self?.errorHandler?("Recording failed.")
                self?.cleanup()
            }
        }
    }

    private func cleanup() {
        stabilizationTimeoutItem?.cancel()
        stabilizationTimeoutItem = nil
        frontExposureObservation = nil
        rearExposureObservation  = nil
        exposureUnlockItem?.cancel()
        unlockExposure()
        writer = nil
        videoInput = nil
        audioInput = nil
        adaptor = nil
        compositePool = nil
        frontNormPool = nil
        rearNormPool  = nil
        pendingFrames.removeAll()
        rearLock.lock(); latestRearBuffer = nil; rearLock.unlock()
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension FrontBackRecorder: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if output === rearOutput {
            // Cache the latest rear frame even while paused so resume composites fresh.
            processRearFrame(sampleBuffer)
            return
        }
        guard !isPaused else { return }
        if output === frontOutput {
            processFrontFrame(sampleBuffer)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {}
}
