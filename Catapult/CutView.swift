import SwiftUI
import AppKit
import AVFoundation
import Observation
import UniformTypeIdentifiers

@Observable final class CutCoordinator {
    static let shared = CutCoordinator()
    var pendingURL: String = "" { didSet { pendingSource = .online(pendingURL) } }
    var pendingSource: MediaSource?
    private init() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--trim-source"), arguments.indices.contains(index + 1) {
            pendingSource = .local(URL(fileURLWithPath: arguments[index + 1]))
        }
        #endif
    }
}

struct CutWindowHost: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(DependencyManager.self) private var dependencies
    @Environment(AppSettings.self) private var settings
    @State private var coordinator = CutCoordinator.shared
    @State private var source: MediaSource = .online("")
    @State private var link = ""
    @State private var title = "Choose a link or media file"
    @State private var uploader = ""
    @State private var duration = 0.0
    @State private var startSeconds = 0.0
    @State private var endSeconds = 0.0
    @State private var zoom = 1.0
    @State private var timelineCenter: Double?
    @State private var thumbnailURL: URL?
    @State private var previewURL: URL?
    @State private var player: AVPlayer?
    @State private var currentTime = 0.0
    @State private var frameStep = 0.1
    @State private var isPlaying = false
    @State private var muted = false
    @State private var loopSelection = true
    @State private var timeObserver: Any?
    @State private var playerStatusObservation: NSKeyValueObservation?
    @State private var playbackObservation: NSKeyValueObservation?
    @State private var playbackEndObserver: NSObjectProtocol?
    @State private var restartingLoop = false
    @State private var loadID = UUID()
    @State private var seekTask: Task<Void, Never>?
    @State private var loadProcess: Process?
    @State private var loading = false
    @State private var loadError: String?
    @State private var previewError: String?
    @State private var cookieWarning: String?
    @State private var asAudio = false
    @State private var accuracy: ClipAccuracy = .accurate
    @State private var videoContainer: VideoContainer = .mp4
    @State private var audioFormat: AudioFormat = .mp3
    @State private var videoQuality: VideoQuality = .p1080
    @State private var job: DownloadItem?
    @State private var rangeHistory: [TrimSelection] = []
    @State private var redoHistory: [TrimSelection] = []
    @State private var historyTask: Task<Void, Never>?
    @State private var startInputInvalid = false
    @State private var endInputInvalid = false
    private var selection: TrimSelection { TrimSelection(start: startSeconds, end: endSeconds) }
    private var selectionIsValid: Bool { MediaTime.valid(start: startSeconds, end: endSeconds, duration: duration) && !startInputInvalid && !endInputInvalid }
    private var busy: Bool { job?.isActive == true }
    private var startBinding: Binding<Double> {
        Binding(get: { startSeconds }, set: { setRange(start: min($0, max(0, endSeconds - min(0.25, duration))), end: endSeconds) })
    }
    private var endBinding: Binding<Double> {
        Binding(get: { endSeconds }, set: { setRange(start: startSeconds, end: max($0, startSeconds + min(0.25, duration))) })
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "scissors").font(.system(size: 24, weight: .medium)).foregroundStyle(H3.blue400)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Trim media").font(H3.display(size: 24, weight: .medium))
                    Text(title).font(H3.body(size: 12)).foregroundStyle(H3.ink500).lineLimit(1)
                }
                Spacer()
                Button("Open file", systemImage: "folder.badge.plus", action: openFile).disabled(busy)
            }.padding(.horizontal, 24).padding(.vertical, 16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "link").foregroundStyle(H3.ink500)
                        TextField("Paste a video link", text: $link).textFieldStyle(.roundedBorder).onSubmit(loadLink)
                        Button("Load", action: loadLink).disabled(busy || link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if loading { ProgressView().controlSize(.small) }
                    }
                    if let loadError { Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(H3.orange).font(H3.body(size: 12)) }
                    preview
                    transport
                    if let warning = cookieWarning { Label(warning, systemImage: "key.slash").font(H3.body(size: 11)).foregroundStyle(H3.orange) }
                    HStack {
                        Label("Selection", systemImage: "timeline.selection").font(H3.body(size: 13, weight: .semibold))
                        Text(MediaTime.format(max(0, endSeconds - startSeconds))).font(H3.mono(size: 12)).foregroundStyle(H3.blue400)
                        Spacer()
                        Button { zoom = max(1, zoom / 1.5) } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom out")
                        Button { zoom = min(50, zoom * 1.5) } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom in")
                        Button("Fit selection") { timelineCenter = (startSeconds + endSeconds) / 2; zoom = min(50, max(1, duration / max(0.25, (endSeconds - startSeconds) * 1.3))) }
                        Button("Reset") { setRange(start: 0, end: duration); zoom = 1; timelineCenter = duration / 2 }
                    }.buttonStyle(.borderless).disabled(duration <= 0 || busy)
                    FilmstripTrimView(start: startBinding, end: endBinding, zoom: $zoom,
                                      center: $timelineCenter, duration: duration, currentTime: currentTime,
                                      previewURL: previewURL, onScrub: { seek($0, precise: false) },
                                      onScrubEnd: { seek($0, precise: true) })
                        .frame(height: 74).padding(.top, 14).padding(.bottom, 12).disabled(busy || duration <= 0)
                    HStack(spacing: 12) {
                        TimeField(label: "Start", seconds: Binding(get: { startSeconds }, set: { setRange(start: $0, end: endSeconds) }), min: 0, max: max(0, endSeconds - min(0.25, duration)), invalid: $startInputInvalid)
                        TimeField(label: "End", seconds: Binding(get: { endSeconds }, set: { setRange(start: startSeconds, end: $0) }), min: startSeconds + min(0.25, duration), max: duration, invalid: $endInputInvalid)
                        Spacer()
                        Button("Set start", systemImage: "inset.filled.leading") { startBinding.wrappedValue = currentTime }.help("Set start at playhead (I)")
                        Button("Set end", systemImage: "inset.filled.trailing") { endBinding.wrappedValue = currentTime }.help("Set end at playhead (O)")
                    }.disabled(busy || duration <= 0)
                    ViewThatFits(in: .horizontal) {
                        exportOptions
                        VStack(alignment: .leading, spacing: 10) {
                            outputKind
                            outputSettings
                        }
                    }.disabled(busy)
                    Text(accuracy == .accurate ? "Accurate cuts re-encode for precise boundaries." : "Fast cuts copy video at nearby keyframes. Boundaries and duration may differ; quality settings do not apply.")
                        .font(H3.body(size: 11)).foregroundStyle(H3.ink500)
                }.padding(20)
            }
            Divider()
            footer.padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(minWidth: 760, idealWidth: 900, minHeight: 640, idealHeight: 720)
        .background(H3.ink50).h3WindowChrome()
        .background(TrimKeyboardMonitor { key, modifiers in handleKey(key, modifiers: modifiers) })
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard !busy, let provider = providers.first else { return false }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let file = (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) } ?? item as? URL
                if let file { Task { @MainActor in source = .local(file) } }
            }
            return true
        }
        .onAppear {
            videoContainer = settings.videoContainer; audioFormat = settings.audioFormat; videoQuality = settings.videoQuality
            if let pending = coordinator.pendingSource, !busy { source = pending }
        }
        .onChange(of: coordinator.pendingSource) { _, pending in if let pending, !busy { source = pending } }
        .task(id: source) { await loadSource() }
        .onDisappear {
            teardownPlayer(); historyTask?.cancel()
            if loadProcess?.isRunning == true { loadProcess?.terminate() }
        }
    }
    private var outputKind: some View {
        HStack(spacing: 12) {
            Text("Export").fixedSize()
            Picker("Output", selection: $asAudio) { Text("Video").tag(false); Text("Audio only").tag(true) }
                .labelsHidden().pickerStyle(.segmented).frame(width: 200)
        }
    }
    private var outputSettings: some View {
        HStack(spacing: 16) {
            if asAudio {
                Picker("Format", selection: $audioFormat) { ForEach(AudioFormat.allCases) { Text($0.label).tag($0) } }
            } else {
                Picker("Format", selection: $videoContainer) { ForEach(VideoContainer.allCases) { Text($0.label).tag($0) } }
                Picker("Quality", selection: $videoQuality) { ForEach(VideoQuality.allCases) { Text($0.label).tag($0) } }
            }
            Picker("Cut", selection: $accuracy) { Text("Accurate").tag(ClipAccuracy.accurate); Text("Fast").tag(ClipAccuracy.fast) }.frame(width: 170)
        }.fixedSize(horizontal: true, vertical: false)
    }
    private var exportOptions: some View {
        HStack(spacing: 16) { outputKind; outputSettings }.fixedSize(horizontal: true, vertical: false)
    }
    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(Color.black)
            if let player { TrimPlaybackSurface(player: player) }
            else if let thumbnailURL { AsyncImage(url: thumbnailURL) { $0.resizable().scaledToFit() } placeholder: { ProgressView() } }
            else { Image(systemName: asAudio ? "waveform" : "play.rectangle").font(.system(size: 42)).foregroundStyle(.white.opacity(0.4)) }
            if loading { ProgressView().tint(.white) }
            if let previewError {
                Text(previewError).font(H3.body(size: 12)).foregroundStyle(.white)
                    .padding(10).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 8)).frame(maxHeight: .infinity, alignment: .bottom).padding(10)
            }
        }.frame(height: 180).clipShape(RoundedRectangle(cornerRadius: 14))
    }
    private var transport: some View {
        HStack(spacing: 10) {
            Button { seek(startSeconds, precise: true) } label: { Image(systemName: "backward.end") }.help("Jump to selection start")
            Button(action: togglePlayback) { Image(systemName: isPlaying ? "pause.fill" : "play.fill") }.help("Play / pause (Space)")
            Button { seek(endSeconds, precise: true) } label: { Image(systemName: "forward.end") }.help("Jump to selection end")
            Button { muted.toggle(); player?.isMuted = muted } label: { Image(systemName: muted ? "speaker.slash" : "speaker.wave.2") }.help("Mute preview")
            Toggle("Loop selection", isOn: $loopSelection).toggleStyle(.checkbox)
            Spacer()
            Text("\(MediaTime.format(currentTime)) / \(MediaTime.format(duration))").font(H3.mono(size: 12))
        }.buttonStyle(MediaActionStyle()).disabled(player == nil)
    }
    @ViewBuilder private var footer: some View {
        HStack(spacing: 12) {
            if let job {
                if job.isActive {
                    ProgressView().controlSize(.small)
                    Text(job.statusLine).font(H3.body(size: 12)).lineLimit(1)
                    Button("Cancel export", systemImage: "xmark.circle") { downloads.cancel(job) }
                } else if case .finished(let file?) = job.status {
                    Label("Clip saved", systemImage: "checkmark.circle.fill").foregroundStyle(H3.green)
                    MediaFileActions(file: file, mode: job.mode)
                } else if case .failed(let message) = job.status {
                    Text(message).font(H3.body(size: 11)).foregroundStyle(H3.red).lineLimit(2)
                    Button("Retry", systemImage: "arrow.clockwise") { downloads.retry(job) }
                } else { Text("Export cancelled").foregroundStyle(H3.ink500) }
            } else { Text("Original files stay untouched.").font(H3.body(size: 12)).foregroundStyle(H3.ink500) }
            Spacer()
            Button(asAudio ? "Export audio clip" : "Export video clip", systemImage: "arrow.down.to.line", action: export)
                .buttonStyle(.borderedProminent).disabled(!selectionIsValid || busy || loading)
                .keyboardShortcut(.return, modifiers: .command)
        }
    }
    private func openFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.movie, .audio]; panel.allowsMultipleSelection = false
        panel.begin { response in if response == .OK, let file = panel.url { source = .local(file) } }
    }
    private func loadLink() {
        guard !busy, let value = ClipboardMonitor.firstDownloadURL(in: link) else { loadError = "Enter a valid media link."; return }
        source = .online(value)
    }
    private func setRange(start: Double, end: Double) {
        guard duration > 0 else { return }
        startSeconds = min(max(0, start), duration)
        endSeconds = min(max(0, end), duration)
        historyTask?.cancel()
        historyTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            rememberRange()
        }
    }
    private func rememberRange() {
        if rangeHistory.last != selection { rangeHistory.append(selection); redoHistory.removeAll() }
        if rangeHistory.count > 100 { rangeHistory.removeFirst() }
    }
    private func undoRange(redo: Bool) {
        historyTask?.cancel()
        if redo {
            guard let next = redoHistory.popLast() else { return }
            rangeHistory.append(next); startSeconds = next.start; endSeconds = next.end
        } else {
            rememberRange()
            guard rangeHistory.count > 1 else { return }
            redoHistory.append(rangeHistory.removeLast())
            let previous = rangeHistory.last!; startSeconds = previous.start; endSeconds = previous.end
        }
    }
    private func handleKey(_ key: String, modifiers: NSEvent.ModifierFlags) -> Bool {
        if modifiers.contains(.command), key.lowercased() == "z" { undoRange(redo: modifiers.contains(.shift)); return true }
        guard !modifiers.contains(.command), !busy, duration > 0 else { return false }
        switch key.lowercased() {
        case " ": togglePlayback()
        case "i": startBinding.wrappedValue = currentTime
        case "o": endBinding.wrappedValue = currentTime
        case "left": seek(currentTime - (modifiers.contains(.shift) ? 1 : frameStep), precise: true)
        case "right": seek(currentTime + (modifiers.contains(.shift) ? 1 : frameStep), precise: true)
        default: return false
        }
        return true
    }
    private func togglePlayback() {
        guard let player else { return }
        if player.rate != 0 { player.pause(); isPlaying = false }
        else {
            if currentTime >= duration || (loopSelection && (currentTime < startSeconds || currentTime >= endSeconds)) { seek(loopSelection ? startSeconds : 0, precise: true) }
            player.play(); isPlaying = true
        }
    }
    private func seek(_ seconds: Double, precise: Bool) {
        seekTask?.cancel()
        let target = min(max(0, seconds), duration)
        currentTime = target
        seekTask = Task {
            if !precise { try? await Task.sleep(for: .milliseconds(35)) }
            guard !Task.isCancelled, let player else { return }
            let tolerance = precise ? CMTime.zero : CMTime(seconds: 0.08, preferredTimescale: 600)
            await player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance)
            if !Task.isCancelled { seekTask = nil }
        }
    }
    private func teardownPlayer() {
        seekTask?.cancel()
        if let observer = timeObserver, let player { player.removeTimeObserver(observer) }
        if let playbackEndObserver { NotificationCenter.default.removeObserver(playbackEndObserver) }
        playbackEndObserver = nil; playbackObservation = nil; restartingLoop = false
        timeObserver = nil; playerStatusObservation = nil; player?.pause(); player = nil; isPlaying = false
    }
    private func configurePlayer(_ file: URL) async {
        teardownPlayer()
        let asset = AVURLAsset(url: file)
        let tracks = try? await asset.loadTracks(withMediaType: .video)
        if let track = tracks?.first, let fps = try? await track.load(.nominalFrameRate), fps > 0 { frameStep = 1 / Double(fps) }
        guard !Task.isCancelled else { return }
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset)); player.isMuted = muted
        self.player = player
        let generation = loadID
        playerStatusObservation = player.currentItem?.observe(\.status, options: [.new]) { item, _ in
            if item.status == .failed { Task { @MainActor in
                guard loadID == generation, self.player === player else { return }
                previewError = "Preview unavailable. The selected range can still be exported."
            } }
        }
        playbackObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { _, _ in
            Task { @MainActor in
                guard loadID == generation, self.player === player else { return }
                isPlaying = player.timeControlStatus != .paused
            }
        }
        playbackEndObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { _ in
            Task { @MainActor in
                guard loadID == generation, self.player === player else { return }
                if loopSelection { restartSelection(player, generation: generation) }
                else { isPlaying = false }
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { time in
            currentTime = max(0, time.seconds.isFinite ? time.seconds : 0)
            isPlaying = player.rate > 0
            if loopSelection && player.rate > 0 && currentTime >= endSeconds { restartSelection(player, generation: generation) }
        }
    }
    private func restartSelection(_ playback: AVPlayer, generation: UUID) {
        guard !restartingLoop else { return }
        restartingLoop = true
        Task { @MainActor in
            await playback.seek(to: CMTime(seconds: startSeconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            guard loadID == generation, player === playback else { return }
            restartingLoop = false
            playback.play()
        }
    }
    private func loadSource() async {
        teardownPlayer()
        loadID = UUID(); let generation = loadID
        loading = true; defer { if loadID == generation { loading = false } }
        loadError = nil; previewError = nil; cookieWarning = nil; previewURL = nil; thumbnailURL = nil
        duration = 0; startSeconds = 0; endSeconds = 0; frameStep = 0.1; zoom = 1; timelineCenter = nil
        rangeHistory = []; redoHistory = []; job = nil; startInputInvalid = false; endInputInvalid = false
        switch source {
        case .local(let file):
            title = file.deletingPathExtension().lastPathComponent; link = ""
            asAudio = LibraryScan.mode(for: file) == .audio
            guard FileManager.default.fileExists(atPath: file.path) else { loadError = "The source file is unavailable."; return }
            let asset = AVURLAsset(url: file)
            let localDuration = (try? await asset.load(.duration).seconds) ?? 0
            guard !Task.isCancelled else { return }
            duration = localDuration
            if !duration.isFinite || duration <= 0 {
                let result = await run(dependencies.binDirectory.appendingPathComponent("ffprobe"), ["-v", "error", "-show_format", "-of", "json", file.path])
                if let data = result?.data(using: .utf8), let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let format = info["format"] as? [String: Any], let value = format["duration"] as? String { duration = Double(value) ?? 0 }
            }
            guard !Task.isCancelled else { return }
            previewURL = file
        case .online(let url):
            guard !url.isEmpty else { loading = false; return }
            link = url; title = "Loading media…"
            let cookies = await CookieArgs.resolve(for: url)
            defer { cookies.cleanup() }
            cookieWarning = cookies.error
            let common = ["--no-playlist", "--no-warnings", "--js-runtimes", "deno", "--js-runtimes", "node"] + cookies.arguments
            guard let response = await run(dependencies.ytDlpPath, common + ["--dump-single-json", "--skip-download", url]),
                  let data = response.data(using: .utf8), let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any], !Task.isCancelled else {
                if !Task.isCancelled { loadError = "Could not load media. Check the link or browser sign-in, then load again." }
                return
            }
            title = info["title"] as? String ?? url; uploader = info["uploader"] as? String ?? ""
            duration = (info["duration"] as? NSNumber)?.doubleValue ?? 0
            thumbnailURL = (info["thumbnail"] as? String).flatMap(URL.init(string:))
            if let response = await run(dependencies.ytDlpPath, common + ["-g", "-f", "b[ext=mp4][protocol^=https][vcodec!=none][acodec!=none]/b", url]),
               let first = response.split(separator: "\n").first { previewURL = URL(string: String(first)) }
            else { previewError = "Preview unavailable. You can still export a valid selection." }
        }
        guard !Task.isCancelled else { return }
        guard duration.isFinite, duration > 0 else { duration = 0; loadError = "This source has no usable duration for trimming."; return }
        startSeconds = 0; endSeconds = min(60, duration); timelineCenter = duration / 2; rangeHistory = [selection]
        if let previewURL { await configurePlayer(previewURL) }
    }
    private func run(_ executable: URL, _ arguments: [String]) async -> String? {
        let process = Process(); process.executableURL = executable; process.arguments = arguments
        process.environment = DependencyManager.enhancedEnvironment; loadProcess = process
        let result = await MediaProcess.run(process)
        if loadProcess === process { loadProcess = nil }
        guard !Task.isCancelled, result.code == 0 else { return nil }
        return result.stdout
    }
    private func export() {
        guard selectionIsValid, !busy else { return }
        player?.pause(); isPlaying = false
        job = downloads.enqueue(url: source.value, mode: asAudio ? .audio : .cut,
                                cutStart: startSeconds, cutEnd: endSeconds,
                                overrides: DownloadOverrides(videoQuality: videoQuality, videoContainer: videoContainer, audioFormat: audioFormat),
                                source: source, clipAccuracy: accuracy)
    }
}

private final class TrimPlayerLayer: NSView {
    let video = AVPlayerLayer()
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        video.videoGravity = .resizeAspect; layer?.addSublayer(video)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); video.frame = bounds }
}
private struct TrimPlaybackSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> TrimPlayerLayer { TrimPlayerLayer() }
    func updateNSView(_ view: TrimPlayerLayer, context: Context) { view.video.player = player }
    static func dismantleNSView(_ view: TrimPlayerLayer, coordinator: ()) { view.video.player = nil }
}

nonisolated struct TrimSelection: Equatable { let start: Double; let end: Double }

private struct TrimKeyboardMonitor: NSViewRepresentable {
    let action: (String, NSEvent.ModifierFlags) -> Bool
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view] event in
            guard let window = view?.window, event.window === window,
                  !(window.firstResponder is NSTextView) else { return event }
            let key = event.keyCode == 123 ? "left" : event.keyCode == 124 ? "right" : event.charactersIgnoringModifiers ?? ""
            return action(key, event.modifierFlags) ? nil : event
        }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }
    final class Coordinator { var monitor: Any? }
}

// MARK: - iOS Photos-style filmstrip trim

struct TimedThumbnail {
    let time: Double
    let image: NSImage?
}
@MainActor final class FilmstripCache {
    static let shared = FilmstripCache()
    private var cache: [String: [TimedThumbnail]] = [:]
    private var order: [String] = []
    func get(_ key: String) -> [TimedThumbnail]? { cache[key] }
    func set(_ key: String, _ images: [TimedThumbnail]) {
        cache[key] = images
        order.removeAll { $0 == key }; order.append(key)
        while order.count > 8 { cache.removeValue(forKey: order.removeFirst()) }
    }
}

struct FilmstripTrimView: View {
    @Binding var start: Double
    @Binding var end: Double
    @Binding var zoom: Double
    @Binding var center: Double?
    let duration: Double
    let currentTime: Double
    let previewURL: URL?
    let onScrub: (Double) -> Void
    let onScrubEnd: (Double) -> Void

    @State private var thumbnails: [TimedThumbnail] = []
    @State private var timelineSpace = UUID()
    @State private var loadingThumbs = false
    @State private var dragAnchor: (startS: Double, endS: Double, startX: CGFloat)?
    @State private var pinchBase: Double?

    private let handleW: CGFloat = 18
    private let handleOverhang: CGFloat = 8   // how far handles extend above/below the strip
    private var minSelection: Double { min(0.25, safeDuration) }

    private var safeDuration: Double {
        duration.isFinite && duration > 0 ? duration : 0.25
    }

    private var safeZoom: Double {
        zoom.isFinite && zoom >= 1 ? zoom : 1
    }

    // Windowed view around selection midpoint when zoomed.
    private var windowDuration: Double { max(safeDuration / safeZoom, minSelection) }
    private var windowStart: Double {
        let mid = center ?? (start + end) / 2
        let half = windowDuration / 2
        let clampedMid = min(max(mid.isFinite ? mid : half, half), max(safeDuration - half, half))
        return max(0, clampedMid - half)
    }
    private var windowEnd: Double { min(safeDuration, windowStart + windowDuration) }

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width.isFinite ? geo.size.width : 1, 1)
            let h = max(geo.size.height.isFinite ? geo.size.height : 1, 1)
            ZStack(alignment: .topLeading) {
                FilmstripScrollCatcher(
                    onScroll: { dx, dy, modifiers in
                        // Horizontal trackpad scroll → scrub the playhead
                        // (shift-scroll pans the selection). Vertical → zoom.
                        let horizontal = abs(dx) > abs(dy)
                        if horizontal && modifiers.contains(.shift) {
                            let delta = Double(dx) / Double(max(w, 1)) * windowDuration
                            center = min(max((center ?? (start + end) / 2) + delta, windowDuration / 2), safeDuration - windowDuration / 2)
                        } else if horizontal {
                            let frac = Double(dx) / Double(max(w, 1))
                            let delta = frac * windowDuration
                            let t = min(max(currentTime + delta, 0), safeDuration)
                            onScrubEnd(t)
                        } else {
                            let factor = pow(1.10, Double(dy) / 6.0)
                            zoom = min(max(zoom * factor, 1), 50)
                        }
                    },
                    onMiddleClick: { x in
                        let sec = windowStart + Double(x / max(w, 1)) * windowDuration
                        onScrubEnd(sec)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                filmstrip(width: w, height: h)
                    .clipShape(RoundedRectangle(cornerRadius: H3.radius2, style: .continuous))
                    .allowsHitTesting(false)

                // Tick marks at sensible intervals so the user always has a
                // sense of where they are even without thumbnails loaded.
                tickOverlay(width: w, height: h)
                    .allowsHitTesting(false)

                // Adaptive dim outside the selection — uses ink900 so it
                // works in both light and dark mode.
                if let sx = xPos(max(start, windowStart), w) {
                    H3.ink900.opacity(0.45)
                        .frame(width: sx, height: h)
                        .allowsHitTesting(false)
                }
                if let ex = xPos(min(end, windowEnd), w) {
                    H3.ink900.opacity(0.45)
                        .frame(width: max(0, w - ex), height: h)
                        .offset(x: ex)
                        .allowsHitTesting(false)
                }

                // h3 brand-blue gradient frame around selection.
                if start <= windowEnd && end >= windowStart {
                    let sx = xPos(max(start, windowStart), w) ?? 0
                    let ex = xPos(min(end, windowEnd), w) ?? w
                    RoundedRectangle(cornerRadius: H3.radius2, style: .continuous)
                        .strokeBorder(H3.gradDeep, lineWidth: 3)
                        .frame(width: max(ex - sx, 0), height: h)
                        .offset(x: sx)
                        .shadow(color: H3.blue500.opacity(0.35), radius: 4)
                        .allowsHitTesting(false)
                }

                // Selection-duration badge in the middle of the selection.
                if start >= windowStart, end <= windowEnd, end - start > 0 {
                    let sx = xPos(start, w) ?? 0
                    let ex = xPos(end, w) ?? 0
                    let mid = (sx + ex) / 2
                    selectionBadge(seconds: end - start)
                        .offset(x: mid - 36, y: h + 4)
                        .allowsHitTesting(false)
                }

                // Playhead — bright blue line with a glossy diamond head and
                // a floating time pill above so the user can read the exact
                // current frame without looking elsewhere.
                if currentTime >= windowStart, currentTime <= windowEnd,
                   let px = xPos(currentTime, w) {
                    playhead(at: px, height: h,
                             time: currentTime)
                        .allowsHitTesting(false)
                }

                // Middle drag area — drags entire selection.
                if start >= windowStart && end <= windowEnd {
                    let sx = xPos(start, w) ?? 0
                    let ex = xPos(end, w) ?? 0
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .frame(width: max(ex - sx - handleW * 2, 0), height: h)
                        .offset(x: sx + handleW)
                        .gesture(selectionDrag(width: w))
                }

                // Left + right glossy h3 handles.
                if start >= windowStart - 0.01 && start <= windowEnd + 0.01,
                   let sx = xPos(start, w) {
                    handle(isStart: true, height: h)
                        .offset(x: sx - handleW / 2, y: -handleOverhang)
                        .gesture(handleDrag(isStart: true, width: w))
                }
                if end >= windowStart - 0.01 && end <= windowEnd + 0.01,
                   let ex = xPos(end, w) {
                    handle(isStart: false, height: h)
                        .offset(x: ex - handleW / 2, y: -handleOverhang)
                        .gesture(handleDrag(isStart: false, width: w))
                }
            }
            .background(
                // Subtle h3 surface beneath the strip so empty thumbnails
                // don't read as a void in dark mode.
                RoundedRectangle(cornerRadius: H3.radius2, style: .continuous)
                    .fill(H3.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: H3.radius2, style: .continuous)
                    .stroke(H3.cardStroke, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .onTapGesture { loc in
                let pct = Double(loc.x / max(w, 1))
                onScrubEnd(windowStart + pct * windowDuration)
            }
            .gesture(
                MagnificationGesture()
                    .onChanged { scale in
                        let base = pinchBase ?? zoom
                        if pinchBase == nil { pinchBase = zoom }
                        zoom = min(max(base * Double(scale), 1), 50)
                    }
                    .onEnded { _ in pinchBase = nil }
            )
        }
        .coordinateSpace(name: timelineSpace)
        .task(id: "\(previewURL?.absoluteString ?? "")|\(windowStart)|\(windowDuration)") { await loadThumbnails() }
    }

    // MARK: - h3 timeline overlays

    /// Pick a tick interval that yields ~6-10 ticks across the visible window.
    private var tickInterval: Double {
        let candidates: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600]
        let target = windowDuration / 8
        return candidates.first { $0 >= target } ?? 3600
    }

    private func tickOverlay(width w: CGFloat, height h: CGFloat) -> some View {
        let interval = tickInterval
        let firstTick = (windowStart / interval).rounded(.up) * interval
        return ZStack(alignment: .topLeading) {
            ForEach(Array(stride(from: firstTick, through: windowEnd, by: interval)), id: \.self) { t in
                if let x = xPos(t, w) {
                    VStack(spacing: 0) {
                        Rectangle()
                            .fill(H3.ink900.opacity(0.25))
                            .frame(width: 1, height: 6)
                        Spacer(minLength: 0)
                        Rectangle()
                            .fill(H3.ink900.opacity(0.25))
                            .frame(width: 1, height: 6)
                    }
                    .frame(height: h)
                    .offset(x: x)
                }
            }
        }
    }

    private func selectionBadge(seconds: Double) -> some View {
        Text(formatSeconds(seconds))
            .font(H3.mono(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(
                Capsule().fill(H3.gradDeep)
            )
            .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1))
            .shadow(color: H3.shadowDrop, radius: 3, y: 2)
            .frame(width: 72)
    }

    private func playhead(at x: CGFloat, height h: CGFloat, time: Double) -> some View {
        ZStack(alignment: .top) {
            // Vertical line.
            Rectangle()
                .fill(Color.white)
                .frame(width: 2, height: h + 6)
                .shadow(color: .black.opacity(0.6), radius: 2)
                .offset(x: x - 1, y: -3)
            // Floating time pill above the strip.
            Text(formatSeconds(time))
                .font(H3.mono(size: 10, weight: .semibold))
                .foregroundStyle(H3.ink900)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(
                    Capsule().fill(H3.cardFill)
                )
                .overlay(Capsule().stroke(H3.cardStroke, lineWidth: 1))
                .shadow(color: H3.shadowDrop.opacity(0.4), radius: 3, y: 2)
                .offset(x: x - 22, y: -22)
        }
    }

    private func formatSeconds(_ t: Double) -> String {
        let total = Int(t.isFinite && t >= 0 ? t : 0)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    private func filmstrip(width w: CGFloat, height h: CGFloat) -> some View {
        let slots = max(Int((w / 48).rounded()), 6)
        return HStack(spacing: 0) {
            if thumbnails.isEmpty {
                ForEach(0..<slots, id: \.self) { _ in
                    Rectangle().fill(Color.secondary.opacity(0.25))
                        .frame(width: w / CGFloat(slots), height: h)
                        .overlay(Rectangle().stroke(.black.opacity(0.15), lineWidth: 0.5))
                }
            } else {
                ForEach(0..<slots, id: \.self) { i in
                    // Map this slot's time into the full thumbnail range
                    let t = windowStart + (Double(i) + 0.5) / Double(slots) * windowDuration
                    let nearest = thumbnails.min { abs($0.time - t) < abs($1.time - t) }
                    if let image = nearest?.image {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: w / CGFloat(slots), height: h).clipped()
                    } else {
                        Rectangle().fill(H3.ink100).frame(width: w / CGFloat(slots), height: h)
                    }
                }
            }
        }.frame(width: w, height: h)
    }

    /// Glossy h3 grab handle: brand-blue gradient pill with white gloss
    /// overlay and three grip dots, matching the rest of the h3 button kit.
    /// Expanded hit zone (handleW × height + overhang) keeps it trackpad-friendly.
    private func handle(isStart: Bool, height: CGFloat) -> some View {
        let totalHeight = height + handleOverhang * 2
        return ZStack {
            RoundedRectangle(cornerRadius: handleW / 2, style: .continuous)
                .fill(H3.gradDeep)
                .overlay(
                    RoundedRectangle(cornerRadius: handleW / 2, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.30), lineWidth: 1)
                )
                .frame(width: handleW, height: totalHeight)
            // White gloss highlight on the top half — h3 signature finish.
            RoundedRectangle(cornerRadius: handleW / 2, style: .continuous)
                .fill(H3.glossTop)
                .frame(width: handleW, height: totalHeight)
                .allowsHitTesting(false)
            // Three vertical grip dots in white for contrast on blue.
            VStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: 2.5, height: 2.5)
                }
            }
        }
        .shadow(color: H3.shadowDrop, radius: 3, y: 1)
        .frame(width: handleW, height: totalHeight)
        .contentShape(Rectangle())
    }

    // MARK: Math

    private func xPos(_ seconds: Double, _ w: CGFloat) -> CGFloat? {
        let span = windowDuration
        guard span > 0 else { return nil }
        let pct = (seconds - windowStart) / span
        guard pct.isFinite else { return nil }
        return w * CGFloat(min(max(pct, 0), 1))
    }

    private func secondsFor(_ x: CGFloat, _ w: CGFloat) -> Double {
        let pct = min(max(Double(x / max(w, 1)), 0), 1)
        return windowStart + pct * windowDuration
    }

    // MARK: Gestures

    private func handleDrag(isStart: Bool, width w: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(timelineSpace)).onChanged { v in
            let sec = secondsFor(v.location.x, w)
            if safeZoom > 1 {
                let delta = v.location.x < 12 ? -windowDuration * 0.02 : v.location.x > w - 12 ? windowDuration * 0.02 : 0
                if delta != 0 { center = min(max((center ?? (start + end) / 2) + delta, windowDuration / 2), safeDuration - windowDuration / 2) }
            }
            if isStart { start = min(max(sec, 0), end - minSelection) }
            else       { end   = min(max(sec, start + minSelection), safeDuration) }
            onScrub(isStart ? start : end)
        }.onEnded { _ in onScrubEnd(isStart ? start : end) }
    }

    private func selectionDrag(width w: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(timelineSpace))
            .onChanged { v in
                if dragAnchor == nil {
                    dragAnchor = (start, end, v.startLocation.x)
                }
                guard let a = dragAnchor else { return }
                let dxPct = Double((v.location.x - a.startX) / max(w, 1))
                let deltaSec = dxPct * windowDuration
                let length = max(a.endS - a.startS, minSelection)
                var newStart = a.startS + deltaSec
                newStart = min(max(newStart, 0), safeDuration - length)
                start = newStart
                end = newStart + length
            }
            .onEnded { _ in dragAnchor = nil }
    }

    // MARK: Thumbnails

    @MainActor
    private func loadThumbnails() async {
        guard let url = previewURL, safeDuration > 0 else { thumbnails = []; return }
        let lower = windowStart, span = windowDuration
        let key = "\(url.absoluteString)|\(lower)|\(span)"
        if let cached = FilmstripCache.shared.get(key) { thumbnails = cached; return }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 90)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
        let times = (0..<24).map { lower + span * (Double($0) + 0.5) / 24 }
        var images: [TimedThumbnail] = times.map { TimedThumbnail(time: $0, image: nil) }
        thumbnails = images
        for index in times.indices.sorted(by: { abs(times[$0] - currentTime) < abs(times[$1] - currentTime) }) {
            guard !Task.isCancelled else { generator.cancelAllCGImageGeneration(); return }
            let result = try? await generator.image(at: CMTime(seconds: times[index], preferredTimescale: 600))
            guard !Task.isCancelled else { generator.cancelAllCGImageGeneration(); return }
            images[index] = TimedThumbnail(time: times[index], image: result.map { NSImage(cgImage: $0.image, size: .zero) })
            thumbnails = images
        }
        FilmstripCache.shared.set(key, images)
    }
}

// MARK: - Scroll-wheel / middle-click catcher

struct FilmstripScrollCatcher: NSViewRepresentable {
    let onScroll: (CGFloat, CGFloat, NSEvent.ModifierFlags) -> Void
    let onMiddleClick: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = _ScrollCatcherView()
        v.onScroll = onScroll
        v.onMiddleClick = onMiddleClick
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        if let v = nsView as? _ScrollCatcherView {
            v.onScroll = onScroll
            v.onMiddleClick = onMiddleClick
        }
    }
}

private final class _ScrollCatcherView: NSView {
    var onScroll: ((CGFloat, CGFloat, NSEvent.ModifierFlags) -> Void)?
    var onMiddleClick: ((CGFloat) -> Void)?
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .otherMouseDown]) { [weak self] ev in
            guard let self, let win = self.window, ev.window === win else { return ev }
            let inView = self.convert(ev.locationInWindow, from: nil)
            guard self.bounds.contains(inView) else { return ev }
            if ev.type == .scrollWheel {
                self.onScroll?(ev.scrollingDeltaX, ev.scrollingDeltaY, ev.modifierFlags)
                return nil
            } else if ev.type == .otherMouseDown {
                self.onMiddleClick?(inView.x)
                return nil
            }
            return ev
        }
    }

    deinit {
        if let m = monitor { NSEvent.removeMonitor(m) }
    }
}

// MARK: - Time entry field

struct TimeField: View {
    let label: String
    @Binding var seconds: Double
    let min: Double
    let max: Double
    @Binding var invalid: Bool
    @State private var text = "00:00:00.000"
    @State private var error: String?
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(label).font(H3.body(size: 11, weight: .semibold)).foregroundStyle(H3.ink500)
                TextField("00:00:00.000", text: $text).textFieldStyle(.roundedBorder)
                    .font(H3.mono(size: 12)).frame(width: 126).focused($focused)
                    .onSubmit(commit)
                    .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
                    .onChange(of: text) { _, value in
                        if focused {
                            invalid = MediaTime.parse(value).map { $0 < min || $0 > max } ?? true
                            error = invalid ? "Enter a time from \(MediaTime.format(min)) to \(MediaTime.format(max))." : nil
                        }
                    }
                    .onChange(of: seconds) { _, value in if !focused { text = MediaTime.format(value) } }
                    .onAppear { text = MediaTime.format(seconds) }
            }
            if let error { Text(error).font(.caption2).foregroundStyle(H3.red) }
        }
    }
    private func commit() {
        guard let parsed = MediaTime.parse(text), parsed >= min, parsed <= max else {
            error = "Enter a time from \(MediaTime.format(min)) to \(MediaTime.format(max))."; invalid = true; return
        }
        seconds = parsed; text = MediaTime.format(seconds); error = nil; invalid = false
    }
}
