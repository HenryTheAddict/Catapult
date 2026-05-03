import Foundation
import Observation
import AppKit

// MARK: - Persistent download history
//
// Keeps a JSON-backed log of every finished / failed download so the user
// can see what they've grabbed even after they "Clear finished" in the
// active queue. Stored in
//   ~/Library/Application Support/Catapult/history.json
// alongside the existing yt-dlp / ffmpeg binaries — same dir DependencyManager
// already creates.
//
// History intentionally does NOT live inside DownloadManager.items because
// the menu-bar list is for active jobs. We snapshot a DownloadItem into a
// HistoryEntry the moment it transitions to a terminal state, then forget it.

struct HistoryEntry: Codable, Identifiable, Hashable {
    let id: UUID
    let url: String
    let title: String
    let mode: DownloadMode
    let outputFile: URL?
    /// Raw error message for failed entries. nil on success.
    let errorMessage: String?
    let uploader: String?
    let durationSeconds: Double?
    let fileSizeBytes: Int64?
    let finishedAt: Date

    enum Outcome: String, Codable {
        case finished, failed, cancelled
    }
    let outcome: Outcome

    var fileExists: Bool {
        guard let f = outputFile else { return false }
        return FileManager.default.fileExists(atPath: f.path)
    }
}

@Observable
@MainActor
final class HistoryStore {
    static let shared = HistoryStore()

    /// Newest first. Capped at `maxEntries` to keep the JSON file from
    /// ballooning on power users.
    var entries: [HistoryEntry] = []

    private let maxEntries = 1000
    private let storeURL: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
            .appendingPathComponent("Catapult", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.storeURL = base.appendingPathComponent("history.json")
        load()
    }

    // MARK: - Mutations

    func record(_ item: DownloadItem) {
        let outcome: HistoryEntry.Outcome
        var output: URL? = nil
        var err: String? = nil
        switch item.status {
        case .finished(let f):
            outcome = .finished
            output = f ?? item.outputFile
        case .failed(let m):
            outcome = .failed
            err = m
        case .cancelled:
            outcome = .cancelled
        default:
            // Not in a terminal state yet — ignore.
            return
        }

        // Best-effort file size.
        var size: Int64? = nil
        if let f = output, let attrs = try? FileManager.default.attributesOfItem(atPath: f.path),
           let n = attrs[.size] as? NSNumber {
            size = n.int64Value
        }

        let entry = HistoryEntry(
            id: item.id,
            url: item.url,
            title: item.title,
            mode: item.mode,
            outputFile: output,
            errorMessage: err,
            uploader: item.uploader,
            durationSeconds: item.durationSeconds,
            fileSizeBytes: size,
            finishedAt: Date(),
            outcome: outcome
        )
        // Dedupe by id — re-runs of retry shouldn't produce two entries.
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        save()
    }

    func remove(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clearAll() {
        entries.removeAll()
        save()
    }

    /// Reveal the file in Finder. Returns false if the file no longer exists.
    @discardableResult
    func reveal(_ entry: HistoryEntry) -> Bool {
        guard let f = entry.outputFile,
              FileManager.default.fileExists(atPath: f.path) else { return false }
        NSWorkspace.shared.activateFileViewerSelecting([f])
        return true
    }

    // MARK: - Persistence

    private func save() {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            // History is non-critical; swallow.
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        if let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            self.entries = decoded
        }
    }
}
