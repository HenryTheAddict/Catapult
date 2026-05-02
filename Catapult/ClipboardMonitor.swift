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

    static let youtubeRegex: NSRegularExpression = {
        let pattern = #"https?://(?:www\.|m\.|music\.)?(?:youtube\.com/(?:watch\?[^\s]*v=|shorts/|embed/|live/|playlist\?list=)|youtu\.be/)[A-Za-z0-9_\-]+[^\s]*"#
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    /// Broad URL extractor for the manual "download any URL" flow.
    static let anyURLRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"https?://[^\s]+"#, options: [])
    }()

    private init() {}

    func start() {
        stop()
        let t = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        self.timer = t
    }

    func stop() {
        timer?.invalidate(); timer = nil
    }

    func clearDetected() {
        detectedURL = nil
        detectedAt = nil
    }

    private func tick() {
        guard AppSettings.shared.clipboardMonitoring else { return }
        let pb = NSPasteboard.general
        guard pb.changeCount != changeCount else { return }
        changeCount = pb.changeCount
        guard let s = pb.string(forType: .string) else { return }
        guard let found = Self.firstYouTubeURL(in: s) else { return }
        if seenURLs.contains(found) { return }
        seenURLs.insert(found)
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
            NotificationHelper.show(title: "YouTube link copied",
                                    body: "Click the menu bar icon to download.")
        }
    }

    static func firstYouTubeURL(in s: String) -> String? {
        let ns = s as NSString
        let r = youtubeRegex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length))
        guard let r else { return nil }
        return ns.substring(with: r.range)
    }

    static func firstURL(in s: String) -> String? {
        let ns = s as NSString
        let r = anyURLRegex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length))
        guard let r else { return nil }
        return ns.substring(with: r.range)
    }
}

enum NotificationHelper {
    private static var authorized = false
    private static var requested = false

    static func requestAuthorization() {
        guard !requested else { return }
        requested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
            authorized = ok
        }
    }

    static func show(title: String, body: String) {
        requestAuthorization()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}
