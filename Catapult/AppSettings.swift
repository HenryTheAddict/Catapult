import Foundation
import Observation
import AppKit

enum VideoQuality: String, CaseIterable, Identifiable, Codable {
    case best = "best"
    case p2160 = "2160"
    case p1440 = "1440"
    case p1080 = "1080"
    case p720 = "720"
    case p480 = "480"
    case p360 = "360"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .best: return "Best available"
        case .p2160: return "4K (2160p)"
        case .p1440: return "1440p"
        case .p1080: return "1080p"
        case .p720:  return "720p"
        case .p480:  return "480p"
        case .p360:  return "360p"
        }
    }
    var ytdlpFormat: String {
        switch self {
        case .best: return "bv*+ba/b"
        default:    return "bv*[height<=\(rawValue)]+ba/b[height<=\(rawValue)]"
        }
    }
}

enum VideoContainer: String, CaseIterable, Identifiable, Codable {
    case mp4, mkv, webm
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
}

enum AudioFormat: String, CaseIterable, Identifiable, Codable {
    case mp3, m4a, opus, flac, wav
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
}

enum FilenamePreset: String, CaseIterable, Identifiable, Codable {
    case simple, normal, nerd, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .simple: return "Simple"
        case .normal: return "Normal"
        case .nerd:   return "Nerd slop"
        case .custom: return "Custom"
        }
    }
    var hint: String {
        switch self {
        case .simple: return "Just the video title."
        case .normal: return "Title + resolution."
        case .nerd:   return "Uploader · title · ID · resolution · codec."
        case .custom: return "Use your own yt-dlp template below."
        }
    }
    var template: String {
        switch self {
        case .simple: return "%(title)s.%(ext)s"
        case .normal: return "%(title)s [%(height)sp].%(ext)s"
        case .nerd:   return "%(uploader)s - %(title)s [%(id)s] [%(height)sp %(vcodec)s].%(ext)s"
        case .custom: return ""
        }
    }
}

enum SponsorBlockMode: String, CaseIterable, Identifiable, Codable {
    case off, mark, remove
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off:    return "Off"
        case .mark:   return "Mark as chapters"
        case .remove: return "Remove from video"
        }
    }
}

enum CookieSource: String, CaseIterable, Identifiable, Codable {
    case off, safari, chrome, firefox, brave, edge
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off:     return "Don't use cookies"
        case .safari:  return "Safari"
        case .chrome:  return "Chrome"
        case .firefox: return "Firefox"
        case .brave:   return "Brave"
        case .edge:    return "Edge"
        }
    }
    var ytdlpName: String? {
        switch self {
        case .off: return nil
        default: return rawValue
        }
    }
}

enum AppearanceOverride: String, CaseIterable, Identifiable, Codable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "Match system"
        case .light:  return "Always light"
        case .dark:   return "Always dark"
        }
    }
}

// MARK: - Device presets
//
// A "download for <device>" recipe. When applied to a download, the preset
// overrides container + height cap, then tacks on yt-dlp's `--recode-video`
// and VideoConvertor postprocessor args so the resulting file plays cleanly
// on old / niche hardware without needing a second manual transcode pass.
//
// Modern entries (iphone, ipadPro, plex, discord10mb) stay light — they
// either remux or size-gate. Retro entries force H.264 Baseline into a
// tiny box so a 2006 iPod Video or a PSP actually accepts the file.

enum DevicePreset: String, CaseIterable, Identifiable, Codable {
    case none
    // modern
    case iphone
    case ipadPro
    case plex
    case discord10mb
    // retro slop
    case psp
    case ps3
    case psvita
    case ipodClassic
    case ipodTouch
    case oldAndroid
    case pocketPC       // windows mobile / pocketpc 320x240 wmv-era era
    case nintendo3ds    // 400x240 (top screen), avi+mjpeg — the 3DS moonshell route
    case gbaVideo       // playback via emulator — tiny 240x160 h.264

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none:         return "No preset"
        case .iphone:       return "iPhone (1080p H.264)"
        case .ipadPro:      return "iPad Pro (4K HEVC)"
        case .plex:         return "Plex-ready (remux)"
        case .discord10mb:  return "Discord <10 MB"
        case .psp:          return "Sony PSP"
        case .ps3:          return "PlayStation 3"
        case .psvita:       return "PS Vita"
        case .ipodClassic:  return "iPod Classic / Nano Video"
        case .ipodTouch:    return "iPod Touch (2nd–4th gen)"
        case .oldAndroid:   return "Old Android (Froyo era)"
        case .pocketPC:     return "PocketPC / WinMo"
        case .nintendo3ds:  return "Nintendo 3DS"
        case .gbaVideo:     return "GBA Video (emulator)"
        }
    }

    var blurb: String {
        switch self {
        case .none:         return "use your regular quality settings."
        case .iphone:       return "h.264 high 1080p, aac 192k, mp4 — plays on any iphone from the 6s up."
        case .ipadPro:      return "hevc 2160p, aac 256k, mp4 — for the big-screen ones."
        case .plex:         return "just remux — keep original codecs, embed subs/metadata."
        case .discord10mb:  return "scales bitrate to fit under 10 mb. nitro-free memes."
        case .psp:          return "480×272 h.264 baseline, aac 128k @ 48k, mp4. plays on stock firmware."
        case .ps3:          return "1080p h.264 high 4.1, aac 320k, mp4. drag into the PS3's video folder."
        case .psvita:       return "960×544 h.264 baseline 3.1, aac 192k, mp4. the vita's native res."
        case .ipodClassic:  return "320×240 h.264 baseline 1.3, aac 128k @ 48k, mp4. itunes-syncable."
        case .ipodTouch:    return "640×480 h.264 baseline 3.0, aac 160k, mp4. 2nd–4th gen friendly."
        case .oldAndroid:   return "800×480 h.264 baseline 3.0, aac 128k, mp4. galaxy s, nexus one, htc desire."
        case .pocketPC:     return "320×240 h.264 baseline 1.3, aac 96k, mp4. runs on windows mobile 6.x via coreplayer."
        case .nintendo3ds:  return "400×240 h.264 baseline, aac 128k, mp4. for video app or homebrew players."
        case .gbaVideo:     return "240×160 h.264 baseline 1.0, aac 64k @ 22k, mp4. for gba emulators — no real hardware."
        }
    }

    var glyph: String {
        switch self {
        case .none:         return "slider.horizontal.3"
        case .iphone:       return "iphone"
        case .ipadPro:      return "ipad"
        case .plex:         return "play.rectangle.on.rectangle"
        case .discord10mb:  return "bubble.left.and.text.bubble.right"
        case .psp:          return "gamecontroller"
        case .ps3:          return "gamecontroller.fill"
        case .psvita:       return "gamecontroller"
        case .ipodClassic:  return "hifispeaker"
        case .ipodTouch:    return "ipod"
        case .oldAndroid:   return "flipphone"
        case .pocketPC:     return "pc"
        case .nintendo3ds:  return "gamecontroller"
        case .gbaVideo:     return "rectangle.portrait"
        }
    }

    /// Max height for the `-f` format selector. `nil` = no cap (defer to quality).
    var heightCap: Int? {
        switch self {
        case .none, .plex:     return nil
        case .iphone:          return 1080
        case .ipadPro:         return 2160
        case .discord10mb:     return 720
        case .psp, .pocketPC:  return 480
        case .ps3:             return 1080
        case .psvita:          return 720
        case .ipodClassic:     return 360
        case .ipodTouch:       return 480
        case .oldAndroid:      return 480
        case .nintendo3ds:     return 360
        case .gbaVideo:        return 240
        }
    }

    /// Container for `--merge-output-format` and `--recode-video`.
    var container: VideoContainer {
        switch self {
        case .plex: return .mkv   // plex is happiest with matroska passthrough
        default:    return .mp4
        }
    }

    /// Hard filesize ceiling, if the preset has one.
    var maxFilesizeMB: Int? {
        switch self {
        case .discord10mb: return 10
        default:           return nil
        }
    }

    /// When true, we pipe through ffmpeg via `--recode-video` with the
    /// postprocessor args below. Plex intentionally skips recoding (stream
    /// passthrough is the whole point).
    var needsRecode: Bool {
        switch self {
        case .none, .plex, .iphone, .ipadPro, .discord10mb: return false
        case .psp, .ps3, .psvita, .ipodClassic, .ipodTouch,
             .oldAndroid, .pocketPC, .nintendo3ds, .gbaVideo: return true
        }
    }

    /// ffmpeg args passed to yt-dlp's VideoConvertor postprocessor. Kept
    /// concise — the actual `-i input output` wrapping happens inside yt-dlp.
    /// Use `scale=…:force_original_aspect_ratio=decrease,pad=…` so output
    /// always matches target res exactly (old hardware hates non-mod-2 dims).
    var recodeArgs: String {
        switch self {
        case .psp:
            return "-vf scale='min(480,iw)':'min(272,ih)':force_original_aspect_ratio=decrease,pad=480:272:(ow-iw)/2:(oh-ih)/2,setsar=1 -c:v libx264 -profile:v baseline -level 3.0 -pix_fmt yuv420p -r 30 -b:v 1500k -c:a aac -ac 2 -ar 48000 -b:a 128k"
        case .ps3:
            return "-c:v libx264 -profile:v high -level 4.1 -pix_fmt yuv420p -c:a aac -ac 2 -ar 48000 -b:a 320k"
        case .psvita:
            return "-vf scale='min(960,iw)':'min(544,ih)':force_original_aspect_ratio=decrease,pad=960:544:(ow-iw)/2:(oh-ih)/2,setsar=1 -c:v libx264 -profile:v baseline -level 3.1 -pix_fmt yuv420p -b:v 2500k -c:a aac -ac 2 -ar 48000 -b:a 192k"
        case .ipodClassic:
            return "-vf scale='min(320,iw)':'min(240,ih)':force_original_aspect_ratio=decrease,pad=320:240:(ow-iw)/2:(oh-ih)/2,setsar=1 -c:v libx264 -profile:v baseline -level 1.3 -pix_fmt yuv420p -r 30 -b:v 768k -c:a aac -ac 2 -ar 48000 -b:a 128k"
        case .ipodTouch:
            return "-vf scale='min(640,iw)':'min(480,ih)':force_original_aspect_ratio=decrease,pad=640:480:(ow-iw)/2:(oh-ih)/2,setsar=1 -c:v libx264 -profile:v baseline -level 3.0 -pix_fmt yuv420p -r 30 -b:v 1500k -c:a aac -ac 2 -ar 48000 -b:a 160k"
        case .oldAndroid:
            return "-vf scale='min(800,iw)':'min(480,ih)':force_original_aspect_ratio=decrease,pad=800:480:(ow-iw)/2:(oh-ih)/2,setsar=1 -c:v libx264 -profile:v baseline -level 3.0 -pix_fmt yuv420p -r 30 -b:v 1200k -c:a aac -ac 2 -ar 44100 -b:a 128k"
        case .pocketPC:
            return "-vf scale='min(320,iw)':'min(240,ih)':force_original_aspect_ratio=decrease,pad=320:240:(ow-iw)/2:(oh-ih)/2,setsar=1 -c:v libx264 -profile:v baseline -level 1.3 -pix_fmt yuv420p -r 25 -b:v 512k -c:a aac -ac 2 -ar 44100 -b:a 96k"
        case .nintendo3ds:
            return "-vf scale='min(400,iw)':'min(240,ih)':force_original_aspect_ratio=decrease,pad=400:240:(ow-iw)/2:(oh-ih)/2,setsar=1 -c:v libx264 -profile:v baseline -level 3.0 -pix_fmt yuv420p -r 30 -b:v 800k -c:a aac -ac 2 -ar 44100 -b:a 128k"
        case .gbaVideo:
            return "-vf scale='min(240,iw)':'min(160,ih)':force_original_aspect_ratio=decrease,pad=240:160:(ow-iw)/2:(oh-ih)/2,setsar=1 -c:v libx264 -profile:v baseline -level 1.0 -pix_fmt yuv420p -r 24 -b:v 256k -c:a aac -ac 1 -ar 22050 -b:a 64k"
        default:
            return ""
        }
    }

    /// For UI grouping.
    var isRetro: Bool {
        switch self {
        case .psp, .ps3, .psvita, .ipodClassic, .ipodTouch,
             .oldAndroid, .pocketPC, .nintendo3ds, .gbaVideo: return true
        default: return false
        }
    }
}

enum SupportedSite: String, CaseIterable, Identifiable, Codable {
    case youtube, tiktok, twitter, reddit, instagram, facebook, twitch, vimeo, soundcloud, bilibili, bluesky, generic

    var id: String { rawValue }
    var title: String {
        switch self {
        case .youtube:    return "youtube"
        case .tiktok:     return "tiktok"
        case .twitter:    return "x / twitter"
        case .reddit:     return "reddit"
        case .instagram:  return "instagram"
        case .facebook:   return "facebook"
        case .twitch:     return "twitch"
        case .vimeo:      return "vimeo"
        case .soundcloud: return "soundcloud"
        case .bilibili:   return "bilibili"
        case .bluesky:    return "bluesky"
        case .generic:    return "anything else"
        }
    }
    var blurb: String {
        switch self {
        case .youtube:    return "videos, shorts, live, music — the flagship."
        case .tiktok:     return "short-form video, with or without the watermark."
        case .twitter:    return "video tweets, spaces, and replies."
        case .reddit:     return "v.redd.it, linked media, and crossposts."
        case .instagram:  return "reels, posts, stories — cookies unlock private."
        case .facebook:   return "public videos and watch clips."
        case .twitch:     return "clips, vods, and past broadcasts."
        case .vimeo:      return "creator uploads, including password-protected."
        case .soundcloud: return "tracks and sets as audio."
        case .bilibili:   return "mainland china's youtube — works fine."
        case .bluesky:    return "video posts from the at-proto network."
        case .generic:    return "anything yt-dlp can grab — 1500+ sites."
        }
    }
    var glyph: String {
        switch self {
        case .youtube:    return "play.rectangle.fill"
        case .tiktok:     return "music.note.list"
        case .twitter:    return "bird.fill"
        case .reddit:     return "bubble.left.and.bubble.right.fill"
        case .instagram:  return "camera.fill"
        case .facebook:   return "person.2.fill"
        case .twitch:     return "gamecontroller.fill"
        case .vimeo:      return "film.fill"
        case .soundcloud: return "waveform"
        case .bilibili:   return "tv.fill"
        case .bluesky:    return "cloud.fill"
        case .generic:    return "globe"
        }
    }
    var hostMatchers: [String] {
        switch self {
        case .youtube:    return ["youtube.com", "youtu.be", "youtube-nocookie.com", "music.youtube.com"]
        case .tiktok:     return ["tiktok.com", "vm.tiktok.com"]
        case .twitter:    return ["twitter.com", "x.com", "t.co"]
        case .reddit:     return ["reddit.com", "redd.it"]
        case .instagram:  return ["instagram.com", "instagr.am"]
        case .facebook:   return ["facebook.com", "fb.watch", "fb.com"]
        case .twitch:     return ["twitch.tv"]
        case .vimeo:      return ["vimeo.com"]
        case .soundcloud: return ["soundcloud.com"]
        case .bilibili:   return ["bilibili.com", "b23.tv"]
        case .bluesky:    return ["bsky.app"]
        case .generic:    return []
        }
    }
    /// Returns the SupportedSite that best matches a given URL, or `.generic`.
    static func match(url: String) -> SupportedSite {
        guard let comps = URLComponents(string: url), let host = comps.host?.lowercased() else {
            return .generic
        }
        for site in SupportedSite.allCases where site != .generic {
            for m in site.hostMatchers where host == m || host.hasSuffix("." + m) {
                return site
            }
        }
        return .generic
    }
}

enum SponsorCategory: String, CaseIterable, Identifiable, Codable {
    case sponsor, selfpromo = "selfpromo", interaction, intro, outro, preview, filler, musicOfftopic = "music_offtopic"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sponsor:        return "Sponsor"
        case .selfpromo:      return "Self-promotion"
        case .interaction:    return "Interaction reminder"
        case .intro:          return "Intro / intermission"
        case .outro:          return "Outro / endcard"
        case .preview:        return "Preview / recap"
        case .filler:         return "Filler tangent"
        case .musicOfftopic:  return "Non-music section (music videos)"
        }
    }
}

@Observable
final class AppSettings {
    static let shared = AppSettings()

    var downloadFolderPath: String {
        didSet { UserDefaults.standard.set(downloadFolderPath, forKey: "downloadFolderPath") }
    }
    var videoQuality: VideoQuality {
        didSet { UserDefaults.standard.set(videoQuality.rawValue, forKey: "videoQuality") }
    }
    var videoContainer: VideoContainer {
        didSet { UserDefaults.standard.set(videoContainer.rawValue, forKey: "videoContainer") }
    }
    var audioFormat: AudioFormat {
        didSet { UserDefaults.standard.set(audioFormat.rawValue, forKey: "audioFormat") }
    }
    var audioQualityKbps: Int {
        didSet { UserDefaults.standard.set(audioQualityKbps, forKey: "audioQualityKbps") }
    }
    var clipboardMonitoring: Bool {
        didSet { UserDefaults.standard.set(clipboardMonitoring, forKey: "clipboardMonitoring") }
    }
    var autoStartDownload: Bool {
        didSet { UserDefaults.standard.set(autoStartDownload, forKey: "autoStartDownload") }
    }
    var showNotifications: Bool {
        didSet { UserDefaults.standard.set(showNotifications, forKey: "showNotifications") }
    }
    var embedThumbnail: Bool {
        didSet { UserDefaults.standard.set(embedThumbnail, forKey: "embedThumbnail") }
    }
    var embedMetadata: Bool {
        didSet { UserDefaults.standard.set(embedMetadata, forKey: "embedMetadata") }
    }
    var embedSubtitles: Bool {
        didSet { UserDefaults.standard.set(embedSubtitles, forKey: "embedSubtitles") }
    }
    var writeThumbnail: Bool {
        didSet { UserDefaults.standard.set(writeThumbnail, forKey: "writeThumbnail") }
    }
    var maxConcurrent: Int {
        didSet { UserDefaults.standard.set(maxConcurrent, forKey: "maxConcurrent") }
    }
    var openFolderOnFinish: Bool {
        didSet { UserDefaults.standard.set(openFolderOnFinish, forKey: "openFolderOnFinish") }
    }
    var filenameTemplate: String {
        didSet { UserDefaults.standard.set(filenameTemplate, forKey: "filenameTemplate") }
    }
    var filenamePreset: FilenamePreset {
        didSet {
            UserDefaults.standard.set(filenamePreset.rawValue, forKey: "filenamePreset")
            if filenamePreset != .custom, filenameTemplate != filenamePreset.template {
                filenameTemplate = filenamePreset.template
            }
        }
    }
    var quickSizeLimitMB: Int {
        didSet { UserDefaults.standard.set(quickSizeLimitMB, forKey: "quickSizeLimitMB") }
    }
    var preferCompatibleCodecs: Bool {
        didSet { UserDefaults.standard.set(preferCompatibleCodecs, forKey: "preferCompatibleCodecs") }
    }
    var sponsorBlockMode: SponsorBlockMode {
        didSet { UserDefaults.standard.set(sponsorBlockMode.rawValue, forKey: "sponsorBlockMode") }
    }
    var sponsorBlockCategories: Set<SponsorCategory> {
        didSet {
            let arr = sponsorBlockCategories.map(\.rawValue)
            UserDefaults.standard.set(arr, forKey: "sponsorBlockCategories")
        }
    }
    var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") }
    }
    var cookieSource: CookieSource {
        didSet { UserDefaults.standard.set(cookieSource.rawValue, forKey: "cookieSource") }
    }
    var autoUpdateYtDlpOnLaunch: Bool {
        didSet { UserDefaults.standard.set(autoUpdateYtDlpOnLaunch, forKey: "autoUpdateYtDlpOnLaunch") }
    }
    /// Whether Sparkle's background update checker is allowed to run.
    /// Mirrored into Sparkle's own preferences via `UpdateController`.
    var autoCheckForUpdates: Bool {
        didSet { UserDefaults.standard.set(autoCheckForUpdates, forKey: "autoCheckForUpdates") }
    }
    var notificationSound: Bool {
        didSet { UserDefaults.standard.set(notificationSound, forKey: "notificationSound") }
    }
    var historyLimit: Int {
        didSet { UserDefaults.standard.set(historyLimit, forKey: "historyLimit") }
    }
    var proxyURL: String {
        didSet { UserDefaults.standard.set(proxyURL, forKey: "proxyURL") }
    }
    var appearance: AppearanceOverride {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "appearance") }
    }
    /// Per-site "use cookies" toggle. Sites in this set get the global
    /// `cookieSource` applied when they're downloaded. This used to be a
    /// browser-per-site picker — we simplified it to a single toggle because
    /// almost nobody actually mixes browsers across sites.
    var siteCookies: Set<SupportedSite> {
        didSet {
            let arr = siteCookies.map(\.rawValue).sorted()
            UserDefaults.standard.set(arr, forKey: "siteCookies")
        }
    }
    var rateLimitKBps: Int {
        didSet { UserDefaults.standard.set(rateLimitKBps, forKey: "rateLimitKBps") }
    }
    /// App-wide default device preset. When set (not `.none`), every new
    /// download gets the preset applied unless a per-download override says
    /// otherwise. Off by default so existing behavior is unchanged.
    var defaultDevicePreset: DevicePreset {
        didSet { UserDefaults.standard.set(defaultDevicePreset.rawValue,
                                           forKey: "defaultDevicePreset") }
    }

    private init() {
        let d = UserDefaults.standard
        let defaultDownloads = (NSSearchPathForDirectoriesInDomains(.downloadsDirectory, .userDomainMask, true).first
            ?? NSHomeDirectory() + "/Downloads")
        self.downloadFolderPath = d.string(forKey: "downloadFolderPath") ?? (defaultDownloads + "/Catapult")
        self.videoQuality = VideoQuality(rawValue: d.string(forKey: "videoQuality") ?? "") ?? .p1080
        self.videoContainer = VideoContainer(rawValue: d.string(forKey: "videoContainer") ?? "") ?? .mp4
        self.audioFormat = AudioFormat(rawValue: d.string(forKey: "audioFormat") ?? "") ?? .mp3
        self.audioQualityKbps = (d.object(forKey: "audioQualityKbps") as? Int) ?? 192
        self.clipboardMonitoring = (d.object(forKey: "clipboardMonitoring") as? Bool) ?? true
        self.autoStartDownload = (d.object(forKey: "autoStartDownload") as? Bool) ?? false
        self.showNotifications = (d.object(forKey: "showNotifications") as? Bool) ?? true
        self.embedThumbnail = (d.object(forKey: "embedThumbnail") as? Bool) ?? true
        self.embedMetadata = (d.object(forKey: "embedMetadata") as? Bool) ?? true
        self.embedSubtitles = (d.object(forKey: "embedSubtitles") as? Bool) ?? false
        self.writeThumbnail = (d.object(forKey: "writeThumbnail") as? Bool) ?? false
        self.maxConcurrent = (d.object(forKey: "maxConcurrent") as? Int) ?? 2
        self.openFolderOnFinish = (d.object(forKey: "openFolderOnFinish") as? Bool) ?? false
        let storedPreset = FilenamePreset(rawValue: d.string(forKey: "filenamePreset") ?? "") ?? .normal
        self.filenamePreset = storedPreset
        self.filenameTemplate = d.string(forKey: "filenameTemplate")
            ?? (storedPreset == .custom ? "%(title)s [%(id)s].%(ext)s" : storedPreset.template)
        self.quickSizeLimitMB = (d.object(forKey: "quickSizeLimitMB") as? Int) ?? 10
        self.preferCompatibleCodecs = (d.object(forKey: "preferCompatibleCodecs") as? Bool) ?? true
        self.sponsorBlockMode = SponsorBlockMode(rawValue: d.string(forKey: "sponsorBlockMode") ?? "") ?? .off
        let storedCats = (d.array(forKey: "sponsorBlockCategories") as? [String]) ?? ["sponsor", "selfpromo", "interaction"]
        self.sponsorBlockCategories = Set(storedCats.compactMap { SponsorCategory(rawValue: $0) })
        self.hasCompletedOnboarding = (d.object(forKey: "hasCompletedOnboarding") as? Bool) ?? false
        self.cookieSource = CookieSource(rawValue: d.string(forKey: "cookieSource") ?? "") ?? .off
        self.autoUpdateYtDlpOnLaunch = (d.object(forKey: "autoUpdateYtDlpOnLaunch") as? Bool) ?? false
        self.autoCheckForUpdates     = (d.object(forKey: "autoCheckForUpdates") as? Bool) ?? true
        self.notificationSound = (d.object(forKey: "notificationSound") as? Bool) ?? true
        self.historyLimit = (d.object(forKey: "historyLimit") as? Int) ?? 50
        self.proxyURL = d.string(forKey: "proxyURL") ?? ""
        self.appearance = AppearanceOverride(rawValue: d.string(forKey: "appearance") ?? "") ?? .system
        // New format: array of site raw-values. Also migrates from the old
        // dictionary format by treating any entry with a non-"off" source as
        // enabled.
        var sc: Set<SupportedSite> = []
        if let arr = d.array(forKey: "siteCookies") as? [String] {
            for k in arr { if let s = SupportedSite(rawValue: k) { sc.insert(s) } }
        } else if let dict = d.dictionary(forKey: "siteCookies") as? [String: String] {
            for (k, v) in dict where v != "off" {
                if let s = SupportedSite(rawValue: k) { sc.insert(s) }
            }
        }
        self.siteCookies = sc
        self.rateLimitKBps = (d.object(forKey: "rateLimitKBps") as? Int) ?? 0
        self.defaultDevicePreset = DevicePreset(rawValue: d.string(forKey: "defaultDevicePreset") ?? "") ?? .none

        try? FileManager.default.createDirectory(atPath: downloadFolderPath,
                                                 withIntermediateDirectories: true)
    }

    var downloadFolderURL: URL {
        URL(fileURLWithPath: downloadFolderPath, isDirectory: true)
    }

    /// Returns the effective cookie source for a given URL. If the site has
    /// cookies explicitly enabled, use the global `cookieSource`; otherwise
    /// fall through to the global default (which may itself be `.off`).
    func cookieSource(for url: String) -> CookieSource {
        let site = SupportedSite.match(url: url)
        if siteCookies.contains(site), cookieSource != .off {
            return cookieSource
        }
        return cookieSource
    }
}
