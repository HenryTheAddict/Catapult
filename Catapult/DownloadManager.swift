import Foundation
import Observation
import AppKit
import ImageIO

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

enum SpotifyBridge {
    struct Track: Hashable {
        let title: String
        let artist: String
        let spotifyURL: String?
        let thumbnailURL: URL?
        let durationSeconds: Double?

        var displayTitle: String {
            artist.isEmpty ? title : "\(artist) - \(title)"
        }

        var youtubeMusicSearch: String {
            let query = [artist, title, "official audio"]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: " ")
            return "ytsearch1:\(query)"
        }
    }

    struct Collection: Hashable {
        let title: String
        let tracks: [Track]
    }

    enum ResolveResult {
        case single(Track)
        case collection(Collection)
        case failure(String)
    }

    private struct Descriptor {
        let kind: String
        let id: String
    }

    private typealias JSONDict = [String: Any]

    static func canBridge(_ rawURL: String) -> Bool {
        SupportedSite.match(url: rawURL) == .spotify
    }

    static func resolve(_ rawURL: String) async -> ResolveResult {
        guard let descriptor = await descriptor(for: rawURL) else {
            return .failure("could not read this Spotify link")
        }
        guard let embedURL = URL(string: "https://open.spotify.com/embed/\(descriptor.kind)/\(descriptor.id)") else {
            return .failure("bad Spotify embed URL")
        }

        do {
            let (data, _) = try await URLSession.shared.data(for: request(embedURL))
            guard let html = String(data: data, encoding: .utf8),
                  let entity = parseEntity(fromEmbedHTML: html) else {
                return .failure("Spotify metadata was not available")
            }
            let fallbackArt = artworkURL(from: entity)
            if descriptor.kind == "track", let track = track(from: entity, fallbackArt: fallbackArt) {
                return .single(track)
            }
            let title = clean(entity["title"] as? String)
                ?? clean(entity["name"] as? String)
                ?? "Spotify \(descriptor.kind)"
            let tracks = tracks(fromCollectionEntity: entity, fallbackArt: fallbackArt)
            if let single = tracks.first, tracks.count == 1, descriptor.kind == "track" {
                return .single(single)
            }
            guard !tracks.isEmpty else {
                return .failure("Spotify \(descriptor.kind) had no visible tracks")
            }
            return .collection(Collection(title: title, tracks: tracks))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private static func descriptor(for rawURL: String) async -> Descriptor? {
        if let fromRaw = descriptor(from: rawURL) {
            return fromRaw
        }
        if let fromOEmbed = await descriptorFromOEmbed(rawURL) {
            return fromOEmbed
        }
        if let final = await resolvedURL(rawURL), final.absoluteString != rawURL {
            if let fromFinal = descriptor(from: final.absoluteString) {
                return fromFinal
            }
            return await descriptorFromOEmbed(final.absoluteString)
        }
        return nil
    }

    private static func descriptorFromOEmbed(_ rawURL: String) async -> Descriptor? {
        var comps = URLComponents(string: "https://open.spotify.com/oembed")
        comps?.queryItems = [URLQueryItem(name: "url", value: rawURL)]
        guard let url = comps?.url else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(for: request(url))
            guard let object = try JSONSerialization.jsonObject(with: data) as? JSONDict else {
                return nil
            }
            if let iframe = object["iframe_url"] as? String {
                return descriptor(from: iframe)
            }
        } catch { }
        return nil
    }

    private static func resolvedURL(_ rawURL: String) async -> URL? {
        guard let url = URL(string: rawURL) else { return nil }
        do {
            let (_, response) = try await URLSession.shared.data(for: request(url))
            return response.url
        } catch {
            return nil
        }
    }

    private static func descriptor(from rawURL: String) -> Descriptor? {
        guard let comps = URLComponents(string: rawURL),
              let host = comps.host?.lowercased(),
              host == "open.spotify.com" || host.hasSuffix(".spotify.com") else {
            return nil
        }
        let parts = comps.path
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }
        guard let index = parts.firstIndex(where: { $0 == "track" || $0 == "playlist" || $0 == "album" }),
              index + 1 < parts.count else {
            return nil
        }
        return Descriptor(kind: parts[index], id: parts[index + 1])
    }

    private static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func parseEntity(fromEmbedHTML html: String) -> JSONDict? {
        let pattern = #"<script id="__NEXT_DATA__" type="application/json">(.+?)</script>"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let ns = html as NSString
        guard let match = re.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 2 else {
            return nil
        }
        let json = ns.substring(with: match.range(at: 1))
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? JSONDict else {
            return nil
        }
        return value(root, path: ["props", "pageProps", "state", "data", "entity"]) as? JSONDict
    }

    private static func track(from entity: JSONDict, fallbackArt: URL?) -> Track? {
        guard let title = clean(entity["title"] as? String) ?? clean(entity["name"] as? String) else {
            return nil
        }
        let artist = artists(from: entity)
            ?? clean(entity["subtitle"] as? String)
            ?? ""
        let uri = entity["uri"] as? String
        let id = clean(entity["id"] as? String) ?? spotifyID(fromURI: uri)
        return Track(title: title,
                     artist: artist,
                     spotifyURL: spotifyTrackURL(id: id),
                     thumbnailURL: artworkURL(from: entity) ?? fallbackArt,
                     durationSeconds: durationSeconds(from: entity))
    }

    private static func tracks(fromCollectionEntity entity: JSONDict, fallbackArt: URL?) -> [Track] {
        guard let list = entity["trackList"] as? [JSONDict] else { return [] }
        return list.compactMap { entry in
            guard let title = clean(entry["title"] as? String) else { return nil }
            let artist = clean(entry["subtitle"] as? String) ?? ""
            let uri = entry["uri"] as? String
            let id = spotifyID(fromURI: uri)
            return Track(title: title,
                         artist: artist,
                         spotifyURL: spotifyTrackURL(id: id),
                         thumbnailURL: artworkURL(from: entry) ?? fallbackArt,
                         durationSeconds: durationSeconds(from: entry))
        }
    }

    private static func artists(from entity: JSONDict) -> String? {
        guard let artists = entity["artists"] as? [JSONDict] else { return nil }
        let names = artists.compactMap { clean($0["name"] as? String) }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    private static func artworkURL(from entity: JSONDict) -> URL? {
        if let visual = entity["visualIdentity"] as? JSONDict,
           let images = visual["image"] as? [JSONDict],
           let url = images.compactMap({ clean($0["url"] as? String) }).first {
            return URL(string: url)
        }
        if let cover = entity["coverArt"] as? JSONDict,
           let sources = cover["sources"] as? [JSONDict],
           let url = sources.compactMap({ clean($0["url"] as? String) }).first {
            return URL(string: url)
        }
        if let images = entity["images"] as? [JSONDict],
           let url = images.compactMap({ clean($0["url"] as? String) }).first {
            return URL(string: url)
        }
        return nil
    }

    private static func durationSeconds(from entity: JSONDict) -> Double? {
        if let ms = entity["duration"] as? Double { return ms / 1000.0 }
        if let ms = entity["duration"] as? Int { return Double(ms) / 1000.0 }
        return nil
    }

    private static func spotifyID(fromURI uri: String?) -> String? {
        guard let uri else { return nil }
        return uri.split(separator: ":").last.map(String.init)
    }

    private static func spotifyTrackURL(id: String?) -> String? {
        guard let id, !id.isEmpty else { return nil }
        return "https://open.spotify.com/track/\(id)"
    }

    private static func value(_ object: Any, path: [String]) -> Any? {
        var current: Any? = object
        for key in path {
            current = (current as? JSONDict)?[key]
        }
        return current
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .replacingOccurrences(of: #"\"#, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
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
    /// Optional bridge target. The visible/source URL stays in `url` so
    /// history and "copy source" still point back to Spotify, while yt-dlp
    /// receives this resolved URL/search query.
    var resolvedDownloadURL: String?

    var status: DownloadStatus = .queued
    var source: MediaSource?
    var clipAccuracy: ClipAccuracy = .accurate
    var attemptID = UUID()
    var transfer = TransferProgress()
    var intermediateFiles: Set<URL> = []
    var hasMeasuredProgress = false
    var progressEstimated = false
    var cookieWarning: String?
    var progress: Double = 0          // 0..1 from yt-dlp
    var speed: String = ""
    var eta: String = ""
    var statusLine: String = "Queued"
    var outputFile: URL?

    var isActive: Bool {
        switch status { case .queued, .fetchingInfo, .downloading, .postProcessing: return true; default: return false }
    }
    // Cut parameters (seconds)
    var cutStart: Double?
    var cutEnd: Double?

    // Per-download overrides (from quick actions)
    var overrides: DownloadOverrides = DownloadOverrides()
    // One-shot copy behavior for notification actions and other quick flows.
    var copyFileAfterFinish: Bool = false

    // A one-shot cookie override for the current attempt. The auto-retry
    // logic populates this with the user's selected browser after a
    // format/auth failure when cookies are enabled for this site but the
    // first attempt didn't include them.
    var forceCookieSource: CookieSource?
    // True once we've already auto-retried with cookies, so we don't loop.
    var cookiesAutoRetried: Bool = false
    // True once we've retried without cookies after the cookie import
    // itself broke (locked cookie DB, keychain denial), so we don't loop.
    var cookieFallbackTried: Bool = false
    // The raw yt-dlp error line, kept for retry classification (the
    // user-facing statusLine gets humanized by parseProgress).
    var lastRawError: String?
    // True once we've refreshed yt-dlp/ffmpeg after a failure, so we don't loop.
    var dependencyRepairAttempted: Bool = false

    fileprivate var process: Process?
    fileprivate var operationTask: Task<Void, Never>?

    init(url: String, mode: DownloadMode) {
        self.url = url
        self.mode = mode
        self.title = url
    }

    var ytdlpURL: String {
        resolvedDownloadURL ?? url
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
                 overrides: DownloadOverrides = DownloadOverrides(),
                 copyFileAfterFinish: Bool = false,
                 source: MediaSource? = nil,
                 clipAccuracy: ClipAccuracy = .accurate) -> DownloadItem {
        let item = DownloadItem(url: url, mode: mode)
        item.source = source
        item.clipAccuracy = clipAccuracy
        item.cutStart = cutStart
        item.cutEnd = cutEnd
        item.overrides = overrides
        item.copyFileAfterFinish = copyFileAfterFinish
        items.insert(item, at: 0)
        if SpotifyBridge.canBridge(url) {
            item.operationTask = Task { await bridgeSpotify(item) }
        } else {
            pendingIDs.append(item.id)
            drain()
        }
        return item
    }

    @MainActor
    func cancel(_ item: DownloadItem) {
        item.attemptID = UUID()
        item.operationTask?.cancel(); item.operationTask = nil
        if item.process?.isRunning == true { item.process?.terminate() }
        item.status = .cancelled
        item.statusLine = "Cancelled"
        HistoryStore.shared.record(item)
        pendingIDs.removeAll { $0 == item.id }
        drain()
    }

    @MainActor
    func remove(_ item: DownloadItem) {
        if item.isActive { cancel(item) }
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
        guard !item.isActive else { return }
        item.status = .queued
        item.statusLine = "Queued"
        item.progress = 0
        // Fresh manual retry gets a fresh shot at the cookie-fallback too.
        item.cookiesAutoRetried = false
        item.cookieFallbackTried = false
        item.forceCookieSource = nil
        item.lastRawError = nil
        item.dependencyRepairAttempted = false
        pendingIDs.append(item.id)
        drain()
    }

    @MainActor
    func refreshConcurrency() {
        drain()
    }

    // MARK: - Scheduling

    @MainActor
    private func drain() {
        let max = AppSettings.shared.maxConcurrent
        while activeCount < max, let nextID = pendingIDs.first {
            pendingIDs.removeFirst()
            guard let item = items.first(where: { $0.id == nextID }) else { continue }
            guard case .queued = item.status else { continue }
            activeCount += 1
            item.attemptID = UUID()
            item.operationTask = Task { await run(item) }
        }
    }

    // MARK: - Spotify → YouTube Music bridge

    @MainActor
    private func bridgeSpotify(_ item: DownloadItem) async {
        guard items.contains(where: { $0.id == item.id }) else { return }
        item.status = .fetchingInfo
        item.statusLine = "Resolving Spotify…"

        let attempt = item.attemptID
        let result = await SpotifyBridge.resolve(item.url)
        guard item.attemptID == attempt, item.isActive, items.contains(where: { $0.id == item.id }) else { return }
        switch result {
        case .single(let track):
            applySpotify(track, to: item)
            queueResolvedSpotifyItem(item)

        case .collection(let collection):
            guard !collection.tracks.isEmpty else {
                item.status = .failed("Spotify playlist had no playable tracks")
                item.statusLine = "Failed: no Spotify tracks found"
                HistoryStore.shared.record(item)
                return
            }
            let sourceMode = item.mode
            let overrides = item.overrides
            items.removeAll { $0.id == item.id }

            let newItems = collection.tracks.map { track -> DownloadItem in
                let child = DownloadItem(url: track.spotifyURL ?? item.url, mode: spotifyMode(from: sourceMode))
                child.overrides = overrides
                applySpotify(track, to: child)
                return child
            }
            items.insert(contentsOf: newItems.reversed(), at: 0)
            pendingIDs.append(contentsOf: newItems.map(\.id))
            drain()
            if AppSettings.shared.showNotifications {
                NotificationHelper.show(title: "Spotify playlist queued",
                                        body: "\(collection.title) · \(newItems.count) track\(newItems.count == 1 ? "" : "s")")
            }

        case .failure(let message):
            item.status = .failed(message)
            item.statusLine = "Failed: \(message)"
            HistoryStore.shared.record(item)
        }
    }

    @MainActor
    private func queueResolvedSpotifyItem(_ item: DownloadItem) {
        item.mode = spotifyMode(from: item.mode)
        item.status = .queued
        item.statusLine = "Queued from Spotify"
        pendingIDs.append(item.id)
        drain()
    }

    private func applySpotify(_ track: SpotifyBridge.Track, to item: DownloadItem) {
        item.title = track.displayTitle
        item.uploader = track.artist
        item.thumbnailURL = track.thumbnailURL
        item.durationSeconds = track.durationSeconds
        item.resolvedDownloadURL = track.youtubeMusicSearch
    }

    private func spotifyMode(from _: DownloadMode) -> DownloadMode {
        .audio
    }

    // MARK: - Actual download

    @MainActor
    private func run(_ item: DownloadItem) async {
        let attempt = item.attemptID
        defer {
            if item.attemptID == attempt { item.operationTask = nil }
            activeCount -= 1
            drain()
        }

        guard !Task.isCancelled, item.isActive, items.contains(where: { $0.id == item.id }) else { return }
        item.transfer = TransferProgress()
        item.intermediateFiles.removeAll()
        item.hasMeasuredProgress = false
        item.speed = ""; item.eta = ""; item.outputFile = nil; item.lastRawError = nil
        if case .local(let file) = item.source {
            await runLocalClip(item, file: file, attempt: attempt)
            return
        }
        let dep = DependencyManager.shared
        guard FileManager.default.fileExists(atPath: dep.ytDlpPath.path) else {
            item.status = .failed("yt-dlp is not installed yet")
            item.statusLine = "Failed: yt-dlp missing"
            HistoryStore.shared.record(item)
            return
        }

        item.status = .downloading
        item.statusLine = "Preparing…"

        let settings = AppSettings.shared
        let folder = settings.downloadFolderURL
        var outputTemplate = folder.path + "/" + settings.filenameTemplate
        if item.cutStart != nil {
            outputTemplate = folder.appendingPathComponent("%(title).180B (clip_\(item.id.uuidString)).%(ext)s").path
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var args: [String] = [
            "--newline",
            "--no-playlist",
            "--progress",
            "-o", outputTemplate,
            "--ffmpeg-location", dep.binDirectory.path,
            "--no-mtime",
            "--no-simulate", "--no-quiet",
            "--progress-delta", "0.25",
            "--print", "before_dl:CATAPULT_META %(.{title,uploader,duration,thumbnail,requested_formats,format_id,filesize,filesize_approx})j",
            "--print", "after_move:CATAPULT_FILE %(filepath)j",
            "--progress-template", "download:CATAPULT_PROGRESS %(info.format_id)j %(progress.{downloaded_bytes,total_bytes,total_bytes_estimate,speed,eta,status,filename})j",
            "--progress-template", "postprocess:CATAPULT_POST %(progress)j",
            "--js-runtimes", "deno",
            "--js-runtimes", "node",
            "--js-runtimes", "bun",
            "--js-runtimes", "quickjs",
        ]

        if SupportedSite.match(url: item.ytdlpURL) == .youtube {
            args.append(contentsOf: ["--http-chunk-size", "10M"])
            if settings.rateLimitKBps == 0 { args.append(contentsOf: ["--throttled-rate", "100K"]) }
            args.append(contentsOf: [
                "--extractor-args", "youtube:player_client=default,ios,web_safari,web_embedded,-tv"
            ])
        }

        if settings.concurrentFragments > 1 {
            args.append(contentsOf: ["--concurrent-fragments", "\(settings.concurrentFragments)"])
        }

        // Cookies: a one-shot `forceCookieSource` (set by the auto-retry
        // path after an auth failure) takes precedence over the user's
        // normal per-site / global resolution. Helium isn't a browser
        // yt-dlp can read, so it arrives as an exported cookie file.
        let cookieSrc = item.forceCookieSource ?? settings.cookieSource(for: item.ytdlpURL)
        let cookieImport = await CookieArgs.resolve(for: item.ytdlpURL, source: cookieSrc)
        defer { cookieImport.cleanup() }
        guard item.attemptID == attempt, item.isActive else { return }
        item.cookieWarning = cookieImport.error
        if cookieImport.error != nil { item.cookieFallbackTried = true }
        let usedCookies = !cookieImport.arguments.isEmpty
        args.append(contentsOf: cookieImport.arguments)

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
            if let index = args.firstIndex(of: "after_move:CATAPULT_FILE %(filepath)j") {
                args[index] = "after_video:CATAPULT_THUMB %(thumbnails.:.{filepath})j"
            }
            args.append(contentsOf: [
                "--skip-download",
                "--write-thumbnail",
                "--convert-thumbnails", item.overrides.thumbnailFormat ?? "png",
            ])
            args.append(item.ytdlpURL)
        } else {
            // Video/audio metadata embedding
            if settings.embedThumbnail { args.append("--embed-thumbnail") }
            if settings.embedMetadata  { args.append("--embed-metadata") }
            if settings.embedSubtitles {
                args.append(contentsOf: ["--write-subs", "--write-auto-subs", "--embed-subs"])
            }
            if settings.writeThumbnail { args.append("--write-thumbnail") }

            // SponsorBlock
            if settings.sponsorBlockMode != .off && !settings.sponsorBlockCategories.isEmpty {
                let cats = settings.sponsorBlockCategories.map(\.rawValue).joined(separator: ",")
                if settings.sponsorBlockMode == .remove {
                    args.append(contentsOf: ["--sponsorblock-remove", cats])
                } else {
                    args.append(contentsOf: ["--sponsorblock-mark", cats])
                }
            }

            // Quality & Container overrides
            let quality = item.overrides.videoQuality ?? settings.videoQuality
            let container = item.overrides.videoContainer ?? settings.videoContainer
            let audioFormat = item.overrides.audioFormat ?? settings.audioFormat
            let maxFilesizeMB = item.overrides.maxFilesizeMB

            // Device preset (if one is active, it trumps raw quality/container settings)
            let preset = item.overrides.devicePreset ?? (settings.defaultDevicePreset == .none ? nil : settings.defaultDevicePreset)

            switch item.mode {
            case .audio:
                args.append(contentsOf: [
                    "-f", "ba/b", "-x",
                    "--audio-format", audioFormat.rawValue,
                    "--audio-quality", "\(settings.audioQualityKbps)K",
                ])
                if settings.normalizeAudio {
                    args.append(contentsOf: [
                        "--postprocessor-args",
                        "ExtractAudio+ffmpeg_o1:-af \(Self.loudnessNormalizeFilter)"
                    ])
                }

            case .video:
                let effectiveQuality: VideoQuality = {
                    guard let cap = preset?.heightCap else { return quality }
                    if let rawCap = Int(quality.rawValue), rawCap <= cap { return quality }
                    switch cap {
                    case ...240:  return .p360
                    case ...360:  return .p360
                    case ...480:  return .p480
                    case ...720:  return .p720
                    case ...1080: return .p1080
                    case ...1440: return .p1440
                    default:      return .p2160
                    }
                }()
                let effectiveContainer = preset?.container ?? container
                let effectiveMaxMB = preset?.maxFilesizeMB ?? maxFilesizeMB

                let fmt = videoFormatString(quality: effectiveQuality,
                                            container: effectiveContainer,
                                            maxMB: effectiveMaxMB,
                                            compat: settings.preferCompatibleCodecs)
                args.append(contentsOf: ["-f", fmt])
                args.append(contentsOf: ["--merge-output-format", effectiveContainer.rawValue])

                applyPresetPostprocess(preset: preset,
                                       container: effectiveContainer,
                                       preferCompat: settings.preferCompatibleCodecs,
                                       normalizeAudio: settings.normalizeAudio,
                                       audioBitrateKbps: settings.audioQualityKbps,
                                       into: &args)

            case .cut:
                let effectiveQuality = quality
                let effectiveContainer = container
                let fmt = videoFormatString(quality: effectiveQuality,
                                            container: effectiveContainer,
                                            maxMB: maxFilesizeMB,
                                            compat: settings.preferCompatibleCodecs)
                args.append(contentsOf: ["-f", fmt])
                args.append(contentsOf: ["--merge-output-format", effectiveContainer.rawValue])
            case .thumbnailOnly:
                break // handled above
            }

            if let start = item.cutStart, let end = item.cutEnd, end > start {
                args.append(contentsOf: ["--download-sections", String(format: "*%.3f-%.3f", start, end)])
                if item.clipAccuracy == .accurate { args.append("--force-keyframes-at-cuts") }
            }
            args.append(item.ytdlpURL)
        }

        let validCutRange: (start: Double, end: Double)? = {
            guard let s = item.cutStart, let e = item.cutEnd, e > s else { return nil }
            return (s, e)
        }()

        let task = Process()
        task.executableURL = dep.ytDlpPath
        task.arguments = args
        task.environment = DependencyManager.enhancedEnvironment
        item.process = task
        let result = await MediaProcess.run(task) { [weak self, weak item] line in
            guard let self, let item, item.attemptID == attempt, item.isActive else { return }
            self.parseProgress(line, for: item)
        }
        guard item.attemptID == attempt, item.isActive else { return }
        item.process = nil
        let finalPath = item.outputFile
        if result.code == -1 { item.lastRawError = result.stderr }

        if result.code == 0 {
            guard let output = item.outputFile, FileManager.default.fileExists(atPath: output.path) else {
                item.status = .failed("The downloader finished without producing a media file.")
                item.statusLine = "Output file missing"
                HistoryStore.shared.record(item)
                return
            }
            if item.cookiesAutoRetried {
                let site = SupportedSite.match(url: item.ytdlpURL)
                if site != .generic {
                    AppSettings.shared.siteCookies.insert(site)
                }
            }

            if (item.mode == .cut || item.mode == .audio),
               let src = finalPath ?? item.outputFile,
               validCutRange != nil {
                item.statusLine = "Finalizing clip…"
                item.status = .postProcessing
                item.outputFile = Self.renameToNextClip(at: src) ?? src
                item.durationSeconds = (item.cutEnd ?? 0) - (item.cutStart ?? 0)
            }

            let shown = item.outputFile ?? finalPath
            await ensureFallbackThumbnailIfNeeded(for: item,
                                                  outputFile: shown,
                                                  ffmpeg: dep.ffmpegPath)
            guard item.attemptID == attempt, item.isActive else { return }
            item.status = .finished(shown)
            item.progress = 1
            item.statusLine = "Finished"
            if (settings.copyFileAfterDownload || item.copyFileAfterFinish), let f = shown {
                Self.copyFileToPasteboard(f)
                item.statusLine = "Finished · copied"
            }
            HistoryStore.shared.record(item)
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
        } else if shouldRetryWithoutCookies(item: item, usedCookies: usedCookies) {
            // Cookie import itself broke (locked cookie DB, keychain denial).
            // Public media still downloads fine without them — retry once,
            // cookie-free, instead of dying on the import error.
            item.cookieFallbackTried = true
            item.forceCookieSource = .off
            item.status = .queued
            item.progress = 0
            item.statusLine = "Cookies couldn't be read — retrying without them…"
            pendingIDs.append(item.id)
        } else if shouldAutoRetryWithCookies(item: item, originalCookies: cookieSrc) {
            // Auto-fallback: this video likely needs auth (age-gated /
            // members-only / private / region-locked). Requeue once with
            // the browser the user selected globally.
            item.cookiesAutoRetried = true
            item.forceCookieSource = AppSettings.shared.cookieSource
            item.status = .queued
            item.progress = 0
            item.statusLine = "Retrying with \(AppSettings.shared.cookieSource.label) cookies…"
            pendingIDs.append(item.id)
            if settings.showNotifications {
                NotificationHelper.show(title: "Retrying with cookies",
                                        body: item.title)
            }
        } else if shouldAutoRepairDependencies(item: item) {
            let previousLine = item.statusLine
            item.dependencyRepairAttempted = true
            item.status = .postProcessing
            item.progress = 0
            item.statusLine = "Checking yt-dlp and ffmpeg before giving up..."
            let repaired = await DependencyManager.shared.troubleshootForDownloadFailure(message: previousLine)
            guard item.attemptID == attempt, item.isActive else { return }
            if repaired {
                item.status = .queued
                item.statusLine = "Tools refreshed; retrying..."
                pendingIDs.append(item.id)
                if settings.showNotifications {
                    NotificationHelper.show(title: "Retrying after tool repair",
                                            body: item.title)
                }
            } else {
                item.status = .failed(previousLine)
                item.statusLine = "Failed after auto-troubleshoot: " + previousLine
                HistoryStore.shared.record(item)
                if settings.showNotifications {
                    NotificationHelper.show(title: "Download failed", body: item.title)
                }
            }
        } else {
            item.status = .failed(item.statusLine)
            item.statusLine = "Failed: " + item.statusLine
            HistoryStore.shared.record(item)
            if settings.showNotifications {
                NotificationHelper.show(title: "Download failed", body: item.title)
            }
        }
    }

    private func ensureFallbackThumbnailIfNeeded(for item: DownloadItem,
                                                 outputFile: URL?,
                                                 ffmpeg: URL) async {
        guard item.thumbnailURL == nil else { return }
        guard item.mode == .video || item.mode == .cut else { return }
        guard let outputFile,
              FileManager.default.fileExists(atPath: outputFile.path),
              FileManager.default.fileExists(atPath: ffmpeg.path) else { return }

        item.status = .postProcessing
        item.statusLine = "Making thumbnail…"
        if let thumbnail = await Self.generateFallbackThumbnail(for: outputFile,
                                                                itemID: item.id,
                                                                ffmpeg: ffmpeg) {
            item.thumbnailURL = thumbnail
        }
    }

    private static func generateFallbackThumbnail(for file: URL,
                                                  itemID: UUID,
                                                  ffmpeg: URL) async -> URL? {
        guard let dir = thumbnailCacheDirectory() else { return nil }
        let output = dir.appendingPathComponent("\(itemID.uuidString).jpg")

        for timestamp in [1.0, 3.0, 5.0, 0.0] {
            if await extractFrame(from: file, at: timestamp, to: output, ffmpeg: ffmpeg) {
                if imageHasVisibleContent(output) {
                    return output
                }
            }
        }
        return nil
    }

    private static func thumbnailCacheDirectory() -> URL? {
        let dir = DependencyManager.shared.supportDirectory
            .appendingPathComponent("thumbnails", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            return nil
        }
    }

    private static func extractFrame(from file: URL,
                                     at seconds: Double,
                                     to output: URL,
                                     ffmpeg: URL) async -> Bool {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let task = Process()
                task.executableURL = ffmpeg
                task.environment = DependencyManager.enhancedEnvironment
                var args = ["-y", "-hide_banner", "-loglevel", "error"]
                if seconds > 0 {
                    args.append(contentsOf: ["-ss", String(format: "%.2f", seconds)])
                }
                args.append(contentsOf: [
                    "-i", file.path,
                    "-map", "0:v:0",
                    "-frames:v", "1",
                    "-vf", "scale=480:-2",
                    "-q:v", "3",
                    output.path
                ])
                task.arguments = args
                task.standardOutput = Pipe()
                task.standardError = Pipe()
                do {
                    try task.run()
                    task.waitUntilExit()
                    cont.resume(returning: task.terminationStatus == 0)
                } catch {
                    cont.resume(returning: false)
                }
            }
        }
    }

    private static func imageHasVisibleContent(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return false
        }

        let width = 32
        let height = 18
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &pixelData,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return true
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var totalLuminance: Double = 0
        var totalVariance: Double = 0
        let pixelCount = Double(width * height)

        for i in stride(from: 0, to: pixelData.count, by: bytesPerPixel) {
            let r = Double(pixelData[i])
            let g = Double(pixelData[i + 1])
            let b = Double(pixelData[i + 2])
            totalLuminance += (0.299 * r + 0.587 * g + 0.114 * b)
        }

        let mean = totalLuminance / pixelCount
        guard mean > 10, mean < 245 else { return false }

        for i in stride(from: 0, to: pixelData.count, by: bytesPerPixel) {
            let r = Double(pixelData[i])
            let g = Double(pixelData[i + 1])
            let b = Double(pixelData[i + 2])
            let l = 0.299 * r + 0.587 * g + 0.114 * b
            totalVariance += abs(l - mean)
        }

        return (totalVariance / pixelCount) > 8
    }

    private static func copyFileToPasteboard(_ file: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([file as NSURL])
    }

    // Identifies yt-dlp cookie extraction errors (syntax, keychain locked,
    // browser DB locked, missing browser profile). Used to bail out cleanly
    // to a no-cookie retry instead of dying on an unreadable cookie store.
    private static func isCookieLoadFailure(_ msg: String) -> Bool {
        let m = msg.lowercased()
        return (m.contains("cookie") || m.contains("cookies")) &&
            (m.contains("could not find") ||
             m.contains("could not copy") ||
             m.contains("could not read") ||
             m.contains("keychain") ||
             m.contains("database is locked") ||
             m.contains("unable to read") ||
             m.contains("failed to decrypt") ||
             m.contains("could not find") ||
             m.contains("could not decrypt") ||
             m.contains("unable to extract"))
    }

    // One retry without cookies after a broken cookie import. Public videos
    // then succeed; auth-gated ones surface their real (actionable) error.
    private func shouldRetryWithoutCookies(item: DownloadItem, usedCookies: Bool) -> Bool {
        guard usedCookies, !item.cookieFallbackTried else { return false }
        guard let msg = item.lastRawError?.lowercased() else { return false }
        return Self.isCookieLoadFailure(msg)
    }

    // Decide whether to auto-retry a failed download by forcing cookies.
    // Trigger when: the first attempt didn't use cookies, we haven't already
    // auto-retried, and the error looks like an auth/format/bot gate.
    private func shouldAutoRetryWithCookies(item: DownloadItem,
                                            originalCookies: CookieSource) -> Bool {
        guard !item.cookiesAutoRetried else { return false }
        guard !item.cookieFallbackTried else { return false }  // cookies are known-broken
        guard originalCookies == .off else { return false }
        guard AppSettings.shared.cookieSource != .off else { return false }
        if let raw = item.lastRawError?.lowercased(),
           Self.isCookieLoadFailure(raw) {
            return false
        }
        let msg = (item.statusLine + " " + (item.lastRawError ?? "")).lowercased()
        let markers = [
            "no downloadable formats",
            "requested format is not available",
            "human check",
            "not a bot",
            "sign in",
            "confirm you’re not a bot",
            "confirm you're not a bot",
            "age-restricted",
            "confirm your age",
            "supporters-only",
            "private video",
            "private or login-only",
            "this account is private",
            "login required",
            "log in to",
            "login to",
            "members only",
            "members-only",
            "this live event",
            "http error 403",
            "403: forbidden"
        ]
        return markers.contains { msg.contains($0) }
    }

    private func shouldAutoRepairDependencies(item: DownloadItem) -> Bool {
        guard !item.dependencyRepairAttempted else { return false }
        let dep = DependencyManager.shared
        if !FileManager.default.fileExists(atPath: dep.ytDlpPath.path) { return true }
        if !FileManager.default.fileExists(atPath: dep.ffmpegPath.path) { return true }
        let msg = item.statusLine.lowercased()
        let markers = [
            "requested format is not available",
            "unable to extract",
            "signature extraction failed",
            "nsig",
            "unsupported url",
            "http error 403",
            "http error 429",
            "fragment",
            "ffmpeg",
            "ffprobe",
            "postprocess",
            "merger",
            "convert",
            "thumbnail",
            "encoder",              // "Error opening output files: Encoder not found"
            "error opening output", // broken/partial ffmpeg binary
            "bad cpu type",         // wrong-arch binary (e.g. Intel ffmpeg, no Rosetta)
            "exec format error",
            "no downloadable formats",
            "this video is unavailable"
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
        guard let item, item.isActive else { return }
        for rawLine in chunk.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(rawLine)
            if line.hasPrefix("CATAPULT_META "), let data = line.dropFirst(14).data(using: .utf8),
               let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                item.title = info["title"] as? String ?? item.title
                item.uploader = info["uploader"] as? String ?? item.uploader
                item.durationSeconds = (info["duration"] as? NSNumber)?.doubleValue ?? item.durationSeconds
                item.thumbnailURL = (info["thumbnail"] as? String).flatMap(URL.init(string:)) ?? item.thumbnailURL
                item.transfer.prepare(info["requested_formats"] as? [[String: Any]] ?? [info])
            } else if line.hasPrefix("CATAPULT_FILE "), let data = line.dropFirst(14).data(using: .utf8),
                      let path = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String {
                item.outputFile = URL(fileURLWithPath: path)
            } else if line.hasPrefix("CATAPULT_THUMB "), let data = line.dropFirst(15).data(using: .utf8),
                      let thumbnails = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                item.outputFile = thumbnails.compactMap { $0["filepath"] as? String }.map { URL(fileURLWithPath: $0) }
                    .last { FileManager.default.fileExists(atPath: $0.path) }
            } else if line.hasPrefix("CATAPULT_PROGRESS ") {
                let body = String(line.dropFirst(18))
                guard let separator = body.range(of: " {") else { continue }
                let idData = String(body[..<separator.lowerBound]).data(using: .utf8)!
                let payload = String(body[body.index(after: separator.lowerBound)...]).data(using: .utf8)!
                guard let id = try? JSONSerialization.jsonObject(with: idData, options: .fragmentsAllowed) as? String,
                      let progress = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { continue }
                if let path = progress["filename"] as? String { item.intermediateFiles.insert(URL(fileURLWithPath: path)) }
                item.transfer.update(id: id, progress: progress)
                item.status = .downloading
                item.hasMeasuredProgress = item.transfer.fraction != nil
                item.progress = item.transfer.fraction ?? 0
                item.progressEstimated = item.transfer.isEstimated
                if let speed = (progress["speed"] as? NSNumber)?.doubleValue, speed > 0 {
                    item.speed = ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .binary) + "/s"
                } else { item.speed = "" }
                if let eta = (progress["eta"] as? NSNumber)?.doubleValue, eta.isFinite && eta >= 0 {
                    item.eta = "\(Int(eta))s"
                } else { item.eta = "" }
                let stream = id.lowercased().contains("audio") ? "Downloading audio" : "Downloading media"
                item.statusLine = stream + (item.speed.isEmpty ? "" : " · \(item.speed)") + (item.eta.isEmpty ? "" : " · ETA \(item.eta)")
            } else if line.hasPrefix("CATAPULT_POST ") || line.hasPrefix("[Merger]") ||
                      line.hasPrefix("[ExtractAudio]") || line.hasPrefix("[VideoConvertor]") ||
                      line.hasPrefix("[EmbedThumbnail]") || line.hasPrefix("[Metadata]") || line.hasPrefix("[Fixup") {
                item.status = .postProcessing
                item.speed = ""; item.eta = ""
                item.statusLine = line.hasPrefix("[Merger]") ? "Merging…" : line.hasPrefix("[VideoConvertor]") ? "Converting…" : "Finalizing…"
            } else if line.hasPrefix("ERROR:") {
                let message = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                item.lastRawError = message
                item.statusLine = Self.friendlyError(for: message)
            } else if item.mode == .thumbnailOnly,
                      let destination = Self.extract(regex: #"Writing video thumbnail.*? to: (.+)"#, from: line) {
                item.outputFile = URL(fileURLWithPath: destination)
            }
        }
    }

    /// Humanizes the yt-dlp error lines people actually hit. Order matters:
    /// "Sign in to confirm your age" contains both the age and bot phrases,
    /// so age gates are matched first. Matching is phrase-precise — a bare
    /// substring like "age" used to swallow "usage"/"message"/"package".
    static func friendlyError(for msg: String) -> String {
        let m = msg.lowercased()
        let cookieSource = AppSettings.shared.cookieSource
        let authTip: String
        if cookieSource == .off {
            authTip = "select your browser in Settings › Network (Cookies) to sign in"
        } else {
            authTip = "ensure you are signed in to this site in \(cookieSource.label)"
        }

        if m.contains("confirm your age") || m.contains("age-restricted") ||
            m.contains("inappropriate for some users") {
            return "Age-restricted — \(authTip)."
        }
        if m.contains("not a bot") || m.contains("sign in to confirm") || (m.contains("bot") && m.contains("sign in")) {
            return "YouTube bot check — \(authTip)."
        }
        if m.contains("requested format is not available") {
            return "No downloadable formats — try enabling cookies, or update yt-dlp in the Dependencies tab."
        }
        if isCookieLoadFailure(msg) {
            return "Cookie import failed — check \(cookieSource == .off ? "your browser" : cookieSource.label) is installed & signed in, then retry."
        }
        if m.contains("members") && (m.contains("only") || m.contains("level")) {
            return "Members-only video — \(authTip)."
        }
        if m.contains("this video is available for") {
            return "Supporters-only or time-gated video — \(authTip)."
        }
        if m.contains("private video") || m.contains("this account is private") ||
            m.contains("login required") || m.contains("log in to") || m.contains("login to") {
            return "Private or login-only video — \(authTip)."
        }
        if m.contains("not available in your country") || m.contains("geo-restricted") {
            return "Region-locked — this video isn't available from your network."
        }
        if m.contains("video unavailable") || m.contains("has been removed") ||
            m.contains("no longer available") || m.contains("this video is unavailable") {
            return "Video unavailable — it may be deleted, private, or region-locked."
        }
        if m.contains("http error 429") || m.contains("too many requests") {
            return "Rate-limited by the site — wait a few minutes, or import cookies in Settings › Network."
        }
        return msg
    }

    private static func extract(regex pattern: String, from s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 2 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    /// Slots a device preset's recode recipe (or the default compat remux)
    /// into the args list. When a retro preset is active, its `--recode-video`
    /// + `--postprocessor-args` replace the normal `--remux-video mp4` step.
    private func applyPresetPostprocess(preset: DevicePreset?,
                                        container: VideoContainer,
                                        preferCompat: Bool,
                                        normalizeAudio: Bool,
                                        audioBitrateKbps: Int,
                                        into args: inout [String]) {
        if let preset, preset.needsRecode {
            args.append(contentsOf: ["--recode-video", preset.container.rawValue])
            let recode = Self.addLoudnessNormalization(to: preset.recodeArgs,
                                                       enabled: normalizeAudio)
            if !recode.isEmpty {
                args.append(contentsOf: [
                    "--postprocessor-args",
                    "VideoConvertor:\(recode)"
                ])
            }
            return
        }
        if normalizeAudio, preset != .plex {
            args.append(contentsOf: ["--recode-video", container.rawValue])
            args.append(contentsOf: [
                "--postprocessor-args",
                "VideoConvertor:\(Self.audioNormalizeRecodeArgs(container: container, bitrateKbps: audioBitrateKbps))"
            ])
            return
        }
        if container == .mp4 {
            // Ensure audio is AAC when container is MP4 so it is playable on Apple devices.
            args.append(contentsOf: ["--recode-video", "mp4"])
            args.append(contentsOf: [
                "--postprocessor-args",
                "VideoConvertor:-c:v copy -c:a aac -b:a \(audioBitrateKbps)k"
            ])
        }
    }

    private static let loudnessNormalizeFilter = "loudnorm=I=-14:TP=-1.5:LRA=11,aresample=48000"

    private static func addLoudnessNormalization(to ffmpegArgs: String, enabled: Bool) -> String {
        guard enabled, !ffmpegArgs.isEmpty else { return ffmpegArgs }
        return "\(ffmpegArgs) -af \(loudnessNormalizeFilter)"
    }

    private static func audioNormalizeRecodeArgs(container: VideoContainer, bitrateKbps: Int) -> String {
        let audioCodec = container == .webm ? "libopus" : "aac"
        let bitrate = max(96, min(320, bitrateKbps))
        return "-c:v copy -c:a \(audioCodec) -b:a \(bitrate)k -af \(loudnessNormalizeFilter)"
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
        let re = try? NSRegularExpression(pattern: #" \(clip(?:_[A-Za-z0-9-]+|\d*)\)$"#)
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

extension DownloadManager {
    @MainActor
    private func runLocalClip(_ item: DownloadItem, file: URL, attempt: UUID) async {
        let settings = AppSettings.shared
        guard let start = item.cutStart, let end = item.cutEnd,
              start.isFinite, end.isFinite, start >= 0, end > start,
              FileManager.default.fileExists(atPath: file.path) else {
            item.status = .failed("Choose an available file and a valid trim range.")
            item.statusLine = "Invalid clip source"
            HistoryStore.shared.record(item)
            return
        }
        let folder = settings.downloadFolderURL
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch {
            item.status = .failed(error.localizedDescription)
            HistoryStore.shared.record(item)
            return
        }
        let ext = item.mode == .audio ? (item.overrides.audioFormat ?? settings.audioFormat).rawValue : (item.overrides.videoContainer ?? settings.videoContainer).rawValue
        let temporary = folder.appendingPathComponent(".catapult-\(item.id.uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let quality = item.overrides.videoQuality ?? settings.videoQuality
        let process = Process()
        process.executableURL = DependencyManager.shared.ffmpegPath
        process.environment = DependencyManager.enhancedEnvironment
        process.arguments = ClipRecipe.arguments(input: file, output: temporary, start: start, end: end,
                                                  audioOnly: item.mode == .audio, accuracy: item.clipAccuracy,
                                                  bitrate: settings.audioQualityKbps, height: Int(quality.rawValue),
                                                  normalize: settings.normalizeAudio && item.clipAccuracy == .accurate)
        item.title = file.deletingPathExtension().lastPathComponent
        item.status = .postProcessing
        item.statusLine = item.clipAccuracy == .accurate ? "Exporting accurate clip…" : "Copying clip…"
        item.process = process
        let result = await MediaProcess.run(process) { line in
            guard item.attemptID == attempt, item.isActive else { return }
            if line.hasPrefix("out_time_us="), let micros = Double(line.dropFirst(12)) {
                item.statusLine = "Exporting · \(MediaTime.format(min(end - start, micros / 1_000_000))) / \(MediaTime.format(end - start))"
            }
        }
        guard item.attemptID == attempt, item.isActive else { return }
        item.process = nil
        guard result.code == 0, FileManager.default.fileExists(atPath: temporary.path) else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            item.status = .failed(message.isEmpty ? "Clip export failed." : message)
            item.statusLine = "Export failed"
            HistoryStore.shared.record(item)
            return
        }
        var index = 1
        var target = folder.appendingPathComponent("\(item.title) (clip).\(ext)")
        while FileManager.default.fileExists(atPath: target.path) {
            index += 1
            target = folder.appendingPathComponent("\(item.title) (clip\(index)).\(ext)")
        }
        do { try FileManager.default.moveItem(at: temporary, to: target) }
        catch {
            item.status = .failed(error.localizedDescription)
            HistoryStore.shared.record(item)
            return
        }
        item.outputFile = target
        item.durationSeconds = end - start
        await ensureFallbackThumbnailIfNeeded(for: item, outputFile: target, ffmpeg: DependencyManager.shared.ffmpegPath)
        guard item.attemptID == attempt, item.isActive else { return }
        item.progress = 1
        item.status = .finished(target)
        item.statusLine = "Saved"
        HistoryStore.shared.record(item)
        if settings.copyFileAfterDownload { Self.copyFileToPasteboard(target) }
        if settings.openFolderOnFinish { NSWorkspace.shared.activateFileViewerSelecting([target]) }
        if settings.showNotifications { NotificationHelper.show(title: "Clip saved", body: item.title) }
    }
}
