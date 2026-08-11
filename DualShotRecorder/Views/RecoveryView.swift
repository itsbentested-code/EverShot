import SwiftUI

/// Lets the user recover recordings that failed to save to Photos —
/// retry the save, or export them via Share.
struct RecoveryView: View {

    @ObservedObject private var store = RecoveryStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var savingURL: URL?
    @State private var alertMessage: String?

    var body: some View {
        NavigationView {
            Group {
                if store.pending.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Recover Recordings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .alert("Still Couldn't Save",
                   isPresented: Binding(get: { alertMessage != nil },
                                        set: { if !$0 { alertMessage = nil } })) {
                Button("OK", role: .cancel) { alertMessage = nil }
            } message: {
                Text(alertMessage ?? "")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 46))
                .foregroundColor(.green)
            Text("Nothing to recover")
                .font(.headline)
            Text("All of your recordings have been saved to Photos.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private var list: some View {
        List {
            Section {
                ForEach(store.pending, id: \.self) { url in
                    row(url)
                }
            } header: {
                Text("Unsaved Recordings")
            } footer: {
                Text("These couldn't be saved to Photos automatically — usually because Photos access was off or storage was full. Tap Save to Photos to try again, or Share to export them. They stay safe here until you save or delete them.")
            }
        }
        .listStyle(.insetGrouped)
    }

    private func row(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label(for: url))
                        .font(.system(size: 16, weight: .semibold))
                    Text(dateText(for: url))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(role: .destructive) {
                    store.delete(url)
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 12) {
                Button {
                    save(url)
                } label: {
                    HStack(spacing: 6) {
                        if savingURL == url {
                            ProgressView()
                        } else {
                            Image(systemName: "square.and.arrow.down")
                        }
                        Text("Save to Photos")
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .disabled(savingURL != nil)

                ShareLink(item: url) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up")
                        Text("Share")
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.15)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                store.delete(url)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Actions & helpers

    private func save(_ url: URL) {
        savingURL = url
        store.retrySave(url) { success in
            savingURL = nil
            if !success {
                alertMessage = "We still couldn't save it to Photos. Check that Photos access is on (Settings → EverShot → Photos) and that you have free storage, then try again. You can also use Share to export it."
            }
        }
    }

    private func label(for url: URL) -> String {
        let name = url.lastPathComponent.lowercased()
        if name.contains("portrait")  { return "Portrait video (9:16)" }
        if name.contains("landscape") { return "Landscape video (16:9)" }
        if name.contains("front")     { return "Front camera video" }
        if name.contains("rear")      { return "Rear camera video" }
        return "Recording"
    }

    private func dateText(for url: URL) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: store.creationDate(of: url))
    }
}
