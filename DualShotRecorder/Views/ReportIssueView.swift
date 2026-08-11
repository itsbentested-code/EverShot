import SwiftUI
import UIKit

/// Lets a user report an issue. Collects a description plus useful diagnostic
/// info, then opens a pre-drafted email (to support) in the user's default mail
/// app. Uses a mailto link so it works with any mail app, not just Apple Mail.
struct ReportIssueView: View {

    @ObservedObject var settings: RecordingSettings
    @Environment(\.dismiss) private var dismiss

    private let supportEmail = "hello@bentested.com"

    @State private var issueText = ""
    @State private var showNoMailAlert = false
    @State private var didCopy = false

    var body: some View {
        NavigationView {
            Form {
                // MARK: What happened
                Section {
                    ZStack(alignment: .topLeading) {
                        if issueText.isEmpty {
                            Text("Describe the issue you experienced…")
                                .foregroundColor(.secondary)
                                .padding(.top, 8)
                                .padding(.leading, 4)
                        }
                        TextEditor(text: $issueText)
                            .frame(minHeight: 120)
                            .scrollContentBackground(.hidden)
                    }
                } header: {
                    Text("What happened?")
                }

                // MARK: Auto-collected info
                Section {
                    infoRow("Device", deviceModel)
                    infoRow("iOS", UIDevice.current.systemVersion)
                    infoRow("App Version", appVersion)
                    infoRow("Mode", modeDescription)
                    infoRow("Video", videoDescription)
                    infoRow("Settings", "Stabilization: Standard")
                } header: {
                    Text("Auto-collected info")
                } footer: {
                    Text("This information is included in your email so we can diagnose the issue faster.")
                }

                // MARK: Copy fallback
                Section {
                    Button {
                        UIPasteboard.general.string = emailBody
                        didCopy = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { didCopy = false }
                    } label: {
                        HStack {
                            Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                            Text(didCopy ? "Copied to clipboard" : "Copy report to clipboard")
                        }
                    }
                } footer: {
                    Text("If your mail app isn't set up, copy the report and paste it into an email or message to \(supportEmail).")
                }
            }
            .navigationTitle("Report Issue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Send") { send() }
                        .fontWeight(.semibold)
                }
            }
            .alert("Couldn't Open Mail", isPresented: $showNoMailAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("We couldn't open a mail app. Please email us at \(supportEmail) and include what happened.")
            }
        }
    }

    // MARK: - Send

    private func send() {
        var comps = URLComponents()
        comps.scheme = "mailto"
        comps.path = supportEmail
        comps.queryItems = [
            URLQueryItem(name: "subject", value: "EverShot Issue Report"),
            URLQueryItem(name: "body", value: emailBody)
        ]
        guard let url = comps.url else {
            showNoMailAlert = true
            return
        }
        UIApplication.shared.open(url, options: [:]) { success in
            if success {
                dismiss()
            } else {
                showNoMailAlert = true
            }
        }
    }

    private var emailBody: String {
        """
        \(issueText.isEmpty ? "(Describe the issue here)" : issueText)

        ———
        Device: \(deviceModel)
        iOS: \(UIDevice.current.systemVersion)
        App Version: \(appVersion)
        Mode: \(modeDescription)
        Video: \(videoDescription)
        Settings: Stabilization: Standard
        """
    }

    // MARK: - Collected info

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    private var deviceModel: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.reduce("") { id, element in
            guard let value = element.value as? Int8, value != 0 else { return id }
            return id + String(UnicodeScalar(UInt8(value)))
        }
        return identifier.isEmpty ? UIDevice.current.model : identifier
    }

    private var modeDescription: String {
        if settings.isFrontBackMode { return "Front + Back" }
        if settings.isSingleLensMode {
            return settings.dualLensUseFrontCamera ? "Single Lens (Front)" : "Single Lens (Rear)"
        }
        return settings.dualLensUseFrontCamera ? "Dual Lens (Front)" : "Dual Lens (Rear)"
    }

    private var videoDescription: String {
        "\(settings.resolution.rawValue) @ \(settings.frameRate.rawValue)fps · \(settings.fileFormat.rawValue) · Bitrate: \(settings.bitrate.rawValue)"
    }
}
