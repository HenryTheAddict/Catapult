import Foundation
import AppKit

// MARK: - CLI installer
//
// Copies the bundled `catapult-cli.sh` to a user-writable spot on PATH, marks
// it executable, and reports whether the install location is actually in the
// user's shell PATH.

@MainActor
enum CLIInstaller {
    enum Status: Equatable {
        case notInstalled
        case installed(path: String, onPath: Bool)
    }

    /// Preferred user-writable install locations, first match wins.
    /// Both avoid sudo; `/usr/local/bin` is writable on many Intel Macs, and
    /// `~/.local/bin` is the canonical fallback.
    static var candidateInstallPaths: [URL] {
        [
            URL(fileURLWithPath: "/usr/local/bin/catapult"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin/catapult"),
        ]
    }

    static var currentInstall: Status {
        for url in candidateInstallPaths {
            if FileManager.default.fileExists(atPath: url.path) {
                return .installed(path: url.path, onPath: isDirectoryOnPath(url.deletingLastPathComponent()))
            }
        }
        return .notInstalled
    }

    /// True when the `capu` short-alias sibling is present next to the
    /// installed `catapult` binary.
    static var hasCapuAlias: Bool {
        guard case .installed(let path, _) = currentInstall else { return false }
        let alias = URL(fileURLWithPath: path)
            .deletingLastPathComponent()
            .appendingPathComponent("capu")
        return FileManager.default.fileExists(atPath: alias.path)
    }

    /// Copies the bundled script to the first writable directory and chmods
    /// it. Also installs a `capu` copy of the same script so the short alias
    /// works even in shells where symlink resolution is fussy. Returns the
    /// install path of the main `catapult` command on success.
    @discardableResult
    static func install() throws -> URL {
        guard let src = Bundle.main.url(forResource: "catapult-cli", withExtension: "sh") else {
            throw CLIError.missingResource
        }
        let fm = FileManager.default

        for dst in candidateInstallPaths {
            let dir = dst.deletingLastPathComponent()
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                continue
            }
            // Must be writable by the current user — otherwise try the next candidate.
            guard fm.isWritableFile(atPath: dir.path) else { continue }

            try installBinary(src: src, to: dst, fm: fm)

            // Install the `capu` alias as a real copy of the script so it
            // behaves identically even under exotic shells, sandboxes, and
            // path-resolvers that misbehave with symlinks. ~8KB of duplication
            // is a fine tradeoff for reliability.
            let alias = dir.appendingPathComponent("capu")
            try? installBinary(src: src, to: alias, fm: fm)

            return dst
        }
        throw CLIError.noWritableDirectory
    }

    private static func installBinary(src: URL, to dst: URL, fm: FileManager) throws {
        // Remove any existing file / symlink first. Use lstat (symlink-aware)
        // via `destinationOfSymbolicLink` to catch dangling symlinks that
        // `fileExists` would silently ignore.
        let hasSymlink = (try? fm.destinationOfSymbolicLink(atPath: dst.path)) != nil
        if fm.fileExists(atPath: dst.path) || hasSymlink {
            try? fm.removeItem(at: dst)
        }
        try fm.copyItem(at: src, to: dst)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
    }

    static func uninstall() {
        let fm = FileManager.default
        for url in candidateInstallPaths {
            removeIfPresent(url, fm: fm)
            // Clean up the sibling `capu` alias (may be a copy or an old
            // symlink from a previous install).
            let alias = url.deletingLastPathComponent().appendingPathComponent("capu")
            removeIfPresent(alias, fm: fm)
        }
    }

    private static func removeIfPresent(_ url: URL, fm: FileManager) {
        let hasSymlink = (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil
        if fm.fileExists(atPath: url.path) || hasSymlink {
            try? fm.removeItem(at: url)
        }
    }

    // MARK: - "Do it for me" — append PATH export to shell rc

    enum PathWriteResult: Equatable {
        case wroteTo(String)      // successfully appended to this file
        case alreadyPresent       // file already contains the export
        case noWritableRc         // couldn't find any writable rc to modify
    }

    /// Appends a PATH export for `dir` to the user's shell rc so subsequent
    /// terminal sessions can find the CLI. Tries zsh (default on macOS ≥10.15),
    /// then bash. Idempotent — re-running is a no-op if the line is present.
    @discardableResult
    static func addDirectoryToShellPath(_ dir: URL) -> PathWriteResult {
        let home = NSHomeDirectory()
        let dirPath = dir.path
        let exportLine = "export PATH=\"\(dirPath):$PATH\""
        let marker = "# added by catapult — puts its cli on your path"

        // Ordered by which shell the system actually uses first. We write to
        // the first existing (or creatable) rc in this list.
        let candidates = [
            "\(home)/.zshrc",
            "\(home)/.zprofile",
            "\(home)/.bash_profile",
            "\(home)/.bashrc",
            "\(home)/.profile",
        ]

        let fm = FileManager.default
        // If any candidate already has the export (exact string match),
        // we're done — don't duplicate.
        for file in candidates {
            if let existing = try? String(contentsOfFile: file, encoding: .utf8),
               existing.contains(exportLine) {
                return .alreadyPresent
            }
        }

        // Prefer existing files (don't create extras), but create ~/.zshrc if
        // none exist, since zsh is the macOS default.
        let target: String = candidates.first(where: { fm.fileExists(atPath: $0) })
            ?? "\(home)/.zshrc"

        var existing = (try? String(contentsOfFile: target, encoding: .utf8)) ?? ""
        if !existing.isEmpty, !existing.hasSuffix("\n") { existing += "\n" }
        existing += "\n\(marker)\n\(exportLine)\n"

        do {
            try existing.write(toFile: target, atomically: true, encoding: .utf8)
            return .wroteTo(target)
        } catch {
            return .noWritableRc
        }
    }

    /// Opens Terminal.app and runs the installed CLI.
    ///
    /// Uses `/usr/bin/open -a Terminal <script>` rather than NSAppleScript —
    /// same effect without triggering the "x wants to control Terminal" prompt
    /// (and without the AppleScript bridge noise in Console).
    static func launchInTerminal() {
        let path: String
        switch currentInstall {
        case .installed(let p, _): path = p
        case .notInstalled:
            guard let src = Bundle.main.url(forResource: "catapult-cli", withExtension: "sh") else { return }
            path = src.path
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", "Terminal", path]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        try? task.run()
    }

    // MARK: PATH inspection

    /// Reports whether `dir` will be visible to a fresh interactive shell —
    /// checks the current process PATH plus the user's shell rc/profile files.
    /// Avoids spawning a login shell, which is a common source of Console
    /// noise (task-name-port / FSFindFolder log lines) and is slow.
    static func isDirectoryOnPath(_ dir: URL) -> Bool {
        let target = standardize(dir.path)

        // Current process PATH — covers the common case where the user's
        // default PATH already includes the install directory.
        let currentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for raw in currentPath.split(separator: ":") {
            if standardize(String(raw)) == target { return true }
        }

        // Fall back to scanning the common shell rc/profile files. We look
        // for the literal directory string inside any `export PATH=…` or
        // `path+=…` line. This is a heuristic, not a full shell parser — it's
        // correct for the lines our own installer tells users to add, and
        // for the overwhelming majority of real-world configs.
        let home = NSHomeDirectory()
        let files = [
            "\(home)/.zshrc", "\(home)/.zshenv", "\(home)/.zprofile",
            "\(home)/.bash_profile", "\(home)/.bashrc", "\(home)/.profile",
            "\(home)/.config/fish/config.fish",
        ]
        // Both the original path and tilde-abbreviated form.
        let needles = [target, (target as NSString).abbreviatingWithTildeInPath]
        for file in files {
            guard let contents = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            for needle in needles where contents.contains(needle) {
                return true
            }
        }
        return false
    }

    private static func standardize(_ p: String) -> String {
        (p as NSString).standardizingPath
    }

    enum CLIError: LocalizedError {
        case missingResource
        case noWritableDirectory
        var errorDescription: String? {
            switch self {
            case .missingResource:
                return "The catapult-cli.sh script is missing from the app bundle."
            case .noWritableDirectory:
                return "Neither /usr/local/bin nor ~/.local/bin is writable. Try creating ~/.local/bin and re-running the installer."
            }
        }
    }
}
