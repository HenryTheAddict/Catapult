import Foundation
import Observation
import AppKit

// MARK: - Channel subscriptions
//
// "Watch this channel/profile" subscriptions. YouTube uses its public RSS
// endpoint. TikTok, Instagram, X/Twitter, SoundCloud, Vimeo, and other
// yt-dlp-supported collection/profile URLs use yt-dlp's flat playlist mode
// to poll recent items without downloading media.
//
// RSS is deliberate: no API key, no quota, no cookies, tiny payload (~8KB
// per channel). YouTube has published this endpoint forever and it's the
// same feed readers like NewPipe and FreshRSS rely on.
//
// Check cadence is conservative (default 1h). YouTube caches the feed for
// minutes anyway, so hitting it more often is pointless.

enum SubscriptionSource: String, Codable, Hashable {
    case youtubeRSS
    case ytdlpFlat

    var label: String {
        switch self {
        case .youtubeRSS: return "youtube rss"
        case .ytdlpFlat:  return "yt-dlp feed"
        }
    }

    var glyph: String {
        switch self {
        case .youtubeRSS: return "play.rectangle.fill"
        case .ytdlpFlat:  return "sparkles.tv"
        }
    }
}

struct ChannelSubscription: Codable, Identifiable, Hashable {
    var id: String { channelID }
    let channelID: String
    var channelTitle: String
    var source: SubscriptionSource
    var sourceURL: String?
    /// Video ID of the most recent upload we've already ingested. New videos
    /// are everything listed above this one in the feed.
    var lastSeenVideoID: String?
    var addedAt: Date
    /// Per-subscription download mode — most people want video, but some
    /// channels are music and the user prefers audio extraction.
    var downloadMode: DownloadMode
    /// Optional per-sub device preset override. `.none` means use global
    /// quality.
    var devicePreset: DevicePreset
    /// Per-channel max quality. `.best` means defer to the global setting.
    var videoQuality: VideoQuality

    init(channelID: String,
         channelTitle: String,
         source: SubscriptionSource = .youtubeRSS,
         sourceURL: String? = nil,
         lastSeenVideoID: String? = nil,
         addedAt: Date = Date(),
         downloadMode: DownloadMode = .video,
         devicePreset: DevicePreset = .none,
         videoQuality: VideoQuality = .best) {
        self.channelID = channelID
        self.channelTitle = channelTitle
        self.source = source
        self.sourceURL = sourceURL
        self.lastSeenVideoID = lastSeenVideoID
        self.addedAt = addedAt
        self.downloadMode = downloadMode
        self.devicePreset = devicePreset
        self.videoQuality = videoQuality
    }

    // Custom decode to keep older persisted subscriptions (without the
    // `videoQuality` field) loading cleanly — they default to `.best`.
    enum CodingKeys: String, CodingKey {
        case channelID, channelTitle, source, sourceURL, lastSeenVideoID, addedAt
        case downloadMode, devicePreset, videoQuality
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.channelID = try c.decode(String.self, forKey: .channelID)
        self.channelTitle = try c.decode(String.self, forKey: .channelTitle)
        self.source = try c.decodeIfPresent(SubscriptionSource.self, forKey: .source) ?? .youtubeRSS
        self.sourceURL = try c.decodeIfPresent(String.self, forKey: .sourceURL)
        self.lastSeenVideoID = try c.decodeIfPresent(String.self, forKey: .lastSeenVideoID)
        self.addedAt = try c.decode(Date.self, forKey: .addedAt)
        self.downloadMode = try c.decode(DownloadMode.self, forKey: .downloadMode)
        self.devicePreset = try c.decodeIfPresent(DevicePreset.self, forKey: .devicePreset) ?? .none
        self.videoQuality = try c.decodeIfPresent(VideoQuality.self, forKey: .videoQuality) ?? .best
    }
}

@Observable
@MainActor
final class SubscriptionManager {
    static let shared = SubscriptionManager()

    /// Hard cap on how many new videos we'll auto-enqueue per channel per
    /// check. Prevents a first-ever sync from ripping an entire back-catalog.
    static let perChannelBurstLimit = 3
    private static let persistKey = "channelSubscriptions.v1"
    private static let lastCheckKey = "channelSubscriptions.lastCheckAt"

    var subscriptions: [ChannelSubscription] = [] {
        didSet { persist() }
    }
    /// Minutes between RSS polls. Kept >= 15 because YouTube's feed cache
    /// makes faster polling a waste of packets.
    var pollMinutes: Int {
        didSet {
            UserDefaults.standard.set(pollMinutes, forKey: "subscriptionPollMinutes")
            restartTimer()
        }
    }
    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "subscriptionsEnabled")
            if enabled { start() } else { stop() }
        }
    }
    var lastCheckAt: Date?
    var lastError: String?

    private var timer: Timer?
    private var shouldRun: Bool { enabled && !subscriptions.isEmpty }

    private init() {
        let d = UserDefaults.standard
        self.pollMinutes = (d.object(forKey: "subscriptionPollMinutes") as? Int) ?? 60
        self.enabled = (d.object(forKey: "subscriptionsEnabled") as? Bool) ?? true
        if let data = d.data(forKey: Self.persistKey),
           let decoded = try? JSONDecoder().decode([ChannelSubscription].self, from: data) {
            self.subscriptions = decoded
        }
        if let t = d.object(forKey: Self.lastCheckKey) as? Date {
            self.lastCheckAt = t
        }
    }

    func start() {
        guard shouldRun else {
            stop()
            return
        }
        restartTimer()
        // Fire one check shortly after launch so the user sees the list
        // refresh without waiting an hour.
        Task { await checkNow(force: false) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func restartTimer() {
        stop()
        guard shouldRun else { return }
        let interval = TimeInterval(max(15, pollMinutes) * 60)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkNow(force: false) }
        }
        t.tolerance = min(interval * 0.15, 90)
        RunLoop.main.add(t, forMode: .common)
        self.timer = t
    }

    // MARK: - Add / remove

    @discardableResult
    func add(channelID: String,
             title: String,
             source: SubscriptionSource = .youtubeRSS,
             sourceURL: String? = nil,
             downloadMode: DownloadMode = .video,
             devicePreset: DevicePreset = .none,
             videoQuality: VideoQuality = .best) -> ChannelSubscription {
        if let existing = subscriptions.first(where: { $0.channelID == channelID }) {
            return existing
        }
        let sub = ChannelSubscription(channelID: channelID,
                                      channelTitle: title,
                                      source: source,
                                      sourceURL: sourceURL,
                                      downloadMode: downloadMode,
                                      devicePreset: devicePreset,
                                      videoQuality: videoQuality)
        subscriptions.append(sub)
        if enabled { restartTimer() }
        // On first subscribe, enqueue every video in the RSS feed (~15
        // most recent uploads). Subsequent polls only enqueue genuinely new
        // uploads relative to the cursor we set at the end of the backfill.
        Task { await backfill(for: channelID) }
        return sub
    }

    func remove(id: String) {
        subscriptions.removeAll { $0.channelID == id }
        if subscriptions.isEmpty { stop() }
    }

    func update(_ sub: ChannelSubscription) {
        if let idx = subscriptions.firstIndex(where: { $0.channelID == sub.channelID }) {
            subscriptions[idx] = sub
        }
    }

    // MARK: - Resolve a user input into a channel ID
    //
    // Accepts:
    //   https://www.youtube.com/channel/UCxxx…     (direct)
    //   https://www.youtube.com/@handle            (scraped)
    //   https://www.youtube.com/c/CustomName       (scraped)
    //   a bare channel ID starting with UC         (used as-is)

    struct ResolvedSubscription {
        let id: String
        let title: String
        let source: SubscriptionSource
        let sourceURL: String?
    }

    static func resolveChannel(from input: String) async -> ResolvedSubscription? {
        var trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("@") {
            trimmed = "https://www.tiktok.com/\(trimmed)"
        } else if !trimmed.contains("://"),
                  trimmed.contains(".") || trimmed.hasPrefix("www.") {
            trimmed = "https://\(trimmed)"
        }
        if trimmed.hasPrefix("UC"), trimmed.count >= 20, !trimmed.contains("/") {
            // Looks like a raw channel ID. Fetch its feed to grab the title.
            if let title = await fetchChannelTitle(channelID: trimmed) {
                return ResolvedSubscription(id: trimmed, title: title, source: .youtubeRSS, sourceURL: nil)
            }
            return ResolvedSubscription(id: trimmed, title: trimmed, source: .youtubeRSS, sourceURL: nil)
        }
        guard let url = URL(string: trimmed) else { return nil }
        // Direct /channel/UC… URLs: grab the ID, fetch feed for the title.
        if let id = extractChannelID(fromDirect: url) {
            let title = (await fetchChannelTitle(channelID: id)) ?? id
            return ResolvedSubscription(id: id, title: title, source: .youtubeRSS, sourceURL: nil)
        }
        if !isYouTubeURL(url) {
            let normalized = normalizedCollectionURL(url)
            let site = SupportedSite.match(url: normalized)
            return ResolvedSubscription(
                id: "\(site.rawValue):\(normalized)",
                title: titleForCollection(url: url, site: site),
                source: .ytdlpFlat,
                sourceURL: normalized
            )
        }
        // Handle / custom / user URLs: scrape the channel page for the
        // canonical externalId metadata. YouTube still embeds it on every
        // channel HTML page.
        return await scrapeChannel(url: url)
    }

    private static func isYouTubeURL(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        return host.contains("youtube.com") || host == "youtu.be"
    }

    private static func extractChannelID(fromDirect url: URL) -> String? {
        // /channel/UCabcdefgh
        let comps = url.pathComponents
        guard let idx = comps.firstIndex(of: "channel"), idx + 1 < comps.count else {
            return nil
        }
        let candidate = comps[idx + 1]
        return candidate.hasPrefix("UC") ? candidate : nil
    }

    private static func fetchChannelTitle(channelID: String) async -> String? {
        let urlString = "https://www.youtube.com/feeds/videos.xml?channel_id=\(channelID)"
        guard let url = URL(string: urlString) else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let s = String(data: data, encoding: .utf8) else { return nil }
            // <title>Channel Name</title> appears before the first entry.
            if let range = s.range(of: "<title>"),
               let end = s.range(of: "</title>", range: range.upperBound..<s.endIndex) {
                return String(s[range.upperBound..<end.lowerBound])
            }
        } catch { }
        return nil
    }

    private static func scrapeChannel(url: URL) async -> ResolvedSubscription? {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let html = String(data: data, encoding: .utf8) else { return nil }
            // externalId appears as "externalId":"UC…" somewhere in the
            // embedded ytInitialData JSON. Grab via a conservative regex.
            let re = try NSRegularExpression(pattern: #""externalId":"(UC[A-Za-z0-9_-]+)""#)
            let ns = html as NSString
            guard let m = re.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)),
                  m.numberOfRanges >= 2 else { return nil }
            let id = ns.substring(with: m.range(at: 1))
            // Title via <meta property="og:title" content="…">
            var title = id
            let tre = try NSRegularExpression(pattern: #"<meta property="og:title" content="([^"]+)""#)
            if let tm = tre.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)),
               tm.numberOfRanges >= 2 {
                title = ns.substring(with: tm.range(at: 1))
            }
            return ResolvedSubscription(id: id, title: title, source: .youtubeRSS, sourceURL: nil)
        } catch {
            return nil
        }
    }

    private static func normalizedCollectionURL(_ url: URL) -> String {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        comps?.fragment = nil
        return comps?.url?.absoluteString ?? url.absoluteString
    }

    private static func titleForCollection(url: URL, site: SupportedSite) -> String {
        let path = url.pathComponents
            .filter { $0 != "/" }
            .last?
            .removingPercentEncoding ?? (url.host ?? site.notificationName)
        let cleaned = path.isEmpty ? (url.host ?? site.notificationName) : path
        if cleaned.hasPrefix("@") {
            return "\(site.notificationName) \(cleaned)"
        }
        return "\(site.notificationName) \(cleaned)"
    }

    /// Initial-subscribe backfill: enqueues every entry in the feed (oldest
    /// first, so the queue order matches upload order), then advances the
    /// cursor to the newest video. The RSS feed only exposes ~15 entries —
    /// this is "everything reasonably recent", not the full channel history.
    private func backfill(for channelID: String) async {
        guard let idx = subscriptions.firstIndex(where: { $0.channelID == channelID }) else { return }
        let entries = await fetchEntries(for: subscriptions[idx])
        guard !entries.isEmpty else { return }
        let sub = subscriptions[idx]
        let overrides = buildOverrides(for: sub)
        for e in entries.reversed() {
            DownloadManager.shared.enqueue(url: e.watchURL,
                                           mode: sub.downloadMode,
                                           overrides: overrides)
        }
        subscriptions[idx].lastSeenVideoID = entries.first?.videoID
        if AppSettings.shared.showNotifications {
            NotificationHelper.show(
                title: "Subscribed to \(sub.channelTitle)",
                body: "queued \(entries.count) recent video\(entries.count == 1 ? "" : "s").")
        }
    }

    /// Per-subscription overrides — preset wins over quality (preset already
    /// implies its own height cap), but we set `videoQuality` either way so
    /// quality-only subs still narrow the format selector correctly.
    private func buildOverrides(for sub: ChannelSubscription) -> DownloadOverrides {
        var o = DownloadOverrides()
        if sub.devicePreset != .none {
            o.devicePreset = sub.devicePreset
        }
        if sub.videoQuality != .best {
            o.videoQuality = sub.videoQuality
        }
        return o
    }

    // MARK: - Polling

    @discardableResult
    func checkNow(force: Bool) async -> Int {
        if !force {
            if let last = lastCheckAt {
                let elapsed = Date().timeIntervalSince(last)
                if elapsed < Double(pollMinutes) * 60 { return 0 }
            }
        }
        guard enabled else { return 0 }
        guard !subscriptions.isEmpty else { return 0 }
        var newCount = 0
        for sub in subscriptions {
            newCount += await checkOne(subscriptionID: sub.channelID)
        }
        lastCheckAt = Date()
        UserDefaults.standard.set(lastCheckAt, forKey: Self.lastCheckKey)
        return newCount
    }

    /// Returns how many new videos were enqueued for this subscription.
    private func checkOne(subscriptionID: String) async -> Int {
        guard let idx = subscriptions.firstIndex(where: { $0.channelID == subscriptionID }) else { return 0 }
        let sub = subscriptions[idx]
        let entries = await fetchEntries(for: sub)
        guard !entries.isEmpty else { return 0 }

        // Everything above the last-seen cursor is "new". If there's no
        // cursor yet, treat the newest entry as the cursor and skip — the
        // seed path already set this, but a race-safe fallback here too.
        var newVideos: [RSSEntry] = []
        if let cursor = sub.lastSeenVideoID {
            for e in entries {
                if e.videoID == cursor { break }
                newVideos.append(e)
            }
        } else {
            // No cursor — set it and don't enqueue.
            subscriptions[idx].lastSeenVideoID = entries.first?.videoID
            return 0
        }
        guard !newVideos.isEmpty else { return 0 }
        // Cap burst so a week-long hiatus doesn't flood the queue.
        let picked = Array(newVideos.prefix(Self.perChannelBurstLimit))

        let overrides = buildOverrides(for: sub)
        for e in picked.reversed() { // oldest first, so list order matches upload order
            DownloadManager.shared.enqueue(url: e.watchURL,
                                           mode: sub.downloadMode,
                                           overrides: overrides)
        }
        // Advance cursor to the newest video we saw (not just the newest we
        // enqueued — otherwise a >burst-limit backlog would re-fire next tick).
        subscriptions[idx].lastSeenVideoID = entries.first?.videoID
        if AppSettings.shared.showNotifications {
            let body = picked.count == 1
                ? picked[0].title
                : "\(picked.count) new from \(sub.channelTitle)"
            NotificationHelper.show(title: "New video" + (picked.count == 1 ? "" : "s"),
                                    body: body)
        }
        return picked.count
    }

    private func feedURL(for channelID: String) -> URL? {
        URL(string: "https://www.youtube.com/feeds/videos.xml?channel_id=\(channelID)")
    }

    // MARK: - RSS parsing

    fileprivate struct RSSEntry {
        let videoID: String
        let title: String
        let url: String?
        var watchURL: String { url ?? "https://www.youtube.com/watch?v=\(videoID)" }
    }

    private func fetchEntries(for sub: ChannelSubscription) async -> [RSSEntry] {
        switch sub.source {
        case .youtubeRSS:
            guard let feedURL = feedURL(for: sub.channelID) else { return [] }
            return await fetchRSSEntries(feedURL: feedURL)
        case .ytdlpFlat:
            guard let sourceURL = sub.sourceURL else { return [] }
            return await fetchFlatEntries(sourceURL: sourceURL)
        }
    }

    private func fetchRSSEntries(feedURL: URL) async -> [RSSEntry] {
        do {
            let (data, _) = try await URLSession.shared.data(from: feedURL)
            guard let s = String(data: data, encoding: .utf8) else { return [] }
            return Self.parseEntries(xml: s)
        } catch {
            self.lastError = error.localizedDescription
            return []
        }
    }

    private func fetchFlatEntries(sourceURL: String) async -> [RSSEntry] {
        let ytDlp = DependencyManager.shared.ytDlpPath
        guard FileManager.default.fileExists(atPath: ytDlp.path) else {
            lastError = "yt-dlp is not installed yet"
            return []
        }
        let result = await Task.detached(priority: .utility) { () -> Result<String, Error> in
            let task = Process()
            task.executableURL = ytDlp
            task.arguments = [
                "--flat-playlist",
                "--dump-json",
                "--playlist-end", "15",
                "--no-warnings",
                sourceURL
            ]
            let pipe = Pipe()
            let err = Pipe()
            task.standardOutput = pipe
            task.standardError = err
            do {
                try task.run()
            } catch {
                return .failure(error)
            }
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if task.terminationStatus != 0 {
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: errData, encoding: .utf8) ?? "yt-dlp feed check failed"
                return .failure(NSError(domain: "Catapult.SubscriptionManager",
                                        code: Int(task.terminationStatus),
                                        userInfo: [NSLocalizedDescriptionKey: message]))
            }
            return .success(String(data: data, encoding: .utf8) ?? "")
        }.value
        switch result {
        case .success(let output):
            return Self.parseFlatEntries(output: output)
        case .failure(let error):
            lastError = error.localizedDescription
            return []
        }
    }

    /// Lightweight XML scrape — regex beats a full XMLParser subclass for
    /// a feed this shape-stable. We need exactly two things per entry:
    /// yt:videoId and title.
    fileprivate static func parseEntries(xml: String) -> [RSSEntry] {
        var entries: [RSSEntry] = []
        // Split on <entry> blocks; the channel-level <title> sits above the
        // first entry boundary so it's correctly ignored.
        let parts = xml.components(separatedBy: "<entry>")
        for part in parts.dropFirst() {
            guard let videoID = extract(regex: #"<yt:videoId>([^<]+)</yt:videoId>"#, in: part) else {
                continue
            }
            let title = extract(regex: #"<title>([^<]+)</title>"#, in: part) ?? videoID
            entries.append(RSSEntry(videoID: videoID,
                                    title: decodeXMLEntities(title),
                                    url: nil))
        }
        return entries
    }

    fileprivate static func parseFlatEntries(output: String) -> [RSSEntry] {
        output.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            let url = object["webpage_url"] as? String
                ?? object["url"] as? String
                ?? object["original_url"] as? String
            let rawID = object["id"] as? String
            let stableID = url ?? rawID
            guard let stableID else { return nil }
            let title = object["title"] as? String ?? stableID
            return RSSEntry(videoID: stableID, title: title, url: url)
        }
    }

    private static func extract(regex: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: regex) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 2 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    private static func decodeXMLEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
         .replacingOccurrences(of: "&quot;", with: "\"")
         .replacingOccurrences(of: "&#39;", with: "'")
         .replacingOccurrences(of: "&lt;", with: "<")
         .replacingOccurrences(of: "&gt;", with: ">")
    }

    // MARK: - Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(subscriptions) else { return }
        UserDefaults.standard.set(data, forKey: Self.persistKey)
    }
}
