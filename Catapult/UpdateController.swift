import Foundation
import AppKit
import CryptoKit

// MARK: - Update handoff
//
// Lightweight HTTPS updater. Catapult reads a static JSON manifest from
// h3nry.xyz/catapult, compares semantic versions, and opens the direct
// .upsweet update package when a newer build is available. The .upsweet file
// is a zip-compatible app bundle archive with a Catapult-specific extension;
// installs use a small relaunch helper instead of a bundled updater framework.

@MainActor
final class UpdateController {
    static let shared = UpdateController()

    private let manifestURL = URL(string: "https://raw.githubusercontent.com/HenryTheAddict/Catapult/master/site/catapult/update.json")!
    private let fallbackManifestURL = URL(string: "https://github.com/HenryTheAddict/Catapult/releases/latest/download/update.json")!
    private let fallbackURL = URL(string: "https://github.com/HenryTheAddict/Catapult/releases/latest")!
    private let automaticCheckInterval: TimeInterval = 12 * 60 * 60
    private let busyRetryInterval: TimeInterval = 30 * 60

    private enum DefaultsKey {
        static let lastAutomaticCheckAt = "updates.lastAutomaticCheckAt"
        static let skippedUpdateID = "updates.skippedUpdateID"
        static let cachedManifestData = "updates.cachedManifestData"
        static let cachedETag = "updates.cachedETag"
        static let cachedLastModified = "updates.cachedLastModified"
    }

    var canCheckForUpdates: Bool { true }

    var automaticallyChecksForUpdates: Bool {
        get { AppSettings.shared.autoCheckForUpdates }
        set { AppSettings.shared.autoCheckForUpdates = newValue }
    }

    private init() {}

    func start() {
        guard automaticallyChecksForUpdates else { return }
        guard shouldRunAutomaticCheck else { return }
        Task {
            try? await Task.sleep(for: .seconds(6))
            await checkForUpdates(userInitiated: false)
        }
    }

    func checkForUpdates() {
        Task {
            await checkForUpdates(userInitiated: true)
        }
    }

    private var shouldRunAutomaticCheck: Bool {
        guard let last = UserDefaults.standard.object(forKey: DefaultsKey.lastAutomaticCheckAt) as? Date else {
            return true
        }
        return Date().timeIntervalSince(last) >= automaticCheckInterval
    }

    private func checkForUpdates(userInitiated: Bool) async {
        if !userInitiated {
            UserDefaults.standard.set(Date(), forKey: DefaultsKey.lastAutomaticCheckAt)
        }
        do {
            let manifest = try await fetchManifest()
            if let minimum = manifest.minimumSystemVersion,
               isCurrentSystemOlder(than: minimum) {
                if userInitiated {
                    presentIncompatibleUpdate(manifest, minimumSystemVersion: minimum)
                }
                return
            }
            if !userInitiated && manifest.updateID == skippedUpdateID {
                return
            }
            if isManifestNewer(manifest) {
                if !userInitiated && shouldDeferUpdate {
                    scheduleAutomaticRetry()
                    return
                }
                if userInitiated {
                    presentAvailableUpdate(manifest)
                } else if settingsCanNotify {
                    NotificationHelper.show(
                        title: "\(manifest.displayName) is available",
                        body: "Open Catapult's update checker when you're ready to upgrade."
                    )
                }
            } else if userInitiated {
                presentCurrent(manifest)
            }
        } catch {
            if userInitiated {
                presentCheckFailed()
            } else if settingsCanNotify {
                NotificationHelper.show(title: "Could not check for updates",
                                        body: "Catapult will try again later.")
            }
        }
    }

    private var shouldDeferUpdate: Bool {
        !runningUpdateBlockers.isEmpty
    }

    private var runningUpdateBlockers: [String] {
        let busyBundleIDs: Set<String> = [
            "com.apple.Safari",
            "com.google.Chrome",
            "org.mozilla.firefox",
            "com.microsoft.edgemac",
            "company.thebrowser.Browser",
            "com.brave.Browser",
            "com.operasoftware.Opera",
            "com.vivaldi.Vivaldi",
            "com.duckduckgo.macos.browser",
            "com.apple.Music",
            "com.spotify.client",
            "com.tidal.desktop",
            "com.amazon.music",
            "com.algoriddim.djay-iphone-free-mac",
            "com.algoriddim.neuralmix",
            "com.apple.FinalCut",
            "com.apple.logic10",
            "com.apple.garageband10",
            "com.apple.iMovieApp",
            "com.apple.QuickTimePlayerX",
            "com.adobe.PremierePro",
            "com.adobe.AfterEffects",
            "com.adobe.Audition",
            "com.adobe.MediaEncoder",
            "com.blackmagic-design.DaVinciResolve",
            "com.ableton.live",
            "com.image-line.flstudio",
            "com.avid.ProTools",
            "com.cockos.reaper",
            "com.obsproject.obs-studio",
            "com.handbrake.HandBrake",
            "com.techsmith.camtasia",
            "com.telestream.screenflow",
        ]
        let busyNameFragments = [
            "safari", "chrome", "firefox", "edge", "arc", "brave", "opera", "vivaldi",
            "duckduckgo", "zen browser", "music", "spotify", "tidal", "djay",
            "neural mix", "final cut", "logic pro", "garageband", "imovie",
            "quicktime", "premiere pro",
            "after effects", "audition", "media encoder", "resolve", "ableton",
            "fl studio", "pro tools", "reaper", "obs", "handbrake", "camtasia",
            "screenflow", "capcut", "davinci"
        ]
        let blockers = NSWorkspace.shared.runningApplications.compactMap { app -> String? in
            if let id = app.bundleIdentifier, busyBundleIDs.contains(id) {
                return app.localizedName ?? id
            }
            let name = (app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "")
                .lowercased()
            if busyNameFragments.contains(where: { name.contains($0) }) {
                return app.localizedName ?? name
            }
            return nil
        }
        return Array(Set(blockers)).sorted()
    }

    private func scheduleAutomaticRetry() {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(busyRetryInterval * 1_000_000_000))
            guard automaticallyChecksForUpdates else { return }
            await checkForUpdates(userInitiated: false)
        }
    }

    private var settingsCanNotify: Bool {
        AppSettings.shared.showNotifications
    }

    private func fetchManifest() async throws -> UpdateManifest {
        do {
            return try await fetchManifest(from: manifestURL)
        } catch {
            return try await fetchManifest(from: fallbackManifestURL)
        }
    }

    private func fetchManifest(from url: URL) async throws -> UpdateManifest {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 12
        if let etag = UserDefaults.standard.string(forKey: DefaultsKey.cachedETag) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let modified = UserDefaults.standard.string(forKey: DefaultsKey.cachedLastModified) {
            request.setValue(modified, forHTTPHeaderField: "If-Modified-Since")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if http.statusCode == 304,
           let cached = UserDefaults.standard.data(forKey: DefaultsKey.cachedManifestData) {
            return try JSONDecoder().decode(UpdateManifest.self, from: cached)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        UserDefaults.standard.set(data, forKey: DefaultsKey.cachedManifestData)
        if let etag = http.value(forHTTPHeaderField: "ETag") {
            UserDefaults.standard.set(etag, forKey: DefaultsKey.cachedETag)
        }
        if let modified = http.value(forHTTPHeaderField: "Last-Modified") {
            UserDefaults.standard.set(modified, forKey: DefaultsKey.cachedLastModified)
        }
        return try JSONDecoder().decode(UpdateManifest.self, from: data)
    }

    private var skippedUpdateID: String? {
        get { UserDefaults.standard.string(forKey: DefaultsKey.skippedUpdateID) }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKey.skippedUpdateID) }
    }

    private func isManifestNewer(_ manifest: UpdateManifest) -> Bool {
        let versionComparison = compareVersion(manifest.version, AppVersion.short)
        if versionComparison != 0 { return versionComparison > 0 }
        guard let remoteBuild = buildNumber(manifest.build),
              let currentBuild = buildNumber(AppVersion.build)
        else { return false }
        return remoteBuild > currentBuild
    }

    private func compareVersion(_ lhsVersion: String, _ rhsVersion: String) -> Int {
        let lhs = versionParts(lhsVersion)
        let rhs = versionParts(rhsVersion)
        let count = max(lhs.count, rhs.count)
        for i in 0..<count {
            let a = i < lhs.count ? lhs[i] : 0
            let b = i < rhs.count ? rhs[i] : 0
            if a != b { return a > b ? 1 : -1 }
        }
        return 0
    }

    private func versionParts(_ version: String) -> [Int] {
        version
            .split(separator: ".")
            .map { part in
                let digits = part.prefix { $0.isNumber }
                return Int(digits) ?? 0
            }
    }

    private func buildNumber(_ build: String?) -> Int? {
        guard let build,
              let match = build.firstMatch(of: /\d+/)
        else { return nil }
        return Int(String(match.output))
    }

    private func isCurrentSystemOlder(than required: String) -> Bool {
        let current = ProcessInfo.processInfo.operatingSystemVersion
        let currentVersion = "\(current.majorVersion).\(current.minorVersion).\(current.patchVersion)"
        return compareVersion(currentVersion, required) < 0
    }

    private func presentAvailableUpdate(_ manifest: UpdateManifest) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "\(manifest.displayName) is available"
        alert.informativeText = [
            "Current: \(AppVersion.short) (build \(AppVersion.build))",
            "Latest: \(manifest.version)" + (manifest.build.map { " (build \($0))" } ?? ""),
            manifest.notes
        ].joined(separator: "\n\n")
        alert.addButton(withTitle: "Install .upsweet")
        if manifest.dmgURL != nil {
            alert.addButton(withTitle: "Download DMG Installer")
        }
        alert.addButton(withTitle: "Release Notes")
        alert.addButton(withTitle: "Skip This Version")

        let response = alert.runModal()
        let hasDMG = manifest.dmgURL != nil
        if response == .alertFirstButtonReturn {
            Task { await installUpsweet(manifest) }
        } else if hasDMG && response == .alertSecondButtonReturn {
            if let dmg = manifest.dmgURL { NSWorkspace.shared.open(dmg) }
        } else if response == .alertSecondButtonReturn || (hasDMG && response == .alertThirdButtonReturn) {
            NSWorkspace.shared.open(manifest.releaseNotesURL ?? fallbackURL)
        } else {
            skippedUpdateID = manifest.updateID
        }
    }

    private func presentCurrent(_ manifest: UpdateManifest) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Catapult is up to date"
        alert.informativeText = "You're on \(AppVersion.short) (build \(AppVersion.build)). The static channel is serving \(manifest.version)\(manifest.build.map { " (build \($0))" } ?? "")."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Release Notes")
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(manifest.releaseNotesURL ?? fallbackURL)
        }
    }

    private func presentIncompatibleUpdate(_ manifest: UpdateManifest,
                                           minimumSystemVersion: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(manifest.displayName) needs macOS \(minimumSystemVersion)"
        alert.informativeText = "You're on macOS \(ProcessInfo.processInfo.operatingSystemVersionString). Catapult will not offer this update automatically on this Mac."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Release Notes")
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(manifest.releaseNotesURL ?? fallbackURL)
        }
    }

    private func presentCheckFailed() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not check for updates"
        alert.informativeText = "The static update manifest was unavailable. You can open the release page instead."
        alert.addButton(withTitle: "Open Release Page")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(fallbackURL)
        }
    }

    private func installUpsweet(_ manifest: UpdateManifest) async {
        let blockers = runningUpdateBlockers
        guard blockers.isEmpty else {
            presentUpdateDeferred(blockers: blockers)
            return
        }

        do {
            let package = try await downloadUpsweet(manifest)
            let app = try extractUpsweet(package)
            try launchInstallHelper(stagedApp: app,
                                    workDirectory: package.deletingLastPathComponent())
        } catch {
            presentInstallFailed(error, manifest: manifest)
        }
    }

    private func downloadUpsweet(_ manifest: UpdateManifest) async throws -> URL {
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CatapultUpdate-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory,
                                                withIntermediateDirectories: true)
        let package = workDirectory.appendingPathComponent("Catapult.upsweet")
        let (temporaryFile, response) = try await URLSession.shared.download(from: manifest.upsweetURL)
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            throw UpdateInstallError.downloadFailed(statusCode: http.statusCode)
        }
        try FileManager.default.moveItem(at: temporaryFile, to: package)

        if let expectedSize = manifest.upsweetSizeBytes {
            let actualSize = try package.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard actualSize == expectedSize else {
                throw UpdateInstallError.sizeMismatch(expected: expectedSize,
                                                      actual: actualSize)
            }
        }
        if let expectedHash = manifest.upsweetSHA256,
           !expectedHash.isEmpty {
            let actualHash = try sha256Hex(of: package)
            guard actualHash.caseInsensitiveCompare(expectedHash) == .orderedSame else {
                throw UpdateInstallError.checksumMismatch
            }
        }
        return package
    }

    private func extractUpsweet(_ package: URL) throws -> URL {
        let expanded = package.deletingLastPathComponent()
            .appendingPathComponent("expanded", isDirectory: true)
        try FileManager.default.createDirectory(at: expanded,
                                                withIntermediateDirectories: true)
        try runProcess(URL(fileURLWithPath: "/usr/bin/ditto"),
                       ["-x", "-k", package.path, expanded.path])
        if FileManager.default.fileExists(atPath: expanded.appendingPathComponent("Catapult.app").path) {
            return expanded.appendingPathComponent("Catapult.app")
        }
        guard let enumerator = FileManager.default.enumerator(at: expanded,
                                                              includingPropertiesForKeys: nil) else {
            throw UpdateInstallError.appMissing
        }
        for case let url as URL in enumerator
            where url.lastPathComponent == "Catapult.app" {
            return url
        }
        throw UpdateInstallError.appMissing
    }

    private func launchInstallHelper(stagedApp: URL,
                                     workDirectory: URL) throws {
        let destination = Bundle.main.bundleURL.standardizedFileURL
        guard destination.pathExtension == "app" else {
            throw UpdateInstallError.invalidDestination
        }
        let destinationParent = destination.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: destinationParent.path) else {
            throw UpdateInstallError.destinationNotWritable(destinationParent.path)
        }

        let script = workDirectory.appendingPathComponent("install-catapult-update.zsh")
        let pid = ProcessInfo.processInfo.processIdentifier
        let contents = """
        #!/bin/zsh
        set -euo pipefail
        while kill -0 \(pid) 2>/dev/null; do
          sleep 0.2
        done
        /bin/rm -rf \(shellQuoted(destination.path))
        /usr/bin/ditto \(shellQuoted(stagedApp.path)) \(shellQuoted(destination.path))
        /usr/bin/xattr -d com.apple.quarantine \(shellQuoted(destination.path)) 2>/dev/null || true
        /usr/bin/open \(shellQuoted(destination.path))
        /bin/rm -rf \(shellQuoted(workDirectory.path))
        """
        try contents.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [script.path]
        try process.run()
        NSApp.terminate(nil)
    }

    private func presentUpdateDeferred(blockers: [String]) {
        let shown = blockers.prefix(5).joined(separator: ", ")
        let remaining = blockers.count > 5 ? " and \(blockers.count - 5) more" : ""
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Close busy apps before updating"
        alert.informativeText = "Catapult will wait while browsers, music apps, or video editors are open. Currently open: \(shown)\(remaining)."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentInstallFailed(_ error: Error, manifest: UpdateManifest) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not install the .upsweet update"
        alert.informativeText = error.localizedDescription
        if manifest.dmgURL != nil {
            alert.addButton(withTitle: "Download DMG Installer")
        }
        alert.addButton(withTitle: "Release Notes")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn, let dmg = manifest.dmgURL {
            NSWorkspace.shared.open(dmg)
        } else if response == .alertSecondButtonReturn || manifest.dmgURL == nil && response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(manifest.releaseNotesURL ?? fallbackURL)
        }
    }

    private func sha256Hex(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func runProcess(_ executable: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateInstallError.processFailed(message ?? executable.lastPathComponent)
        }
    }

    private func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private struct UpdateManifest: Decodable, Sendable {
    let version: String
    let build: String?
    let minimumSystemVersion: String?
    let notes: String
    let name: String?
    let publishedAt: String?
    let upsweetURL: URL
    let dmgURL: URL?
    let releaseNotesURL: URL?
    let upsweetSHA256: String?
    let upsweetSizeBytes: Int?
    let dmgSHA256: String?
    let dmgSizeBytes: Int?

    var updateID: String {
        [version, build].compactMap(\.self).joined(separator: "-")
    }

    var displayName: String {
        name ?? "Catapult \(version)"
    }

    var installURL: URL {
        upsweetURL
    }
}

private enum UpdateInstallError: LocalizedError {
    case downloadFailed(statusCode: Int)
    case sizeMismatch(expected: Int, actual: Int)
    case checksumMismatch
    case appMissing
    case invalidDestination
    case destinationNotWritable(String)
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let statusCode):
            return "The update server returned HTTP \(statusCode)."
        case .sizeMismatch(let expected, let actual):
            return "The .upsweet file size did not match the manifest. Expected \(expected) bytes, got \(actual)."
        case .checksumMismatch:
            return "The .upsweet checksum did not match the static manifest."
        case .appMissing:
            return "The .upsweet package did not contain Catapult.app."
        case .invalidDestination:
            return "Catapult is not running from an app bundle that can be replaced."
        case .destinationNotWritable(let path):
            return "Catapult cannot write to \(path). Use the DMG installer instead."
        case .processFailed(let message):
            return "The update helper failed: \(message)"
        }
    }
}
