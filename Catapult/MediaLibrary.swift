import Foundation
import Observation
import UniformTypeIdentifiers
import CryptoKit

nonisolated struct LibraryFile: Sendable {
    let url: URL
    let mode: DownloadMode
    let date: Date
    let size: Int64?
    var id: UUID {
        let bytes = Array(SHA256.hash(data: Data(url.standardizedFileURL.path.utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

nonisolated enum LibraryScan {
    static func mode(for file: URL) -> DownloadMode? {
        let ext = file.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        if type?.conforms(to: .movie) == true || ["mkv", "webm", "avi", "m4v"].contains(ext) { return .video }
        if type?.conforms(to: .audio) == true || ["opus", "flac", "ogg"].contains(ext) { return .audio }
        if type?.conforms(to: .image) == true || ["webp", "avif"].contains(ext) { return .thumbnailOnly }
        return nil
    }
    static func files(in folder: URL) -> [LibraryFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let iterator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var files: [LibraryFile] = []
        for case let url as URL in iterator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let mode = mode(for: url) else { continue }
            files.append(LibraryFile(url: url, mode: mode, date: values.contentModificationDate ?? .distantPast,
                                     size: values.fileSize.map(Int64.init)))
        }
        return files.sorted { $0.date > $1.date }
    }
}

@Observable @MainActor final class MediaLibrary {
    static let shared = MediaLibrary()
    var entries: [HistoryEntry] = []
    private var scanID = UUID()
    private init() {}
    func refresh(folder: URL) async {
        let generation = UUID(); scanID = generation
        let files = await Task.detached(priority: .utility) { LibraryScan.files(in: folder) }.value
        guard !Task.isCancelled, scanID == generation else { return }
        entries = files.map {
            HistoryEntry(id: $0.id, url: $0.url.absoluteString, title: $0.url.deletingPathExtension().lastPathComponent,
                         mode: $0.mode, outputFile: $0.url, errorMessage: nil, uploader: nil,
                         durationSeconds: nil, fileSizeBytes: $0.size, finishedAt: $0.date,
                         source: .local($0.url), outcome: .finished)
        }
    }
    func combined(with history: [HistoryEntry], excluding active: [URL] = []) -> [HistoryEntry] {
        let existing = Set(history.compactMap { $0.outputFile?.resolvingSymlinksInPath().standardizedFileURL.path })
        let inProgress = Set(active.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
        return (history + entries.filter { entry in
            guard let path = entry.outputFile?.resolvingSymlinksInPath().standardizedFileURL.path else { return false }
            return !existing.contains(path) && !inProgress.contains(path)
        }).sorted { $0.finishedAt > $1.finishedAt }
    }
}

@Observable @MainActor final class GalleryNavigation {
    static let shared = GalleryNavigation()
    var requestID = 0
    private init() {}
}
