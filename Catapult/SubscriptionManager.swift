import Foundation
import Observation
import AppKit

// MARK: - Channel subscriptions
//
// "Watch this channel" for YouTube — stores a channel ID + the last video
// we've seen, then polls YouTube's public RSS feed at
// https://www.youtube.com/feeds/videos.xml?channel_id=…
// on a timer. New uploads are auto-enqueued as regular downloads.
//
// RSS is deliberate: no API key, no quota, no cookies, tiny payload (~8KB
// per channel). YouTube has published this endpoint forever and it's the
// same feed readers like NewPipe and FreshRSS rely on.
//
// Check cadence is conservative (default 1h). YouTube caches the feed for
// minutes anyway, so hitting it more often is pointless.

struct ChannelSubscription: Codable, Identifiable, Hashable {
    var id: String { channelID }
    let channelID: String
    var channelTitle: String
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
         lastSeenVideoID: String? = nil,
         addedAt: Date = Date(),
         downloadMode: DownloadMode = .video,
         devicePreset: DevicePreset = .none,
         videoQuality: VideoQuality = .best) {
        self.channelID = channelID
        self.channelTitle = channelTitle
        self.lastSeenVideoID = lastSeenVideoID
        self.addedAt = addedAt
        self.downloadMode = downloadMode
        self.devicePreset = devicePreset
        self.videoQuality = videoQuality
    }

    // Custom decode to keep older persisted subscriptions (without the
    // `videoQuality` field) loading cleanly — they default to `.best`.
    enum CodingKeys: String, CodingKey {
        case channelID, channelTitle, lastSeenVideoID, addedAt
        case downloadMode, devicePreset, videoQuality
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.channelID = try c.decode(String.self, forKey: .channelID)
        self.channelTitle = try c.decode(String.self, forKey: .channelTitle)
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
        guard enabled else { return }
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
        // Tick every minute; `checkNow(force: false)` decides whether enough
        // time has passed. Cheaper than one long Timer that gets out of sync
        // after a sleep/wake cycle.
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkNow(force: false) }
        }
        RunLoop.main.add(t, forMode: .common)
        self.timer = t
    }

    // MARK: - Add / remove

    @discardableResult
    func add(channelID: String, title: String,
             downloadMode: DownloadMode = .video,
             devicePreset: DevicePreset = .none,
             videoQuality: VideoQuality = .best) -> ChannelSubscription {
        if let existing = subscriptions.first(where: { $0.channelID == channelID }) {
            return existing
        }
        let sub = ChannelSubscription(channelID: channelID,
                                      channelTitle: title,
                                      downloadMode: downloadMode,
                                      devicePreset: devicePreset,
                                      videoQuality: videoQuality)
        subscriptions.append(sub)
        // On first subscribe, enqueue every video in the RSS feed (~15
        // most recent uploads). Subsequent polls only enqueue genuinely new
        // uploads relative to the cursor we set at the end of the backfill.
        Task { await backfill(for: channelID) }
        return sub
    }

    func remove(id: String) {
        subscriptions.removeAll { $0.channelID == id }
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

    static func resolveChannel(from input: String) async -> (id: String, title: String)? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("UC"), trimmed.count >= 20, !trimmed.contains("/") {
            // Looks like a raw channel ID. Fetch its feed to grab the title.
            if let title = await fetchChannelTitle(channelID: trimmed) {
                return (trimmed, title)
            }
            return (trimmed, trimmed)
        }
        guard let url = URL(string: trimmed) else { return nil }
        // Direct /channel/UC… URLs: grab the ID, fetch feed for the title.
        if let id = extractChannelID(fromDirect: url) {
            let title = (await fetchChannelTitle(channelID: id)) ?? id
            return (id, title)
        }
        // Handle / custom / user URLs: scrape the channel page for the
        // canonical externalId metadata. YouTube still embeds it on every
        // channel HTML page.
        return await scrapeChannel(url: url)
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

    private static func scrapeChannel(url: URL) async -> (id: String, title: String)? {
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
            return (id, title)
        } catch {
            return nil
        }
    }

    /// Initial-subscribe backfill: enqueues every entry in the feed (oldest
    /// first, so the queue order matches upload order), then advances the
    /// cursor to the newest video. The RSS feed only exposes ~15 entries —
    /// this is "everything reasonably recent", not the full channel history.
    private func backfill(for channelID: String) async {
        guard let feedURL = feedURL(for: channelID) else { return }
        let entries = await fetchEntries(feedURL: feedURL)
        guard !entries.isEmpty else { return }
        guard let idx = subscriptions.firstIndex(where: { $0.channelID == channelID }) else { return }
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
        guard let idx = subscriptions.firstIndex(where: { $0.channelID == subscriptionID }),
              let feedURL = feedURL(for: subscriptionID)
        else { return 0 }
        let sub = subscriptions[idx]
        let entries = await fetchEntries(feedURL: feedURL)
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
        var watchURL: String { "https://www.youtube.com/watch?v=\(videoID)" }
    }

    private func fetchEntries(feedURL: URL) async -> [RSSEntry] {
        do {
            let (data, _) = try await URLSession.shared.data(from: feedURL)
            guard let s = String(data: data, encoding: .utf8) else { return [] }
            return Self.parseEntries(xml: s)
        } catch {
            self.lastError = error.localizedDescription
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
                                    title: decodeXMLEntities(title)))
        }
        return entries
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
