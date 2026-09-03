import Foundation
import Observation
import AppKit
import UserNotifications

@Observable
final class ClipboardMonitor {
    static let shared = ClipboardMonitor()

    /// Most recently detected URL from the pasteboard.
    var detectedURL: String? = nil
    /// Time the URL was detected (for fade-out UI).
    var detectedAt: Date? = nil
    /// History of recently seen URLs (most recent first, de-duplicated).
    var history: [String] = []

    private var changeCount: Int = NSPasteboard.general.changeCount
    private var timer: Timer?
    private var seenURLs: Set<String> = []
    private var seenURLOrder: [String] = []

    private var lastPasteboardActivityAt = Date.distantPast

    private let fastPollInterval: TimeInterval = 0.6
    private let idlePollInterval: TimeInterval = 3.0
    private let idleAfter: TimeInterval = 60
    private let maxSeenURLs = 40

    /// Broad URL extractor for the manual "download any URL" flow and
    /// supported-site clipboard detection.
    static let anyURLRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"https?://[^\s<>"']+"#, options: [])
    }()

    private init() {}

    func start() {
        stop()
        guard AppSettings.shared.clipboardMonitoring else { return }
        changeCount = NSPasteboard.general.changeCount
        lastPasteboardActivityAt = Date()
        scheduleNextTick()
    }

    private func scheduleNextTick() {
        guard timer == nil, AppSettings.shared.clipboardMonitoring else { return }
        let interval = currentPollInterval
        let t = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            self?.timer = nil
            self?.tick()
        }
        t.tolerance = min(interval * 0.3, 1.0)
        // .common keeps detection alive while menus/the popover are tracking —
        // with .default the timer stalls exactly when the user opens a menu.
        RunLoop.main.add(t, forMode: .common)
        self.timer = t
    }

    private var currentPollInterval: TimeInterval {
        Date().timeIntervalSince(lastPasteboardActivityAt) < idleAfter
            ? fastPollInterval
            : idlePollInterval
    }

    func stop() {
        timer?.invalidate(); timer = nil
    }

    func setEnabled(_ enabled: Bool) {
        enabled ? start() : stop()
    }

    func clearDetected() {
        detectedURL = nil
        detectedAt = nil
    }

    /// Immediate one-shot check, called when the popover opens so a link the
    /// user copied a split-second ago is already there — no poll-interval lag.
    func checkNow() {
        guard AppSettings.shared.clipboardMonitoring else { return }
        autoreleasepool { _ = readPasteboard() }
    }

    private func tick() {
        guard AppSettings.shared.clipboardMonitoring else {
            stop()
            return
        }
        autoreleasepool {
            if readPasteboard() {
                lastPasteboardActivityAt = Date()
            }
        }
        scheduleNextTick()
    }

    @discardableResult
    private func readPasteboard() -> Bool {
        let pb = NSPasteboard.general
        guard pb.changeCount != changeCount else { return false }
        changeCount = pb.changeCount
        guard let s = pb.string(forType: .string) else { return true }
        guard let found = Self.firstDownloadURL(in: s) else { return true }
        if seenURLs.contains(found) { return true }
        seenURLs.insert(found)
        seenURLOrder.append(found)
        if seenURLOrder.count > maxSeenURLs {
            let evicted = seenURLOrder.removeFirst()
            seenURLs.remove(evicted)
        }
        detectedURL = found
        detectedAt = Date()
        if !history.contains(found) {
            history.insert(found, at: 0)
            if history.count > 10 { history.removeLast() }
        }
        if AppSettings.shared.autoStartDownload {
            Task { @MainActor in
                DownloadManager.shared.enqueue(url: found, mode: .video)
            }
        } else if AppSettings.shared.showNotifications {
            let site = SupportedSite.match(url: found)
            NotificationHelper.showClipboardLink(url: found, site: site)
        }
        return true
    }

    static func firstURL(in s: String) -> String? {
        urlCandidates(in: s).first
    }

    /// Prefer a known media/social host, then fall back to any URL so
    /// yt-dlp's long tail still works.
    static func firstDownloadURL(in s: String) -> String? {
        let candidates = urlCandidates(in: s)
        return candidates.first { SupportedSite.match(url: $0) != .generic }
            ?? candidates.first
    }

    private static func urlCandidates(in s: String) -> [String] {
        let ns = s as NSString
        let matches = anyURLRegex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        return matches.compactMap { match in
            cleanURLCandidate(ns.substring(with: match.range))
        }
    }

    private static func cleanURLCandidate(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: #".,;:!?)]}>"'”’»"#))
        guard let comps = URLComponents(string: cleaned),
              let scheme = comps.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              comps.host != nil
        else { return nil }
        return cleaned
    }
}

enum NotificationHelper {
    static let clipboardLinkCategory = "h3nry.catapult.notification.clipboardLink"
    private static let actionDownload = "h3nry.catapult.action.download"
    private static let actionDownloadCopy = "h3nry.catapult.action.downloadCopy"
    private static let actionUnderLimitCopy = "h3nry.catapult.action.underLimitCopy"

    private static var authorized = false
    private static var requested = false
    private static var configured = false

    static func configure(delegate: UNUserNotificationCenterDelegate) {
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        registerCategories()
    }

    static func requestAuthorization() {
        guard !requested else { return }
        requested = true
        registerCategories()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
            authorized = ok
        }
    }

    static func show(title: String, body: String) {
        requestAuthorization()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if AppSettings.shared.notificationSound {
            content.sound = .default
        }
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    static func showClipboardLink(url: String, site: SupportedSite) {
        requestAuthorization()
        let content = UNMutableNotificationContent()
        content.title = site.copiedNotificationTitle
        content.body = "Download it, copy the finished file, or make a small copy."
        content.categoryIdentifier = clipboardLinkCategory
        content.userInfo = [
            "url": url,
            "site": site.rawValue
        ]
        if AppSettings.shared.notificationSound {
            content.sound = .default
        }
        let req = UNNotificationRequest(identifier: "clipboard-link-\(UUID().uuidString)",
                                        content: content,
                                        trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    @MainActor
    static func handleNotificationAction(actionIdentifier: String,
                                         categoryIdentifier: String,
                                         url: String?) {
        guard categoryIdentifier == clipboardLinkCategory,
              let url,
              let cleaned = ClipboardMonitor.firstDownloadURL(in: url) else {
            return
        }

        switch actionIdentifier {
        case actionDownload:
            DownloadManager.shared.enqueue(url: cleaned, mode: .video)
        case actionDownloadCopy:
            DownloadManager.shared.enqueue(url: cleaned,
                                           mode: .video,
                                           copyFileAfterFinish: true)
        case actionUnderLimitCopy:
            DownloadManager.shared.enqueue(
                url: cleaned,
                mode: .video,
                overrides: DownloadOverrides(maxFilesizeMB: AppSettings.shared.quickSizeLimitMB),
                copyFileAfterFinish: true
            )
        default:
            return
        }
        ClipboardMonitor.shared.clearDetected()
    }

    private static func registerCategories() {
        guard !configured else { return }
        configured = true

        let download = UNNotificationAction(identifier: actionDownload,
                                            title: "Download",
                                            options: [])
        let downloadCopy = UNNotificationAction(identifier: actionDownloadCopy,
                                                title: "Download + Copy",
                                                options: [])
        let underLimitCopy = UNNotificationAction(identifier: actionUnderLimitCopy,
                                                  title: "Under 10 MB + Copy",
                                                  options: [])
        let clipboardLink = UNNotificationCategory(identifier: clipboardLinkCategory,
                                                  actions: [download, downloadCopy, underLimitCopy],
                                                  intentIdentifiers: [],
                                                  options: [])
        UNUserNotificationCenter.current().setNotificationCategories([clipboardLink])
    }
}
