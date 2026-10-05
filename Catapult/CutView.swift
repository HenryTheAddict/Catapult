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
    @State private var showLinkEntry = false
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
    @State private var playbackRequested = false
    @State private var timelineEditing = false
    @State private var timelineControlFocused = false
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
            editorHeader
            Divider()
            if showLinkEntry || (source.isOnline && duration == 0) { linkEntry.padding(.horizontal, 20).padding(.top, 12) }
            if let loadError { notice(loadError, symbol: "exclamationmark.triangle") }
            if let cookieWarning { notice(cookieWarning, symbol: "key.slash") }
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 12) {
                    preview.frame(minHeight: 160, maxHeight: .infinity)
                    transport
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                inspector.frame(width: 228).frame(maxHeight: .infinity)
            }.padding(16).frame(minHeight: 200, maxHeight: .infinity)
            Divider()
            timeline.padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
                .background(H3.cardFill.opacity(0.45))
            Divider()
            footer.padding(.horizontal, 20).padding(.vertical, 12)
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
    private var editorHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "scissors").font(.system(size: 16, weight: .medium)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(duration > 0 ? title : "Trim media").font(H3.body(size: 15, weight: .semibold)).lineLimit(1)
                Text(duration > 0 ? sourceDetails : "Choose a file or paste a link")
                    .font(H3.body(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }.layoutPriority(1)
            Spacer(minLength: 16)
            Button { showLinkEntry.toggle() } label: { Image(systemName: "link") }
                .help(showLinkEntry ? "Hide link entry" : "Load a media link")
                .accessibilityLabel("Load a media link")
            Button("Open file", systemImage: "folder", action: openFile)
        }.buttonStyle(TrimControlStyle()).disabled(busy)
            .padding(.horizontal, 20).padding(.vertical, 12)
    }
    private var sourceDetails: String {
        let kind = source.isOnline ? "Online source" : "Local file"
        let length = String(MediaTime.format(duration).dropLast(4))
        return [kind, length, uploader.isEmpty ? nil : uploader].compactMap { $0 }.joined(separator: " · ")
    }
    private var linkEntry: some View {
        HStack(spacing: 10) {
            Image(systemName: "link").foregroundStyle(.secondary)
            TextField("Paste a video link", text: $link).textFieldStyle(.roundedBorder).onSubmit(loadLink)
            Button("Load", action: loadLink).disabled(busy || link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if loading { ProgressView().controlSize(.small) }
        }.disabled(busy)
    }
    private func notice(_ message: String, symbol: String) -> some View {
        Label(message, systemImage: symbol).font(H3.body(size: 11)).foregroundStyle(H3.orange)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.top, 8)
    }
    private var timeline: some View {
        TrimTimelineView(start: startBinding, end: endBinding, zoom: $zoom,
                         center: $timelineCenter, duration: duration, currentTime: currentTime,
                         frameStep: frameStep, previewURL: previewURL,
                         onScrub: { seek($0, precise: false) }, onScrubEnd: { seek($0, precise: true) },
                         onMoveSelection: { setRange(start: $0.start, end: $0.end) },
                         onInteractionBegin: beginTimelineEdit, onInteractionEnd: endTimelineEdit,
                         onControlFocus: { timelineControlFocused = $0 })
            .id(source).disabled(busy || duration <= 0)
    }
    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Clip range").font(H3.body(size: 12, weight: .semibold))
                        Spacer()
                        Button { setRange(start: 0, end: duration); zoom = 1; timelineCenter = duration / 2 } label: { Image(systemName: "arrow.counterclockwise") }
                            .buttonStyle(TrimControlStyle()).help("Reset to the full source")
                            .accessibilityLabel("Reset clip range")
                    }
                    boundaryField(isStart: true)
                    boundaryField(isStart: false)
                    HStack {
                        Text("Duration").foregroundStyle(.secondary)
                        Spacer()
                        Text(MediaTime.format(max(0, endSeconds - startSeconds))).font(H3.mono(size: 11))
                    }.font(H3.body(size: 11)).padding(.top, 2)
                }.disabled(busy || duration <= 0)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Output").font(H3.body(size: 12, weight: .semibold))
                        Spacer(minLength: 8)
                        Picker("Output", selection: $asAudio) { Text("Video").tag(false); Text("Audio").tag(true) }
                            .labelsHidden().pickerStyle(.segmented)
                    }
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Format").font(H3.body(size: 11)).foregroundStyle(.secondary)
                            if asAudio {
                                Picker("Format", selection: $audioFormat) { ForEach(AudioFormat.allCases) { Text($0.label).tag($0) } }
                                    .labelsHidden()
                            } else {
                                Picker("Format", selection: $videoContainer) { ForEach(VideoContainer.allCases) { Text($0.label).tag($0) } }
                                    .labelsHidden()
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        if !asAudio {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Quality").font(H3.body(size: 11)).foregroundStyle(.secondary)
                                Picker("Quality", selection: $videoQuality) { ForEach(VideoQuality.allCases) { Text($0.label).tag($0) } }
                                    .labelsHidden().disabled(accuracy == .fast)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Picker("Cut method", selection: $accuracy) {
                        Text("Accurate").tag(ClipAccuracy.accurate); Text("Fast").tag(ClipAccuracy.fast)
                    }.labelsHidden().pickerStyle(.segmented)
                    Text(accuracy == .accurate ? "Precise boundaries. Re-encodes the clip." : "Copies at nearby keyframes. Boundaries may shift; quality settings do not apply.")
                        .font(H3.body(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.disabled(busy)
            }.padding(12)
        }.scrollIndicators(.hidden)
            .background(H3.cardFill, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(H3.cardStroke, lineWidth: 0.5))
    }
    private func boundaryField(isStart: Bool) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            TimeField(label: isStart ? "Start" : "End",
                      seconds: Binding(get: { isStart ? startSeconds : endSeconds }, set: {
                if isStart { setRange(start: $0, end: endSeconds) } else { setRange(start: startSeconds, end: $0) }
            }), min: isStart ? 0 : startSeconds + min(0.25, duration),
                      max: isStart ? max(0, endSeconds - min(0.25, duration)) : duration,
                      invalid: isStart ? $startInputInvalid : $endInputInvalid)
            Spacer(minLength: 0)
            Button {
                if isStart { startBinding.wrappedValue = currentTime } else { endBinding.wrappedValue = currentTime }
            } label: { Image(systemName: isStart ? "i.square" : "o.square") }
                .buttonStyle(TrimControlStyle())
                .help(isStart ? "Set start at playhead (I)" : "Set end at playhead (O)")
                .accessibilityLabel(isStart ? "Set start" : "Set end")
        }
    }
    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color.black)
            if let player { TrimPlaybackSurface(player: player) }
            else if let thumbnailURL { AsyncImage(url: thumbnailURL) { $0.resizable().scaledToFit() } placeholder: { ProgressView() } }
            else {
                VStack(spacing: 12) {
                    Image(systemName: asAudio ? "waveform" : "play.rectangle").font(.system(size: 30, weight: .light))
                    Text(loading ? "Loading preview…" : "Drop media here").font(H3.body(size: 13, weight: .medium))
                }.foregroundStyle(.white.opacity(0.5))
            }
            if loading { ProgressView().tint(.white) }
            if let previewError {
                Text(previewError).font(H3.body(size: 12)).foregroundStyle(.white)
                    .padding(10).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 8)).frame(maxHeight: .infinity, alignment: .bottom).padding(10)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).clipShape(RoundedRectangle(cornerRadius: 10))
    }
    private var transport: some View {
        HStack(spacing: 4) {
            Text(MediaTime.format(currentTime)).font(H3.mono(size: 11)).foregroundStyle(.secondary)
                .frame(width: 102, alignment: .leading)
            Spacer(minLength: 4)
            Button { seek(startSeconds, precise: true) } label: { Image(systemName: "backward.end.fill") }.help("Jump to clip start")
            Button(action: togglePlayback) { Image(systemName: isPlaying ? "pause.fill" : "play.fill").frame(width: 14) }
                .help("Play / pause (Space)").accessibilityLabel(isPlaying ? "Pause" : "Play")
            Button { seek(endSeconds, precise: true) } label: { Image(systemName: "forward.end.fill") }.help("Jump to clip end")
            Spacer(minLength: 4)
            Button { loopSelection.toggle() } label: {
                Image(systemName: "repeat").foregroundStyle(loopSelection ? H3.ink900 : H3.ink300)
            }.help("Loop clip").accessibilityLabel("Loop clip").accessibilityValue(loopSelection ? "On" : "Off")
            Button { muted.toggle(); player?.isMuted = muted } label: { Image(systemName: muted ? "speaker.slash" : "speaker.wave.2") }
                .help("Mute preview").accessibilityLabel(muted ? "Unmute" : "Mute")
        }.buttonStyle(TrimControlStyle()).disabled(player == nil || busy)
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
            } else { Text("Save as a separate clip").font(H3.body(size: 11)).foregroundStyle(.secondary) }
            Spacer()
            Button("Export clip", systemImage: "arrow.down.to.line", action: export)
                .buttonStyle(.borderedProminent).controlSize(.large).fixedSize()
                .disabled(!selectionIsValid || busy || loading)
                .help("Save a separate clip (⌘ Return)")
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
        guard !timelineEditing else { return }
        historyTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            rememberRange()
        }
    }
    private func beginTimelineEdit() {
        historyTask?.cancel(); rememberRange(); timelineEditing = true
        playbackRequested = false; player?.pause(); isPlaying = false
    }
    private func endTimelineEdit() {
        timelineEditing = false; rememberRange()
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
        if timelineControlFocused && (key == "left" || key == "right") { return false }
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
        if playbackRequested { playbackRequested = false; player.pause(); isPlaying = false }
        else {
            playbackRequested = true
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
        playbackRequested = false; timelineEditing = false; timelineControlFocused = false
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
                if loopSelection && playbackRequested { restartSelection(player, generation: generation) }
                else { isPlaying = false; playbackRequested = false }
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { time in
            if seekTask == nil { currentTime = max(0, time.seconds.isFinite ? time.seconds : 0) }
            isPlaying = player.rate > 0
            if loopSelection && player.rate > 0 && currentTime >= endSeconds { restartSelection(player, generation: generation) }
        }
    }
    private func restartSelection(_ playback: AVPlayer, generation: UUID) {
        guard !restartingLoop, playbackRequested else { return }
        restartingLoop = true
        Task { @MainActor in
            await playback.seek(to: CMTime(seconds: startSeconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            guard loadID == generation, player === playback else { return }
            restartingLoop = false
            if playbackRequested { playback.play() }
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
        playbackRequested = false; player?.pause(); isPlaying = false
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
            HStack(spacing: 6) { fieldLabel; entry }
            if let error { Text(error).font(.caption2).foregroundStyle(H3.red) }
        }
    }
    private var fieldLabel: some View {
        Text(label).font(H3.body(size: 11)).foregroundStyle(.secondary).frame(width: 32, alignment: .leading)
    }
    private var entry: some View {
        TextField("00:00:00.000", text: $text).textFieldStyle(.roundedBorder)
            .font(H3.mono(size: 12)).frame(width: 126).focused($focused)
            .accessibilityLabel(label)
            .onSubmit(commit)
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            .onChange(of: text) { _, value in
                if focused {
                    invalid = MediaTime.parse(value).map { $0 < min || $0 > max } ?? true
                    error = invalid ? "Enter a time from \(MediaTime.format(min)) to \(MediaTime.format(max))." : nil
                }
            }
            .onChange(of: seconds) { _, value in
                if !focused { text = MediaTime.format(value); invalid = false; error = nil }
            }
            .onAppear { text = MediaTime.format(seconds) }
    }
    private func commit() {
        guard let parsed = MediaTime.parse(text), parsed >= min, parsed <= max else {
            error = "Enter a time from \(MediaTime.format(min)) to \(MediaTime.format(max))."; invalid = true; return
        }
        seconds = parsed; text = MediaTime.format(seconds); error = nil; invalid = false
    }
}
