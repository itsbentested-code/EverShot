import SwiftUI

struct TermsAndConditionsView: View {

    private let lastUpdated = "July 2026"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                Text("Last updated: \(lastUpdated)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                TermsSection(title: "Acceptance of Terms") {
                    """
                    By downloading or using EverShot ("the App"), you agree to be bound by these Terms and Conditions. If you do not agree with any part of these terms, please do not use the App.
                    """
                }

                TermsSection(title: "Use of the App") {
                    """
                    EverShot is licensed to you for your personal use to create your own video content. You own the videos you record and may use them however you wish, including commercially.

                    You agree to use the App only for lawful purposes and in a manner consistent with all applicable local, national, and international laws and regulations.
                    """
                }

                TermsSection(title: "Subscriptions, Free Trial, and Billing") {
                    """
                    EverShot offers auto-renewing subscriptions that unlock the App's features:

                    • A 7-day free trial, after which the subscription renews automatically at the price shown at the time of purchase (for example, $0.99/month or $9.99/year, in your local currency).
                    • Payment is charged to your Apple ID account upon confirmation of purchase.
                    • Your subscription automatically renews unless auto-renew is turned off at least 24 hours before the end of the current period.
                    • Your account is charged for renewal within 24 hours before the end of the current period, at the then-current price.
                    • You can manage or cancel your subscription in your Apple ID account settings after purchase. Deleting the App does not cancel your subscription.
                    • If you begin a free trial and then purchase a subscription, any unused portion of the trial is forfeited.

                    Prices are shown in your local currency, may vary by region, and may change over time in accordance with App Store rules.
                    """
                }

                TermsSection(title: "Recording Consent and Privacy Laws") {
                    """
                    Recording individuals without their knowledge or consent may be illegal in your jurisdiction. It is your responsibility to understand and comply with all applicable recording consent laws before using EverShot to capture video or audio of others.

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
                    You retain full ownership of all video and audio content you create with EverShot. We do not access, collect, or claim any rights over your recordings. All content stays on your device unless you choose to share it.
                    """
                }

                TermsSection(title: "No Warranty") {
                    """
                    EverShot is provided "as is" without warranties of any kind, either express or implied. We do not warrant that the App will be error-free, uninterrupted, or suitable for any particular purpose.

                    We are not responsible for any loss of recordings, data corruption, or device issues arising from use of the App.
                    """
                }

                TermsSection(title: "Limitation of Liability") {
                    """
                    To the fullest extent permitted by law, we shall not be liable for any indirect, incidental, special, or consequential damages arising out of your use of — or inability to use — the App, even if we have been advised of the possibility of such damages.
                    """
                }

                TermsSection(title: "Apple App Store Terms") {
                    """
                    These Terms are between you and the developer of EverShot, not with Apple. Apple is not responsible for the App or its content, and has no obligation to provide any maintenance or support for the App.

                    If the App fails to conform to any applicable warranty, you may notify Apple, and Apple will refund the purchase price (if any); to the maximum extent permitted by law, Apple has no other warranty obligation with respect to the App. Apple and its subsidiaries are third-party beneficiaries of these Terms and may enforce them against you.

                    You represent that you are not located in a country subject to a U.S. Government embargo and that you are not listed on any U.S. Government restricted-parties list.
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
                    These terms are governed by and construed in accordance with the laws of the State of Tennessee, United States, without regard to conflict-of-law principles. Any disputes arising under these terms shall be subject to the exclusive jurisdiction of the state and federal courts located in Tennessee.
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
