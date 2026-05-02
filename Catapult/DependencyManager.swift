import Foundation
import Observation
import AppKit

enum DependencyState: Equatable {
    case unknown
    case checking
    case downloading(String, Double)   // (component, progress 0-1)
    case installing(String)
    case ready
    case error(String)
}

@Observable
final class DependencyManager {
    static let shared = DependencyManager()

    var state: DependencyState = .unknown
    var ytDlpVersion: String? = nil
    var ffmpegVersion: String? = nil

    /// URL to latest yt-dlp universal binary for macOS
    private let ytDlpURL = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!
    /// evermeet.cx redirects to the latest ffmpeg zip for macOS
    private let ffmpegURL = URL(string: "https://evermeet.cx/ffmpeg/getrelease/zip")!

    var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Catapult", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    var binDirectory: URL {
        let dir = supportDirectory.appendingPathComponent("bin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    var ytDlpPath: URL  { binDirectory.appendingPathComponent("yt-dlp") }
    var ffmpegPath: URL { binDirectory.appendingPathComponent("ffmpeg") }
    var ffprobePath: URL { binDirectory.appendingPathComponent("ffprobe") }

    private init() {}

    @MainActor
    func ensureInstalled() async {
        state = .checking
        do {
            if !FileManager.default.fileExists(atPath: ytDlpPath.path) {
                try await downloadYtDlp()
            }
            if !FileManager.default.fileExists(atPath: ffmpegPath.path) {
                try await downloadFfmpeg()
            }
            ytDlpVersion  = try? await runForOutput(ytDlpPath, ["--version"]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let full = try? await runForOutput(ffmpegPath, ["-version"]) {
                ffmpegVersion = full.split(separator: "\n").first.map(String.init) ?? full
            }
            state = .ready
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    @MainActor
    func updateYtDlp() async {
        state = .installing("yt-dlp")
        do {
            try await downloadYtDlp()
            ytDlpVersion = try? await runForOutput(ytDlpPath, ["--version"]).trimmingCharacters(in: .whitespacesAndNewlines)
            state = .ready
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    @MainActor
    func reinstallFfmpeg() async {
        state = .installing("ffmpeg")
        do {
            try? FileManager.default.removeItem(at: ffmpegPath)
            try? FileManager.default.removeItem(at: ffprobePath)
            try await downloadFfmpeg()
            if let full = try? await runForOutput(ffmpegPath, ["-version"]) {
                ffmpegVersion = full.split(separator: "\n").first.map(String.init) ?? full
            }
            state = .ready
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    // MARK: - Downloads

    @MainActor
    private func downloadYtDlp() async throws {
        state = .downloading("yt-dlp", 0)
        let tmp = try await download(from: ytDlpURL) { [weak self] p in
            self?.state = .downloading("yt-dlp", p)
        }
        try? FileManager.default.removeItem(at: ytDlpPath)
        try FileManager.default.moveItem(at: tmp, to: ytDlpPath)
        try makeExecutable(ytDlpPath)
        try clearQuarantine(ytDlpPath)
        try adhocSign(ytDlpPath)
    }

    @MainActor
    private func downloadFfmpeg() async throws {
        state = .downloading("ffmpeg", 0)
        let zip = try await download(from: ffmpegURL) { [weak self] p in
            self?.state = .downloading("ffmpeg", p)
        }
        state = .installing("ffmpeg")

        let unzipDir = supportDirectory.appendingPathComponent("unzip-tmp", isDirectory: true)
        try? FileManager.default.removeItem(at: unzipDir)
        try FileManager.default.createDirectory(at: unzipDir, withIntermediateDirectories: true)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        task.arguments = ["-o", zip.path, "-d", unzipDir.path]
        task.standardOutput = Pipe(); task.standardError = Pipe()
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw NSError(domain: "Catapult", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to unzip ffmpeg"])
        }
        try? FileManager.default.removeItem(at: zip)

        // Find the ffmpeg binary inside the unzipped tree
        guard let found = findBinary(named: "ffmpeg", in: unzipDir) else {
            throw NSError(domain: "Catapult", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "ffmpeg binary not found in archive"])
        }
        try? FileManager.default.removeItem(at: ffmpegPath)
        try FileManager.default.moveItem(at: found, to: ffmpegPath)
        try makeExecutable(ffmpegPath)
        try clearQuarantine(ffmpegPath)
        try adhocSign(ffmpegPath)

        // Try to also fetch ffprobe separately (evermeet provides its own zip)
        if let probeURL = URL(string: "https://evermeet.cx/ffmpeg/getrelease/ffprobe/zip") {
            if let probeZip = try? await download(from: probeURL, progress: { _ in }) {
                let probeDir = supportDirectory.appendingPathComponent("unzip-probe", isDirectory: true)
                try? FileManager.default.removeItem(at: probeDir)
                try? FileManager.default.createDirectory(at: probeDir, withIntermediateDirectories: true)
                let t = Process()
                t.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                t.arguments = ["-o", probeZip.path, "-d", probeDir.path]
                t.standardOutput = Pipe(); t.standardError = Pipe()
                try? t.run(); t.waitUntilExit()
                if let probe = findBinary(named: "ffprobe", in: probeDir) {
                    try? FileManager.default.removeItem(at: ffprobePath)
                    try? FileManager.default.moveItem(at: probe, to: ffprobePath)
                    try? makeExecutable(ffprobePath)
                    try? clearQuarantine(ffprobePath)
                    try? adhocSign(ffprobePath)
                }
                try? FileManager.default.removeItem(at: probeDir)
                try? FileManager.default.removeItem(at: probeZip)
            }
        }

        try? FileManager.default.removeItem(at: unzipDir)
    }

    private func findBinary(named name: String, in dir: URL) -> URL? {
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return nil
        }
        for case let url as URL in en where url.lastPathComponent == name {
            return url
        }
        return nil
    }

    // MARK: - Networking (URLSession download with progress)

    private func download(from url: URL, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let (tempFile, _) = try await DownloadProgressDelegate.run(url: url) { p in
            Task { @MainActor in progress(p) }
        }
        return tempFile
    }

    // MARK: - Post-install fix-ups

    private func makeExecutable(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    @discardableResult
    private func clearQuarantine(_ url: URL) throws -> Int32 {
        let t = Process()
        t.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        t.arguments = ["-dr", "com.apple.quarantine", url.path]
        t.standardOutput = Pipe(); t.standardError = Pipe()
        try t.run(); t.waitUntilExit()
        return t.terminationStatus
    }

    @discardableResult
    private func adhocSign(_ url: URL) throws -> Int32 {
        let t = Process()
        t.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        t.arguments = ["--force", "--sign", "-", url.path]
        t.standardOutput = Pipe(); t.standardError = Pipe()
        try t.run(); t.waitUntilExit()
        return t.terminationStatus
    }

    private func runForOutput(_ exe: URL, _ args: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let t = Process()
            t.executableURL = exe
            t.arguments = args
            let out = Pipe()
            t.standardOutput = out
            t.standardError = Pipe()
            try t.run()
            t.waitUntilExit()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        }.value
    }

}

/// A URLSessionDownloadDelegate wrapper that yields progress via a callback.
final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    private let progressHandler: (Double) -> Void
    private let continuation: CheckedContinuation<(URL, URLResponse), Error>
    private var response: URLResponse?

    private init(progress: @escaping (Double) -> Void,
                 continuation: CheckedContinuation<(URL, URLResponse), Error>) {
        self.progressHandler = progress
        self.continuation = continuation
    }

    static func run(url: URL,
                    progress: @escaping (Double) -> Void) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { cont in
            let delegate = DownloadProgressDelegate(progress: progress, continuation: cont)
            let config = URLSessionConfiguration.default
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            let task = session.downloadTask(with: URLRequest(url: url))
            task.resume()
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            progressHandler(min(max(p, 0), 1))
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Move to a stable temp path; the framework deletes `location` when we return.
        let suggested = downloadTask.response?.suggestedFilename ?? "download.bin"
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-" + suggested)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            if let resp = downloadTask.response {
                continuation.resume(returning: (dest, resp))
            } else {
                continuation.resume(throwing: URLError(.badServerResponse))
            }
        } catch {
            continuation.resume(throwing: error)
        }
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { continuation.resume(throwing: error); session.invalidateAndCancel() }
    }
}
