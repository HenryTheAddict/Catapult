//
//  CatapultTests.swift
//  CatapultTests
//
//  Created by Catapult contributors on 4/19/26.
//

import Testing
import Foundation
import SQLite3
@testable import Catapult

struct CatapultTests {

    @Test func detectsKnownSocialLinksBeforeGenericLinks() async throws {
        let text = "read this https://example.com first, then grab https://www.instagram.com/reel/ABC123/?utm_source=copy-link"
        let picked = await MainActor.run { ClipboardMonitor.firstDownloadURL(in: text) }
        #expect(picked == "https://www.instagram.com/reel/ABC123/?utm_source=copy-link")
    }

    @Test func trimsCommonCopiedLinkPunctuation() async throws {
        let picked = await MainActor.run {
            ClipboardMonitor.firstDownloadURL(in: "watch: https://www.tiktok.com/@catapult/video/12345).")
        }
        #expect(picked == "https://www.tiktok.com/@catapult/video/12345")
    }

    @Test func fallsBackToGenericYtDlpURL() async throws {
        let picked = await MainActor.run {
            ClipboardMonitor.firstDownloadURL(in: "https://example.com/media/clip")
        }
        #expect(picked == "https://example.com/media/clip")
    }

    @Test func defaultConcurrentFragmentsIsEight() async throws {
        let defaultFragments = await MainActor.run {
            AppSettings.shared.concurrentFragments
        }
        #expect(defaultFragments >= 8)
    }

    @Test func enhancedEnvironmentIncludesToolPaths() async throws {
        let env = DependencyManager.enhancedEnvironment
        let path = env["PATH"] ?? ""
        #expect(path.contains("/opt/homebrew/bin"))
        #expect(path.contains("/usr/local/bin"))
        #expect(path.contains(".deno/bin"))
    }

    @Test func cookieSourceResolution() async throws {
        await MainActor.run {
            let s = AppSettings.shared
            let oldSource = s.cookieSource
            let oldSites = s.siteCookies

            s.cookieSource = .safari
            s.siteCookies = [SupportedSite.youtube]

            #expect(s.cookieSource(for: "https://www.youtube.com/watch?v=dQw4w9WgXcQ") == .safari)
            // Generic sites receive the global cookie source when enabled
            #expect(s.cookieSource(for: "https://customdomain.org/video.mp4") == .safari)
            // Un-toggled supported sites do not receive it
            #expect(s.cookieSource(for: "https://www.tiktok.com/@user/video/12345") == .off)

            // When cookieSource is off, nothing receives cookies
            s.cookieSource = .off
            #expect(s.cookieSource(for: "https://www.youtube.com/watch?v=dQw4w9WgXcQ") == .off)
            #expect(s.cookieSource(for: "https://customdomain.org/video.mp4") == .off)

            // Restore original settings
            s.cookieSource = oldSource
            s.siteCookies = oldSites
        }
    }

    @Test func friendlyErrorMapping() async throws {
        let botCheck = DownloadManager.friendlyError(for: "Sign in to confirm you’re not a bot. This helps protect our community.")
        #expect(botCheck.contains("bot") || botCheck.contains("Cookies") || botCheck.contains("sign into") || botCheck.contains("signed in"))

        let ageGated = DownloadManager.friendlyError(for: "Sign in to confirm your age. This video may be inappropriate for some users.")
        #expect(ageGated.contains("age") || ageGated.contains("Cookies") || ageGated.contains("Settings") || ageGated.contains("signed in"))

        let formatErr = DownloadManager.friendlyError(for: "ERROR: Requested format is not available")
        #expect(formatErr.contains("format") || formatErr.contains("quality") || formatErr.contains("yt-dlp"))
    }

}

struct MediaPipelineTests {
    @Test func framesSplitUTF8AndTrailingRecords() {
        var framer = LineFramer()
        let bytes = Array("name café\r\nnext\nlast".utf8)
        var lines: [String] = []
        for byte in bytes { lines += framer.append(Data([byte])) }
        lines += framer.append(Data(), finish: true)
        #expect(lines == ["name café", "next", "last"])
    }
    @Test func combinesStreamsAndClearsUnknownProgress() {
        var progress = TransferProgress()
        progress.prepare([["format_id": "video", "filesize": 900], ["format_id": "audio", "filesize": 100]])
        progress.update(id: "video", progress: ["downloaded_bytes": 900, "total_bytes": 900, "status": "finished"])
        #expect(progress.fraction == 0.9)
        progress.update(id: "audio", progress: ["downloaded_bytes": 50, "total_bytes": 100])
        #expect(progress.fraction == 0.95)
        var unknown = TransferProgress()
        unknown.update(id: "x", progress: ["downloaded_bytes": 500])
        #expect(unknown.fraction == nil)
        unknown.update(id: "x", progress: ["downloaded_bytes": 500, "total_bytes_estimate": 1000])
        #expect(unknown.fraction == 0.5 && unknown.isEstimated)
        unknown.update(id: "x", progress: ["downloaded_bytes": 600, "total_bytes": 1000])
        #expect(!unknown.isEstimated)
    }
    @Test func validatesPreciseTimesAndBoundaries() {
        #expect(MediaTime.parse("01:02:03.125") == 3723.125)
        #expect(MediaTime.parse("62.25") == 62.25)
        #expect(MediaTime.parse("1:60") == nil)
        #expect(MediaTime.parse("nan") == nil)
        #expect(MediaTime.parse("-1") == nil)
        #expect(MediaTime.parse("1::2") == nil)
        #expect(MediaTime.format(3723.125) == "01:02:03.125")
        #expect(MediaTime.valid(start: 0, end: 0.1, duration: 0.1))
        #expect(!MediaTime.valid(start: 1, end: 1.1, duration: 10))
        #expect(!MediaTime.valid(start: -1, end: 2, duration: 10))
        #expect(!MediaTime.valid(start: 0, end: 11, duration: 10))
    }
    @Test func clipRecipesKeepSourcesSeparate() {
        let source = URL(fileURLWithPath: "/tmp/source.mp4")
        let target = URL(fileURLWithPath: "/tmp/clip.mp4")
        let accurate = ClipRecipe.arguments(input: source, output: target, start: 1.125, end: 2.875, audioOnly: false, accuracy: .accurate, bitrate: 192, height: 720)
        #expect(accurate.contains("libx264"))
        #expect(accurate.contains("1.750000"))
        #expect(accurate.last == target.path)
        #expect(accurate.contains("-n"))
        let fast = ClipRecipe.arguments(input: source, output: target, start: 1, end: 2, audioOnly: false, accuracy: .fast, bitrate: 192, height: nil)
        #expect(fast.contains("copy") && !fast.contains("libx264"))
    }
    @Test func loadsHistoryWithoutNewOptionalFields() async throws {
        let json = """
        {"id":"C86FB081-A377-4AF8-86F7-1B1465EC10F1","url":"https://example.org/video","title":"Old video","mode":"video","finishedAt":0,"outcome":"finished"}
        """
        let entry = try await MainActor.run { try JSONDecoder().decode(HistoryEntry.self, from: Data(json.utf8)) }
        #expect(entry.thumbnailURL == nil && entry.source == nil)
    }
    @Test func sqliteSnapshotIncludesLiveWAL() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = folder.appendingPathComponent("Cookies")
        var source: OpaquePointer?
        #expect(sqlite3_open(database.path, &source) == SQLITE_OK)
        defer { sqlite3_close(source) }
        #expect(sqlite3_exec(source, "PRAGMA journal_mode=WAL; CREATE TABLE cookies(value TEXT); INSERT INTO cookies VALUES('fixture');", nil, nil, nil) == SQLITE_OK)
        let copy = folder.appendingPathComponent("snapshot")
        try HeliumCookieBridge.snapshot(database: database, to: copy)
        var snapshot: OpaquePointer?
        #expect(sqlite3_open(copy.path, &snapshot) == SQLITE_OK)
        defer { sqlite3_close(snapshot) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(snapshot, "SELECT value FROM cookies", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(String(cString: sqlite3_column_text(statement, 0)) == "fixture")
    }
    @Test func discoversSyntheticHeliumProfiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = root.appendingPathComponent("Profile 2/Network")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try Data().write(to: profile.appendingPathComponent("Cookies"))
        let profiles = HeliumCookieBridge.profiles(roots: [root.path])
        #expect(profiles.count == 1 && profiles.first?.label == "Profile 2")
    }
    @Test func processDrainsBothPipesAndHandlesLaunchFailure() async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf 'first\nlast'; printf 'error\n' >&2"]
        let result = await MediaProcess.run(process)
        #expect(result.code == 0 && result.stdout == "first\nlast" && result.stderr == "error\n")
        let missing = Process(); missing.executableURL = URL(fileURLWithPath: "/missing-catapult-executable")
        let failed = await MediaProcess.run(missing)
        #expect(failed.code == -1 && !failed.stderr.isEmpty)
    }
}

struct ClipIntegrationTests {
    @Test func accurateAndFastExportsAndAudio() async throws {
        let bin = await MainActor.run { DependencyManager.shared.binDirectory }
        guard FileManager.default.fileExists(atPath: bin.appendingPathComponent("ffmpeg").path) else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.mp4")
        let fixture = Process(); fixture.executableURL = bin.appendingPathComponent("ffmpeg")
        fixture.arguments = ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=30:duration=5", "-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=48000:duration=5", "-c:v", "libx264", "-g", "90", "-c:a", "aac", source.path]
        let generated = await MediaProcess.run(fixture)
        #expect(generated.code == 0)
        let original = try Data(contentsOf: source)
        for accuracy in ClipAccuracy.allCases {
            let file = folder.appendingPathComponent("\(accuracy.rawValue).mp4")
            let export = Process(); export.executableURL = bin.appendingPathComponent("ffmpeg")
            export.arguments = ClipRecipe.arguments(input: source, output: file, start: 1.125, end: 2.875, audioOnly: false, accuracy: accuracy, bitrate: 192, height: nil)
            let result = await MediaProcess.run(export)
            #expect(result.code == 0)
            let probe = Process(); probe.executableURL = bin.appendingPathComponent("ffprobe")
            probe.arguments = ["-v", "error", "-show_format", "-show_streams", "-of", "json", file.path]
            let info = await MediaProcess.run(probe)
            let json = try #require(JSONSerialization.jsonObject(with: Data(info.stdout.utf8)) as? [String: Any])
            let format = try #require(json["format"] as? [String: Any])
            let duration = try #require(Double(format["duration"] as? String ?? ""))
            if accuracy == .accurate { #expect(abs(duration - 1.75) < 0.04) }
            else { #expect(duration > 1.75) }
        }
        let audio = folder.appendingPathComponent("clip.m4a")
        let export = Process(); export.executableURL = bin.appendingPathComponent("ffmpeg")
        export.arguments = ClipRecipe.arguments(input: source, output: audio, start: 1.125, end: 2.875, audioOnly: true, accuracy: .accurate, bitrate: 192, height: nil)
        let result = await MediaProcess.run(export)
        #expect(result.code == 0)
        #expect(try Data(contentsOf: source) == original)
    }
    @Test func cancellingProcessStopsIt() async throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sleep"); process.arguments = ["10"]
        let task = Task { await MediaProcess.run(process) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let result = await task.value
        #expect(result.code != 0)
        #expect(!process.isRunning)
    }
}

struct LibraryTests {
    @Test func scansMediaRecursivelyAndSkipsIncompleteFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for file in ["video.mp4", "nested/audio.flac", "photo.png", "video.mp4.part", ".catapult-temp.mp4", "notes.txt"] {
            try Data().write(to: root.appendingPathComponent(file))
        }
        let files = LibraryScan.files(in: root)
        #expect(files.count == 3)
        #expect(Set(files.map(\.mode)) == Set([.video, .audio, .thumbnailOnly]))
        #expect(files.map(\.id) == LibraryScan.files(in: root).map(\.id))
    }
    @Test func combinesWithoutDuplicatingRecordedFiles() async throws {
        let file = URL(fileURLWithPath: "/tmp/library-video.mp4")
        await MainActor.run {
            let library = MediaLibrary.shared
            let old = library.entries
            defer { library.entries = old }
            let entry = HistoryEntry(id: UUID(), url: file.absoluteString, title: "clip", mode: .video,
                                     outputFile: file, errorMessage: nil, uploader: nil, durationSeconds: nil,
                                     fileSizeBytes: nil, finishedAt: Date(), outcome: .finished)
            library.entries = [entry]
            #expect(library.combined(with: [entry]).count == 1)
            #expect(library.combined(with: [], excluding: [file]).isEmpty)
        }
    }
}

struct StructuredDownloadTests {
    @Test func structuredEventsPreserveFinalPathAndIgnoreCancelledJobs() async throws {
        await MainActor.run {
            let manager = DownloadManager.shared
            let item = DownloadItem(url: "https://example.org/video", mode: .video)
            item.status = .downloading
            manager.items.append(item)
            defer { manager.items.removeAll { $0.id == item.id } }
            manager.parseProgress("CATAPULT_META {\"title\":\"Example\",\"requested_formats\":[{\"format_id\":\"video\",\"filesize\":900},{\"format_id\":\"audio\",\"filesize\":100}]}", forID: item.id)
            manager.parseProgress("CATAPULT_PROGRESS \"video\" {\"downloaded_bytes\":900,\"total_bytes\":900,\"speed\":1000,\"eta\":1}", forID: item.id)
            #expect(item.title == "Example" && item.progress == 0.9)
            manager.parseProgress("[Merger] Merging formats into \"/tmp/wrong-path.mp4\"", forID: item.id)
            #expect(item.status == .postProcessing && item.speed.isEmpty && item.eta.isEmpty)
            manager.parseProgress("CATAPULT_FILE \"/tmp/final café.mp4\"", forID: item.id)
            #expect(item.outputFile?.lastPathComponent == "final café.mp4")
            item.status = .cancelled
            manager.parseProgress("CATAPULT_PROGRESS \"audio\" {\"downloaded_bytes\":100,\"total_bytes\":100}", forID: item.id)
            #expect(item.status == .cancelled && item.progress == 0.9)
        }
    }
}

struct CookieCryptoTests {
    @Test func rejectsUnsupportedEncryptionAndWrongHost() {
        let key = Data(repeating: 0, count: 16)
        #expect(HeliumCookieBridge.decryptValue(Data("v20unsupported".utf8), key: key, hashPrefixFirst: false, domain: ".example.org") == nil)
        #expect(HeliumCookieBridge.decryptValue(Data("v10invalid".utf8), key: key, hashPrefixFirst: true, domain: ".example.org") == nil)
        #expect(HeliumCookieBridge.decryptValue(Data("plaintext".utf8), key: key, hashPrefixFirst: false, domain: ".example.org") == Data("plaintext".utf8))
    }
}
