import Foundation
import Observation
import AppKit

enum DownloadMode: String, CaseIterable, Codable {
    case video         // full quality video+audio
    case audio         // extract audio
    case cut           // trim a range (video+audio)
    case thumbnailOnly // save thumbnail image, no media
}

struct DownloadOverrides {
    var videoQuality: VideoQuality?
    var videoContainer: VideoContainer?
    var audioFormat: AudioFormat?
    var maxFilesizeMB: Int?
    var thumbnailFormat: String?
    /// A device preset trumps quality + container + filesize, and can append
    /// a full ffmpeg recode recipe (retro presets lean on this).
    var devicePreset: DevicePreset?
}

enum DownloadStatus: Equatable {
    case queued
    case fetchingInfo
    case downloading
    case postProcessing
    case finished(URL?)
    case failed(String)
    case cancelled
}

@Observable
final class DownloadItem: Identifiable, Hashable {
    let id = UUID()
    let url: String
    var mode: DownloadMode
    var title: String
    var thumbnailURL: URL?
    var durationSeconds: Double?
    var uploader: String?

    var status: DownloadStatus = .queued
    var progress: Double = 0          // 0..1 from yt-dlp
    var speed: String = ""
    var eta: String = ""
    var statusLine: String = "Queued"
    var outputFile: URL?

    // Cut parameters (seconds)
    var cutStart: Double?
    var cutEnd: Double?

    // Per-download overrides (from quick actions)
    var overrides: DownloadOverrides = DownloadOverrides()

    // A one-shot cookie override for the current attempt. The auto-retry
    // logic populates this with e.g. `.safari` after a format/auth failure
    // when the user hadn't enabled cookies.
    var forceCookieSource: CookieSource?
    // True once we've already auto-retried with cookies, so we don't loop.
    var cookiesAutoRetried: Bool = false

    fileprivate var process: Process?

    init(url: String, mode: DownloadMode) {
        self.url = url
        self.mode = mode
        self.title = url
    }

    static func == (l: DownloadItem, r: DownloadItem) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

@Observable
final class DownloadManager {
    static let shared = DownloadManager()

    var items: [DownloadItem] = []
    private var activeCount = 0
    private var pendingIDs: [UUID] = []

    private init() {}

    // MARK: - Public API

    @discardableResult
    @MainActor
    func enqueue(url: String,
                 mode: DownloadMode,
                 cutStart: Double? = nil,
                 cutEnd: Double? = nil,
                 overrides: DownloadOverrides = DownloadOverrides()) -> DownloadItem {
        let item = DownloadItem(url: url, mode: mode)
        item.cutStart = cutStart
        item.cutEnd = cutEnd
        item.overrides = overrides
        items.insert(item, at: 0)
        pendingIDs.append(item.id)
        Task { await fetchInfo(for: item) }
        drain()
        return item
    }

    @MainActor
    func cancel(_ item: DownloadItem) {
        item.process?.terminate()
        item.status = .cancelled
        item.statusLine = "Cancelled"
        pendingIDs.removeAll { $0 == item.id }
        drain()
    }

    @MainActor
    func remove(_ item: DownloadItem) {
        if case .downloading = item.status { item.process?.terminate() }
        items.removeAll { $0.id == item.id }
        pendingIDs.removeAll { $0 == item.id }
    }

    @MainActor
    func clearFinished() {
        items.removeAll { item in
            switch item.status {
            case .finished, .failed, .cancelled: return true
            default: return false
            }
        }
    }

    @MainActor
    func retry(_ item: DownloadItem) {
        item.status = .queued
        item.statusLine = "Queued"
        item.progress = 0
        // Fresh manual retry gets a fresh shot at the cookie-fallback too.
        item.cookiesAutoRetried = false
        item.forceCookieSource = nil
        pendingIDs.append(item.id)
        drain()
    }

    // MARK: - Scheduling

    @MainActor
    private func drain() {
        let max = AppSettings.shared.maxConcurrent
        while activeCount < max, let nextID = pendingIDs.first {
            pendingIDs.removeFirst()
            guard let item = items.first(where: { $0.id == nextID }) else { continue }
            if case .cancelled = item.status { continue }
            activeCount += 1
            Task { await run(item) }
        }
    }

    // MARK: - Info (title, thumbnail, duration) via yt-dlp --dump-single-json

    @MainActor
    private func fetchInfo(for item: DownloadItem) async {
        item.status = .fetchingInfo
        item.statusLine = "Fetching info…"
        let dep = DependencyManager.shared
        guard FileManager.default.fileExists(atPath: dep.ytDlpPath.path) else { return }
        let args = ["--dump-single-json", "--no-warnings",
                    "--no-playlist", "--skip-download", item.url]

        let result: Data? = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let t = Process()
                t.executableURL = dep.ytDlpPath
                t.arguments = args
                let out = Pipe()
                t.standardOutput = out
                t.standardError = Pipe()
                do {
                    try t.run()
                    let data = out.fileHandleForReading.readDataToEndOfFile()
                    t.waitUntilExit()
                    cont.resume(returning: data)
                } catch {
                    cont.resume(returning: nil)
                }
            }
        }

        guard let data = result,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        if let t = obj["title"] as? String { item.title = t }
        if let u = obj["uploader"] as? String { item.uploader = u }
        if let d = obj["duration"] as? Double { item.durationSeconds = d }
        if let thumb = obj["thumbnail"] as? String, let u = URL(string: thumb) {
            item.thumbnailURL = u
        }
        if case .fetchingInfo = item.status { item.statusLine = "Ready" }
    }

    // MARK: - Actual download

    @MainActor
    private func run(_ item: DownloadItem) async {
        defer {
            activeCount -= 1
            drain()
        }
        item.status = .downloading
        item.statusLine = "Starting…"

        let settings = AppSettings.shared
        let dep = DependencyManager.shared

        let folder = settings.downloadFolderURL
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Device preset takes precedence over explicit quality/container
        // overrides and the global defaults — it's an intentional recipe.
        // Per-download preset wins; otherwise fall back to the app-wide
        // default (which is usually `.none`).
        let resolvedPreset: DevicePreset? = {
            if let p = item.overrides.devicePreset, p != .none { return p }
            if settings.defaultDevicePreset != .none { return settings.defaultDevicePreset }
            return nil
        }()
        let preset = resolvedPreset
        let presetHeightQuality: VideoQuality? = {
            guard let h = preset?.heightCap else { return nil }
            // Pick the smallest available VideoQuality ≥ heightCap so we
            // don't pull down a 4K source just to scale it to 272p. Falls
            // back to 360p for sub-360 retro targets.
            let stops: [VideoQuality] = [.p360, .p480, .p720, .p1080, .p1440, .p2160]
            return stops.first(where: { Int($0.rawValue) ?? 0 >= h }) ?? .p2160
        }()
        let quality   = presetHeightQuality
                        ?? item.overrides.videoQuality
                        ?? settings.videoQuality
        let container = preset?.container
                        ?? item.overrides.videoContainer
                        ?? settings.videoContainer
        let audioFmt  = item.overrides.audioFormat    ?? settings.audioFormat
        let effectiveMaxMB = preset?.maxFilesizeMB ?? item.overrides.maxFilesizeMB

        // Output template — clip mode gets a unique " (clip_<stamp>)" suffix that is
        // renamed to " (clip)" / " (clip2)" / ... post-download.
        var outputTemplate = folder
            .appendingPathComponent(settings.filenameTemplate).path
        if item.mode == .cut {
            let stamp = Int(Date().timeIntervalSince1970)
            outputTemplate = outputTemplate.replacingOccurrences(
                of: ".%(ext)s",
                with: " (clip_\(stamp)).%(ext)s"
            )
        }

        var args: [String] = [
            "--newline",
            "--no-playlist",
            "--progress",
            "-o", outputTemplate,
            "--ffmpeg-location", dep.binDirectory.path,
            "--no-mtime",
        ]

        // Cookies: a one-shot `forceCookieSource` (set by the auto-retry
        // path after an auth failure) takes precedence over the user's
        // normal per-site / global resolution.
        let cookieSrc = item.forceCookieSource ?? settings.cookieSource(for: item.url)
        if let browser = cookieSrc.ytdlpName {
            args.append(contentsOf: ["--cookies-from-browser", browser])
        }

        // Proxy (blank string means off)
        let proxy = settings.proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !proxy.isEmpty {
            args.append(contentsOf: ["--proxy", proxy])
        }

        // Rate limit (0 means unlimited)
        if settings.rateLimitKBps > 0 {
            args.append(contentsOf: ["--limit-rate", "\(settings.rateLimitKBps)K"])
        }

        // Thumbnail-only short-circuits: skip media and just save the image.
        if item.mode == .thumbnailOnly {
            let fmt = item.overrides.thumbnailFormat ?? "png"
            args.append(contentsOf: [
                "--skip-download",
                "--write-thumbnail",
                "--convert-thumbnails", fmt,
            ])
            args.append(item.url)
        } else {
            if settings.writeThumbnail { args.append("--write-thumbnail") }
            if settings.embedThumbnail {
                args.append("--embed-thumbnail")
                // WebP thumbnails can't be embedded into opus/flac/mkv; normalize to jpg.
                args.append(contentsOf: ["--convert-thumbnails", "jpg"])
                // Some containers need an explicit pp to tag the embedded image.
                args.append(contentsOf: ["--ppa", "EmbedThumbnail+ffmpeg_o1:-c:v mjpeg"])
            }
            if settings.embedMetadata  { args.append("--embed-metadata") }
            if settings.embedSubtitles {
                args.append(contentsOf: ["--embed-subs", "--sub-langs", "en.*,en"])
                args.append("--write-auto-subs")
            }

            // SponsorBlock integration
            if settings.sponsorBlockMode != .off, !settings.sponsorBlockCategories.isEmpty {
                let cats = settings.sponsorBlockCategories.map(\.rawValue).sorted().joined(separator: ",")
                switch settings.sponsorBlockMode {
                case .mark:   args.append(contentsOf: ["--sponsorblock-mark", cats])
                case .remove: args.append(contentsOf: ["--sponsorblock-remove", cats])
                case .off:    break
                }
            }

            switch item.mode {
            case .video:
                args.append(contentsOf: ["-f", videoFormatString(quality: quality,
                                                                 container: container,
                                                                 maxMB: effectiveMaxMB,
                                                                 compat: settings.preferCompatibleCodecs)])
                args.append(contentsOf: ["--merge-output-format", container.rawValue])
                if let mb = effectiveMaxMB {
                    args.append(contentsOf: ["--max-filesize", "\(mb)M"])
                }
                applyPresetPostprocess(preset: preset,
                                       container: container,
                                       preferCompat: settings.preferCompatibleCodecs,
                                       into: &args)
            case .audio:
                args.append(contentsOf: [
                    "-f", "bestaudio/best",
                    "-x",
                    "--audio-format", audioFmt.rawValue,
                    "--audio-quality", String(settings.audioQualityKbps) + "K",
                ])
            case .cut:
                args.append(contentsOf: ["-f", videoFormatString(quality: quality,
                                                                 container: container,
                                                                 maxMB: nil,
                                                                 compat: settings.preferCompatibleCodecs)])
                args.append(contentsOf: ["--merge-output-format", container.rawValue])
                applyPresetPostprocess(preset: preset,
                                       container: container,
                                       preferCompat: settings.preferCompatibleCodecs,
                                       into: &args)
                if let s = item.cutStart, let e = item.cutEnd, e > s {
                    let range = "*\(formatSec(s))-\(formatSec(e))"
                    args.append(contentsOf: ["--download-sections", range])
                    args.append("--force-keyframes-at-cuts")
                    args.append(contentsOf: [
                        "--postprocessor-args",
                        "Merger+ffmpeg_o1:-avoid_negative_ts make_zero -fflags +genpts"
                    ])
                }
            case .thumbnailOnly:
                break // handled above
            }

            args.append(item.url)
        }

        let task = Process()
        task.executableURL = dep.ytDlpPath
        task.arguments = args
        task.environment = ProcessInfo.processInfo.environment
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe
        item.process = task

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            let itemID = item.id
            Task { @MainActor in
                DownloadManager.shared.parseProgress(s, forID: itemID)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            let itemID = item.id
            Task { @MainActor in
                DownloadManager.shared.parseProgress(s, forID: itemID)
            }
        }

        let finalPath: URL? = await withCheckedContinuation { cont in
            task.terminationHandler = { t in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                Task { @MainActor in
                    if t.terminationStatus == 0 {
                        cont.resume(returning: item.outputFile)
                    } else if case .cancelled = item.status {
                        cont.resume(returning: nil)
                    } else {
                        cont.resume(returning: nil)
                    }
                }
            }
            do {
                try task.run()
            } catch {
                cont.resume(returning: nil)
            }
        }

        if task.terminationStatus == 0 {
            if item.mode == .cut,
               let src = finalPath ?? item.outputFile,
               let s = item.cutStart, let e = item.cutEnd, e > s {
                item.statusLine = "Finalizing clip…"
                item.status = .postProcessing
                let fixed = await fixClipDuration(file: src,
                                                  duration: e - s,
                                                  ffmpeg: dep.ffmpegPath)
                let after = fixed ?? src
                item.outputFile = Self.renameToNextClip(at: after) ?? after
            }

            let shown = item.outputFile ?? finalPath
            item.status = .finished(shown)
            item.progress = 1
            item.statusLine = "Finished"
            if settings.openFolderOnFinish {
                if let f = shown {
                    NSWorkspace.shared.activateFileViewerSelecting([f])
                } else {
                    NSWorkspace.shared.open(folder)
                }
            }
            if settings.showNotifications {
                NotificationHelper.show(title: "Download finished", body: item.title)
            }
        } else if case .cancelled = item.status {
            // keep status
        } else if shouldAutoRetryWithCookies(item: item, originalCookies: cookieSrc) {
            // Auto-fallback: this video likely needs auth (age-gated /
            // members-only / region-locked). Pick Safari's cookies — it's
            // always installed on macOS — and requeue. We only do this
            // once per download.
            item.cookiesAutoRetried = true
            item.forceCookieSource = .safari
            item.status = .queued
            item.progress = 0
            item.statusLine = "Retrying with Safari cookies…"
            pendingIDs.append(item.id)
            if settings.showNotifications {
                NotificationHelper.show(title: "Retrying with cookies",
                                        body: item.title)
            }
        } else {
            item.status = .failed(item.statusLine)
            item.statusLine = "Failed: " + item.statusLine
            if settings.showNotifications {
                NotificationHelper.show(title: "Download failed", body: item.title)
            }
        }
    }

    // Decide whether to auto-retry a failed download by forcing cookies.
    // Trigger when: the first attempt didn't use cookies, we haven't already
    // auto-retried, and the error looks like an auth/format gate.
    private func shouldAutoRetryWithCookies(item: DownloadItem,
                                            originalCookies: CookieSource) -> Bool {
        guard !item.cookiesAutoRetried else { return false }
        guard originalCookies == .off else { return false }
        let msg = item.statusLine.lowercased()
        let markers = [
            "requested format is not available",
            "sign in to confirm",
            "age",
            "private video",
            "this video is available for",
            "members only",
            "this live event",
        ]
        return markers.contains { msg.contains($0) }
    }

    // MARK: - Progress parser

    @MainActor
    func parseProgress(_ chunk: String, forID id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        parseProgress(chunk, for: item)
    }

    @MainActor
    private func parseProgress(_ chunk: String, for item: DownloadItem?) {
        guard let item else { return }
        for rawLine in chunk.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(rawLine)
            if line.contains("[download]") {
                // [download]  23.4% of 12.34MiB at 2.45MiB/s ETA 00:04
                if let pct = Self.extract(regex: #"(\d+\.\d+)%"#, from: line),
                   let p = Double(pct) {
                    item.progress = p / 100
                }
                if let sp = Self.extract(regex: #"at\s+([\d\.]+[KMG]?i?B/s)"#, from: line) {
                    item.speed = sp
                }
                if let eta = Self.extract(regex: #"ETA\s+([\d:]+)"#, from: line) {
                    item.eta = eta
                }
                item.statusLine = "Downloading" +
                    (item.speed.isEmpty ? "" : " · \(item.speed)") +
                    (item.eta.isEmpty ? "" : " · ETA \(item.eta)")
            } else if line.contains("[Merger]") || line.contains("[ExtractAudio]") ||
                      line.contains("[VideoConvertor]") || line.contains("[EmbedThumbnail]") ||
                      line.contains("[Metadata]") || line.contains("[FixupM3u8]") {
                item.status = .postProcessing
                item.statusLine = "Processing…"
            } else if line.hasPrefix("ERROR:") {
                let msg = line
                    .replacingOccurrences(of: "ERROR: ", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // Humanize the most common one. "Requested format is not available"
                // almost always means the video is age-gated / members-only /
                // region-locked, or yt-dlp is stale.
                if msg.contains("Requested format is not available") {
                    item.statusLine = "No downloadable formats — try enabling cookies for this site, or update yt-dlp in the Dependencies tab."
                } else if msg.contains("Sign in to confirm") || msg.contains("age") {
                    item.statusLine = "Age-restricted — enable cookies in Settings › Sites to sign in."
                } else {
                    item.statusLine = msg
                }
            } else if let dest = Self.extract(regex: #"Destination:\s+(.+)"#, from: line) {
                let p = dest.trimmingCharacters(in: .whitespaces)
                item.outputFile = URL(fileURLWithPath: p)
            } else if let merged = Self.extract(regex: #"Merging formats into\s+"(.+?)""#, from: line) {
                item.outputFile = URL(fileURLWithPath: merged)
            }
        }
    }

    private static func extract(regex pattern: String, from s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 2 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    /// Rewrites the container with the actual clip duration so players don't show
    /// the full original video length. Returns the (possibly renamed) final file URL.
    private func fixClipDuration(file: URL, duration: Double, ffmpeg: URL) async -> URL? {
        guard FileManager.default.fileExists(atPath: ffmpeg.path) else { return file }
        guard FileManager.default.fileExists(atPath: file.path) else { return file }
        let temp = file.deletingLastPathComponent()
            .appendingPathComponent("." + file.lastPathComponent + ".tmp." + file.pathExtension)

        let success: Bool = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let t = Process()
                t.executableURL = ffmpeg
                t.arguments = [
                    "-y",
                    "-i", file.path,
                    "-t", String(format: "%.3f", duration),
                    "-c", "copy",
                    "-avoid_negative_ts", "make_zero",
                    "-reset_timestamps", "1",
                    "-movflags", "+faststart",
                    "-map_metadata", "0",
                    temp.path
                ]
                t.standardOutput = Pipe(); t.standardError = Pipe()
                do {
                    try t.run()
                    t.waitUntilExit()
                    cont.resume(returning: t.terminationStatus == 0)
                } catch {
                    cont.resume(returning: false)
                }
            }
        }

        guard success, FileManager.default.fileExists(atPath: temp.path) else {
            try? FileManager.default.removeItem(at: temp)
            return file
        }
        do {
            try FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: temp, to: file)
            return file
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return file
        }
    }

    /// Slots a device preset's recode recipe (or the default compat remux)
    /// into the args list. When a retro preset is active, its `--recode-video`
    /// + `--postprocessor-args` replace the normal `--remux-video mp4` step.
    private func applyPresetPostprocess(preset: DevicePreset?,
                                        container: VideoContainer,
                                        preferCompat: Bool,
                                        into args: inout [String]) {
        if let preset, preset.needsRecode {
            args.append(contentsOf: ["--recode-video", preset.container.rawValue])
            let recode = preset.recodeArgs
            if !recode.isEmpty {
                args.append(contentsOf: [
                    "--postprocessor-args",
                    "VideoConvertor:\(recode)"
                ])
            }
            return
        }
        if preferCompat, container == .mp4 {
            // Force recode to H.264/AAC if source differs (AV1/VP9 → H.264).
            args.append(contentsOf: ["--remux-video", "mp4"])
        }
    }

    /// Builds a yt-dlp `-f` selector that prefers h264/aac/mp4 when `compat` is on,
    /// optionally capped by height and filesize.
    private func videoFormatString(quality: VideoQuality,
                                   container: VideoContainer,
                                   maxMB: Int?,
                                   compat: Bool) -> String {
        let heightPred: String = {
            if case .best = quality { return "" }
            return "[height<=\(quality.rawValue)]"
        }()
        let sizePred: String = {
            guard let mb = maxMB else { return "" }
            return "[filesize<=\(mb)M]/[filesize_approx<=\(mb)M]"
        }()
        if maxMB != nil {
            // Prefer a single merged file under the limit; fall back to approx, then best effort.
            let mb = maxMB!
            return [
                "b[filesize<=\(mb)M]\(heightPred)",
                "b[filesize_approx<=\(mb)M]\(heightPred)",
                "bv*\(heightPred)+ba/b\(heightPred)",
                "b"
            ].joined(separator: "/")
        }
        if compat && container == .mp4 {
            // Gradually loosen the constraints so videos that don't publish a
            // strict avc1+mp4a+height match still resolve to *something* rather
            // than erroring with "Requested format is not available".
            return [
                "bv*[vcodec^=avc1]\(heightPred)+ba[acodec^=mp4a]",
                "bv*[ext=mp4]\(heightPred)+ba[ext=m4a]",
                "bv*\(heightPred)+ba",
                "b\(heightPred)",
                "bv*+ba",
                "b",
                "best"
            ].joined(separator: "/")
        }
        _ = sizePred
        // Add a no-height-cap final fallback to the non-compat chain for the
        // same reason.
        return quality.ytdlpFormat + "/bv*+ba/b/best"
    }

    /// Renames a cut file so the first clip is "name (clip).ext", second is
    /// "name (clip2).ext", etc. The incoming `file` is expected to have a
    /// " (clip_<stamp>)" stem suffix which we strip before counting.
    static func renameToNextClip(at file: URL) -> URL? {
        let dir = file.deletingLastPathComponent()
        let ext = file.pathExtension
        let stem = file.deletingPathExtension().lastPathComponent
        let re = try? NSRegularExpression(pattern: #" \(clip(?:_\d+|\d*)\)$"#)
        let ns = stem as NSString
        let baseStem: String
        if let m = re?.firstMatch(in: stem, range: NSRange(location: 0, length: ns.length)),
           m.range.location != NSNotFound {
            baseStem = ns.substring(with: NSRange(location: 0, length: m.range.location))
        } else {
            baseStem = stem
        }
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent("\(baseStem) (clip).\(ext)")
        var n = 1
        while fm.fileExists(atPath: candidate.path) {
            n += 1
            candidate = dir.appendingPathComponent("\(baseStem) (clip\(n)).\(ext)")
        }
        do {
            try fm.moveItem(at: file, to: candidate)
            return candidate
        } catch {
            return nil
        }
    }

    private func formatSec(_ t: Double) -> String {
        let total = Int(t)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        let frac = t - Double(Int(t))
        let fracStr = String(format: "%.2f", frac).dropFirst() // ".xx"
        if h > 0 {
            return String(format: "%d:%02d:%02d%@", h, m, s, String(fracStr))
        } else {
            return String(format: "%02d:%02d%@", m, s, String(fracStr))
        }
    }
}
