import SwiftUI
import AppKit
import AVKit
import AVFoundation
import Observation

/// Pass a URL through the global-window mechanism (MenuBarExtra can't hand it directly).
@Observable
final class CutCoordinator {
    static let shared = CutCoordinator()
    var pendingURL: String = ""
    private init() {}
}

struct CutWindowHost: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(DependencyManager.self) private var dependencies
    @Environment(AppSettings.self) private var settings

    @State private var url: String = ""
    @State private var title: String = ""
    @State private var uploader: String = ""
    @State private var duration: Double = 0
    @State private var thumbnailURL: URL?
    @State private var loadingInfo = true
    @State private var loadError: String?

    @State private var startSeconds: Double = 0
    @State private var endSeconds: Double = 60
    @State private var asAudio: Bool = false

    @State private var previewURL: URL?
    @State private var loadingPreview = false
    @State private var previewError: String?
    @State private var player: AVPlayer?
    @State private var currentTime: Double = 0
    @State private var isPlaying = false
    @State private var timeObserver: Any?

    @State private var zoom: Double = 1.0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if loadingInfo {
                ProgressView("Fetching video info…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = loadError {
                errorView(err)
            } else {
                content
            }
        }
        .frame(width: 620, height: 560)
        .background(.regularMaterial)
        .background(EscKeyCatcher { NSApp.keyWindow?.close() })
        .task(id: url) {
            guard !url.isEmpty else { return }
            await loadInfo()
        }
        .task(id: previewURL) { configurePlayer() }
        .onDisappear { teardownPlayer() }
        .onAppear {
            let pending = CutCoordinator.shared.pendingURL
            if pending != url { url = pending }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "scissors")
                .font(.title3)
                .foregroundStyle(.orange)
            Text("Trim & Download")
                .font(.system(.title3, design: .rounded).weight(.semibold))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red).font(.largeTitle)
            Text("Couldn't load video").font(.headline)
            Text(msg).font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("Retry") { Task { await loadInfo() } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Main content

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            videoPreview

            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).lineLimit(1).truncationMode(.tail)
                    if !uploader.isEmpty {
                        Text(uploader).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(formatTime(duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            trimControls

            HStack {
                Toggle("Audio only (\(settings.audioFormat.label))", isOn: $asAudio)
                Spacer()
                Text("Selection: \(formatTime(max(endSeconds - startSeconds, 0)))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack {
                Button("Cancel", role: .cancel) { NSApp.keyWindow?.close() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    startDownload()
                    NSApp.keyWindow?.close()
                } label: {
                    Label(asAudio ? "Cut & Export Audio" : "Cut & Download",
                          systemImage: "arrow.down.to.line")
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(endSeconds <= startSeconds)
            }
        }
        .padding(16)
    }

    // MARK: - Video preview

    @ViewBuilder
    private var videoPreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black)
                .aspectRatio(16/9, contentMode: .fit)

            if let player {
                VideoPlayer(player: player)
                    .aspectRatio(16/9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else if loadingPreview {
                VStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading preview…").font(.caption).foregroundStyle(.white.opacity(0.8))
                }
            } else if let t = thumbnailURL {
                AsyncImage(url: t) { phase in
                    if let img = phase.image {
                        img.resizable().aspectRatio(contentMode: .fit)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(spacing: 4) {
                    if let err = previewError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.6)))
                    } else {
                        Text("Preview unavailable")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
            } else {
                Image(systemName: "play.rectangle")
                    .font(.system(size: 40))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .aspectRatio(16/9, contentMode: .fit)
    }

    // MARK: - Trim controls

    private var trimControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(formatTime(startSeconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Selection · \(formatTime(max(endSeconds - startSeconds, 0)))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.primary)
                Spacer()
                Text(formatTime(endSeconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            FilmstripTrimView(
                start: $startSeconds,
                end: $endSeconds,
                zoom: $zoom,
                duration: max(duration, 1),
                currentTime: currentTime,
                previewURL: previewURL,
                onScrub: scrub(to:)
            )
            .frame(height: 72)

            HStack(spacing: 8) {
                Button {
                    if let p = player { startSeconds = currentCMTime(from: p) }
                } label: { Label("Set Start", systemImage: "arrow.down.to.line.compact") }
                    .controlSize(.small)
                Button {
                    if let p = player { endSeconds = currentCMTime(from: p) }
                } label: { Label("Set End", systemImage: "arrow.up.to.line.compact") }
                    .controlSize(.small)
                Spacer()
                if zoom > 1.01 {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { zoom = 1 }
                    } label: { Label("Reset zoom", systemImage: "arrow.counterclockwise") }
                        .controlSize(.small)
                }
                TimeField(label: "Start", seconds: $startSeconds, max: duration)
                TimeField(label: "End", seconds: $endSeconds, max: duration)
            }
        }
    }

    // MARK: - Player

    private func configurePlayer() {
        teardownPlayer()
        guard let u = previewURL else { return }
        let asset = AVURLAsset(url: u)
        let item = AVPlayerItem(asset: asset)
        let p = AVPlayer(playerItem: item)
        p.isMuted = false
        self.player = p
        let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
        self.timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { t in
            currentTime = t.seconds
        }
    }

    private func teardownPlayer() {
        if let o = timeObserver, let p = player {
            p.removeTimeObserver(o)
        }
        timeObserver = nil
        player?.pause()
        player = nil
    }

    private func scrub(to seconds: Double) {
        guard let p = player else { return }
        let t = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        p.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func currentCMTime(from p: AVPlayer) -> Double {
        let t = p.currentTime().seconds
        return t.isFinite ? max(0, min(t, duration)) : 0
    }

    // MARK: - Info + preview URL loading

    private func loadInfo() async {
        loadingInfo = true
        loadError = nil
        let dep = dependencies
        guard FileManager.default.fileExists(atPath: dep.ytDlpPath.path) else {
            loadingInfo = false
            loadError = "yt-dlp is not yet installed."
            return
        }

        let args = ["--dump-single-json", "--no-warnings", "--no-playlist",
                    "--skip-download", url]

        let data: Data? = await run(dep.ytDlpPath, args)

        guard let data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            loadingInfo = false
            loadError = "Could not reach YouTube or parse the response."
            return
        }

        title = obj["title"] as? String ?? url
        uploader = obj["uploader"] as? String ?? ""
        duration = obj["duration"] as? Double ?? 0
        if let s = obj["thumbnail"] as? String, let u = URL(string: s) {
            thumbnailURL = u
        }
        if duration > 0 {
            endSeconds = min(60, duration)
        }
        loadingInfo = false
        await loadPreviewURL()
    }

    private func loadPreviewURL() async {
        loadingPreview = true
        defer { loadingPreview = false }
        // YouTube's progressive mp4 (format 22 = 720p, 18 = 360p) plays directly in AVPlayer.
        // Ask yt-dlp for the direct URL.
        let formatString = "b[ext=mp4][protocol^=https][vcodec!=none][acodec!=none]/22/18/best"
        let args = ["-g", "-f", formatString, "--no-warnings", "--no-playlist", url]
        guard let data = await run(dependencies.ytDlpPath, args),
              let out = String(data: data, encoding: .utf8) else {
            previewError = "No playable preview URL"
            return
        }
        let line = out
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .first { !$0.isEmpty }
            .map(String.init) ?? ""
        if let u = URL(string: line) {
            previewURL = u
        } else {
            previewError = "No playable preview URL"
        }
    }

    private func run(_ exe: URL, _ args: [String]) async -> Data? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let t = Process()
                t.executableURL = exe
                t.arguments = args
                let out = Pipe()
                t.standardOutput = out
                t.standardError = Pipe()
                do {
                    try t.run()
                    let d = out.fileHandleForReading.readDataToEndOfFile()
                    t.waitUntilExit()
                    cont.resume(returning: d)
                } catch {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private func startDownload() {
        DownloadManager.shared.enqueue(
            url: url,
            mode: asAudio ? .audio : .cut,
            cutStart: startSeconds,
            cutEnd: endSeconds
        )
    }

    private func formatTime(_ t: Double) -> String {
        let total = Int(t)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - iOS Photos-style filmstrip trim

/// Thumbnail cache keyed by preview URL → array of (time, image).
@MainActor
final class FilmstripCache {
    static let shared = FilmstripCache()
    private var cache: [URL: [NSImage]] = [:]
    func get(_ u: URL) -> [NSImage]? { cache[u] }
    func set(_ u: URL, _ imgs: [NSImage]) { cache[u] = imgs }
}

struct FilmstripTrimView: View {
    @Binding var start: Double
    @Binding var end: Double
    @Binding var zoom: Double
    let duration: Double
    let currentTime: Double
    let previewURL: URL?
    let onScrub: (Double) -> Void

    @State private var thumbnails: [NSImage] = []
    @State private var loadingThumbs = false
    @State private var dragAnchor: (startS: Double, endS: Double, startX: CGFloat)?
    @State private var pinchBase: Double?

    private let handleW: CGFloat = 18
    private let handleOverhang: CGFloat = 8   // how far handles extend above/below the strip
    private let minSelection: Double = 0.1

    // Windowed view around selection midpoint when zoomed.
    private var windowDuration: Double { max(duration / max(zoom, 1), minSelection) }
    private var windowStart: Double {
        let mid = (start + end) / 2
        let half = windowDuration / 2
        let clampedMid = min(max(mid, half), max(duration - half, half))
        return max(0, clampedMid - half)
    }
    private var windowEnd: Double { min(duration, windowStart + windowDuration) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .topLeading) {
                FilmstripScrollCatcher(
                    onScroll: { dx, dy, modifiers in
                        // Horizontal trackpad scroll → scrub the playhead
                        // (and when shift-scrolling, pan the selection).
                        // Vertical scroll → zoom in/out.
                        let horizontal = abs(dx) > abs(dy)
                        if horizontal && modifiers.contains(.shift) {
                            // Shift + horizontal = pan the whole selection
                            let panFraction = Double(dx) / Double(max(w, 1))
                            let deltaSec = panFraction * windowDuration
                            let length = end - start
                            let newStart = max(0, min(start + deltaSec, duration - length))
                            start = newStart
                            end = newStart + length
                        } else if horizontal {
                            // Plain horizontal scroll = scrub playhead,
                            // proportional to visible window (faster when zoomed out).
                            let frac = Double(dx) / Double(max(w, 1))
                            let delta = frac * windowDuration
                            let t = min(max(currentTime + delta, 0), duration)
                            onScrub(t)
                        } else {
                            // Vertical = zoom centered on current window midpoint.
                            let factor = pow(1.10, Double(dy) / 6.0)
                            zoom = min(max(zoom * factor, 1), 50)
                        }
                    },
                    onMiddleClick: { x in
                        let sec = windowStart + Double(x / max(w, 1)) * windowDuration
                        onScrub(sec)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                filmstrip(width: w)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .allowsHitTesting(false)

                // Dim outside selection
                if let sx = xPos(max(start, windowStart), w) {
                    Color.black.opacity(0.55)
                        .frame(width: sx, height: geo.size.height)
                        .allowsHitTesting(false)
                }
                if let ex = xPos(min(end, windowEnd), w) {
                    Color.black.opacity(0.55)
                        .frame(width: max(0, w - ex), height: geo.size.height)
                        .offset(x: ex)
                        .allowsHitTesting(false)
                }

                // iOS-style yellow frame around selection
                if start <= windowEnd && end >= windowStart {
                    let sx = xPos(max(start, windowStart), w) ?? 0
                    let ex = xPos(min(end, windowEnd), w) ?? w
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.yellow, lineWidth: 3)
                        .frame(width: max(ex - sx, 0), height: geo.size.height)
                        .offset(x: sx)
                        .allowsHitTesting(false)
                }

                // Playhead
                if currentTime >= windowStart, currentTime <= windowEnd,
                   let px = xPos(currentTime, w) {
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 2, height: geo.size.height + 4)
                        .offset(x: px - 1, y: -2)
                        .shadow(color: .black.opacity(0.5), radius: 2)
                        .allowsHitTesting(false)
                }

                // Middle drag area — drags entire selection
                if start >= windowStart && end <= windowEnd {
                    let sx = xPos(start, w) ?? 0
                    let ex = xPos(end, w) ?? 0
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .frame(width: max(ex - sx - handleW * 2, 0), height: geo.size.height)
                        .offset(x: sx + handleW)
                        .gesture(selectionDrag(width: w))
                }

                // Left handle
                if start >= windowStart - 0.01 && start <= windowEnd + 0.01,
                   let sx = xPos(start, w) {
                    handle(isStart: true, height: geo.size.height)
                        .offset(x: sx - handleW / 2, y: -handleOverhang)
                        .gesture(handleDrag(isStart: true, width: w))
                }
                // Right handle
                if end >= windowStart - 0.01 && end <= windowEnd + 0.01,
                   let ex = xPos(end, w) {
                    handle(isStart: false, height: geo.size.height)
                        .offset(x: ex - handleW / 2, y: -handleOverhang)
                        .gesture(handleDrag(isStart: false, width: w))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { loc in
                let pct = Double(loc.x / max(w, 1))
                onScrub(windowStart + pct * windowDuration)
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
        .task(id: previewURL) { await loadThumbnails() }
    }

    private func filmstrip(width w: CGFloat) -> some View {
        let slots = max(Int((w / 48).rounded()), 6)
        return HStack(spacing: 0) {
            if thumbnails.isEmpty {
                ForEach(0..<slots, id: \.self) { _ in
                    Rectangle().fill(Color.secondary.opacity(0.25))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(Rectangle().stroke(.black.opacity(0.15), lineWidth: 0.5))
                }
            } else {
                let count = thumbnails.count
                ForEach(0..<slots, id: \.self) { i in
                    // Map this slot's time into the full thumbnail range
                    let t = windowStart + (Double(i) + 0.5) / Double(slots) * windowDuration
                    let idx = min(max(Int((t / max(duration, 0.001)) * Double(count)), 0), count - 1)
                    Image(nsImage: thumbnails[idx])
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                }
            }
        }
    }

    /// Photos-app-style grab handle: a chunky yellow pill that sticks out
    /// above and below the filmstrip, with three grip dots for affordance.
    /// The expanded hit zone (handleW × height+overhang) makes it easy to
    /// grab on a trackpad.
    private func handle(isStart: Bool, height: CGFloat) -> some View {
        let totalHeight = height + handleOverhang * 2
        return ZStack {
            // Outer pill — slightly darker yellow border for contrast
            // against bright filmstrip frames.
            RoundedRectangle(cornerRadius: handleW / 2, style: .continuous)
                .fill(Color.yellow)
                .overlay(
                    RoundedRectangle(cornerRadius: handleW / 2, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.35), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                .frame(width: handleW, height: totalHeight)
            // Three vertical grip dots in the center.
            VStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(Color.black.opacity(0.55))
                        .frame(width: 2.5, height: 2.5)
                }
            }
        }
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
        DragGesture(minimumDistance: 0).onChanged { v in
            let sec = secondsFor(v.location.x, w)
            if isStart { start = min(max(sec, 0), end - minSelection) }
            else       { end   = min(max(sec, start + minSelection), duration) }
        }
    }

    private func selectionDrag(width w: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { v in
                if dragAnchor == nil {
                    dragAnchor = (start, end, v.startLocation.x)
                }
                guard let a = dragAnchor else { return }
                let dxPct = Double((v.location.x - a.startX) / max(w, 1))
                let deltaSec = dxPct * windowDuration
                let length = a.endS - a.startS
                var newStart = a.startS + deltaSec
                newStart = min(max(newStart, 0), duration - length)
                start = newStart
                end = newStart + length
            }
            .onEnded { _ in dragAnchor = nil }
    }

    // MARK: Thumbnails

    private func loadThumbnails() async {
        guard let u = previewURL, duration > 0 else { return }
        if let cached = FilmstripCache.shared.get(u) {
            thumbnails = cached
            return
        }
        guard !loadingThumbs else { return }
        loadingThumbs = true
        defer { loadingThumbs = false }

        let asset = AVURLAsset(url: u)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 160, height: 90)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        let steps = 60
        let times: [NSValue] = (0..<steps).map { i in
            let t = duration * Double(i) / Double(steps - 1)
            return NSValue(time: CMTime(seconds: t, preferredTimescale: 600))
        }

        let images: [NSImage] = await withCheckedContinuation { cont in
            var out: [NSImage] = []
            var done = 0
            gen.generateCGImagesAsynchronously(forTimes: times) { _, cg, _, _, _ in
                done += 1
                if let cg {
                    let ns = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    out.append(ns)
                }
                if done == times.count {
                    cont.resume(returning: out)
                }
            }
        }

        guard !images.isEmpty else { return }
        FilmstripCache.shared.set(u, images)
        thumbnails = images
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
    let max: Double

    @State private var text: String = "0:00"

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField("", text: $text, onCommit: commit)
                .textFieldStyle(.roundedBorder)
                .frame(width: 92)
                .monospacedDigit()
                .onAppear { text = format(seconds) }
                .onChange(of: seconds) { _, new in text = format(new) }
        }
    }

    private func commit() {
        if let parsed = parse(text) {
            seconds = min(Swift.max(parsed, 0), Swift.max(max, parsed))
        }
        text = format(seconds)
    }

    private func parse(_ s: String) -> Double? {
        let parts = s.split(separator: ":").map { String($0) }
        switch parts.count {
        case 1:
            return Double(parts[0])
        case 2:
            guard let m = Double(parts[0]), let sec = Double(parts[1]) else { return nil }
            return m * 60 + sec
        case 3:
            guard let h = Double(parts[0]), let m = Double(parts[1]), let sec = Double(parts[2])
            else { return nil }
            return h * 3600 + m * 60 + sec
        default: return nil
        }
    }

    private func format(_ t: Double) -> String {
        let total = Int(t)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        let frac = Int((t - Double(Int(t))) * 1000)
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        if frac > 0 { return String(format: "%d:%02d.%03d", m, s, frac) }
        return String(format: "%d:%02d", m, s)
    }
}
