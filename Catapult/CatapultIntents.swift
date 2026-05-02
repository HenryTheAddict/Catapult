import Foundation
import AppIntents

// MARK: - App intents (Shortcuts.app integration)
//
// Exposes Catapult's download pipeline to Shortcuts so users can build
// automations — e.g. "on share sheet: download with Catapult, then Airdrop".
// All intents run in-process on the main actor: they talk directly to
// DownloadManager.shared.
//
// We keep the surface small on purpose: download a URL (video / audio /
// thumb), optionally pick a device preset, then fetch the resulting file
// URL or a list of recent downloads. Anything more complex lives in the
// menu-bar UI.

// MARK: App enums mirroring the settings types

enum DownloadModeAppEnum: String, AppEnum, CaseIterable {
    case video, audio, thumbnail

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Mode"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .video:     "Video",
        .audio:     "Audio (extract)",
        .thumbnail: "Thumbnail only",
    ]

    var asDownloadMode: DownloadMode {
        switch self {
        case .video:     return .video
        case .audio:     return .audio
        case .thumbnail: return .thumbnailOnly
        }
    }
}

enum VideoQualityAppEnum: String, AppEnum, CaseIterable {
    case best, p2160, p1440, p1080, p720, p480, p360

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Quality"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .best:  "Best available",
        .p2160: "4K (2160p)",
        .p1440: "1440p",
        .p1080: "1080p",
        .p720:  "720p",
        .p480:  "480p",
        .p360:  "360p",
    ]

    var asVideoQuality: VideoQuality {
        switch self {
        case .best:  return .best
        case .p2160: return .p2160
        case .p1440: return .p1440
        case .p1080: return .p1080
        case .p720:  return .p720
        case .p480:  return .p480
        case .p360:  return .p360
        }
    }
}

enum DevicePresetAppEnum: String, AppEnum, CaseIterable {
    case none, iphone, ipadPro, plex, discord10mb
    case psp, ps3, psvita, ipodClassic, ipodTouch
    case oldAndroid, pocketPC, nintendo3ds, gbaVideo

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Device preset"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .none:         "No preset",
        .iphone:       "iPhone",
        .ipadPro:      "iPad Pro",
        .plex:         "Plex-ready",
        .discord10mb:  "Discord <10 MB",
        .psp:          "Sony PSP",
        .ps3:          "PlayStation 3",
        .psvita:       "PS Vita",
        .ipodClassic:  "iPod Classic",
        .ipodTouch:    "iPod Touch",
        .oldAndroid:   "Old Android",
        .pocketPC:     "PocketPC",
        .nintendo3ds:  "Nintendo 3DS",
        .gbaVideo:     "GBA Video",
    ]

    var asDevicePreset: DevicePreset {
        switch self {
        case .none:         return .none
        case .iphone:       return .iphone
        case .ipadPro:      return .ipadPro
        case .plex:         return .plex
        case .discord10mb:  return .discord10mb
        case .psp:          return .psp
        case .ps3:          return .ps3
        case .psvita:       return .psvita
        case .ipodClassic:  return .ipodClassic
        case .ipodTouch:    return .ipodTouch
        case .oldAndroid:   return .oldAndroid
        case .pocketPC:     return .pocketPC
        case .nintendo3ds:  return .nintendo3ds
        case .gbaVideo:     return .gbaVideo
        }
    }
}

// MARK: - Download intent

struct DownloadWithCatapultIntent: AppIntent {
    static var title: LocalizedStringResource = "Download with Catapult"
    static var description = IntentDescription(
        "Queue a URL for download in Catapult. Works with anything yt-dlp supports."
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "URL",
               description: "A YouTube, TikTok, or other yt-dlp-supported link.")
    var url: URL

    @Parameter(title: "Mode", default: .video)
    var mode: DownloadModeAppEnum

    @Parameter(title: "Quality", default: .best)
    var quality: VideoQualityAppEnum

    @Parameter(title: "Device preset", default: DevicePresetAppEnum.none)
    var preset: DevicePresetAppEnum

    @Parameter(title: "Wait for completion",
               description: "Block until the download finishes, returning the file URL.",
               default: false)
    var wait: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<URL?> {
        let presetValue = preset.asDevicePreset
        var overrides = DownloadOverrides()
        overrides.videoQuality = quality.asVideoQuality
        if presetValue != .none {
            overrides.devicePreset = presetValue
        }
        let item = DownloadManager.shared.enqueue(
            url: url.absoluteString,
            mode: mode.asDownloadMode,
            overrides: overrides
        )
        guard wait else {
            return .result(value: nil)
        }
        // Poll item status — simple and side-effect-free. Shortcuts has its
        // own timeout so we don't need one here.
        while true {
            switch item.status {
            case .finished(let out):
                return .result(value: out)
            case .failed, .cancelled:
                return .result(value: nil)
            default:
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }
}

// MARK: - Recent downloads intent

struct GetRecentDownloadsIntent: AppIntent {
    static var title: LocalizedStringResource = "Get recent downloads"
    static var description = IntentDescription(
        "Returns the file URLs of Catapult's most recent completed downloads."
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Limit",
               description: "How many recent downloads to return.",
               default: 5)
    var limit: Int

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[URL]> {
        let urls: [URL] = DownloadManager.shared.items.compactMap { item in
            guard case .finished = item.status else { return nil }
            return item.outputFile
        }
        let capped = Array(urls.prefix(max(1, limit)))
        return .result(value: capped)
    }
}

// MARK: - Shortcuts provider

struct CatapultShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: DownloadWithCatapultIntent(),
            phrases: [
                "Download with \(.applicationName)",
                "\(.applicationName) download",
                "Grab with \(.applicationName)",
            ],
            shortTitle: "Download URL",
            systemImageName: "arrow.down.to.line"
        )
        AppShortcut(
            intent: GetRecentDownloadsIntent(),
            phrases: [
                "Recent \(.applicationName) downloads",
                "Latest \(.applicationName) files",
            ],
            shortTitle: "Recent downloads",
            systemImageName: "clock.arrow.circlepath"
        )
    }
}
