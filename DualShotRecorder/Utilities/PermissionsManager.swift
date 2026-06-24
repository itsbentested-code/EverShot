import AVFoundation
import Photos
import SwiftUI

/// Manages requesting and checking camera, microphone, and photo library permissions.
final class PermissionsManager: ObservableObject {

    @Published var cameraAuthorized = false
    @Published var microphoneAuthorized = false
    @Published var photoLibraryAuthorized = false

    /// Whether all required permissions are granted
    var allPermissionsGranted: Bool {
        cameraAuthorized && microphoneAuthorized && photoLibraryAuthorized
    }

    /// Checks current authorization status without prompting
    func checkCurrentStatus() {
        cameraAuthorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        microphoneAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

        let photoStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        photoLibraryAuthorized = (photoStatus == .authorized || photoStatus == .limited)
    }

    /// Requests all permissions sequentially
    func requestAllPermissions() async {
        // Camera
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            await MainActor.run { cameraAuthorized = granted }
        } else {
            await MainActor.run {
                cameraAuthorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
            }
        }

        // Microphone
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            await MainActor.run { microphoneAuthorized = granted }
        } else {
            await MainActor.run {
                microphoneAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            }
        }

        // Photo Library (add only)
        let photoStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if photoStatus == .notDetermined {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            await MainActor.run {
                photoLibraryAuthorized = (status == .authorized || status == .limited)
            }
        } else {
            await MainActor.run {
                photoLibraryAuthorized = (photoStatus == .authorized || photoStatus == .limited)
            }
        }
    }

    /// Opens the system Settings app to the app's settings page
    static func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
