import Foundation
import CallKit
import AVFoundation

/// Watches for active phone/FaceTime/VoIP calls and AVCaptureSession interruptions.
///
/// Two signals are combined so that every path that can make the camera unavailable
/// is covered:
///
///  • `CXCallObserver`  — reliable for cellular calls and FaceTime Audio/Video (CallKit).
///  • `AVCaptureSessionWasInterruptedNotification` — catches third-party VoIP apps
///    (Zoom, WhatsApp, etc.) that interrupt the capture session without going through
///    CallKit.
///
/// Consumers observe `isBlocking` (computed from both signals).  When it becomes
/// `true`, show the "Camera Unavailable" overlay; when it becomes `false`, restart
/// the camera session.
final class CallStateMonitor: NSObject, ObservableObject, CXCallObserverDelegate {

    /// `true` while at least one phone / FaceTime call is active.
    @Published private(set) var isOnCall = false

    /// `true` while the capture session is interrupted by another process using
    /// the camera (VoIP apps, FaceTime video, etc.).
    @Published private(set) var isCaptureInterrupted = false

    /// Combined gate — `true` when either signal is active.
    var isBlocking: Bool { isOnCall || isCaptureInterrupted }

    private let callObserver = CXCallObserver()

    override init() {
        super.init()

        // Queue: .main ensures delegate callbacks arrive on the main actor,
        // which is required before writing to @Published properties.
        callObserver.setDelegate(self, queue: .main)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(captureSessionWasInterrupted(_:)),
            name: .AVCaptureSessionWasInterrupted,
            object: nil          // nil = observe all sessions
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(captureSessionInterruptionEnded(_:)),
            name: .AVCaptureSessionInterruptionEnded,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - CXCallObserverDelegate

    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        // Re-evaluate the full call list each time any call changes state.
        // `hasEnded` is the only reliable terminal state — checking the full
        // list (rather than just `call`) handles simultaneous-call edge cases.
        let active = callObserver.calls.contains { !$0.hasEnded }
        // Delegate queue is already .main, but guard with async to be safe
        // if Apple ever changes that behavior.
        DispatchQueue.main.async { self.isOnCall = active }
    }

    // MARK: - AVCaptureSession Interruption

    @objc private func captureSessionWasInterrupted(_ notification: Notification) {
        guard
            let rawValue = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int,
            let reason = AVCaptureSession.InterruptionReason(rawValue: rawValue)
        else { return }

        // .videoDeviceInUseByAnotherClient = another process has claimed the camera
        // hardware (FaceTime video, Zoom, WhatsApp video, etc.).  This is the only
        // reason we block on here; other reasons (audio-only, backgrounded app) don't
        // prevent the user from recording once the interruption ends.
        guard reason == .videoDeviceInUseByAnotherClient else { return }
        DispatchQueue.main.async { self.isCaptureInterrupted = true }
    }

    @objc private func captureSessionInterruptionEnded(_ notification: Notification) {
        DispatchQueue.main.async { self.isCaptureInterrupted = false }
    }
}
