import SwiftUI

struct PrivacyPolicyView: View {

    private let lastUpdated = "August 2026"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                Text("Last updated: \(lastUpdated)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                PolicySection(title: "Overview") {
                    """
                    EverShot ("the App") is a dual-camera video recording app. This policy explains what the App accesses, how that information is used, and what we do — and don't do — with it.

                    Your recordings stay on your device. We never see, upload, or store your videos. The only information that leaves your device is the limited data needed to process subscriptions and purchases, described below.
                    """
                }

                PolicySection(title: "Information We Do Not Collect") {
                    """
                    We do not collect, sell, or share:

                    • Your name, email address, or contact information
                    • Your location or GPS data
                    • Advertising identifiers — the App shows no ads
                    • The video, audio, or photo content you record
                    """
                }

                PolicySection(title: "Camera and Microphone Access") {
                    """
                    EverShot requires access to your device's cameras and microphone solely to record video. This content is processed entirely on your device and is never uploaded, streamed, or transmitted anywhere.

                    You can revoke camera and microphone access at any time in Settings → Privacy & Security on your iPhone.
                    """
                }

                PolicySection(title: "Photo Library Access") {
                    """
                    After recording, EverShot saves your video clips directly to your Photos library. The App requests write access to your photo library for this purpose only. We do not read, scan, or access any existing photos or videos in your library.

                    You can manage this permission at any time in Settings → Privacy & Security → Photos on your iPhone.
                    """
                }

                PolicySection(title: "Data Storage") {
                    """
                    All video files are stored locally on your device. When a recording is saved successfully to your Photos library, its temporary working file is deleted automatically.

                    If a save does not complete — for example, because Photos access is turned off or your device storage is full — the recording is kept in the App's private on-device storage so that you can recover it. It stays there until you save it or delete it yourself. None of this ever leaves your device, and your recordings are never stored on our servers.
                    """
                }

                PolicySection(title: "Subscriptions and Purchase Data") {
                    """
                    EverShot offers auto-renewing subscriptions. Purchases are processed by Apple through the App Store — we never receive or store your payment card details.

                    To unlock features and manage your subscription, we use RevenueCat, Inc., a third-party service that records purchase events. For this purpose, RevenueCat and Apple may process a randomly generated app-user identifier, your subscription and purchase history, and basic device and country information.

                    This data is used only to deliver and validate your subscription, prevent fraud, and understand aggregate purchase trends. It is never used to advertise to you and is not sold to anyone. You can review Apple's and RevenueCat's own privacy practices in their respective privacy policies.
                    """
                }

                PolicySection(title: "Third-Party Services") {
                    """
                    The App uses two third-party services, both solely to operate subscriptions:

                    • Apple App Store — processes payments and manages billing.
                    • RevenueCat — validates purchases and manages subscription status.

                    The App contains no advertising networks and no other third-party analytics or tracking SDKs beyond what is described above.
                    """
                }

                PolicySection(title: "Diagnostic Information") {
                    """
                    If you choose to report an issue from within the App, EverShot prepares an email to us that includes basic technical details about your device and settings — such as your device model, iOS version, App version, and the recording mode and quality settings in use. This information helps us diagnose the problem faster.

                    Nothing is sent automatically. The email is created in your own mail app, and you decide whether to send it. We use this information solely to respond to your report.
                    """
                }

                PolicySection(title: "Your Choices and Rights") {
                    """
                    Depending on where you live, you may have rights to access or delete the limited data associated with your purchases. Because that data is tied to an anonymous identifier held by Apple and RevenueCat, please contact us and we will help you exercise those rights.
                    """
                }

                PolicySection(title: "Children's Privacy") {
                    """
                    EverShot is not directed to children under 13, and we do not knowingly collect personal information from children under 13. If you believe a child has provided information through the App, please contact us and we will take appropriate steps to address it.
                    """
                }

                PolicySection(title: "Changes to This Policy") {
                    """
                    If we update this privacy policy, the new version will be reflected in the App with a revised "last updated" date. We encourage you to review this page periodically.
                    """
                }

                PolicySection(title: "Contact") {
                    """
                    If you have any questions about this privacy policy, you can reach us at:

                    hello@bentested.com
                    """
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Helper view

private struct PolicySection: View {
    let title: String
    let content: String

    init(title: String, _ content: () -> String) {
        self.title   = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Text(content)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
