import SwiftUI
import AVFoundation
import StoreKit

@main
struct EverShotApp: App {

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    // Session gate — prevents the review prompt firing more than once per process launch
    // (onAppear can fire multiple times as sheets open/close).
    @State private var hasRequestedReviewThisSession = false

    init() {
        configureAudioSession()
        // Increment exactly once per process launch using UserDefaults directly.
        // @AppStorage is not safe to write in init() before the property is fully initialized.
        let current = UserDefaults.standard.integer(forKey: "appLaunchCount")
        UserDefaults.standard.set(current + 1, forKey: "appLaunchCount")
    }

    var body: some Scene {
        WindowGroup {
            if hasCompletedOnboarding {
                RecordingView()
                    .onAppear {
                        requestReviewIfNeeded()
                    }
            } else {
                OnboardingView()
            }
        }
    }

    private func requestReviewIfNeeded() {
        guard !hasRequestedReviewThisSession else { return }
        let count = UserDefaults.standard.integer(forKey: "appLaunchCount")
        guard count >= 3 else { return }
        hasRequestedReviewThisSession = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            guard let scene = UIApplication.shared.connectedScenes
                .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
            else { return }
            SKStoreReviewController.requestReview(in: scene)
        }
    }

    private func configureAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .videoRecording, options: [
                .defaultToSpeaker,
                .allowBluetooth
            ])
            try audioSession.setActive(true)
        } catch {
            print("EverShotApp: Failed to configure audio session: \(error)")
        }
    }
}
