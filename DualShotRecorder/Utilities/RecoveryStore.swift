import Foundation
import Photos

/// Safety net for recordings that failed to save to Photos.
///
/// Recordings are written to the temp directory, which iOS can purge. When a
/// save to Photos fails (permission off, storage full, transient error) we MOVE
/// the file here into a persistent folder so the footage survives, and the user
/// can retry saving or export it from the recovery screen.
/// Not `@MainActor`: it's called from CameraManager's save closures (which run
/// on the main queue via DispatchQueue.main.async) and from SwiftUI on the main
/// thread, so all `@Published` mutations already happen on main.
final class RecoveryStore: ObservableObject {

    static let shared = RecoveryStore()

    @Published private(set) var pending: [URL] = []

    private let folder: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("UnsavedRecordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private init() {
        refresh()
    }

    var hasPending: Bool { !pending.isEmpty }

    /// Moves a just-failed recording out of temp into persistent storage so it
    /// isn't lost or purged. Returns the new location (or nil if it couldn't be kept).
    @discardableResult
    func preserve(_ url: URL) -> URL? {
        let dest = folder.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: url, to: dest)
        } catch {
            // Fallback to copy if the move fails (e.g. cross-container).
            guard (try? FileManager.default.copyItem(at: url, to: dest)) != nil else {
                return nil
            }
        }
        refresh()
        return dest
    }

    /// Sweeps the temp directory for any EverShot recording files left behind by
    /// a failed finalize, an interruption, or a crash, and moves them into
    /// persistent recovery storage. Only call when NOT actively recording
    /// (app launch, or after a recording has stopped/errored).
    @discardableResult
    func preserveOrphans() -> Int {
        let tmp = FileManager.default.temporaryDirectory
        let files = (try? FileManager.default.contentsOfDirectory(
            at: tmp,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []

        var moved = 0
        for url in files
        where url.lastPathComponent.hasPrefix("evershot_")
            && ["mp4", "mov"].contains(url.pathExtension.lowercased()) {
            if preserve(url) != nil { moved += 1 }
        }
        return moved
    }

    /// Re-lists the persistent folder, newest first.
    func refresh() {
        let keys: [URLResourceKey] = [.creationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles])) ?? []

        pending = files
            .filter { ["mp4", "mov"].contains($0.pathExtension.lowercased()) }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return da > db
            }
    }

    /// Retries saving a preserved recording to Photos. On success the local copy
    /// is removed; on failure it stays so the user can try again or export it.
    func retrySave(_ url: URL, completion: @escaping (Bool) -> Void) {
        PhotoLibrarySaver.saveVideo(url: url) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    try? FileManager.default.removeItem(at: url)
                    self?.refresh()
                    completion(true)
                case .failure:
                    completion(false)
                }
            }
        }
    }

    /// Permanently removes a preserved recording (user chose to discard it).
    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        refresh()
    }

    /// Creation date of a preserved file, for display.
    func creationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
    }
}
