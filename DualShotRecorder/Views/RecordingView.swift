import SwiftUI
import AVFoundation
import StoreKit

// MARK: - Camera Preview UIViewRepresentable

/// Wraps AVCaptureVideoPreviewLayer in a UIView for use in SwiftUI.
struct CameraPreviewView: UIViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer?

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        uiView.layer.sublayers?.forEach { layer in
            if layer is AVCaptureVideoPreviewLayer {
                layer.removeFromSuperlayer()
            }
        }
        if let previewLayer = previewLayer {
            previewLayer.frame = uiView.bounds
            previewLayer.videoGravity = .resizeAspectFill
            uiView.layer.addSublayer(previewLayer)
        }
    }
}

class PreviewUIView: UIView {
    var previewLayer: AVCaptureVideoPreviewLayer?

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
    }
}

struct CameraPreviewContainer: UIViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer?

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.backgroundColor = .black
        if let layer = previewLayer {
            view.previewLayer = layer
            layer.videoGravity = .resizeAspectFill
            view.layer.addSublayer(layer)
        }
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        guard uiView.previewLayer !== previewLayer else {
            // Same layer — just keep the frame correct.
            uiView.previewLayer?.frame = uiView.bounds
            return
        }

        // Only remove the outgoing layer if THIS view still owns it.
        // When two containers swap layers in the same render pass the other
        // container's updateUIView may have already moved the layer away, and
        // calling removeFromSuperlayer() would wrongly rip it out of its new home.
        if let old = uiView.previewLayer, old.superlayer === uiView.layer {
            old.removeFromSuperlayer()
        }

        uiView.previewLayer = previewLayer

        if let layer = previewLayer {
            layer.videoGravity = .resizeAspectFill
            // Only add if this view doesn't already own it (avoids double-add).
            if layer.superlayer !== uiView.layer {
                uiView.layer.addSublayer(layer)
            }
        }

        uiView.previewLayer?.frame = uiView.bounds
    }
}

// MARK: - Main Recording View

struct RecordingView: View {
    @StateObject private var settings = RecordingSettings()
    @StateObject private var permissions = PermissionsManager()
    @StateObject private var cameraManager: CameraManager
    @StateObject private var callMonitor = CallStateMonitor()

    @Environment(\.requestReview) private var requestReview

    @State private var showSettings = false
    @State private var showSaveConfirmation = false
    @State private var showUnsupportedAlert = false

    // Zoom gesture state
    @State private var lastZoomFactor: CGFloat = 1.0
    @State private var showZoomIndicator = false
    @State private var zoomHideTask: Task<Void, Never>? = nil

    // Draggable PiP thumbnail state
    // nil = default position (centered above record button)
    @State private var thumbnailPosition: CGPoint? = nil
    @State private var thumbnailDragOffset: CGSize = .zero


    // PiP thumbnail dimensions (15% larger than the previous 180×101)
    private let thumbW: CGFloat = 207
    private let thumbH: CGFloat = 116
    private let thumbPad: CGFloat = 16      // padding from screen edges
    private let thumbTopInset: CGFloat = 70 // clear the top bar
    private let thumbBottomInset: CGFloat = 175 // sits just above the record button

    // MARK: - Preview Layer Routing
    // Wide is always previewLayer, ultra-wide is always secondaryPreviewLayer.
    // When the user swaps assignment, we route them to different positions on screen
    // so the viewfinder matches what will actually be recorded.

    private var isDualRearMode: Bool {
        !settings.isSingleLensMode && !settings.isFrontBackMode && !settings.dualLensUseFrontCamera
    }

    private var mainPreviewLayer: AVCaptureVideoPreviewLayer? {
        if isDualRearMode && !settings.cameraAssignment.wideIsPortrait {
            return cameraManager.secondaryPreviewLayer ?? cameraManager.previewLayer
        }
        return cameraManager.previewLayer
    }

    private var pipPreviewLayer: AVCaptureVideoPreviewLayer? {
        if isDualRearMode && !settings.cameraAssignment.wideIsPortrait {
            return cameraManager.previewLayer
        }
        return cameraManager.secondaryPreviewLayer
    }

    init() {
        let s = RecordingSettings()
        _settings = StateObject(wrappedValue: s)
        _cameraManager = StateObject(wrappedValue: CameraManager(settings: s))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if permissions.allPermissionsGranted {
                cameraView
            } else {
                permissionsView
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(cameraManager.isRecording)
        .onAppear {
            permissions.checkCurrentStatus()
            if let saved = settings.savedThumbnailPosition {
                thumbnailPosition = saved
            }
        }
        .task {
            // Only requests permissions on first launch.
            // Camera start is handled by onChange(of: permissions.allPermissionsGranted) —
            // that fires whether permissions flip here or in checkCurrentStatus() above.
            if !permissions.allPermissionsGranted {
                await permissions.requestAllPermissions()
            }
        }
        .onChange(of: permissions.allPermissionsGranted) { granted in
            if granted {
                cameraManager.reconfigure(with: settings)
            }
        }
        .onChange(of: cameraManager.saveComplete) { saved in
            if saved {
                showSaveConfirmation = true
                // Request a review after the banner has been visible for ~1 second.
                // Apple throttles this to a max of 3 prompts per year — no extra
                // rate-limiting needed on our side.
                #if !DEBUG
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    // Never interrupt an in-progress recording with the rating prompt.
                    // (The user can stop+save, then immediately start a new take within
                    // this 1s window — guard against showing the sheet mid-record.)
                    if !cameraManager.isRecording {
                        requestReview()
                    }
                }
                #endif
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    showSaveConfirmation = false
                }
            }
        }
        .onChange(of: cameraManager.zoomFactor) { factor in
            if factor == 1.0 { lastZoomFactor = 1.0 }
        }
        // When a call ends (or the capture interruption clears), restart the camera
        // session so the preview recovers without requiring the user to relaunch.
        .onChange(of: callMonitor.isOnCall) { isOnCall in
            if !isOnCall && !callMonitor.isCaptureInterrupted {
                cameraManager.reconfigure(with: settings)
            }
        }
        .onChange(of: callMonitor.isCaptureInterrupted) { interrupted in
            if !interrupted && !callMonitor.isOnCall {
                cameraManager.reconfigure(with: settings)
            }
        }
    }

    // MARK: - Camera View

    private var cameraView: some View {
        GeometryReader { geo in
            ZStack {
                // Live camera preview — pinch to zoom, double-tap to reset
                CameraPreviewContainer(previewLayer: mainPreviewLayer)
                    .ignoresSafeArea()
                    .gesture(
                        MagnificationGesture()
                            .onChanged { scale in
                                cameraManager.setZoom(lastZoomFactor * scale)
                                showZoomIndicator = true
                                zoomHideTask?.cancel()
                            }
                            .onEnded { _ in
                                lastZoomFactor = cameraManager.zoomFactor
                                scheduleZoomIndicatorHide()
                            }
                    )
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded {
                            cameraManager.resetZoom()
                            lastZoomFactor = 1.0
                            showZoomIndicator = true
                            scheduleZoomIndicatorHide()
                        }
                    )

                // Teleprompter overlay — sits just below the top bar
                if settings.showTeleprompter {
                    VStack {
                        TeleprompterView(
                            text: settings.teleprompterText,
                            speed: $settings.teleprompterSpeed
                        )
                        .frame(height: 267)
                        .cornerRadius(12)
                        .padding(.horizontal, 12)
                        .padding(.top, 60)
                        Spacer()
                    }
                    .allowsHitTesting(true)
                }

                // Rule-of-thirds grid overlay
                if settings.showGrid {
                    GridOverlay()
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }

                // Horizon level indicator
                if settings.showLevel {
                    LevelIndicator()
                        .allowsHitTesting(false)
                }

                // Single Lens framing guide — only visible in Single Lens rear-camera mode.
                // Dims the portrait-only regions and draws a border around the landscape
                // (16:9) center strip so the user can frame both outputs simultaneously.
                if settings.isSingleLensMode {
                    singleLensFramingOverlay(in: geo)
                }

                // PiP thumbnail — draggable, snaps to corners
                pipThumbnail(in: geo)

                // UI overlay — top bar + record row + bottom bar
                VStack {
                    topBar
                    Spacer()
                    bottomControls
                }

                // Pause / resume — bottom-left while recording
                if cameraManager.isRecording {
                    VStack {
                        Spacer()
                        HStack {
                            PauseButton(isPaused: cameraManager.isPaused) {
                                if cameraManager.isPaused {
                                    cameraManager.resumeRecording()
                                } else {
                                    cameraManager.pauseRecording()
                                }
                            }
                            .padding(.leading, 44)
                            .padding(.bottom, 48)
                            Spacer()
                        }
                    }
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: cameraManager.isRecording)
                }

                // Zoom level indicator
                if showZoomIndicator {
                    VStack {
                        Spacer()
                        Text(String(format: "%.1f×", cameraManager.zoomFactor))
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Color.black.opacity(0.55)))
                            .padding(.bottom, 160)
                    }
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: showZoomIndicator)
                }

                // Save confirmation banner
                if showSaveConfirmation {
                    saveConfirmationBanner
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .animation(.easeInOut(duration: 0.3), value: showSaveConfirmation)
                }

                // Saving overlay
                if cameraManager.isSaving {
                    savingOverlay
                }

                // Phone call / VoIP blocking overlay — sits on top of everything.
                // Shown when CXCallObserver detects an active call OR when the
                // AVCaptureSession is interrupted by another process using the camera.
                // Dismisses automatically when the call ends; no user action needed.
                let isBlocking = callMonitor.isOnCall || callMonitor.isCaptureInterrupted
                if isBlocking {
                    phoneCallOverlay
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.35), value: isBlocking)
                        .zIndex(100)
                }
            }
            .animation(.easeInOut(duration: 0.35),
                       value: callMonitor.isOnCall || callMonitor.isCaptureInterrupted)
        }
    }

    // MARK: - Single Lens Framing Overlay

    /// Visual guide shown in Single Lens mode so the user can see both output frames at once.
    ///
    /// The portrait preview fills the screen (9:16).  The landscape output is a 16:9 crop
    /// taken from the horizontal center of that same frame.  This overlay:
    ///  • dims the top and bottom strips (portrait-only areas, not in the landscape output)
    ///  • leaves the center window clear (the landscape region)
    ///  • draws a border around the landscape window: white when idle, red when recording
    @ViewBuilder
    private func singleLensFramingOverlay(in geo: GeometryProxy) -> some View {
        // Use geo.size.width for the strip calculation (width is reliable regardless of safe areas).
        // Height must be measured AFTER ignoresSafeArea() so it reflects the full screen height
        // including the Dynamic Island and home indicator — hence the inner GeometryReader.
        let W = geo.size.width
        let stripH = W * (9.0 / 16.0)
        let borderColor: Color = (cameraManager.isRecording && !cameraManager.isPaused) ? .red : .white

        GeometryReader { fullGeo in
            let fullH = fullGeo.size.height
            let capH  = max((fullH - stripH) / 2, 0)

            VStack(spacing: 0) {
                // Top dimmed cap — portrait-only region (not captured in landscape output)
                Rectangle()
                    .fill(Color.black.opacity(0.35))
                    .frame(height: capH)

                // Landscape window — clear center with border showing the 16:9 crop area
                Color.clear
                    .frame(height: max(stripH, 0))
                    .overlay(
                        Rectangle()
                            .strokeBorder(borderColor, lineWidth: 2)
                    )

                // Bottom dimmed cap — portrait-only region (not captured in landscape output)
                Rectangle()
                    .fill(Color.black.opacity(0.35))
                    .frame(height: capH)
            }
            .frame(width: fullGeo.size.width, height: fullH)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)   // pass through all taps/gestures to the camera preview
    }

    // MARK: - Draggable PiP Thumbnail

    @ViewBuilder
    private func pipThumbnail(in geo: GeometryProxy) -> some View {
        // Front/Back uses a portrait-shaped PiP pinned to the top-right (matches the
        // composited export). Other modes keep the landscape PiP centered above the controls.
        let isFB = settings.isFrontBackMode
        let pipW: CGFloat = isFB ? 116 : thumbW
        let pipH: CGFloat = isFB ? 206 : thumbH   // portrait 9:16
        let defaultPos: CGPoint = isFB
            ? CGPoint(x: geo.size.width - pipW / 2 - 14,
                      y: pipH / 2 + 64)
            : CGPoint(x: geo.size.width / 2,
                      y: geo.size.height - thumbH / 2 - thumbBottomInset)
        // Front/Back pins the PiP to a fixed top-right slot. It must NOT inherit the
        // draggable position saved by the (shorter, landscape) PiP in other modes —
        // that value lands the taller portrait PiP in the corner, clipped off-screen.
        let base = isFB ? defaultPos : (thumbnailPosition ?? defaultPos)
        let display = isFB ? base : CGPoint(
            x: base.x + thumbnailDragOffset.width,
            y: base.y + thumbnailDragOffset.height
        )

        Group {
            if let secondaryLayer = pipPreviewLayer {
                // Dual lens: secondary preview layer (respects camera assignment swap)
                CameraPreviewContainer(previewLayer: secondaryLayer)
                    .frame(width: pipW, height: pipH)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(
                                (cameraManager.isRecording && !cameraManager.isPaused) ? Color.red : Color.white.opacity(0.4),
                                lineWidth: 1.5
                            )
                    )
                    .shadow(color: .black.opacity(0.5), radius: 8, x: 0, y: 4)
                    .position(display)
                    .gesture(
                        DragGesture()
                            .onChanged { v in thumbnailDragOffset = v.translation }
                            .onEnded { v in
                                let dropped = CGPoint(
                                    x: base.x + v.translation.width,
                                    y: base.y + v.translation.height
                                )
                                let snapped = snapToCorner(dropped, in: geo.size)
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                    thumbnailPosition = snapped
                                    thumbnailDragOffset = .zero
                                }
                                settings.savedThumbnailPosition = snapped
                            }
                    )
            } else if settings.dualLensUseFrontCamera && !settings.isSingleLensMode {
                // Dual mode flipped to front: front fullscreen + generated PiP (wide FOV).
                // (Single-lens front uses the crop + framing guide instead — no PiP.)
                FrontCameraPipImage(
                    pipModel: cameraManager.pipModel,
                    thumbW: thumbW,
                    thumbH: thumbH,
                    isActive: cameraManager.isRecording && !cameraManager.isPaused
                )
                .position(display)
                .gesture(
                    DragGesture()
                        .onChanged { v in thumbnailDragOffset = v.translation }
                        .onEnded { v in
                            let dropped = CGPoint(
                                x: base.x + v.translation.width,
                                y: base.y + v.translation.height
                            )
                            let snapped = snapToCorner(dropped, in: geo.size)
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                thumbnailPosition = snapped
                                thumbnailDragOffset = .zero
                            }
                            settings.savedThumbnailPosition = snapped
                        }
                )
            }
        }
    }

    /// Snaps a dragged point to the nearest of four corners, respecting
    /// the top-bar and record-button safe areas.
    private func snapToCorner(_ point: CGPoint, in size: CGSize) -> CGPoint {
        let hw = thumbW / 2 + thumbPad
        let hh = thumbH / 2 + thumbPad
        let corners: [CGPoint] = [
            CGPoint(x: hw,                  y: hh + thumbTopInset),              // top-left
            CGPoint(x: size.width / 2,      y: hh + thumbTopInset),              // top-center
            CGPoint(x: size.width - hw,     y: hh + thumbTopInset),              // top-right
            CGPoint(x: hw,                  y: size.height - hh - thumbBottomInset), // bottom-left
            CGPoint(x: size.width / 2,      y: size.height - hh - thumbBottomInset), // bottom-center
            CGPoint(x: size.width - hw,     y: size.height - hh - thumbBottomInset), // bottom-right
        ]
        return corners.min(by: { hypot($0.x - point.x, $0.y - point.y) <
                                 hypot($1.x - point.x, $1.y - point.y) }) ?? point
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(alignment: .center) {
            // Left: resolution/fps pill (idle) → opens Settings; recording timer while recording
            if cameraManager.isRecording {
                HStack(spacing: 5) {
                    Circle()
                        .fill(cameraManager.isPaused ? Color.yellow : Color.red)
                        .frame(width: 8, height: 8)
                    Text(formattedDuration(cameraManager.recordingDuration))
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .foregroundColor(cameraManager.isPaused ? .yellow : .red)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.black.opacity(0.45)))
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: cameraManager.isPaused)
            } else {
                resolutionPill
            }

            Spacer()

            // Right: flash + settings — hidden while recording
            if !cameraManager.isRecording {
                HStack(spacing: 22) {
                    // Flash / torch — only meaningful on the rear camera (hidden when flipped to front)
                    if !settings.dualLensUseFrontCamera {
                        Button {
                            let newMode: TorchMode = settings.torchMode == .off ? .on : .off
                            settings.torchMode = newMode
                            cameraManager.setTorch(newMode)
                        } label: {
                            Image(systemName: settings.torchMode == .on ? "bolt.fill" : "bolt.slash.fill")
                                .font(.system(size: 20))
                                .foregroundColor(settings.torchMode == .on ? .yellow : .white)
                        }
                    }

                    // Settings (full sheet)
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.white)
                    }
                    .sheet(isPresented: $showSettings, onDismiss: {
                        cameraManager.reconfigure(with: settings)
                    }) {
                        SettingsSheet(settings: settings)
                            .presentationDetents([.medium, .large])
                    }
                }
                .frame(height: 44)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .animation(.easeInOut(duration: 0.2), value: cameraManager.isRecording)
    }

    /// Compact "1080p RES | 30 FPS" pill shown top-left. Tapping opens Settings.
    private var resolutionPill: some View {
        HStack(spacing: 5) {
            Text(settings.resolution.rawValue)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
            Text("RES")
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(.white.opacity(0.55))
            Rectangle()
                .fill(Color.white.opacity(0.3))
                .frame(width: 1, height: 11)
            Text("\(settings.frameRate.rawValue)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
            Text("FPS")
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(.white.opacity(0.55))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.black.opacity(0.45)))
    }

    // MARK: - Capture Mode

    private enum CaptureMode: String, CaseIterable {
        case dual      = "Dual"
        case single    = "Single"
        case frontBack = "Front/Back"
    }

    private var currentCaptureMode: CaptureMode {
        if settings.isFrontBackMode  { return .frontBack }
        if settings.isSingleLensMode { return .single }
        return .dual
    }

    /// Switches to the given mode, reconfiguring the session.
    /// No-ops if already recording.
    private func switchToMode(_ mode: CaptureMode) {
        guard !cameraManager.isRecording else { return }
        settings.torchMode = .off
        thumbnailPosition = nil
        settings.savedThumbnailPosition = nil
        // Every mode (re)enters on the rear camera — clear any prior front flip.
        settings.dualLensUseFrontCamera = false
        switch mode {
        case .dual:
            settings.isSingleLensMode = false
            settings.isFrontBackMode  = false
        case .single:
            settings.isSingleLensMode = true
            settings.isFrontBackMode  = false
        case .frontBack:
            settings.isSingleLensMode = false
            settings.isFrontBackMode  = true
        }
        cameraManager.reconfigure(with: settings)
    }

    /// Flips the active capture between the rear and front camera.
    /// Drives the `dualLensUseFrontCamera` flag, which the session router honors for
    /// Dual and Single modes (configureFrontCameraSession). No-op while recording, and
    /// ignored in Front/Back mode (which already runs front + rear simultaneously).
    private func flipCamera() {
        // Front/Back: swap which camera is fullscreen vs PiP. This is a live composite
        // change (no session rebuild), so it's allowed even mid-recording.
        if settings.isFrontBackMode {
            cameraManager.swapFrontBackMain()
            return
        }
        // Dual/Single: flip to the front camera — needs a session reconfigure, so it's
        // only allowed when not recording.
        guard !cameraManager.isRecording else { return }
        settings.torchMode = .off
        settings.dualLensUseFrontCamera.toggle()
        cameraManager.reconfigure(with: settings)
    }

    /// Swaps which lens feeds portrait vs. landscape in dual rear mode.
    /// Flips the recorder delegates without tearing down the session — no black-screen glitch.
    private func toggleLensAssignment() {
        guard !cameraManager.isRecording else { return }
        settings.cameraAssignment = settings.cameraAssignment == .widePortrait
            ? .wideLeftLandscape : .widePortrait
        cameraManager.swapDualLensAssignment()
    }

    // MARK: - Zoom Helpers

    private func scheduleZoomIndicatorHide() {
        zoomHideTask?.cancel()
        zoomHideTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { showZoomIndicator = false }
        }
    }

    // MARK: - Timer Formatting

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let s = Int(duration)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    // MARK: - Bottom Controls

    /// The full bottom control stack: the record row (with the lens/zoom toggle) and,
    /// below it, the action bar (gallery · mode selector · flip-camera).
    /// The action bar fades out while recording so the record button never shifts.
    private var bottomControls: some View {
        // Two independent layers, both pinned to the bottom:
        //  • Side controls (gallery/lens toggle on the left, flip on the right) in the corners
        //  • A centered column with the record button directly above the mode pill
        // Keeping them separate means the side buttons' heights never push the record
        // button up — it stays low, just above the mode pill, in every mode.
        ZStack(alignment: .bottom) {
            HStack(alignment: .bottom) {
                VStack(spacing: 10) {
                    if isDualRearMode { lensZoomToggle }
                    galleryButton
                }
                .opacity(cameraManager.isRecording ? 0 : 1)
                .allowsHitTesting(!cameraManager.isRecording)

                Spacer()

                // Flip stays available while recording in Front/Back (live main/PiP swap);
                // in other modes it hides during recording (it would need a session rebuild).
                if !cameraManager.isRecording || settings.isFrontBackMode {
                    flipCameraButton
                } else {
                    Color.clear.frame(width: 48, height: 48)
                }
            }
            .padding(.horizontal, 16)

            VStack(spacing: 16) {
                recordButton
                // Reserve the mode pill's space while recording so the record button
                // never shifts when the pill fades out.
                modeSelector
                    .opacity(cameraManager.isRecording ? 0 : 1)
            }
        }
        .padding(.bottom, 28)
        .animation(.easeInOut(duration: 0.2), value: cameraManager.isRecording)
    }

    /// The record / stop button plus its 4K-in-dual guard alert.
    private var recordButton: some View {
        Group {
            if cameraManager.isRecording {
                RecordButton(isRecording: true) { cameraManager.stopRecording() }
            } else {
                RecordButton(isRecording: false) {
                    if settings.resolution == .uhd4K && isDualRearMode {
                        showUnsupportedAlert = true
                    } else {
                        cameraManager.startRecording()
                    }
                }
            }
        }
        .alert("Unsupported Setting", isPresented: $showUnsupportedAlert) {
            Button("Open Settings") { showSettings = true }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("4K is not supported in Dual Lens mode. Use 1080p for Dual Lens recording.")
        }
    }

    /// Two-stop lens toggle (0.5× ultrawide ⇄ 1× wide). Tapping swaps which rear lens
    /// records portrait vs landscape — drives the existing swapDualLensAssignment().
    /// Only shown in dual rear mode.
    private var lensZoomToggle: some View {
        Button { toggleLensAssignment() } label: {
            Text(settings.cameraAssignment.wideIsPortrait ? "1×" : "0.5×")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 48, height: 48)
                .background(Circle().fill(Color.black.opacity(0.45)))
        }
    }

    /// Opens the Photos app to the user's camera roll.
    private var galleryButton: some View {
        Button {
            if let url = URL(string: "photos-redirect://") {
                UIApplication.shared.open(url)
            }
        } label: {
            Image(systemName: "photo.stack")
                .font(.system(size: 18))
                .foregroundColor(.white)
                .frame(width: 48, height: 48)
                .background(Circle().fill(Color.black.opacity(0.45)))
        }
    }

    /// Flips the active capture to the front camera (Dual/Single modes) and back.
    private var flipCameraButton: some View {
        Button { flipCamera() } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 48, height: 48)
                .background(Circle().fill(Color.black.opacity(0.45)))
        }
    }

    // MARK: - Mode Selector

    /// Three-way mode picker — centered directly below the record button.
    /// Fades out while recording so the record button layout stays stable.
    private var modeSelector: some View {
        HStack(spacing: 0) {
            ForEach(CaptureMode.allCases, id: \.self) { mode in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { switchToMode(mode) }
                } label: {
                    Text(mode.rawValue)
                        .font(.system(size: 14,
                                      weight: currentCaptureMode == mode ? .semibold : .regular))
                        .foregroundColor(currentCaptureMode == mode ? .black : .white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(
                            Group {
                                if currentCaptureMode == mode {
                                    Capsule().fill(Color.yellow)
                                }
                            }
                        )
                }
                .disabled(cameraManager.isRecording)
            }
        }
        .background(Capsule().fill(Color.black.opacity(0.55)))
    }

    // MARK: - Save Confirmation

    private var saveConfirmationBanner: some View {
        VStack {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 22))
                Text(settings.isFrontBackMode ? "VIDEO SAVED TO PHOTOS" : "2 VIDEOS SAVED TO PHOTOS")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color.black.opacity(0.75)))
            .padding(.top, 60)
            Spacer()
        }
    }

    // MARK: - Saving Overlay

    private var savingOverlay: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView().tint(.white).scaleEffect(1.5)
                Text("Saving to Photos...")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white)
            }
            .padding(32)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.7)))
        }
    }

    // MARK: - Phone Call Overlay

    /// Full-screen blur + message shown when the camera is unavailable during a call.
    /// Uses `.ultraThinMaterial` (dark variant, because the app enforces `.dark` color scheme)
    /// which feels like a native iOS interruption state rather than a flat dim.
    private var phoneCallOverlay: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "phone.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.white.opacity(0.85))

                Text("Camera Unavailable")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundColor(.white)

                Text("EverShot can't access the camera while you're on a call. End the call and the camera will resume automatically.")
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 44)
            }
        }
    }

    // MARK: - Permissions View

    private var permissionsView: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "camera.fill")
                .font(.system(size: 60))
                .foregroundColor(.white.opacity(0.6))
            Text("EverShot needs access to your camera, microphone, and Photos to record video.")
                .font(.system(size: 17))
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            VStack(spacing: 12) {
                permissionRow(icon: "camera.fill",  title: "Camera",      granted: permissions.cameraAuthorized)
                permissionRow(icon: "mic.fill",     title: "Microphone",  granted: permissions.microphoneAuthorized)
                permissionRow(icon: "photo.fill",   title: "Photos",      granted: permissions.photoLibraryAuthorized)
            }
            .padding(.horizontal, 40)
            Button {
                Task { await permissions.requestAllPermissions() }
            } label: {
                Text("Grant Permissions")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(Color.yellow))
            }
            Button("Open Settings") { PermissionsManager.openSettings() }
                .font(.system(size: 15))
                .foregroundColor(.white.opacity(0.6))
            Spacer()
        }
    }

    private func permissionRow(icon: String, title: String, granted: Bool) -> some View {
        HStack {
            Image(systemName: icon).frame(width: 24).foregroundColor(.white.opacity(0.7))
            Text(title).foregroundColor(.white)
            Spacer()
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundColor(granted ? .green : .white.opacity(0.4))
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Front Camera PiP Image
//
// Isolated ObservableObject observer so that per-frame snapshot updates
// only re-render this small view, not RecordingView as a whole.

private struct FrontCameraPipImage: View {
    @ObservedObject var pipModel: FrontCameraPipModel
    let thumbW: CGFloat
    let thumbH: CGFloat
    let isActive: Bool

    var body: some View {
        Group {
            if let snapshot = pipModel.snapshot {
                Image(decorative: snapshot, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.black
            }
        }
        .frame(width: thumbW, height: thumbH)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isActive ? Color.red : Color.white.opacity(0.4),
                    lineWidth: 1.5
                )
        )
        .shadow(color: .black.opacity(0.5), radius: 8, x: 0, y: 4)
    }
}

// MARK: - Grid Overlay

struct GridOverlay: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            Path { path in
                // Two vertical lines (rule of thirds)
                path.move(to: CGPoint(x: w / 3, y: 0))
                path.addLine(to: CGPoint(x: w / 3, y: h))
                path.move(to: CGPoint(x: w * 2 / 3, y: 0))
                path.addLine(to: CGPoint(x: w * 2 / 3, y: h))
                // Two horizontal lines (rule of thirds)
                path.move(to: CGPoint(x: 0, y: h / 3))
                path.addLine(to: CGPoint(x: w, y: h / 3))
                path.move(to: CGPoint(x: 0, y: h * 2 / 3))
                path.addLine(to: CGPoint(x: w, y: h * 2 / 3))
            }
            .stroke(Color.white.opacity(0.4), lineWidth: 0.7)
        }
    }
}
