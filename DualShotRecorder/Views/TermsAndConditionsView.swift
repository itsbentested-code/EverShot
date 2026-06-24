import SwiftUI

struct TermsAndConditionsView: View {

    private let lastUpdated = "April 2026"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                Text("Last updated: \(lastUpdated)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                TermsSection(title: "Acceptance of Terms") {
                    """
                    By downloading or using EverShot Cam ("the App"), you agree to be bound by these Terms and Conditions. If you do not agree with any part of these terms, please do not use the App.
                    """
                }

                TermsSection(title: "Use of the App") {
                    """
                    EverShot Cam is provided for personal, non-commercial use. You agree to use the App only for lawful purposes and in a manner consistent with all applicable local, national, and international laws and regulations.

                    You are solely responsible for any content you record using the App, including ensuring you have the appropriate consent from any individuals who appear in your recordings.
                    """
                }

                TermsSection(title: "Recording Consent and Privacy Laws") {
                    """
                    Recording individuals without their knowledge or consent may be illegal in your jurisdiction. It is your responsibility to understand and comply with all applicable recording consent laws before using EverShot Cam to capture video or audio of others.

                    We are not liable for any recordings made in violation of applicable laws or the privacy rights of any individual.
                    """
                }

                TermsSection(title: "Intellectual Property") {
                    """
                    All rights, title, and interest in and to the App — including its design, code, graphics, and branding — are owned by the developer. You are granted a limited, non-exclusive, non-transferable license to use the App on your personal Apple device in accordance with these terms.

                    You may not copy, modify, distribute, sell, or reverse-engineer any part of the App.
                    """
                }

                TermsSection(title: "Your Content") {
                    """
                    You retain full ownership of all video and audio content you create with EverShot Cam. We do not access, collect, or claim any rights over your recordings. All content stays on your device unless you choose to share it.
                    """
                }

                TermsSection(title: "No Warranty") {
                    """
                    EverShot Cam is provided "as is" without warranties of any kind, either express or implied. We do not warrant that the App will be error-free, uninterrupted, or suitable for any particular purpose.

                    We are not responsible for any loss of recordings, data corruption, or device issues arising from use of the App.
                    """
                }

                TermsSection(title: "Limitation of Liability") {
                    """
                    To the fullest extent permitted by law, we shall not be liable for any indirect, incidental, special, or consequential damages arising out of your use of — or inability to use — the App, even if we have been advised of the possibility of such damages.
                    """
                }

                TermsSection(title: "Changes to the App") {
                    """
                    We reserve the right to modify, suspend, or discontinue the App or any part of it at any time without notice. We are not liable to you or any third party for any such changes.
                    """
                }

                TermsSection(title: "Updates to These Terms") {
                    """
                    We may update these Terms and Conditions from time to time. When we do, the revised date at the top of this page will be updated. Continued use of the App after changes are posted constitutes your acceptance of the updated terms.
                    """
                }

                TermsSection(title: "Governing Law") {
                    """
                    These terms are governed by and construed in accordance with the laws of the United States. Any disputes arising under these terms shall be subject to the exclusive jurisdiction of the courts located in the United States.
                    """
                }

                TermsSection(title: "Contact") {
                    """
                    If you have questions about these Terms and Conditions, please contact us at:

                    hello@bentested.com
                    """
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .navigationTitle("Terms & Conditions")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Helper view

private struct TermsSection: View {
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
