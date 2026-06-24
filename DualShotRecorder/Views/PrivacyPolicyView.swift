import SwiftUI

struct PrivacyPolicyView: View {

    private let lastUpdated = "April 2026"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                Text("Last updated: \(lastUpdated)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                PolicySection(title: "Overview") {
                    """
                    EverShot Cam ("the App") is a dual-camera video recording app. We take your privacy seriously. This policy explains what information the App accesses, how it is used, and what we do (and don't do) with it.

                    The short version: everything stays on your device. We don't collect, store, or transmit any personal data.
                    """
                }

                PolicySection(title: "Information We Do Not Collect") {
                    """
                    EverShot Cam does not collect, transmit, or share any of the following:

                    • Your name, email address, or any account information
                    • Your location or GPS data
                    • Device identifiers or advertising IDs
                    • Usage analytics or crash reports sent to our servers
                    • Any video, audio, or photo content you record
                    """
                }

                PolicySection(title: "Camera and Microphone Access") {
                    """
                    EverShot Cam requires access to your device's rear cameras and microphone solely to record video. This content is processed entirely on your device and is never uploaded, streamed, or transmitted anywhere.

                    You can revoke camera and microphone access at any time in Settings → Privacy & Security on your iPhone.
                    """
                }

                PolicySection(title: "Photo Library Access") {
                    """
                    After recording, EverShot Cam saves your video clips directly to your Photos library. The App requests write access to your photo library for this purpose only. We do not read, scan, or access any existing photos or videos in your library.

                    You can manage this permission at any time in Settings → Privacy & Security → Photos on your iPhone.
                    """
                }

                PolicySection(title: "Data Storage") {
                    """
                    All video files are stored locally on your device. Temporary working files created during recording are deleted automatically once the clips are saved to your Photos library. No data is stored on external servers.
                    """
                }

                PolicySection(title: "Third-Party Services") {
                    """
                    EverShot Cam does not integrate any third-party SDKs, analytics tools, advertising networks, or crash reporting services. No data is shared with any third party.
                    """
                }

                PolicySection(title: "Children's Privacy") {
                    """
                    EverShot Cam does not knowingly collect any information from anyone, including children under the age of 13. Since no data is collected at all, the App complies fully with the Children's Online Privacy Protection Act (COPPA).
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
