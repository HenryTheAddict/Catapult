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

    private var trimDuration: Double {
        Self.cleanSeconds(duration, fallback: 0)
    }

    private var selectionIsValid: Bool {
        let start = Self.cleanSeconds(startSeconds, fallback: -1)
        let end = Self.cleanSeconds(endSeconds, fallback: -1)
        return trimDuration > 0 && end > start
    }

    var body: some View {
        ZStack {
            // h3 sky background — adapts to dark mode automatically.
            H3SkyBackground()

            VStack(spacing: 0) {
                header
                if loadingInfo {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.large)
                        Text("fetching video info…")
                            .font(H3.body(size: 13))
                            .foregroundStyle(H3.ink500)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = loadError {
                    errorView(err)
                } else {
                    content
                }
            }
        }
        .frame(width: 620, height: 580)
        .background(EscKeyCatcher { NSApp.keyWindow?.close() })
        .h3WindowChrome()
        .task(id: url) {
            guard !url.isEmpty else { return }
            await loadInfo()
        }
        .task(id: previewURL) { configurePlayer() }
        .onDisappear { teardownPlayer() }
        .onAppear {
            FontLoader.registerBundled()
            let pending = CutCoordinator.shared.pendingURL
            let picked = ClipboardMonitor.firstDownloadURL(in: pending)
                ?? pending.trimmingCharacters(in: .whitespacesAndNewlines)
            if picked != url { url = picked }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            // Tiny gradient glyph instead of plain SF symbol — feels h3.
            GradientGlyph(systemName: "scissors", gradient: H3.gradDeep, size: 22)
            Text("trim & download")
                .font(H3.display(size: 22, weight: .medium))
                .foregroundStyle(H3.ink900)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(H3.orange).font(.largeTitle)
            Text("couldn't load video")
                .font(H3.display(size: 20, weight: .medium))
                .foregroundStyle(H3.ink900)
            Text(msg)
                .font(H3.body(size: 12))
                .foregroundStyle(H3.ink500)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            H3Button(gradient: H3.gradDeep) {
                Task { await loadInfo() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                    Text("retry")
                }
            }
            .fixedSize()
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
                    Text(title)
                        .font(H3.body(size: 14, weight: .semibold))
                        .foregroundStyle(H3.ink900)
                        .lineLimit(1).truncationMode(.tail)
                    if !uploader.isEmpty {
                        Text(uploader.lowercased())
                            .font(H3.body(size: 12))
                            .foregroundStyle(H3.ink500)
                    }
                }
                Spacer()
                Text(formatTime(trimDuration))
                    .font(H3.mono(size: 12, weight: .semibold))
                    .foregroundStyle(H3.ink500)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(
                        Capsule().fill(H3.cardFill)
                    )
                    .overlay(Capsule().stroke(H3.cardStroke, lineWidth: 1))
            }

            trimControls

            HStack(spacing: 10) {
                Toggle(isOn: $asAudio) {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform")
                            .foregroundStyle(asAudio ? H3.blue400 : H3.ink500)
                        Text("audio only (\(settings.audioFormat.label.lowercased()))")
                            .font(H3.body(size: 13, weight: .medium))
                            .foregroundStyle(H3.ink700)
                    }
                }
                .toggleStyle(.switch)
                .tint(H3.blue400)
                Spacer()
            }

            Spacer(minLength: 4)

            HStack {
                H3Button(gradient: H3.gradDeep, filled: false) {
                    NSApp.keyWindow?.close()
                } label: {
                    Text("cancel")
                }
                .fixedSize()
                .keyboardShortcut(.cancelAction)
                Spacer()
                H3Button(gradient: H3.gradDeep) {
                    startDownload()
                    NSApp.keyWindow?.close()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.to.line")
                        Text(asAudio ? "cut & export audio" : "cut & download")
                    }
                }
                .fixedSize()
                .keyboardShortcut(.defaultAction)
                .opacity(selectionIsValid ? 1 : 0.4)
                .disabled(!selectionIsValid)
            }
        }
        .padding(20)
    }

    // MARK: - Video preview

    @ViewBuilder
    private var videoPreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: H3.radius3, style: .continuous)
                .fill(Color.black)
                .aspectRatio(16/9, contentMode: .fit)

            if let player {
                VideoPlayer(player: player)
                    .aspectRatio(16/9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: H3.radius3, style: .continuous))
            } else if loadingPreview {
                VStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("loading preview…")
                        .font(H3.body(size: 12))
                        .foregroundStyle(.white.opacity(0.8))
                }
            } else if let t = thumbnailURL {
                AsyncImage(url: t) { phase in
                    if let img = phase.image {
                        img.resizable().aspectRatio(contentMode: .fit)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: H3.radius3, style: .continuous))
                VStack(spacing: 4) {
                    if let err = previewError {
                        Text(err.lowercased())
                            .font(H3.body(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(.black.opacity(0.65)))
                    } else {
                        Text("preview unavailable")
                            .font(H3.body(size: 12))
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
        .overlay(
            RoundedRectangle(cornerRadius: H3.radius3, style: .continuous)
                .stroke(H3.cardStroke, lineWidth: 1)
        )
        .shadow(color: H3.shadowDrop.opacity(0.4), radius: 10, y: 4)
    }

    // MARK: - Trim controls

    private var trimControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Selection info row — three monospaced pills.
            HStack(spacing: 8) {
                timePill(formatTime(startSeconds), tint: H3.ink500)
                Spacer()
                timePill("selection · \(formatTime(max(endSeconds - startSeconds, 0)))",
                         tint: H3.blue400, emphatic: true)
                Spacer()
                timePill(formatTime(endSeconds), tint: H3.ink500)
            }

            SafeTrimRangeView(
                start: $startSeconds,
                end: $endSeconds,
                duration: max(trimDuration, 1),
                currentTime: currentTime,
                onScrub: scrub(to:)
            )
            .frame(height: 88)

            HStack(spacing: 8) {
                miniButton("set start", system: "arrow.down.to.line.compact") {
                    if let p = player {
                        startSeconds = min(currentCMTime(from: p), max(endSeconds - 0.25, 0))
                    }
                }
                miniButton("set end", system: "arrow.up.to.line.compact") {
                    if let p = player {
                        endSeconds = max(currentCMTime(from: p), min(startSeconds + 0.25, trimDuration))
                    }
                }
                Spacer()
                TimeField(label: "start", seconds: $startSeconds, max: trimDuration)
                TimeField(label: "end", seconds: $endSeconds, max: trimDuration)
            }
        }
        .onChange(of: startSeconds) { _, _ in clampTrimSelection() }
        .onChange(of: endSeconds) { _, _ in clampTrimSelection() }
    }

    /// h3-style pill for time readouts. emphatic = filled blue chip.
    private func timePill(_ text: String, tint: Color, emphatic: Bool = false) -> some View {
        Text(text)
            .font(H3.mono(size: 11, weight: .semibold))
            .foregroundStyle(emphatic ? Color.white : tint)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(
                Capsule().fill(emphatic
                    ? AnyShapeStyle(H3.gradDeep)
                    : AnyShapeStyle(H3.cardFill))
            )
            .overlay(
                Capsule().stroke(H3.cardStroke, lineWidth: emphatic ? 0 : 1)
            )
    }

    /// Compact h3 chip-button used for the Set Start / Set End row.
    private func miniButton(_ label: String, system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: system)
                Text(label)
            }
            .font(H3.body(size: 11, weight: .semibold))
            .foregroundStyle(H3.blue400)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(
                Capsule().fill(H3.cardFill)
            )
            .overlay(
                Capsule().stroke(H3.blue400.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
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
            currentTime = Self.cleanSeconds(t.seconds, fallback: 0)
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
        let clean = min(max(Self.cleanSeconds(seconds, fallback: 0), 0), max(trimDuration, 0))
        let t = CMTime(seconds: clean, preferredTimescale: 600)
        p.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func currentCMTime(from p: AVPlayer) -> Double {
        let t = p.currentTime().seconds
        return t.isFinite ? max(0, min(t, trimDuration)) : 0
    }

    // MARK: - Info + preview URL loading

    private func loadInfo() async {
        let requestURL = url
        loadingInfo = true
        loadError = nil
        previewError = nil
        previewURL = nil
        thumbnailURL = nil
        teardownPlayer()
        currentTime = 0
        startSeconds = 0
        endSeconds = 0
        let dep = dependencies
        guard FileManager.default.fileExists(atPath: dep.ytDlpPath.path) else {
            loadingInfo = false
            loadError = "yt-dlp is not yet installed."
            return
        }

        var args = ["--dump-single-json", "--no-warnings", "--no-playlist",
                    "--skip-download",
                    "--js-runtimes", "deno",
                    "--js-runtimes", "node",
                    "--js-runtimes", "bun",
                    "--js-runtimes", "quickjs"]
        if SupportedSite.match(url: requestURL) == .youtube {
            args.append(contentsOf: [
                "--extractor-args", "youtube:player_client=default,ios,web_safari,web_embedded,-tv"
            ])
        }
        args.append(contentsOf: await CookieArgs.flags(for: requestURL))
        args.append(requestURL)

        let data: Data? = await run(dep.ytDlpPath, args)

        guard requestURL == url else { return }
        guard let data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            loadingInfo = false
            loadError = "Could not reach this link or parse the response."
            return
        }

        title = obj["title"] as? String ?? url
        uploader = obj["uploader"] as? String ?? ""
        duration = Self.seconds(from: obj["duration"])
        if let s = obj["thumbnail"] as? String, let u = URL(string: s) {
            thumbnailURL = u
        }
        if trimDuration > 0 {
            endSeconds = min(60, trimDuration)
        } else {
            loadError = "This link did not report a usable duration for trimming."
        }
        loadingInfo = false
        if loadError == nil {
            await loadPreviewURL(for: requestURL)
        }
    }

    private func loadPreviewURL(for requestURL: String) async {
        loadingPreview = true
        defer { loadingPreview = false }
        // Progressive mp4 streams play directly in AVPlayer. Ask yt-dlp for
        // the best direct preview URL it can find.
        let formatString = "b[ext=mp4][protocol^=https][vcodec!=none][acodec!=none]/22/18/best"
        var args = [
            "-g", "-f", formatString, "--no-warnings", "--no-playlist",
            "--js-runtimes", "deno",
            "--js-runtimes", "node",
            "--js-runtimes", "bun",
            "--js-runtimes", "quickjs"
        ]
        if SupportedSite.match(url: requestURL) == .youtube {
            args.append(contentsOf: [
                "--extractor-args", "youtube:player_client=default,ios,web_safari,web_embedded,-tv"
            ])
        }
        args.append(contentsOf: await CookieArgs.flags(for: requestURL))
        args.append(requestURL)
        guard let data = await run(dependencies.ytDlpPath, args),
              let out = String(data: data, encoding: .utf8) else {
            guard requestURL == url else { return }
            previewError = "No playable preview URL"
            return
        }
        guard requestURL == url else { return }
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
                t.environment = DependencyManager.enhancedEnvironment
                let out = Pipe()
                t.standardOutput = out
                t.standardError = Pipe()
                do {
                    try t.run()
                    let d = out.fileHandleForReading.readDataToEndOfFile()
                    t.waitUntilExit()
                    cont.resume(returning: t.terminationStatus == 0 && !d.isEmpty ? d : nil)
                } catch {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private func startDownload() {
        clampTrimSelection()
        guard selectionIsValid else { return }
        DownloadManager.shared.enqueue(
            url: url,
            mode: asAudio ? .audio : .cut,
            cutStart: Self.cleanSeconds(startSeconds, fallback: 0),
            cutEnd: Self.cleanSeconds(endSeconds, fallback: trimDuration)
        )
    }

    private func formatTime(_ t: Double) -> String {
        let total = Int(Self.cleanSeconds(t, fallback: 0))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    private func clampTrimSelection() {
        let limit = trimDuration
        guard limit > 0 else {
            if startSeconds != 0 { startSeconds = 0 }
            if endSeconds != 0 { endSeconds = 0 }
            return
        }
        let minGap = min(0.25, limit)
        var start = min(max(Self.cleanSeconds(startSeconds, fallback: 0), 0), limit)
        var end = min(max(Self.cleanSeconds(endSeconds, fallback: min(60, limit)), 0), limit)
        if end - start < minGap {
            if start + minGap <= limit {
                end = start + minGap
            } else {
                start = max(0, end - minGap)
            }
        }
        if abs(start - startSeconds) > 0.001 { startSeconds = start }
        if abs(end - endSeconds) > 0.001 { endSeconds = end }
    }

    private static func seconds(from value: Any?) -> Double {
        switch value {
        case let double as Double:
            return cleanSeconds(double, fallback: 0)
        case let int as Int:
            return cleanSeconds(Double(int), fallback: 0)
        case let number as NSNumber:
            return cleanSeconds(number.doubleValue, fallback: 0)
        default:
            return 0
        }
    }

    private static func cleanSeconds(_ value: Double, fallback: Double) -> Double {
        value.isFinite && value >= 0 ? value : fallback
    }
}

// MARK: - Safe trim range

struct SafeTrimRangeView: View {
    @Binding var start: Double
    @Binding var end: Double
    let duration: Double
    let currentTime: Double
    let onScrub: (Double) -> Void

    @State private var dragAnchor: (start: Double, end: Double, x: CGFloat)?

    private let minSelection: Double = 0.25
    private let handleWidth: CGFloat = 18
    private var safeDuration: Double {
        duration.isFinite && duration > 0 ? duration : 0
    }

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width.isFinite ? geo.size.width : 1, 1)
            let height = geo.size.height.isFinite ? geo.size.height : 88
            let trackHeight: CGFloat = 18
            let trackY = (height - trackHeight) / 2
            let startX = xPosition(for: start, width: width)
            let endX = xPosition(for: end, width: width)
            let playheadX = xPosition(for: currentTime, width: width)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: H3.radius2, style: .continuous)
                    .fill(H3.cardFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: H3.radius2, style: .continuous)
                            .stroke(H3.cardStroke, lineWidth: 1)
                    )

                ForEach(0..<7, id: \.self) { index in
                    let x = width * CGFloat(index) / 6.0
                    Rectangle()
                        .fill(H3.ink300.opacity(0.28))
                        .frame(width: 1, height: index == 0 || index == 6 ? 30 : 20)
                        .offset(x: x, y: (height - (index == 0 || index == 6 ? 30 : 20)) / 2)
                }

                Capsule()
                    .fill(H3.ink100)
                    .frame(height: trackHeight)
                    .padding(.horizontal, handleWidth / 2)
                    .offset(y: trackY)

                Capsule()
                    .fill(H3.gradDeep)
                    .frame(width: max(endX - startX, 0), height: trackHeight)
                    .offset(x: startX, y: trackY)
                    .shadow(color: H3.blue400.opacity(0.22), radius: 5, y: 2)
                    .gesture(selectionDrag(width: width))

                if currentTime.isFinite, currentTime >= 0, currentTime <= safeDuration {
                    VStack(spacing: 4) {
                        Text(formatTime(currentTime))
                            .font(H3.mono(size: 10, weight: .semibold))
                            .foregroundStyle(H3.ink900)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(H3.cardFill))
                            .overlay(Capsule().stroke(H3.cardStroke, lineWidth: 1))
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: 2, height: 44)
                            .shadow(color: .black.opacity(0.28), radius: 2)
                    }
                    .offset(x: playheadX - 24, y: 6)
                    .allowsHitTesting(false)
                }

                trimHandle(systemName: "chevron.left")
                    .offset(x: startX - handleWidth / 2, y: (height - 50) / 2)
                    .gesture(handleDrag(isStart: true, width: width))

                trimHandle(systemName: "chevron.right")
                    .offset(x: endX - handleWidth / 2, y: (height - 50) / 2)
                    .gesture(handleDrag(isStart: false, width: width))
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                onScrub(seconds(for: location.x, width: width))
            }
            .animation(H3.appleSnap, value: start)
            .animation(H3.appleSnap, value: end)
        }
    }

    private func trimHandle(systemName: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(H3.cardFill)
                .frame(width: handleWidth, height: 50)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(H3.blue400.opacity(0.55), lineWidth: 1.5)
                )
                .shadow(color: H3.shadowDrop.opacity(0.18), radius: 6, y: 3)
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(H3.blue400)
        }
        .contentShape(Rectangle())
    }

    private func handleDrag(isStart: Bool, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let target = seconds(for: value.location.x, width: width)
                let gap = min(minSelection, max(safeDuration, 0))
                if isStart {
                    start = min(max(target, 0), max(end - gap, 0))
                    onScrub(start)
                } else {
                    end = max(min(target, safeDuration), min(start + gap, safeDuration))
                    onScrub(end)
                }
            }
    }

    private func selectionDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragAnchor == nil {
                    dragAnchor = (start, end, value.startLocation.x)
                }
                guard let anchor = dragAnchor else { return }
                let delta = seconds(for: value.location.x, width: width)
                    - seconds(for: anchor.x, width: width)
                let length = max(anchor.end - anchor.start, minSelection)
                let newStart = min(max(anchor.start + delta, 0), max(safeDuration - length, 0))
                start = newStart
                end = newStart + length
            }
            .onEnded { _ in dragAnchor = nil }
    }

    private func xPosition(for seconds: Double, width: CGFloat) -> CGFloat {
        guard safeDuration > 0, seconds.isFinite, width.isFinite else { return 0 }
        let clamped = min(max(seconds, 0), safeDuration)
        let usableWidth = max(width - handleWidth, 1)
        return handleWidth / 2 + usableWidth * CGFloat(clamped / safeDuration)
    }

    private func seconds(for x: CGFloat, width: CGFloat) -> Double {
        guard safeDuration > 0, x.isFinite, width.isFinite else { return 0 }
        let usableWidth = max(width - handleWidth, 1)
        let adjustedX = min(max(x - handleWidth / 2, 0), usableWidth)
        let pct = Double(adjustedX / usableWidth)
        return pct * safeDuration
    }

    private func formatTime(_ t: Double) -> String {
        let total = Int(t.isFinite && t >= 0 ? t : 0)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - iOS Photos-style filmstrip trim

/// Thumbnail cache keyed by preview URL → array of (time, image).
@MainActor
final class FilmstripCache {
    static let shared = FilmstripCache()
    private let maxEntries = 2
    private var cache: [URL: [NSImage]] = [:]
    private var order: [URL] = []

    func get(_ u: URL) -> [NSImage]? {
        guard let images = cache[u] else { return nil }
        order.removeAll { $0 == u }
        order.append(u)
        return images
    }

    func set(_ u: URL, _ imgs: [NSImage]) {
        cache[u] = imgs
        order.removeAll { $0 == u }
        order.append(u)
        while order.count > maxEntries, let evicted = order.first {
            order.removeFirst()
            cache.removeValue(forKey: evicted)
        }
    }
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

    private var safeDuration: Double {
        duration.isFinite && duration > 0 ? duration : minSelection
    }

    private var safeZoom: Double {
        zoom.isFinite && zoom >= 1 ? zoom : 1
    }

    // Windowed view around selection midpoint when zoomed.
    private var windowDuration: Double { max(safeDuration / safeZoom, minSelection) }
    private var windowStart: Double {
        let mid = (start + end) / 2
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
                            let panFraction = Double(dx) / Double(max(w, 1))
                            let deltaSec = panFraction * windowDuration
                            let length = max(end - start, minSelection)
                            let newStart = max(0, min(start + deltaSec, safeDuration - length))
                            start = newStart
                            end = newStart + length
                        } else if horizontal {
                            let frac = Double(dx) / Double(max(w, 1))
                            let delta = frac * windowDuration
                            let t = min(max(currentTime + delta, 0), safeDuration)
                            onScrub(t)
                        } else {
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
                    Capsule().fill(Color.white)
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
                    let idx = min(max(Int((t / max(safeDuration, 0.001)) * Double(count)), 0), count - 1)
                    Image(nsImage: thumbnails[idx])
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                }
            }
        }
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
        DragGesture(minimumDistance: 0).onChanged { v in
            let sec = secondsFor(v.location.x, w)
            if isStart { start = min(max(sec, 0), end - minSelection) }
            else       { end   = min(max(sec, start + minSelection), safeDuration) }
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
        guard let u = previewURL, safeDuration > 0 else { return }
        if let cached = FilmstripCache.shared.get(u) {
            thumbnails = cached
            return
        }
        guard !loadingThumbs else { return }
        loadingThumbs = true
        defer { loadingThumbs = false }

        let totalDuration = safeDuration
        let images: [NSImage] = await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: u)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 160, height: 90)
            gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
            gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

            let steps = 36
            var out: [NSImage] = []
            out.reserveCapacity(steps)
            for i in 0..<steps {
                if Task.isCancelled { return [] }
                let seconds = totalDuration * Double(i) / Double(max(steps - 1, 1))
                let time = CMTime(seconds: seconds, preferredTimescale: 600)
                let cg = await withCheckedContinuation { continuation in
                    gen.generateCGImageAsynchronously(for: time) { image, _, _ in
                        continuation.resume(returning: image)
                    }
                }
                guard let cg else { continue }
                out.append(NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
            }
            return out
        }.value

        guard !Task.isCancelled else { return }
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
            Text(label)
                .font(H3.body(size: 11, weight: .semibold))
                .foregroundStyle(H3.ink500)
            TextField("", text: $text, onCommit: commit)
                .textFieldStyle(.plain)
                .font(H3.mono(size: 12, weight: .semibold))
                .foregroundStyle(H3.ink900)
                .multilineTextAlignment(.center)
                .frame(width: 80)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: H3.radius1, style: .continuous)
                        .fill(H3.cardFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: H3.radius1, style: .continuous)
                        .stroke(H3.cardStroke, lineWidth: 1)
                )
                .onAppear { text = format(seconds) }
                .onChange(of: seconds) { _, new in text = format(new) }
        }
    }

    private func commit() {
        if let parsed = parse(text) {
            let limit = max.isFinite && max > 0 ? max : 0
            seconds = min(Swift.max(parsed.isFinite ? parsed : 0, 0), limit)
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
        let clean = t.isFinite && t >= 0 ? t : 0
        let total = Int(clean)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        let frac = Int((clean - Double(total)) * 1000)
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        if frac > 0 { return String(format: "%d:%02d.%03d", m, s, frac) }
        return String(format: "%d:%02d", m, s)
    }
}
