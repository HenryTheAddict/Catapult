import SwiftUI
import AppKit
import AVFoundation
import Observation
import CryptoKit

@Observable @MainActor
final class HoverPreview {
    static let shared = HoverPreview()
    var activeID: UUID?
    var player: AVPlayer?
    private var pending: Task<Void, Never>?
    private var observer: Any?
    func begin(id: UUID, file: URL) {
        stop()
        activeID = id
        pending = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, activeID == id else { return }
            let asset = AVURLAsset(url: file)
            guard let duration = try? await asset.load(.duration), duration.seconds > 0,
                  (try? await asset.load(.isPlayable)) == true,
                  !Task.isCancelled, activeID == id else { return }
            let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            player.isMuted = true
            let limit = min(6, duration.seconds)
            self.player = player
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak player] time in
                if time.seconds >= max(0.1, limit - 0.05) { player?.seek(to: .zero); player?.play() }
            }
            player.play()
        }
    }
    func stop(id: UUID? = nil) {
        if let id, id != activeID { return }
        pending?.cancel(); pending = nil
        if let observer, let player { player.removeTimeObserver(observer) }
        observer = nil
        player?.pause(); player?.replaceCurrentItem(with: nil)
        player = nil; activeID = nil
    }
}

@MainActor enum MediaThumbnails {
    private static let memory = NSCache<NSURL, NSImage>()
    static func image(file: URL, mode: DownloadMode) async -> NSImage? {
        let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let key = URL(string: "catapult-cache:\(SHA256.hash(data: Data("\(file.path)|\(date)".utf8)).map { String(format: "%02x", $0) }.joined())")!
        if let image = memory.object(forKey: key as NSURL) { return image }
        if mode == .thumbnailOnly {
            let image = await Task.detached { NSImage(contentsOf: file) }.value
            if let image { memory.setObject(image, forKey: key as NSURL) }
            return image
        }
        let cacheFolder = DependencyManager.shared.supportDirectory.appendingPathComponent("thumbnails")
        try? FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        let disk = cacheFolder.appendingPathComponent(key.absoluteString.replacingOccurrences(of: "catapult-cache:", with: "") + ".jpg")
        if let image = NSImage(contentsOf: disk) { memory.setObject(image, forKey: key as NSURL); return image }
        let asset = AVURLAsset(url: file)
        if mode == .audio, let metadata = try? await asset.load(.commonMetadata) {
            for item in metadata where item.commonKey == .commonKeyArtwork {
                if let data = try? await item.load(.dataValue), let artwork = NSImage(data: data), !Task.isCancelled {
                    memory.setObject(artwork, forKey: key as NSURL)
                    return artwork
                }
            }
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 360)
        var image: NSImage?
        if let result = try? await generator.image(at: CMTime(seconds: 0, preferredTimescale: 600)), !Task.isCancelled {
            image = NSImage(cgImage: result.image, size: .zero)
            let bitmap = NSBitmapImageRep(cgImage: result.image)
            if let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) { try? jpeg.write(to: disk, options: .atomic) }
        } else if mode != .audio, !Task.isCancelled {
            let process = Process(); process.executableURL = DependencyManager.shared.ffmpegPath
            process.environment = DependencyManager.enhancedEnvironment
            process.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-i", file.path, "-frames:v", "1", "-vf", "scale=640:-2", disk.path]
            let result = await MediaProcess.run(process)
            if result.code == 0 { image = NSImage(contentsOf: disk) }
        }
        guard let image, !Task.isCancelled else { return nil }
        memory.setObject(image, forKey: key as NSURL)
        memory.countLimit = 120
        return image
    }
}

private final class PreviewLayerView: NSView {
    let videoLayer = AVPlayerLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        videoLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(videoLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); videoLayer.frame = bounds }
}
private struct SilentVideo: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> PreviewLayerView { PreviewLayerView() }
    func updateNSView(_ view: PreviewLayerView, context: Context) { view.videoLayer.player = player }
    static func dismantleNSView(_ view: PreviewLayerView, coordinator: ()) { view.videoLayer.player = nil }
}

struct MediaPreview: View {
    let id: UUID
    let file: URL?
    let thumbnail: URL?
    let mode: DownloadMode
    var revision: Date? = nil
    @State private var image: NSImage?
    @State private var previews = HoverPreview.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var playable: Bool { mode == .video || mode == .cut }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                H3.ink100
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else if let thumbnail {
                    AsyncImage(url: thumbnail) { image in image.resizable().scaledToFill() }
                        placeholder: { glyph }
                } else { glyph }
                if previews.activeID == id, let player = previews.player { SilentVideo(player: player) }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .onHover { hover in
            if hover && playable && !reduceMotion, let file, FileManager.default.fileExists(atPath: file.path) {
                previews.begin(id: id, file: file)
            } else { previews.stop(id: id) }
        }
        .task(id: "\(file?.absoluteString ?? "")|\(revision?.timeIntervalSince1970 ?? 0)") {
            previews.stop(id: id)
            image = nil
            if let file { image = await MediaThumbnails.image(file: file, mode: mode) }
        }
        .onDisappear { previews.stop(id: id) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in previews.stop(id: id) }
    }
    private var glyph: some View {
        Image(systemName: mode == .audio ? "music.note" : mode == .thumbnailOnly ? "photo" : "play.rectangle")
            .font(.system(size: 28)).foregroundStyle(H3.ink300)
    }
}

struct MediaActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        ActionSurface(configuration: configuration, enabled: enabled)
    }
    private struct ActionSurface: View {
        let configuration: ButtonStyle.Configuration
        let enabled: Bool
        @State private var hover = false
        var body: some View {
            configuration.label.font(.system(size: 12, weight: .medium))
                .frame(minWidth: 28, minHeight: 28)
                .foregroundStyle(enabled ? (hover ? H3.blue500 : H3.blue400) : H3.ink300)
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .onHover { hover = $0 }
                .animation(H3.easeOut, value: hover)
                .animation(H3.appleSnap, value: configuration.isPressed)
        }
    }
}

struct MediaFileActions: View {
    let file: URL
    let mode: DownloadMode
    var onFocusChange: ((Bool) -> Void)? = nil
    private enum Action: Hashable { case open, finder, trim }
    @FocusState private var focusedAction: Action?
    @Environment(\.openWindow) private var openWindow
    private var available: Bool { FileManager.default.fileExists(atPath: file.path) }
    var body: some View {
        HStack(spacing: 6) {
            Button {
                if mode == .thumbnailOnly { NSWorkspace.shared.open(file) }
                else { NSWorkspace.openInQuickTime(url: file) }
            } label: { Image(systemName: mode == .thumbnailOnly ? "arrow.up.forward.app" : "play.rectangle") }
            .help(mode == .thumbnailOnly ? "Open image" : "Open in QuickTime")
            .focused($focusedAction, equals: .open)
            Button { NSWorkspace.shared.activateFileViewerSelecting([file]) } label: { Image(systemName: "folder") }.help("Show in Finder")
                .focused($focusedAction, equals: .finder)
            if mode != .thumbnailOnly {
                Button {
                    HoverPreview.shared.stop()
                    CutCoordinator.shared.pendingSource = .local(file)
                    openWindow(id: "cut")
                    NSApp.activate(ignoringOtherApps: true)
                } label: { Image(systemName: "scissors") }.help("Trim this file")
                    .focused($focusedAction, equals: .trim)
            }
        }
        .buttonStyle(MediaActionStyle())
        .disabled(!available)
        .onChange(of: focusedAction) { _, value in onFocusChange?(value != nil) }
    }
}

struct MediaGalleryCard: View {
    let entry: HistoryEntry
    @State private var hover = false
    @State private var localDuration: Double?
    private var previewDuration: Double? { entry.durationSeconds ?? localDuration }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MediaPreview(id: entry.id, file: entry.fileExists ? entry.outputFile : nil, thumbnail: entry.thumbnailURL, mode: entry.mode, revision: entry.finishedAt)
                .frame(height: 142)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .bottomTrailing) {
                    if let duration = previewDuration {
                        Text(MediaTime.format(duration).dropLast(4)).font(.system(size: 10, design: .monospaced))
                            .padding(5).foregroundStyle(.white).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4)).padding(7)
                    }
                }
            Text(entry.title).font(H3.body(size: 13, weight: .semibold)).lineLimit(2).frame(height: 36, alignment: .topLeading)
            HStack {
                Label(entry.mode.rawValue.capitalized, systemImage: entry.mode == .audio ? "waveform" : "film")
                Spacer()
                if let bytes = entry.fileSizeBytes { Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) }
            }.font(H3.body(size: 10)).foregroundStyle(H3.ink500)
            HStack {
                if let file = entry.outputFile { MediaFileActions(file: file, mode: entry.mode) }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.url, forType: .string)
                } label: { Image(systemName: "link") }.buttonStyle(MediaActionStyle()).help("Copy source")
            }
            if entry.outcome != .finished || !entry.fileExists {
                Label(entry.outcome == .finished ? "File unavailable" : entry.outcome.rawValue.capitalized,
                      systemImage: "exclamationmark.circle").font(H3.body(size: 11)).foregroundStyle(H3.orange)
            }
            if let error = entry.errorMessage { Text(error).font(H3.body(size: 11)).foregroundStyle(H3.red).lineLimit(2) }
        }
        .padding(12)
        .background(H3.cardFill, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(hover ? H3.blue400.opacity(0.45) : H3.cardStroke, lineWidth: 1))
        .onHover { hover = $0 }
        .task(id: "\(entry.outputFile?.path ?? "")|\(entry.finishedAt)") {
            if entry.durationSeconds == nil, entry.mode != .thumbnailOnly, let file = entry.outputFile {
                let value = try? await AVURLAsset(url: file).load(.duration)
                if let seconds = value?.seconds, seconds.isFinite, seconds > 0 { localDuration = seconds }
            }
        }
        .contextMenu {
            Button("Copy source URL", systemImage: "link") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.url, forType: .string)
            }
            if HistoryStore.shared.entries.contains(where: { $0.id == entry.id }) {
                Button("Remove from history", systemImage: "trash", role: .destructive) { HistoryStore.shared.remove(entry) }
            }
        }
    }
}
