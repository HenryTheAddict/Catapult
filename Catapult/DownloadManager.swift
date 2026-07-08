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
    // One-shot copy behavior for notification actions and other quick flows.
    var copyFileAfterFinish: Bool = false

    // A one-shot cookie override for the current attempt. The auto-retry
    // logic populates this with the user's selected browser after a
    // format/auth failure when cookies are enabled for this site but the
    // first attempt didn't include them.
    var forceCookieSource: CookieSource?
    // True once we've already auto-retried with cookies, so we don't loop.
    var cookiesAutoRetried: Bool = false
    // True once we've refreshed yt-dlp/ffmpeg after a failure, so we don't loop.
    var dependencyRepairAttempted: Bool = false

    fileprivate var process: Process?

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
                 copyFileAfterFinish: Bool = false) -> DownloadItem {
        let item = DownloadItem(url: url, mode: mode)
        item.cutStart = cutStart
        item.cutEnd = cutEnd
        item.overrides = overrides
        item.copyFileAfterFinish = copyFileAfterFinish
        items.insert(item, at: 0)
        if SpotifyBridge.canBridge(url) {
            Task { await bridgeSpotify(item) }
        } else {
            pendingIDs.append(item.id)
            Task { await fetchInfo(for: item) }
            drain()
        }
        return item
    }

    @MainActor
    func cancel(_ item: DownloadItem) {
        item.process?.terminate()
        item.status = .cancelled
        item.statusLine = "Cancelled"
        HistoryStore.shared.record(item)
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
            if case .cancelled = item.status { continue }
            activeCount += 1
            Task { await run(item) }
        }
    }

    // MARK: - Spotify → YouTube Music bridge

    @MainActor
    private func bridgeSpotify(_ item: DownloadItem) async {
        guard items.contains(where: { $0.id == item.id }) else { return }
        item.status = .fetchingInfo
        item.statusLine = "Resolving Spotify…"

        let result = await SpotifyBridge.resolve(item.url)
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

    // MARK: - Info (title, thumbnail, duration) via yt-dlp --dump-single-json

    @MainActor
    private func fetchInfo(for item: DownloadItem) async {
        item.status = .fetchingInfo
        item.statusLine = "Fetching info…"
        let dep = DependencyManager.shared
        guard FileManager.default.fileExists(atPath: dep.ytDlpPath.path) else { return }
        let settings = AppSettings.shared
        var args = ["--dump-single-json", "--no-warnings",
                    "--no-playlist", "--skip-download"]
        if let browser = settings.cookieSource(for: item.ytdlpURL).ytdlpName {
            args.append(contentsOf: ["--cookies-from-browser", browser])
        }
        args.append(item.ytdlpURL)

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

        let validCutRange: (start: Double, end: Double)? = {
            guard let s = item.cutStart,
                  let e = item.cutEnd,
                  s.isFinite,
                  e.isFinite,
                  s >= 0,
                  e > s else { return nil }
            return (s, e)
        }()

        // Output template — trimmed media gets a unique " (clip_<stamp>)" suffix that is
        // renamed to " (clip)" / " (clip2)" / ... post-download.
        var outputTemplate = folder
            .appendingPathComponent(settings.filenameTemplate).path
        if item.mode == .cut || validCutRange != nil {
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

        if settings.concurrentFragments > 1 {
            args.append(contentsOf: ["--concurrent-fragments", "\(settings.concurrentFragments)"])
        }

        // Cookies: a one-shot `forceCookieSource` (set by the auto-retry
        // path after an auth failure) takes precedence over the user's
        // normal per-site / global resolution.
        let cookieSrc = item.forceCookieSource ?? settings.cookieSource(for: item.ytdlpURL)
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
            args.append(item.ytdlpURL)
        } else {
            if settings.writeThumbnail { args.append("--write-thumbnail") }
            let canEmbedThumbnail: Bool = {
                switch item.mode {
                case .audio:
                    return audioFmt.supportsEmbeddedThumbnail
                case .video, .cut:
                    return container.supportsEmbeddedThumbnail
                case .thumbnailOnly:
                    return false
                }
            }()
            if settings.embedThumbnail && canEmbedThumbnail {
                args.append("--embed-thumbnail")
                // Normalize WebP thumbnails before handing them to ffmpeg's
                // artwork muxer.
                args.append(contentsOf: ["--convert-thumbnails", "jpg"])
                // Some containers need an explicit pp to tag the embedded image.
                args.append(contentsOf: ["--ppa", "EmbedThumbnail+ffmpeg_o1:-c:v mjpeg"])
                // Keep Shorts / VP9-only sources from ending as WebM when the
                // chosen video container can carry embedded artwork.
                if item.mode == .video || item.mode == .cut {
                    args.append(contentsOf: ["--remux-video", container.rawValue])
                }
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
                                       normalizeAudio: settings.normalizeAudio,
                                       audioBitrateKbps: settings.audioQualityKbps,
                                       into: &args)
            case .audio:
                args.append(contentsOf: [
                    "-f", "bestaudio/best",
                    "-x",
                    "--audio-format", audioFmt.rawValue,
                    "--audio-quality", String(settings.audioQualityKbps) + "K",
                ])
                if settings.normalizeAudio {
                    let codec: String? = {
                        switch audioFmt {
                        case .mp3:  return "libmp3lame"
                        case .m4a:  return "aac"
                        case .opus: return "libopus"
                        case .flac: return "flac"
                        case .wav:  return nil
                        }
                    }()
                    let codecArg = codec != nil ? "-c:a \(codec!) " : ""
                    args.append(contentsOf: [
                        "--ppa",
                        "ExtractAudio+ffmpeg_o1:\(codecArg)-af \(Self.loudnessNormalizeFilter)"
                    ])
                }
                if let rangeValues = validCutRange {
                    let range = "*\(formatSec(rangeValues.start))-\(formatSec(rangeValues.end))"
                    args.append(contentsOf: ["--download-sections", range])
                }
            case .cut:
                args.append(contentsOf: ["-f", videoFormatString(quality: quality,
                                                                 container: container,
                                                                 maxMB: nil,
                                                                 compat: settings.preferCompatibleCodecs)])
                args.append(contentsOf: ["--merge-output-format", container.rawValue])
                applyPresetPostprocess(preset: preset,
                                       container: container,
                                       preferCompat: settings.preferCompatibleCodecs,
                                       normalizeAudio: settings.normalizeAudio,
                                       audioBitrateKbps: settings.audioQualityKbps,
                                       into: &args)
                if let rangeValues = validCutRange {
                    let range = "*\(formatSec(rangeValues.start))-\(formatSec(rangeValues.end))"
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

            args.append(item.ytdlpURL)
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
            if (item.mode == .cut || item.mode == .audio),
               let src = finalPath ?? item.outputFile,
               let rangeValues = validCutRange {
                item.statusLine = "Finalizing clip…"
                item.status = .postProcessing
                let fixed = await fixClipDuration(file: src,
                                                  duration: rangeValues.end - rangeValues.start,
                                                  ffmpeg: dep.ffmpegPath)
                let after = fixed ?? src
                item.outputFile = Self.renameToNextClip(at: after) ?? after
            }

            let shown = item.outputFile ?? finalPath
            await ensureFallbackThumbnailIfNeeded(for: item,
                                                  outputFile: shown,
                                                  ffmpeg: dep.ffmpegPath)
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
        } else if shouldAutoRetryWithCookies(item: item, originalCookies: cookieSrc) {
            // Auto-fallback: this video likely needs auth (age-gated /
            // members-only / private / region-locked). Requeue once with
            // the browser the user selected globally, but only when cookies
            // are enabled for this matched site.
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

    private static func copyFileToPasteboard(_ file: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !pasteboard.writeObjects([file as NSURL]) {
            pasteboard.setString(file.path, forType: .string)
        }
    }

    private static func generateFallbackThumbnail(for file: URL,
                                                  itemID: UUID,
                                                  ffmpeg: URL) async -> URL? {
        guard let dir = fallbackThumbnailDirectory() else { return nil }
        let offsets: [Double] = [0.05, 0.25, 0.75, 1.5, 3.0]

        for (index, seconds) in offsets.enumerated() {
            let candidate = dir.appendingPathComponent("\(itemID.uuidString)-\(index).jpg")
            try? FileManager.default.removeItem(at: candidate)
            guard await extractFrame(from: file,
                                     at: seconds,
                                     to: candidate,
                                     ffmpeg: ffmpeg),
                  FileManager.default.fileExists(atPath: candidate.path) else { continue }

            if imageHasVisibleContent(candidate) {
                return candidate
            }
            try? FileManager.default.removeItem(at: candidate)
        }
        return nil
    }

    private static func fallbackThumbnailDirectory() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                        in: .userDomainMask).first else {
            return nil
        }
        let dir = appSupport
            .appendingPathComponent("Catapult", isDirectory: true)
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
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        let drew = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow,
                                          space: colorSpace,
                                          bitmapInfo: bitmapInfo) else {
                return false
            }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return false }

        var luminanceTotal = 0.0
        var litPixels = 0
        for offset in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            let r = Double(pixels[offset]) / 255.0
            let g = Double(pixels[offset + 1]) / 255.0
            let b = Double(pixels[offset + 2]) / 255.0
            let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
            luminanceTotal += luminance
            if luminance > 0.08 {
                litPixels += 1
            }
        }

        let sampleCount = Double(width * height)
        let average = luminanceTotal / sampleCount
        let litShare = Double(litPixels) / sampleCount
        return average > 0.018 || litShare > 0.004
    }

    // Decide whether to auto-retry a failed download by forcing cookies.
    // Trigger when: the first attempt didn't use cookies, we haven't already
    // auto-retried, and the error looks like an auth/format gate.
    private func shouldAutoRetryWithCookies(item: DownloadItem,
                                            originalCookies: CookieSource) -> Bool {
        guard !item.cookiesAutoRetried else { return false }
        guard originalCookies == .off else { return false }
        guard AppSettings.shared.cookieSource != .off else { return false }
        guard AppSettings.shared.siteCookies.contains(SupportedSite.match(url: item.ytdlpURL)) else { return false }
        let msg = item.statusLine.lowercased()
        let markers = [
            "requested format is not available",
            "sign in to confirm",
            "age",
            "private video",
            "this account is private",
            "login required",
            "log in to",
            "login to",
            "cookies",
            "this video is available for",
            "members only",
            "this live event",
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
                } else if msg.localizedCaseInsensitiveContains("private") ||
                          msg.localizedCaseInsensitiveContains("login") {
                    item.statusLine = "Private or login-only video — enable cookies for this site in Settings › Sites."
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
