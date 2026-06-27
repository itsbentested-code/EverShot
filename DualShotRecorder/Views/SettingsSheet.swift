import SwiftUI

// MARK: - Settings Sheet

struct SettingsSheet: View {
    @ObservedObject var settings: RecordingSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    // MARK: - Computed helpers

    private var storageSummary: String {
        let mbPerMin = StorageCalculator.totalMBPerMinute(
            resolution: settings.resolution,
            frameRate: settings.frameRate,
            bitrate: settings.bitrate
        )
        let remaining = StorageCalculator.formattedRemainingTime(
            resolution: settings.resolution,
            frameRate: settings.frameRate,
            bitrate: settings.bitrate
        )
        return "\(settings.bitrate.rawValue) · ~\(Int(mbPerMin.rounded())) MB/min (both clips) · \(remaining)"
    }

    private var freeStorageString: String {
        let mb = StorageCalculator.availableStorageMB()
        let gb = mb / 1024.0
        return String(format: "%.1f GB", gb)
    }

    private var resolutionNote: String {
        if settings.resolution == .uhd4K && settings.frameRate == .fps60 {
            return "High demand"
        }
        return "Full quality"
    }

    // MARK: - Body

    var body: some View {
        NavigationView {
            Form {

                // MARK: Video Quality
                Section {
                    Picker("Resolution", selection: $settings.resolution) {
                        ForEach(VideoResolution.allCases) { res in
                            Text(res.rawValue).tag(res)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("Frame Rate", selection: $settings.frameRate) {
                        ForEach(FrameRate.allCases) { fps in
                            Text(fps.displayName).tag(fps)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("Quality", selection: $settings.bitrate) {
                        ForEach(VideoBitrate.allCases) { b in
                            Text(b.rawValue).tag(b)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(storageSummary)
                        .font(.caption)
                        .foregroundColor(.secondary)

                } header: {
                    Text("Video Quality")
                }

                // MARK: Timelapse
                Section {
                    Toggle(isOn: $settings.isTimelapse) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Timelapse")
                            Text("Records a fraction of frames for a sped-up result")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if settings.isTimelapse {
                        Picker("Speed", selection: $settings.timelapseSpeed) {
                            ForEach(TimelapseSpeed.allCases) { speed in
                                Text(speed.displayName).tag(speed)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                } footer: {
                    if settings.isTimelapse {
                        Text("Audio is not recorded in timelapse mode. \(settings.timelapseSpeed.displayName) speed keeps 1 of every \(settings.timelapseSpeed.skipInterval) frames.")
                    }
                }

                // MARK: Teleprompter
                Section {
                    Toggle(isOn: $settings.showTeleprompter) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Teleprompter")
                            Text("Scrolling script overlay on the live viewfinder")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if settings.showTeleprompter {
                        Picker("Speed", selection: $settings.teleprompterSpeed) {
                            ForEach(TeleprompterSpeed.allCases) { speed in
                                Text(speed.rawValue).tag(speed)
                            }
                        }
                        .pickerStyle(.segmented)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Script")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextEditor(text: $settings.teleprompterText)
                                .frame(minHeight: 120)
                                .font(.system(size: 15))
                                .scrollContentBackground(.hidden)
                                .background(Color(.systemGray6))
                                .cornerRadius(8)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(Color(.systemGray4), lineWidth: 0.5)
                                )
                        }
                        .padding(.vertical, 4)
                    }
                } footer: {
                    if settings.showTeleprompter {
                        Text("Tap the teleprompter overlay on the viewfinder to pause or resume scrolling.")
                    }
                }

                // MARK: Viewfinder
                Section {
                    Toggle(isOn: $settings.showGrid) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Grid")
                            Text("Rule-of-thirds overlay on the live viewfinder")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Toggle(isOn: $settings.showLevel) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Level")
                            Text("Horizon indicator — turns yellow when the camera is level")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Viewfinder")
                }

                // MARK: Preferences
                Section {
                    Toggle(isOn: $settings.savePreferences) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Save Preferences")
                            Text("Remember your settings, overlays, and thumbnail position between sessions")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Preferences")
                }

                // MARK: Device
                Section {
                    HStack {
                        Text("MultiCam Support")
                        Spacer()
                        Text(DeviceCapabilities.isMultiCamSupported ? "Supported" : "Not Supported")
                            .foregroundColor(DeviceCapabilities.isMultiCamSupported ? .secondary : .red)
                    }

                    HStack {
                        Text("Active Resolution")
                        Spacer()
                        Text(resolutionNote)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Format")
                        Spacer()
                        Text("MP4 (H.264)")
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Device")
                }

                // MARK: About
                Section {
                    // 1. Rate Us
                    Button {
                        if let url = URL(string: "https://apps.apple.com/app/id6761794917?action=write-review") {
                            openURL(url)
                        }
                    } label: {
                        HStack {
                            Text("Rate Us")
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    // 2. Share
                    ShareLink(
                        item: URL(string: "https://apps.apple.com/app/id6761794917")!,
                        subject: Text("Check out EverShot Cam"),
                        message: Text("Record portrait and landscape video at the same time — one tap, both cameras.")
                    ) {
                        HStack {
                            Text("Share")
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    // 3. Give Us Feedback
                    Button {
                        if let url = URL(string: "mailto:hello@bentested.com?subject=EverShot%20Feedback") {
                            openURL(url)
                        }
                    } label: {
                        HStack {
                            Text("Give Us Feedback")
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    // 4. Privacy Policy
                    Button {
                        if let url = URL(string: "https://bentested.com/evershot-legal") {
                            openURL(url)
                        }
                    } label: {
                        HStack {
                            Text("Privacy Policy")
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    // 5. Legal
                    Button {
                        if let url = URL(string: "https://bentested.com/evershot-legal") {
                            openURL(url)
                        }
                    } label: {
                        HStack {
                            Text("Legal")
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}
