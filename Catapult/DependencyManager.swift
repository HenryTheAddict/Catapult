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
    /// GitHub API endpoint used to cheaply check whether yt-dlp is stale.
    private let ytDlpLatestReleaseURL = URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!

    /// A downloadable ffmpeg/ffprobe zip pair. evermeet.cx is Intel-only and
    /// semi-retired, so on Apple Silicon we prefer martin-riedl.de's native
    /// arm64 builds; evermeet remains as the Intel fallback.
    private struct FfmpegSource {
        let name: String
        let ffmpegURL: URL
        let ffprobeURL: URL?
    }

    private var ffmpegSources: [FfmpegSource] {
        var sources: [FfmpegSource] = []
        #if arch(arm64)
        if let ff = URL(string: "https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/ffmpeg.zip") {
            sources.append(FfmpegSource(
                name: "martin-riedl (arm64)",
                ffmpegURL: ff,
                ffprobeURL: URL(string: "https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/ffprobe.zip")
            ))
        }
        #else
        if let ff = URL(string: "https://evermeet.cx/ffmpeg/getrelease/zip") {
            sources.append(FfmpegSource(
                name: "evermeet",
                ffmpegURL: ff,
                ffprobeURL: URL(string: "https://evermeet.cx/ffmpeg/getrelease/ffprobe/zip")
            ))
        }
        if let ff = URL(string: "https://ffmpeg.martin-riedl.de/redirect/latest/macos/amd64/release/ffmpeg.zip") {
            sources.append(FfmpegSource(
                name: "martin-riedl (amd64)",
                ffmpegURL: ff,
                ffprobeURL: URL(string: "https://ffmpeg.martin-riedl.de/redirect/latest/macos/amd64/release/ffprobe.zip")
            ))
        }
        #endif
        // Last-ditch cross-arch fallback: evermeet Intel builds still run
        // under Rosetta on Apple Silicon.
        #if arch(arm64)
        if let ff = URL(string: "https://evermeet.cx/ffmpeg/getrelease/zip") {
            sources.append(FfmpegSource(
                name: "evermeet (intel via Rosetta)",
                ffmpegURL: ff,
                ffprobeURL: URL(string: "https://evermeet.cx/ffmpeg/getrelease/ffprobe/zip")
            ))
        }
        #endif
        return sources
    }

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

    /// Augmented environment with search paths for Homebrew, Node/Deno/Bun runtimes,
    /// and Catapult's bundled tools so child processes can resolve JS engines and binaries.
    static var enhancedEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let binDir = DependencyManager.shared.binDirectory.path
        let searchPaths = [
            binDir,
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "\(home)/.deno/bin",
            "\(home)/.bun/bin",
            "\(home)/.cargo/bin",
            "\(home)/.nvm/current/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        let current = env["PATH"] ?? ""
        let parts = current.split(separator: ":").map(String.init)
        var result = searchPaths
        for p in parts where !result.contains(p) {
            result.append(p)
        }
        env["PATH"] = result.joined(separator: ":")
        return env
    }

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
            // A present-but-broken ffmpeg (truncated download, wrong arch,
            // missing encoders) is what surfaces to users as
            // "Postprocessing: Encoder not found". Catch it here.
            if await !ffmpegIsUsable() {
                state = .installing("ffmpeg")
                try? FileManager.default.removeItem(at: ffmpegPath)
                try? FileManager.default.removeItem(at: ffprobePath)
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

    /// Checks GitHub for a newer yt-dlp and downloads it only when the local
    /// build is actually stale. Throttled to one check per 12h unless forced,
    /// so launch-time checks stay cheap. YouTube breaks old yt-dlp builds
    /// every few weeks, which is the #1 cause of "downloads stopped working".
    @MainActor
    func updateYtDlpIfNeeded(force: Bool = false) async {
        let lastCheck = UserDefaults.standard.double(forKey: "ytDlpLastUpdateCheckAt")
        if !force, Date().timeIntervalSince1970 - lastCheck < 12 * 3600 { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "ytDlpLastUpdateCheckAt")

        guard let latest = await latestYtDlpTag() else { return }
        var current = ytDlpVersion
        if current == nil || current!.isEmpty {
            current = try? await runForOutput(ytDlpPath, ["--version"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let current, !current.isEmpty else {
            await updateYtDlp()
            return
        }
        if current != latest {
            await updateYtDlp()
        }
    }

    private func latestYtDlpTag() async -> String? {
        var request = URLRequest(url: ytDlpLatestReleaseURL)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String, !tag.isEmpty else {
            return nil
        }
        return tag
    }

    /// True when the installed ffmpeg both launches on this machine and was
    /// built with the encoders Catapult's pipelines depend on. This doubles
    /// as a Rosetta/arch check: a binary that can't exec here fails the run.
    private func ffmpegIsUsable() async -> Bool {
        guard FileManager.default.fileExists(atPath: ffmpegPath.path) else { return false }
        guard let listing = try? await runForOutput(ffmpegPath, ["-hide_banner", "-encoders"]),
              !listing.isEmpty else { return false }
        let required = ["libmp3lame", "libopus", "libx264", "mjpeg", "png", " aac "]
        return required.allSatisfy { listing.contains($0) }
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

    @MainActor
    func troubleshootForDownloadFailure(message: String) async -> Bool {
        let lower = message.lowercased()
        let shouldRefreshFfmpeg = !FileManager.default.fileExists(atPath: ffmpegPath.path) ||
            lower.contains("ffmpeg") ||
            lower.contains("ffprobe") ||
            lower.contains("postprocess") ||
            lower.contains("merger") ||
            lower.contains("convert") ||
            lower.contains("thumbnail") ||
            lower.contains("encoder") ||
            lower.contains("error opening output") ||
            lower.contains("bad cpu type") ||
            lower.contains("exec format error") ||
            lower.contains("audio") ||
            lower.contains("clip")

        state = .checking
        do {
            try await downloadYtDlp()
            ytDlpVersion = try? await runForOutput(ytDlpPath, ["--version"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if shouldRefreshFfmpeg {
                try? FileManager.default.removeItem(at: ffmpegPath)
                try? FileManager.default.removeItem(at: ffprobePath)
                try await downloadFfmpeg()
            } else if !FileManager.default.fileExists(atPath: ffmpegPath.path) {
                try await downloadFfmpeg()
            }
            if let full = try? await runForOutput(ffmpegPath, ["-version"]) {
                ffmpegVersion = full.split(separator: "\n").first.map(String.init) ?? full
            }
            state = .ready
            return true
        } catch {
            state = .error("Auto-troubleshoot failed: \(error.localizedDescription)")
            return false
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
        var lastError: Error = NSError(domain: "Catapult", code: 3,
                                       userInfo: [NSLocalizedDescriptionKey: "No ffmpeg download sources configured"])
        for source in ffmpegSources {
            do {
                try await installFfmpeg(from: source)
                if await ffmpegIsUsable() { return }
                lastError = NSError(domain: "Catapult", code: 4,
                                    userInfo: [NSLocalizedDescriptionKey: "ffmpeg from \(source.name) failed verification (missing encoders or wrong architecture)"])
            } catch {
                lastError = error
            }
            // This source didn't work out — clear partial installs before
            // trying the next one.
            try? FileManager.default.removeItem(at: ffmpegPath)
            try? FileManager.default.removeItem(at: ffprobePath)
        }
        throw lastError
    }

    @MainActor
    private func installFfmpeg(from source: FfmpegSource) async throws {
        state = .downloading("ffmpeg", 0)
        let zip = try await download(from: source.ffmpegURL) { [weak self] p in
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
                          userInfo: [NSLocalizedDescriptionKey: "Failed to unzip ffmpeg (\(source.name))"])
        }
        try? FileManager.default.removeItem(at: zip)

        // Find the ffmpeg binary inside the unzipped tree
        guard let found = findBinary(named: "ffmpeg", in: unzipDir) else {
            throw NSError(domain: "Catapult", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "ffmpeg binary not found in archive (\(source.name))"])
        }
        try? FileManager.default.removeItem(at: ffmpegPath)
        try FileManager.default.moveItem(at: found, to: ffmpegPath)
        try makeExecutable(ffmpegPath)
        try clearQuarantine(ffmpegPath)
        try adhocSign(ffmpegPath)

        // Best-effort ffprobe from the same source.
        if let probeURL = source.ffprobeURL {
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
        t.arguments = ["-d", "com.apple.quarantine", url.path]
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
            t.environment = DependencyManager.enhancedEnvironment
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
