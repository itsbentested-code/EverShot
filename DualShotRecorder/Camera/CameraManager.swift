import AVFoundation
import Combine
import SwiftUI
import UIKit

/// Isolated ObservableObject that carries only the front-camera PiP snapshot.
/// Keeping it separate from CameraManager means SwiftUI only re-renders the
/// small PiP thumbnail view when a new frame arrives — not all of RecordingView.
final class FrontCameraPipModel: ObservableObject {
    @Published var snapshot: CGImage?
}

/// Central manager for the camera capture pipeline.
/// Handles session setup, preview, mode switching, and delegates to
/// DualLensRecorder or SingleLensRecorder for actual recording.
final class CameraManager: NSObject, ObservableObject {

    // MARK: - Published State

    @Published var isRecording = false
    @Published var isPaused = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var systemPressureCost: Float = 0
    @Published var hardwareCost: Float = 0
    @Published var isSaving = false
    @Published var saveComplete = false
    @Published var saveError: String?

    // MARK: - Session

    private var multiCamSession: AVCaptureMultiCamSession?
    private var singleSession: AVCaptureSession?

    /// The active session (either multi-cam or single)
    var activeSession: AVCaptureSession? {
        multiCamSession ?? singleSession
    }

    // MARK: - Components

    let audioManager = AudioManager()
    private var dualLensRecorder: DualLensRecorder?
    private var singleLensRecorder: SingleLensRecorder?
    private var frontBackRecorder: FrontBackRecorder?
    let videoProcessor = VideoProcessor()

    // MARK: - Settings

    private(set) var settings: RecordingSettings

    // MARK: - Timer

    private var recordingTimer: Timer?
    private var recordingStartTime: Date?
    private var pauseStartTime: Date?
    private var totalPausedDuration: TimeInterval = 0

    // MARK: - Zoom

    /// Current zoom factor on the main (portrait) camera. Drives the zoom indicator UI.
    @Published private(set) var zoomFactor: CGFloat = 1.0

    /// The device whose zoom factor we control — whichever camera is powering the main preview.
    /// In dual-lens rear mode this is the wide camera; the ultrawide is synced separately in setZoom.
    private var activeZoomDevice: AVCaptureDevice? {
        if settings.isFrontBackMode { return DeviceCapabilities.wideCamera }
        return settings.dualLensUseFrontCamera
            ? DeviceCapabilities.bestFrontCamera   // match the camera actually in use
            : DeviceCapabilities.wideCamera
    }

    /// Applies a zoom factor to a single device, clamped to that device's supported range.
    /// Returns the actual factor that was set (after clamping).
    @discardableResult
    private func applyZoom(_ factor: CGFloat, to device: AVCaptureDevice) -> CGFloat {
        let minZoom = device.minAvailableVideoZoomFactor
        let maxZoom = min(device.activeFormat.videoMaxZoomFactor, 10.0)
        let clamped = max(minZoom, min(factor, maxZoom))
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
        } catch {
            print("CameraManager: setZoom error on \(device.localizedName): \(error)")
        }
        return clamped
    }

    /// Sets the zoom factor on all active cameras, clamped per-device to each device's
    /// supported range. In dual-lens rear mode both wide and ultrawide are zoomed in sync
    /// so both recorded outputs scale together when the user pinches.
    func setZoom(_ factor: CGFloat) {
        guard let primary = activeZoomDevice else { return }
        let actual = applyZoom(factor, to: primary)

        // In dual-lens rear mode, mirror the same factor to the ultrawide so the
        // landscape output zooms in lockstep with the portrait output.
        if !settings.dualLensUseFrontCamera && !settings.isSingleLensMode && !settings.isFrontBackMode,
           let ultraWide = ultraWideDeviceRef {
            applyZoom(factor, to: ultraWide)
        }

        zoomFactor = actual
    }

    /// Resets zoom to 1× (native focal length).
    func resetZoom() {
        setZoom(1.0)
    }

    /// Swaps which camera feeds portrait vs landscape without tearing down the session.
    /// Safe to call while the session is running (just moves sample buffer delegates).
    /// The SwiftUI view already re-routes the preview layers correctly via its
    /// mainPreviewLayer / pipPreviewLayer computed properties when cameraAssignment changes.
    func swapDualLensAssignment() {
        guard let recorder = dualLensRecorder,
              let wide = wideVideoOutputRef,
              let ultraWide = ultraWideVideoOutputRef else { return }
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if self.settings.cameraAssignment.wideIsPortrait {
                recorder.setOutputs(portraitOutput: wide, landscapeOutput: ultraWide)
            } else {
                recorder.setOutputs(portraitOutput: ultraWide, landscapeOutput: wide)
            }
        }
    }

    // MARK: - Preview

    /// The preview layer for the main camera feed
    @Published private(set) var previewLayer: AVCaptureVideoPreviewLayer?

    /// The preview layer for the secondary camera (PiP in dual-lens mode)
    @Published private(set) var secondaryPreviewLayer: AVCaptureVideoPreviewLayer?

    /// Carries the front-camera PiP frame. Observed directly by FrontCameraPipImage
    /// so frame updates don't trigger a full RecordingView re-render.
    let pipModel = FrontCameraPipModel()

    // MARK: - Background Task

    /// Holds a background task token so iOS gives us time to finish writing
    /// after the app is backgrounded or the capture session is interrupted.
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    // MARK: - Session Queue

    private let sessionQueue = DispatchQueue(label: "com.evershot.session", qos: .userInitiated)

    // Device references kept so startRecording() can pass them to the recorder for
    // KVO observation of isAdjustingExposure.
    private var wideDeviceRef:      AVCaptureDevice?
    private var ultraWideDeviceRef: AVCaptureDevice?
    private var frontDeviceRef:     AVCaptureDevice?

    // Output references kept so swapDualLensAssignment() can re-route delegates
    // without tearing down the session.
    private var wideVideoOutputRef:      AVCaptureVideoDataOutput?
    private var ultraWideVideoOutputRef: AVCaptureVideoDataOutput?


    // MARK: - Init

    init(settings: RecordingSettings) {
        self.settings = settings
        super.init()
        registerInterruptionObservers()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        endBackgroundTaskIfNeeded()
    }

    // MARK: - Interruption Observers

    private func registerInterruptionObservers() {
        let nc = NotificationCenter.default

        nc.addObserver(
            self,
            selector: #selector(captureSessionWasInterrupted(_:)),
            name: .AVCaptureSessionWasInterrupted,
            object: nil
        )

        nc.addObserver(
            self,
            selector: #selector(audioSessionInterrupted(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )

        nc.addObserver(
            self,
            selector: #selector(appWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
    }

    @objc private func captureSessionWasInterrupted(_ notification: Notification) {
        guard isRecording else { return }
        print("CameraManager: Capture session interrupted — stopping recording.")
        stopRecording()
    }

    @objc private func audioSessionInterrupted(_ notification: Notification) {
        guard isRecording else { return }
        guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue),
              type == .began else { return }
        print("CameraManager: Audio session interrupted — stopping recording to save the file.")
        stopRecording()
    }

    @objc private func appWillResignActive() {
        guard isRecording else { return }
        print("CameraManager: App will resign active — stopping recording to save the file.")
        stopRecording()
    }

    // MARK: - Background Task Helpers

    private func beginBackgroundTaskIfNeeded() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "EverShot.finishRecording") {
            [weak self] in
            // Expiry handler: iOS is about to kill us — end cleanly
            self?.endBackgroundTaskIfNeeded()
        }
    }

    private func endBackgroundTaskIfNeeded() {
        let id = backgroundTaskID
        guard id != .invalid else { return }
        backgroundTaskID = .invalid
        UIApplication.shared.endBackgroundTask(id)
    }

    // MARK: - Session Lifecycle

    /// Configures and starts the capture session based on current settings.
    func startSession() {
        // Keep the screen awake while the camera is open — same behaviour as
        // Apple's built-in Camera app. Re-enabled in tearDownSession().
        if Thread.isMainThread {
            UIApplication.shared.isIdleTimerDisabled = true
        } else {
            DispatchQueue.main.sync {
                UIApplication.shared.isIdleTimerDisabled = true
            }
        }

        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.tearDownSession()

            let route: String
            if self.settings.isFrontBackMode {
                route = "FrontBack"
            } else if self.settings.dualLensUseFrontCamera {
                route = "FrontCamera (dualLensUseFrontCamera=true)"
            } else if self.settings.isSingleLensMode {
                route = "WideOnly (singleLens)"
            } else {
                route = "DualLens (rear)"
            }
            print("🔀 CameraManager startSession → \(route)")

            if self.settings.isFrontBackMode {
                // True Front+Rear MultiCam — two simultaneous portrait videos
                self.configureFrontBackSession()
            } else if self.settings.dualLensUseFrontCamera {
                // Dual/Single modes flipped to front camera
                self.configureFrontCameraSession()
            } else if self.settings.isSingleLensMode {
                // Single Lens mode — Wide (1×) rear camera only, same two-crop approach
                self.configureWideOnlySession()
            } else {
                self.configureDualLensSession()
            }
        }
    }

    /// Stops the capture session.
    func stopSession() {
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        sessionQueue.async { [weak self] in
            self?.activeSession?.stopRunning()
        }
    }

    /// Tears down the current session completely.
    /// Must be called on sessionQueue.
    private func tearDownSession() {
        // Re-enable idle timer during teardown — startSession() will disable it
        // again immediately if a new session is being configured.
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = false
        }

        // 1. Capture old sessions in local vars so we can stop them after cleanup
        let oldMultiCam = multiCamSession
        let oldSingle = singleSession

        // 2. Nil out delegates on all outputs so no callbacks fire during teardown
        for output in (oldMultiCam?.outputs ?? []) + (oldSingle?.outputs ?? []) {
            (output as? AVCaptureVideoDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
            (output as? AVCaptureAudioDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
        }

        dualLensRecorder  = nil
        singleLensRecorder = nil
        frontBackRecorder = nil
        audioManager.reset()

        // 3. Clear session ivars before stopping — prevents any re-entrant access
        multiCamSession = nil
        singleSession = nil

        // Reset zoom so the next session always starts at 1×
        DispatchQueue.main.async { self.zoomFactor = 1.0 }

        // 4. Force SwiftUI to release old preview layers SYNCHRONOUSLY.
        //    This is safe because startSession() dispatches to sessionQueue async,
        //    so the main thread is NOT blocked — no deadlock risk.
        //    Once the layers are removed from the view hierarchy AND nil'd,
        //    they no longer hold a strong reference to the old session.
        DispatchQueue.main.sync { [weak self] in
            self?.previewLayer?.removeFromSuperlayer()
            self?.previewLayer = nil
            self?.secondaryPreviewLayer?.removeFromSuperlayer()
            self?.secondaryPreviewLayer = nil
            self?.pipModel.snapshot = nil
        }

        // 5. Now stop the old sessions. With preview layers fully detached,
        //    stopRunning() won't deadlock trying to sync with the main thread.
        oldMultiCam?.stopRunning()
        oldSingle?.stopRunning()
    }

    // MARK: - Dual Lens Session

    private func configureDualLensSession() {
        let session = AVCaptureMultiCamSession()
        self.multiCamSession = session

        session.beginConfiguration()

        // --- Wide Camera (rear) ---
        guard let wideDevice = DeviceCapabilities.wideCamera,
              let wideInput = try? AVCaptureDeviceInput(device: wideDevice) else {
            print("CameraManager: Failed to get wide camera")
            session.commitConfiguration()
            return
        }

        let wideVideoOutput = AVCaptureVideoDataOutput()
        wideVideoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        wideVideoOutput.alwaysDiscardsLateVideoFrames = true

        guard session.canAddInput(wideInput) else { session.commitConfiguration(); return }
        session.addInputWithNoConnections(wideInput)

        guard session.canAddOutput(wideVideoOutput) else { session.commitConfiguration(); return }
        session.addOutputWithNoConnections(wideVideoOutput)

        guard let wideVideoPort = wideInput.ports(for: .video, sourceDeviceType: .builtInWideAngleCamera, sourceDevicePosition: .back).first else {
            print("CameraManager: No wide video port")
            session.commitConfiguration()
            return
        }

        let wideConnection = AVCaptureConnection(inputPorts: [wideVideoPort], output: wideVideoOutput)
        // .landscapeRight delivers the native 1920×1080 sensor frame with no system
        // transform applied to the pixel data. We rotate the frame to portrait ourselves
        // in DualLensRecorder.processPortraitFrame using rotatedCW90.
        // (Requesting .portrait here causes the system to letterbox or incorrectly rotate
        // the output depending on the active format — both produce wrong exported clips.)
        wideConnection.videoOrientation = .landscapeRight
        // Disable EIS — we receive raw frames and handle crop/scale ourselves.
        // With EIS enabled (the default), the stabiliser resets its crop reference
        // at the start of every recording and drifts back to centre over ~1 second,
        // producing an unwanted zoom-out effect at the beginning of each clip.
        if wideConnection.isVideoStabilizationSupported {
            wideConnection.preferredVideoStabilizationMode = .off
        }
        guard session.canAddConnection(wideConnection) else { session.commitConfiguration(); return }
        session.addConnection(wideConnection)

        // --- Ultra-Wide Camera (always rear, used for PiP and second recording) ---
        guard let ultraWideDevice = DeviceCapabilities.ultraWideCamera,
              let ultraWideInput = try? AVCaptureDeviceInput(device: ultraWideDevice) else {
            print("CameraManager: Failed to get ultra-wide camera")
            session.commitConfiguration()
            return
        }

        let ultraWideVideoOutput = AVCaptureVideoDataOutput()
        ultraWideVideoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        ultraWideVideoOutput.alwaysDiscardsLateVideoFrames = true

        guard session.canAddInput(ultraWideInput) else { session.commitConfiguration(); return }
        session.addInputWithNoConnections(ultraWideInput)

        guard session.canAddOutput(ultraWideVideoOutput) else { session.commitConfiguration(); return }
        session.addOutputWithNoConnections(ultraWideVideoOutput)

        guard let ultraWideVideoPort = ultraWideInput.ports(for: .video, sourceDeviceType: .builtInUltraWideCamera, sourceDevicePosition: .back).first else {
            print("CameraManager: No ultra-wide video port")
            session.commitConfiguration()
            return
        }

        let ultraWideConnection = AVCaptureConnection(inputPorts: [ultraWideVideoPort], output: ultraWideVideoOutput)
        // Use .landscapeRight so the system delivers frames in the ultrawide's
        // native landscape orientation with the scene correctly oriented for
        // landscape playback. This avoids the rotate-then-crop path in
        // DualLensRecorder that was causing the landscape video to be zoomed in
        // (~1.78× upscale after cropping a narrow portrait strip).
        // The secondary preview connection (PiP) keeps .portrait independently.
        ultraWideConnection.videoOrientation = .landscapeRight
        // Same EIS disable as wide connection above.
        if ultraWideConnection.isVideoStabilizationSupported {
            ultraWideConnection.preferredVideoStabilizationMode = .off
        }
        guard session.canAddConnection(ultraWideConnection) else { session.commitConfiguration(); return }
        session.addConnection(ultraWideConnection)

        // --- Audio ---
        if let audioComponents = audioManager.configure() {
            if session.canAddInput(audioComponents.input) {
                session.addInputWithNoConnections(audioComponents.input)
            }
            if session.canAddOutput(audioComponents.output) {
                session.addOutputWithNoConnections(audioComponents.output)
            }

            if let micInput = audioManager.audioInput,
               let audioPort = micInput.ports(for: .audio, sourceDeviceType: .builtInMicrophone, sourceDevicePosition: .unspecified).first ??
                               micInput.ports(for: .audio, sourceDeviceType: nil, sourceDevicePosition: .unspecified).first,
               let audioOut = audioManager.audioOutput {
                let audioConnection = AVCaptureConnection(inputPorts: [audioPort], output: audioOut)
                if session.canAddConnection(audioConnection) {
                    session.addConnection(audioConnection)
                }
            }
        }

        // --- Configure Devices ---
        // multiCamOnly: true — AVCaptureMultiCamSession requires formats with
        // isMultiCamSupported = true. Omitting this filter causes the session to fail
        // silently (black screen) when the requested resolution/fps is only available
        // in a non-MultiCam format (common at 4K 60fps on many devices).
        configureDevice(wideDevice, frameRate: settings.frameRate, resolution: settings.resolution, multiCamOnly: true)
        configureDevice(ultraWideDevice, frameRate: settings.frameRate, resolution: settings.resolution, multiCamOnly: true)

        // --- Apple Log Color Space (iOS 17+) ---
        if #available(iOS 17, *), settings.appleLog {
            do {
                try wideDevice.lockForConfiguration()
                if wideDevice.activeFormat.supportedColorSpaces.contains(.appleLog) {
                    wideDevice.activeColorSpace = .appleLog
                } else {
                    print("CameraManager: Apple Log not supported on this device/format")
                }
                wideDevice.unlockForConfiguration()
            } catch {
                print("CameraManager: Failed to set Apple Log color space: \(error)")
            }
        }

        session.commitConfiguration()

        // --- Preview Layer (wide camera — full screen) ---
        let preview = AVCaptureVideoPreviewLayer(sessionWithNoConnection: session)
        preview.videoGravity = .resizeAspectFill

        let previewConnection = AVCaptureConnection(inputPort: wideVideoPort, videoPreviewLayer: preview)
        previewConnection.videoOrientation = .portrait
        if session.canAddConnection(previewConnection) {
            session.addConnection(previewConnection)
        }

        // --- Secondary Preview Layer (ultra-wide camera PiP) ---
        let secondaryPreview = AVCaptureVideoPreviewLayer(sessionWithNoConnection: session)
        secondaryPreview.videoGravity = .resizeAspectFill

        let secondaryPreviewConnection = AVCaptureConnection(inputPort: ultraWideVideoPort, videoPreviewLayer: secondaryPreview)
        secondaryPreviewConnection.videoOrientation = .portrait
        if session.canAddConnection(secondaryPreviewConnection) {
            session.addConnection(secondaryPreviewConnection)
        }

        // --- Diagnostic: confirm both cameras and their output assignments --------
        print("🎥 CameraManager [DUAL LENS] session configured:")
        print("   Wide camera     : \(wideDevice.localizedName) (\(wideDevice.uniqueID))")
        print("   Ultrawide camera: \(ultraWideDevice.localizedName) (\(ultraWideDevice.uniqueID))")
        print("   Wide orientation supported     : \(wideConnection.isVideoOrientationSupported)")
        print("   Ultrawide orientation supported: \(ultraWideConnection.isVideoOrientationSupported)")
        if settings.cameraAssignment.wideIsPortrait {
            print("   Assignment: wide→PORTRAIT, ultrawide→LANDSCAPE")
        } else {
            print("   Assignment: ultrawide→PORTRAIT, wide→LANDSCAPE")
        }

        // --- Create Recorder ---
        let recorder = DualLensRecorder(
            settings: settings,
            videoProcessor: videoProcessor,
            audioManager: audioManager
        )

        // Assign outputs based on camera assignment setting
        if settings.cameraAssignment.wideIsPortrait {
            recorder.setOutputs(
                portraitOutput: wideVideoOutput,
                landscapeOutput: ultraWideVideoOutput
            )
        } else {
            recorder.setOutputs(
                portraitOutput: ultraWideVideoOutput,
                landscapeOutput: wideVideoOutput
            )
        }

        self.dualLensRecorder = recorder

        // Monitor costs
        monitorSessionCosts(session)

        // Store device refs for KVO exposure observation at recording start
        self.wideDeviceRef      = wideDevice
        self.ultraWideDeviceRef = ultraWideDevice

        // Store output refs so swapDualLensAssignment() can re-route without session teardown
        self.wideVideoOutputRef      = wideVideoOutput
        self.ultraWideVideoOutputRef = ultraWideVideoOutput

        // Start session BEFORE publishing preview layers.
        // This ensures frames are flowing when the layers appear in the view.
        session.startRunning()

        // Publish preview layers on main thread — replace any old ones
        DispatchQueue.main.async { [weak self] in
            self?.previewLayer?.removeFromSuperlayer()
            self?.secondaryPreviewLayer?.removeFromSuperlayer()
            self?.previewLayer = preview
            self?.secondaryPreviewLayer = secondaryPreview
        }
    }

    // MARK: - Front Camera Session (used when dual-lens mode flips to front)

    private func configureFrontCameraSession() {
        let session = AVCaptureSession()
        self.singleSession = session

        session.beginConfiguration()
        session.sessionPreset = .high

        // Use bestFrontCamera — on iPhone 17+ this is the dedicated Front Ultra Wide
        // Camera (builtInUltraWideCamera at front position), which has dramatically
        // wider FOV than the standard selfie camera and is what gives the wide look.
        // On older devices it falls back to builtInWideAngleCamera front.
        let ultraWideFront = DeviceCapabilities.frontUltraWideCamera
        let standardFront  = DeviceCapabilities.frontCamera
        print("🔍 CameraManager [FrontSession] ultraWideFront=\(ultraWideFront?.localizedName ?? "nil"), standardFront=\(standardFront?.localizedName ?? "nil")")
        let chosenDevice   = ultraWideFront ?? standardFront
        print("🔍 CameraManager [FrontSession] using: \(chosenDevice?.localizedName ?? "nil")")

        guard let frontDevice = chosenDevice,
              let videoInput = try? AVCaptureDeviceInput(device: frontDevice) else {
            print("CameraManager: Failed to get front camera")
            session.commitConfiguration()
            return
        }

        if session.canAddInput(videoInput) {
            session.addInput(videoInput)
        }

        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true

        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        // Recording output — portrait orientation, NOT mirrored.
        // The preview is mirrored (feels natural, like a mirror) but the
        // saved file must be unmirrored so playback looks correct to viewers.
        if let connection = videoOutput.connection(with: .video) {
            connection.videoOrientation = .portrait
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }

        // Landscape output — native landscapeRight orientation.
        // By requesting .landscapeRight here, the system physically rotates the front
        // camera's sensor data to deliver full-width 1920×1080 landscape frames instead
        // of the narrow portrait crop we used previously.  This gives full FOV without
        // any zoom — the scene fills the landscape frame the same way it fills portrait.
        let landscapeOutput = AVCaptureVideoDataOutput()
        landscapeOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        landscapeOutput.alwaysDiscardsLateVideoFrames = true

        if session.canAddOutput(landscapeOutput) {
            session.addOutput(landscapeOutput)
        }
        if let lConn = landscapeOutput.connection(with: .video) {
            lConn.videoOrientation = .landscapeRight
            lConn.automaticallyAdjustsVideoMirroring = false
            lConn.isVideoMirrored = false   // recorded landscape is not mirrored
        }

        // Audio
        if let audioComponents = audioManager.configure() {
            if session.canAddInput(audioComponents.input) {
                session.addInput(audioComponents.input)
            }
            if session.canAddOutput(audioComponents.output) {
                session.addOutput(audioComponents.output)
            }
        }

        configureDevice(frontDevice, frameRate: settings.frameRate, resolution: settings.resolution)

        // Disable Center Stage — it auto-crops/pans to track faces which fights our pipeline.
        if #available(iOS 14.5, *), AVCaptureDevice.isCenterStageEnabled {
            AVCaptureDevice.centerStageControlMode = .app
            AVCaptureDevice.isCenterStageEnabled   = false
        }

        // Unlock the full ultrawide FOV.
        // On Center Stage iPhones (A14+) the front camera is physically an ultrawide
        // sensor. Setting a format via configureDevice (and/or disabling Center Stage)
        // leaves videoZoomFactor at the system's "standard selfie" default — typically
        // 1.7–2×, which crops the sensor down to the old narrower front-camera look.
        // Explicitly setting it to minAvailableVideoZoomFactor gives the full-width
        // ultrawide view, matching what Plop and similar apps display in their main
        // preview and landscape output.
        do {
            try frontDevice.lockForConfiguration()
            frontDevice.videoZoomFactor = frontDevice.minAvailableVideoZoomFactor
            frontDevice.unlockForConfiguration()
        } catch {
            print("CameraManager: Could not set min zoom on front camera: \(error)")
        }

        session.commitConfiguration()

        // Main preview layer — full-screen viewfinder
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        if let connection = preview.connection {
            connection.videoOrientation = .portrait
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }

        // Recorder — portrait from videoOutput, landscape from native landscapeOutput
        let recorder = SingleLensRecorder(
            settings: settings,
            videoProcessor: videoProcessor,
            audioManager: audioManager
        )
        recorder.setOutput(videoOutput)
        recorder.setNativeLandscapeOutput(landscapeOutput)

        // PiP thumbnail: feed frames into the isolated pipModel so only the
        // small PiP subview re-renders per frame — not all of RecordingView.
        recorder.onPreviewFrame = { [weak self] cgImage in
            DispatchQueue.main.async {
                self?.pipModel.snapshot = cgImage
            }
        }

        self.singleLensRecorder = recorder
        self.frontDeviceRef = frontDevice

        session.startRunning()

        DispatchQueue.main.async { [weak self] in
            self?.previewLayer?.removeFromSuperlayer()
            self?.secondaryPreviewLayer?.removeFromSuperlayer()
            self?.previewLayer = preview
            self?.secondaryPreviewLayer = nil
            self?.pipModel.snapshot = nil
        }
    }

    // MARK: - Wide-Only Single Lens Session

    /// Single Lens mode: Wide (1×) rear camera only.
    /// Uses SingleLensRecorder to crop two simultaneous outputs (portrait 9:16 + landscape 16:9)
    /// from the same sensor feed — identical to the front-camera path but with the rear Wide lens.
    private func configureWideOnlySession() {
        let session = AVCaptureSession()
        self.singleSession = session

        session.beginConfiguration()
        session.sessionPreset = .high

        guard let wideDevice = DeviceCapabilities.wideCamera,
              let videoInput = try? AVCaptureDeviceInput(device: wideDevice) else {
            print("CameraManager: Failed to get wide camera for single-lens mode")
            session.commitConfiguration()
            return
        }

        if session.canAddInput(videoInput) {
            session.addInput(videoInput)
        }

        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true

        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        if let connection = videoOutput.connection(with: .video) {
            connection.videoOrientation = .portrait
            // Disable EIS — we receive raw frames and handle crop/scale ourselves.
            // With EIS enabled, the stabiliser builds a lookahead buffer that delays
            // delivery of the first video frame by ~1 second. This causes two bugs:
            // (1) audio before the first delivered frame is dropped (no audio at start),
            // (2) the video track ends ~1 second shorter than the audio track, making
            // the playback appear frozen on the last frame. Same fix as dual cam sessions.
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .off
            }
        }

        // Audio
        if let audioComponents = audioManager.configure() {
            if session.canAddInput(audioComponents.input) {
                session.addInput(audioComponents.input)
            }
            if session.canAddOutput(audioComponents.output) {
                session.addOutput(audioComponents.output)
            }
        }

        configureDevice(wideDevice, frameRate: settings.frameRate, resolution: settings.resolution)

        session.commitConfiguration()

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        if let connection = preview.connection {
            connection.videoOrientation = .portrait
        }

        let recorder = SingleLensRecorder(
            settings: settings,
            videoProcessor: videoProcessor,
            audioManager: audioManager
        )
        recorder.setOutput(videoOutput)
        // No onPreviewFrame needed — there is no secondary PiP in single-lens wide mode

        self.singleLensRecorder = recorder
        self.wideDeviceRef      = wideDevice
        self.frontDeviceRef     = nil

        session.startRunning()

        DispatchQueue.main.async { [weak self] in
            self?.previewLayer?.removeFromSuperlayer()
            self?.secondaryPreviewLayer?.removeFromSuperlayer()
            self?.previewLayer          = preview
            self?.secondaryPreviewLayer = nil
            self?.pipModel.snapshot     = nil
        }
    }

    // MARK: - Front/Back MultiCam Session

    /// True simultaneous front+rear recording using AVCaptureMultiCamSession.
    /// Main preview: rear wide camera (full-screen). PiP preview: front camera (portrait corner).
    /// Both recorded outputs are portrait 9:16.
    private func configureFrontBackSession() {
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            print("CameraManager: MultiCam not supported on this device — falling back to front-only")
            configureFrontCameraSession()
            return
        }

        let session = AVCaptureMultiCamSession()
        self.multiCamSession = session
        session.beginConfiguration()

        // --- Rear Wide Camera (main viewfinder + rearFile) ---
        guard let rearDevice = DeviceCapabilities.wideCamera,
              let rearInput  = try? AVCaptureDeviceInput(device: rearDevice) else {
            print("CameraManager: Failed to get rear camera for Front/Back mode")
            session.commitConfiguration()
            return
        }

        let rearVideoOutput = AVCaptureVideoDataOutput()
        rearVideoOutput.videoSettings  = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        rearVideoOutput.alwaysDiscardsLateVideoFrames = true

        guard session.canAddInput(rearInput)         else { session.commitConfiguration(); return }
        session.addInputWithNoConnections(rearInput)
        guard session.canAddOutput(rearVideoOutput)  else { session.commitConfiguration(); return }
        session.addOutputWithNoConnections(rearVideoOutput)

        guard let rearVideoPort = rearInput.ports(
            for: .video,
            sourceDeviceType: .builtInWideAngleCamera,
            sourceDevicePosition: .back
        ).first else {
            print("CameraManager: No rear video port for Front/Back mode")
            session.commitConfiguration()
            return
        }

        let rearRecordConn = AVCaptureConnection(inputPorts: [rearVideoPort], output: rearVideoOutput)
        rearRecordConn.videoOrientation = .portrait
        if rearRecordConn.isVideoStabilizationSupported {
            rearRecordConn.preferredVideoStabilizationMode = .off
        }
        guard session.canAddConnection(rearRecordConn) else { session.commitConfiguration(); return }
        session.addConnection(rearRecordConn)

        // --- Front Camera (PiP viewfinder + frontFile) ---
        guard let frontDevice = DeviceCapabilities.frontCamera,
              let frontInput  = try? AVCaptureDeviceInput(device: frontDevice) else {
            print("CameraManager: Failed to get front camera for Front/Back mode")
            session.commitConfiguration()
            return
        }

        let frontVideoOutput = AVCaptureVideoDataOutput()
        frontVideoOutput.videoSettings  = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        frontVideoOutput.alwaysDiscardsLateVideoFrames = true

        guard session.canAddInput(frontInput)        else { session.commitConfiguration(); return }
        session.addInputWithNoConnections(frontInput)
        guard session.canAddOutput(frontVideoOutput) else { session.commitConfiguration(); return }
        session.addOutputWithNoConnections(frontVideoOutput)

        guard let frontVideoPort = frontInput.ports(
            for: .video,
            sourceDeviceType: .builtInWideAngleCamera,
            sourceDevicePosition: .front
        ).first else {
            print("CameraManager: No front video port for Front/Back mode")
            session.commitConfiguration()
            return
        }

        let frontRecordConn = AVCaptureConnection(inputPorts: [frontVideoPort], output: frontVideoOutput)
        frontRecordConn.videoOrientation = .portrait
        frontRecordConn.automaticallyAdjustsVideoMirroring = false
        frontRecordConn.isVideoMirrored = false // record unmirrored (correct for exports)
        if frontRecordConn.isVideoStabilizationSupported {
            frontRecordConn.preferredVideoStabilizationMode = .off
        }
        guard session.canAddConnection(frontRecordConn) else { session.commitConfiguration(); return }
        session.addConnection(frontRecordConn)

        // --- Audio ---
        if let audioComponents = audioManager.configure() {
            if session.canAddInput(audioComponents.input) {
                session.addInputWithNoConnections(audioComponents.input)
            }
            if session.canAddOutput(audioComponents.output) {
                session.addOutputWithNoConnections(audioComponents.output)
            }
            if let micInput = audioManager.audioInput,
               let audioPort = micInput.ports(for: .audio, sourceDeviceType: .builtInMicrophone, sourceDevicePosition: .unspecified).first
                            ?? micInput.ports(for: .audio, sourceDeviceType: nil, sourceDevicePosition: .unspecified).first,
               let audioOut = audioManager.audioOutput {
                let audioConn = AVCaptureConnection(inputPorts: [audioPort], output: audioOut)
                if session.canAddConnection(audioConn) { session.addConnection(audioConn) }
            }
        }

        // --- Device Configuration ---
        configureDevice(rearDevice,   frameRate: settings.frameRate, resolution: settings.resolution, multiCamOnly: true)
        configureDevice(frontDevice,  frameRate: settings.frameRate, resolution: settings.resolution, multiCamOnly: true)

        // Disable Center Stage so it doesn't fight the front-camera crop pipeline.
        if #available(iOS 14.5, *), AVCaptureDevice.isCenterStageEnabled {
            AVCaptureDevice.centerStageControlMode = .app
            AVCaptureDevice.isCenterStageEnabled   = false
        }

        session.commitConfiguration()

        // --- Rear Preview (main — full screen) ---
        let rearPreview = AVCaptureVideoPreviewLayer(sessionWithNoConnection: session)
        rearPreview.videoGravity = .resizeAspectFill
        let rearPreviewConn = AVCaptureConnection(inputPort: rearVideoPort, videoPreviewLayer: rearPreview)
        rearPreviewConn.videoOrientation = .portrait
        if session.canAddConnection(rearPreviewConn) { session.addConnection(rearPreviewConn) }

        // --- Front Preview (secondary — PiP) ---
        let frontPreview = AVCaptureVideoPreviewLayer(sessionWithNoConnection: session)
        frontPreview.videoGravity = .resizeAspectFill
        let frontPreviewConn = AVCaptureConnection(inputPort: frontVideoPort, videoPreviewLayer: frontPreview)
        frontPreviewConn.videoOrientation = .portrait
        frontPreviewConn.automaticallyAdjustsVideoMirroring = false
        frontPreviewConn.isVideoMirrored = true // mirror the preview only — not the recording
        if session.canAddConnection(frontPreviewConn) { session.addConnection(frontPreviewConn) }

        // --- Recorder ---
        let recorder = FrontBackRecorder(
            settings: settings,
            videoProcessor: videoProcessor,
            audioManager: audioManager
        )
        recorder.setOutputs(frontOutput: frontVideoOutput, rearOutput: rearVideoOutput)
        self.frontBackRecorder = recorder

        // Store device refs for AEC KVO
        self.wideDeviceRef  = rearDevice
        self.frontDeviceRef = frontDevice

        monitorSessionCosts(session)
        session.startRunning()

        DispatchQueue.main.async { [weak self] in
            self?.previewLayer?.removeFromSuperlayer()
            self?.secondaryPreviewLayer?.removeFromSuperlayer()
            self?.previewLayer          = rearPreview    // main = rear wide
            self?.secondaryPreviewLayer = frontPreview   // pip  = front
            self?.pipModel.snapshot     = nil
        }
    }

    /// Swaps main vs PiP preview in Front/Back mode.
    /// The recording outputs (front→frontFile, rear→rearFile) are unchanged.
    func swapFrontBackAssignment() {
        guard settings.isFrontBackMode else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let old = self.previewLayer
            self.previewLayer          = self.secondaryPreviewLayer
            self.secondaryPreviewLayer = old
        }
    }

    // MARK: - Device Configuration

    private func configureDevice(
        _ device: AVCaptureDevice,
        frameRate: FrameRate,
        resolution: VideoResolution,
        multiCamOnly: Bool = false
    ) {
        let targetWidth = resolution.longSide
        let targetHeight = resolution.shortSide

        guard let best = DeviceCapabilities.bestFormat(
            for: device,
            targetWidth: targetWidth,
            targetHeight: targetHeight,
            frameRate: frameRate,
            multiCamOnly: multiCamOnly
        ) else { return }

        // Clamp to the actual max fps the selected format supports.
        // When multiCamOnly falls back to a lower-quality format (e.g. 4K 60fps
        // isn't available in MultiCam so we get 4K 30fps), the range's maxFrameRate
        // may be below the user's requested fps. Setting an unsupported duration throws
        // a fatal NSException ("Unsupported frame duration"), so we cap it here.
        let targetFPS = Float64(frameRate.rawValue)
        let supportedFPS = min(targetFPS, best.frameRateRange.maxFrameRate)
        let actualDuration = CMTimeMake(value: 1, timescale: Int32(supportedFPS))

        do {
            try device.lockForConfiguration()
            device.activeFormat = best.format
            device.activeVideoMinFrameDuration = actualDuration
            device.activeVideoMaxFrameDuration = actualDuration
            device.unlockForConfiguration()
        } catch {
            print("CameraManager: Failed to configure device: \(error)")
        }

        // Diagnostic: log the FOV of the selected format so we can verify the
        // widest-FOV format is being chosen (not the narrower "standard selfie" one).
        let dims = CMVideoFormatDescriptionGetDimensions(best.format.formatDescription)
        let fov  = best.format.videoFieldOfView
        print("📷 CameraManager: \(device.localizedName) → \(dims.width)×\(dims.height) " +
              "@ \(Int(supportedFPS)) fps, FOV=\(String(format: "%.1f", fov))°")
    }

    // MARK: - Cost Monitoring (Dual-Lens)

    private func monitorSessionCosts(_ session: AVCaptureMultiCamSession) {
        // Check periodically on the session queue
        sessionQueue.asyncAfter(deadline: .now() + 5.0) { [weak self, weak session] in
            guard let self = self, let session = session, session.isRunning else { return }
            let hw = session.hardwareCost
            let sp = session.systemPressureCost

            DispatchQueue.main.async {
                self.hardwareCost = hw
                self.systemPressureCost = sp
            }

            if hw > 1.0 {
                print("CameraManager: WARNING - Hardware cost \(hw) exceeds 1.0. Session may fail.")
            }

            self.monitorSessionCosts(session)
        }
    }

    // MARK: - Recording Control

    func startRecording() {
        print("★ CameraManager.startRecording() — dualLensRecorder=\(dualLensRecorder != nil) singleLensRecorder=\(singleLensRecorder != nil) frontBackRecorder=\(frontBackRecorder != nil) wideDeviceRef=\(wideDeviceRef != nil)")
        guard !isRecording else { return }

        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = true  // prevent screen sleep during recording
            self.isRecording  = true
            self.isPaused     = false
            self.saveComplete = false
            self.saveError    = nil
            self.recordingDuration    = 0
            self.totalPausedDuration  = 0
            self.pauseStartTime       = nil
            self.recordingStartTime   = Date()
        }

        // Start timer on main thread
        DispatchQueue.main.async {
            self.recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self = self, let start = self.recordingStartTime else { return }
                self.recordingDuration = Date().timeIntervalSince(start) - self.totalPausedDuration
            }
        }

        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if let fbRecorder = self.frontBackRecorder {
                fbRecorder.startRecording(
                    frontDevice: self.frontDeviceRef,
                    rearDevice:  self.wideDeviceRef
                )
            } else if let dualRecorder = self.dualLensRecorder,
                      let wide = self.wideDeviceRef {
                dualRecorder.startRecording(
                    wideDevice: wide,
                    ultraWideDevice: self.ultraWideDeviceRef
                )
            } else if let singleRecorder = self.singleLensRecorder {
                // Single Lens mode (wide rear) or front camera mode — both use SingleLensRecorder.
                // wideDeviceRef is set in configureWideOnlySession; frontDeviceRef in configureFrontCameraSession.
                let device = self.wideDeviceRef ?? self.frontDeviceRef
                if let device = device {
                    singleRecorder.startRecording(device: device)
                }
            }
        }
    }

    func pauseRecording() {
        guard isRecording, !isPaused else { return }
        DispatchQueue.main.async {
            self.isPaused = true
            self.pauseStartTime = Date()
            self.recordingTimer?.invalidate()
            self.recordingTimer = nil
        }
        sessionQueue.async { [weak self] in
            self?.dualLensRecorder?.pause()
            self?.singleLensRecorder?.pause()
            self?.frontBackRecorder?.pause()
        }
    }

    func resumeRecording() {
        guard isRecording, isPaused else { return }
        DispatchQueue.main.async {
            self.isPaused = false
            if let start = self.pauseStartTime {
                self.totalPausedDuration += Date().timeIntervalSince(start)
            }
            self.pauseStartTime = nil
            // Restart the display timer from the frozen elapsed time
            self.recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self = self, let start = self.recordingStartTime else { return }
                self.recordingDuration = Date().timeIntervalSince(start) - self.totalPausedDuration
            }
        }
        sessionQueue.async { [weak self] in
            self?.dualLensRecorder?.resume()
            self?.singleLensRecorder?.resume()
            self?.frontBackRecorder?.resume()
        }
    }

    func stopRecording() {
        guard isRecording else { return }

        // Request background execution time BEFORE stopping — this keeps the app alive
        // long enough for AVAssetWriter to finishWriting() even if the user has already
        // switched away or locked the screen.
        beginBackgroundTaskIfNeeded()

        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = false  // re-enable screen sleep
            self.isRecording = false
            self.isPaused    = false
            self.pauseStartTime = nil
            self.recordingTimer?.invalidate()
            self.recordingTimer = nil
            self.isSaving = true
        }

        sessionQueue.async { [weak self] in
            guard let self = self else { return }

            let completion: (URL, URL) -> Void = { [weak self] url1, url2 in
                self?.saveRecordedFiles(portraitURL: url1, landscapeURL: url2)
            }

            let errorHandler: (String) -> Void = { [weak self] error in
                DispatchQueue.main.async {
                    self?.isSaving = false
                    self?.saveError = error
                    self?.endBackgroundTaskIfNeeded()
                }
            }

            if let fbRecorder = self.frontBackRecorder {
                fbRecorder.stopRecording(completion: completion, error: errorHandler)
            } else if let dualRecorder = self.dualLensRecorder {
                dualRecorder.stopRecording(completion: completion, error: errorHandler)
            } else if let singleRecorder = self.singleLensRecorder {
                singleRecorder.stopRecording(completion: completion, error: errorHandler)
            }
        }
    }

    // MARK: - Save Files

    private func saveRecordedFiles(portraitURL: URL, landscapeURL: URL) {
        PhotoLibrarySaver.saveBothVideos(
            portraitURL: portraitURL,
            landscapeURL: landscapeURL
        ) { [weak self] result in
            DispatchQueue.main.async {
                self?.isSaving = false
                switch result {
                case .success:
                    self?.saveComplete = true
                    // Clean up temp files
                    try? FileManager.default.removeItem(at: portraitURL)
                    try? FileManager.default.removeItem(at: landscapeURL)
                case .failure(let error):
                    self?.saveError = error.localizedDescription
                    // Clean up temp files even on failure — don't leave them accumulating
                    try? FileManager.default.removeItem(at: portraitURL)
                    try? FileManager.default.removeItem(at: landscapeURL)
                }
                // Release the background task now that we're fully done saving.
                self?.endBackgroundTaskIfNeeded()
            }
        }
    }

    // MARK: - Torch

    func setTorch(_ mode: TorchMode) {
        guard let device = DeviceCapabilities.wideCamera, device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            switch mode {
            case .on:
                try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
            case .off:
                device.torchMode = .off
            }
            device.unlockForConfiguration()
        } catch {
            print("CameraManager: Torch error: \(error)")
        }
    }


    // MARK: - Mode Switching

    /// Reconfigures the session when settings change.
    func reconfigure(with newSettings: RecordingSettings) {
        guard !isRecording else { return }
        self.settings = newSettings
        startSession()
    }
}

