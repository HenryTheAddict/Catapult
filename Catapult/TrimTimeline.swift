import SwiftUI
import AppKit
import AVFoundation

/// All timeline positions use the same inset track, including the ruler and pan control.
nonisolated struct TrimTimelineGeometry {
    let duration: Double
    let span: Double
    let lower: Double
    let width: Double
    let inset: Double
    var upper: Double { lower + span }
    var trackWidth: Double { max(1, width - 2 * inset) }
    var midpoint: Double { lower + span / 2 }
    var panLimit: Double { max(0, duration - span) }

    init(duration: Double, zoom: Double, center: Double?, width: Double, inset: Double = 16) {
        self.duration = duration.isFinite && duration > 0 ? duration : 0.25
        self.width = width.isFinite ? max(1, width) : 1
        self.inset = min(max(0, inset), max(0, (self.width - 1) / 2))
        let factor = zoom.isFinite ? min(50, max(1, zoom)) : 1
        span = min(self.duration, max(min(0.25, self.duration), self.duration / factor))
        let middle = center.flatMap { $0.isFinite ? $0 : nil } ?? self.duration / 2
        lower = min(max(0, middle - span / 2), max(0, self.duration - span))
    }
    func x(at seconds: Double) -> Double { inset + (seconds - lower) / span * trackWidth }
    func time(at x: Double) -> Double { lower + min(1, max(0, (x - inset) / trackWidth)) * span }
    func contains(_ seconds: Double) -> Bool { seconds >= lower - 0.000001 && seconds <= upper + 0.000001 }
    func draggedTime(initial: Double, translation: Double) -> Double {
        min(duration, max(0, initial + translation / trackWidth * span))
    }
    func centerKeepingVisible(_ seconds: Double) -> Double {
        let margin = span * 0.06
        let nextLower = seconds < lower + margin ? seconds - margin : seconds > upper - margin ? seconds + margin - span : lower
        return min(max(0, nextLower), panLimit) + span / 2
    }
    func zoomedCenter(to zoom: Double, anchor: Double) -> Double {
        let next = TrimTimelineGeometry(duration: duration, zoom: zoom, center: midpoint, width: width, inset: inset)
        let point = contains(anchor) ? anchor : midpoint
        let fraction = (point - lower) / span
        return min(max(0, point - fraction * next.span), next.panLimit) + next.span / 2
    }
    static func move(_ selection: TrimSelection, by seconds: Double, duration: Double) -> TrimSelection {
        let length = min(duration, max(0, selection.end - selection.start))
        let start = min(max(0, selection.start + seconds), max(0, duration - length))
        return TrimSelection(start: start, end: start + length)
    }
}

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

struct TrimTimelineView: View {
    @Binding var start: Double
    @Binding var end: Double
    @Binding var zoom: Double
    @Binding var center: Double?
    let duration: Double
    let currentTime: Double
    let frameStep: Double
    let previewURL: URL?
    let onScrub: (Double) -> Void
    let onScrubEnd: (Double) -> Void
    let onMoveSelection: (TrimSelection) -> Void
    let onInteractionBegin: () -> Void
    let onInteractionEnd: () -> Void
    let onControlFocus: (Bool) -> Void

    private enum Handle: Hashable { case start, end }
    private enum Control: Hashable { case handle(Handle), zoom, pan }
    private struct DragAnchor {
        let geometry: TrimTimelineGeometry
        let selection: TrimSelection
    }
    @State private var anchor: DragAnchor?
    @State private var thumbnails: [TimedThumbnail] = []
    @State private var timelineWidth = 800.0
    @State private var space = UUID()
    @Environment(\.isEnabled) private var enabled
    @FocusState private var focusedControl: Control?
    private var viewport: TrimTimelineGeometry {
        TrimTimelineGeometry(duration: duration, zoom: zoom, center: center, width: timelineWidth)
    }
    private var minimumRange: Double { min(0.25, viewport.duration) }

    var body: some View {
        VStack(spacing: 8) {
            toolbar
            GeometryReader { proxy in
                let geometry = TrimTimelineGeometry(duration: duration, zoom: zoom, center: center, width: proxy.size.width)
                VStack(spacing: 6) {
                    ruler(geometry)
                    filmstrip(geometry)
                    moveBar(geometry)
                }
                .onAppear { timelineWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { _, value in timelineWidth = value }
            }.frame(height: 110)
            if viewport.panLimit > 0 { panControl }
            Text("Drag the ends to trim · Drag the video to seek · Drag the range bar to move the clip")
                .font(H3.body(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
        .coordinateSpace(name: space)
        .allowsHitTesting(enabled)
        .task(id: "\(previewURL?.absoluteString ?? "")|\(viewport.lower)|\(viewport.span)") { await loadThumbnails() }
        .onChange(of: focusedControl) { _, value in onControlFocus(value != nil) }
        .onDisappear {
            if anchor != nil { onInteractionEnd() }
            onControlFocus(false)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text("Zoom").font(H3.body(size: 11)).foregroundStyle(.secondary)
            Button { setZoom(zoom / 1.5) } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom out")
            Slider(value: Binding(get: { log2(max(1, zoom)) }, set: { setZoom(pow(2, $0)) }), in: 0...log2(50))
                .frame(width: 110).accessibilityLabel("Timeline zoom")
                .focusable()
                .focused($focusedControl, equals: .zoom)
                .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in focusedControl = .zoom })
                .onKeyPress(keys: [.leftArrow, .rightArrow], phases: [.down, .repeat]) { event in
                    guard enabled, anchor == nil else { return .ignored }
                    let step = event.modifiers.contains(.shift) ? 1.0 : 0.25
                    setZoom(zoom * pow(2, event.key == .leftArrow ? -step : step))
                    return .handled
                }
            Button { setZoom(zoom * 1.5) } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom in")
            Text(String(format: "%.1f×", zoom)).font(H3.mono(size: 10)).frame(width: 40)
            Spacer()
            Button("Fit range") {
                zoom = min(50, max(1, viewport.duration / max(minimumRange, (end - start) * 1.2)))
                center = (start + end) / 2
            }
            Button("Show all") { zoom = 1; center = viewport.duration / 2 }
        }.buttonStyle(.borderless).disabled(anchor != nil)
    }
    private func setZoom(_ factor: Double) {
        let next = min(50, max(1, factor))
        let nextCenter = viewport.zoomedCenter(to: next, anchor: currentTime)
        zoom = next; center = nextCenter
    }
    private var panControl: some View {
        HStack(spacing: 10) {
            Text("View").font(H3.body(size: 11)).foregroundStyle(.secondary)
            Slider(value: Binding(get: { viewport.lower }, set: { center = $0 + viewport.span / 2 }), in: 0...max(0.001, viewport.panLimit))
                .accessibilityLabel("Timeline position")
                .accessibilityValue("\(MediaTime.format(viewport.lower)) to \(MediaTime.format(viewport.upper))")
                .disabled(viewport.panLimit <= 0 || anchor != nil)
                .focusable()
                .focused($focusedControl, equals: .pan)
                .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in focusedControl = .pan })
                .onKeyPress(keys: [.leftArrow, .rightArrow], phases: [.down, .repeat]) { event in
                    guard enabled, anchor == nil else { return .ignored }
                    let step = viewport.span * (event.modifiers.contains(.shift) ? 0.1 : 0.02)
                    let lower = min(viewport.panLimit, max(0, viewport.lower + (event.key == .leftArrow ? -step : step)))
                    center = lower + viewport.span / 2
                    return .handled
                }
            Text("\(stamp(viewport.lower)) – \(stamp(viewport.upper))").font(H3.mono(size: 10)).foregroundStyle(.secondary).fixedSize()
        }
    }
    private func ruler(_ geometry: TrimTimelineGeometry) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<5) { index in
                Text(stamp(geometry.lower + Double(index) / 4 * geometry.span))
                    .font(H3.mono(size: 10)).foregroundStyle(.secondary)
                    .frame(width: 80, alignment: index == 0 ? .leading : index == 4 ? .trailing : .center)
                    .offset(x: geometry.x(at: geometry.lower + Double(index) / 4 * geometry.span) - (index == 0 ? 0 : index == 4 ? 80 : 40))
            }
        }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 16).accessibilityHidden(true)
    }
    private func filmstrip(_ geometry: TrimTimelineGeometry) -> some View {
        let left = max(geometry.inset, min(geometry.width - geometry.inset, geometry.x(at: start)))
        let right = max(left, min(geometry.width - geometry.inset, geometry.x(at: end)))
        return ZStack(alignment: .topLeading) {
            thumbnailStrip(geometry)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, geometry.inset)
                .contentShape(Rectangle())
                .background(TimelineCursor(cursor: .crosshair))
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
                    .onChanged { value in
                        focusedControl = nil
                        begin(geometry)
                        // The coordinate space includes the toolbar; its horizontal inset is shared.
                        onScrub(geometry.time(at: value.location.x))
                    }.onEnded { value in
                        onScrubEnd(geometry.time(at: value.location.x)); finish()
                    })
                .accessibilityLabel("Video timeline")
                .accessibilityHint("Drag to seek. Use the start and end handles to change the clip.")
            Rectangle().fill(.black.opacity(0.55)).frame(width: max(0, left - geometry.inset), height: 58).offset(x: geometry.inset).allowsHitTesting(false)
            Rectangle().fill(.black.opacity(0.55)).frame(width: max(0, geometry.width - geometry.inset - right), height: 58).offset(x: right).allowsHitTesting(false)
            Rectangle().stroke(H3.blue400, lineWidth: 2).frame(width: max(0, right - left), height: 58).offset(x: left).allowsHitTesting(false)
            if geometry.contains(currentTime) {
                Rectangle().fill(.white).frame(width: 2, height: 58).offset(x: geometry.x(at: currentTime) - 1)
                    .shadow(color: .black.opacity(0.5), radius: 1).allowsHitTesting(false)
            }
            boundary(.start, geometry: geometry)
            boundary(.end, geometry: geometry)
        }.frame(height: 58)
    }
    private func thumbnailStrip(_ geometry: TrimTimelineGeometry) -> some View {
        let slots = max(6, Int(geometry.trackWidth / 70))
        return HStack(spacing: 1) {
            ForEach(0..<slots, id: \.self) { index in
                let time = geometry.lower + (Double(index) + 0.5) / Double(slots) * geometry.span
                let nearest = thumbnails.min { abs($0.time - time) < abs($1.time - time) }
                Group {
                    if let image = nearest?.image { Image(nsImage: image).resizable().scaledToFill() }
                    else { Rectangle().fill(.secondary.opacity(0.12)).overlay(Image(systemName: "film").foregroundStyle(.tertiary)) }
                }.frame(width: max(1, (geometry.trackWidth - Double(slots - 1)) / Double(slots)), height: 58).clipped()
            }
        }.frame(width: geometry.trackWidth, height: 58).accessibilityHidden(true)
    }
    @ViewBuilder private func boundary(_ handle: Handle, geometry: TrimTimelineGeometry) -> some View {
        let seconds = handle == .start ? start : end
        let isVisible = geometry.contains(seconds)
        let x = min(geometry.width - geometry.inset, max(geometry.inset, geometry.x(at: seconds)))
        if isVisible {
            handleSurface(handle)
                .gesture(boundaryDrag(handle, geometry: geometry))
                .focusable().focused($focusedControl, equals: .handle(handle))
                .onKeyPress(keys: [.leftArrow, .rightArrow], phases: [.down, .repeat]) { event in
                    let step = event.modifiers.contains(.shift) ? 1 : frameStep
                    adjust(handle, by: event.key == .leftArrow ? -step : step)
                    return .handled
                }
                .accessibilityLabel(handle == .start ? "Clip start" : "Clip end")
                .accessibilityValue(MediaTime.format(seconds))
                .accessibilityAdjustableAction { direction in
                    adjust(handle, by: direction == .increment ? frameStep : -frameStep)
                }
                .help("Drag to trim. Arrow keys adjust one frame; Shift adjusts one second.")
                .offset(x: x - 14)
        } else {
            Button {
                center = seconds; onScrubEnd(seconds)
            } label: { Image(systemName: handle == .start ? "chevron.left" : "chevron.right").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.bordered).frame(width: 28, height: 58).offset(x: x - 14)
                .help(handle == .start ? "Show clip start" : "Show clip end")
        }
    }
    private func handleSurface(_ handle: Handle) -> some View {
        RoundedRectangle(cornerRadius: 5).fill(H3.blue400)
            .overlay(Image(systemName: handle == .start ? "chevron.left" : "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.white))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(focusedControl == .handle(handle) ? Color.white : Color.clear, lineWidth: 2))
            .frame(width: 18, height: 58).padding(.horizontal, 5).contentShape(Rectangle())
            .background(TimelineCursor(cursor: .resizeLeftRight))
    }
    private func boundaryDrag(_ handle: Handle, geometry: TrimTimelineGeometry) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
            .onChanged { value in
                begin(geometry)
                guard let anchor else { return }
                let initial = handle == .start ? anchor.selection.start : anchor.selection.end
                update(handle, to: anchor.geometry.draggedTime(initial: initial, translation: value.translation.width))
                let target = handle == .start ? start : end
                center = geometry.centerKeepingVisible(target); onScrub(target)
            }.onEnded { _ in onScrubEnd(handle == .start ? start : end); finish() }
    }
    private func moveBar(_ geometry: TrimTimelineGeometry) -> some View {
        let left = min(geometry.width - geometry.inset, max(geometry.inset, geometry.x(at: start)))
        let right = min(geometry.width - geometry.inset, max(geometry.inset, geometry.x(at: end)))
        return ZStack(alignment: .leading) {
            Capsule().fill(.secondary.opacity(0.08)).frame(height: 24).padding(.horizontal, geometry.inset)
            if right > left {
                rangeSurface(width: right - left)
                    .contentShape(Rectangle()).background(TimelineCursor(cursor: .openHand))
                    .gesture(rangeDrag(geometry))
                    .accessibilityLabel("Move clip range").accessibilityValue("\(MediaTime.format(start)) to \(MediaTime.format(end))")
                    .accessibilityAdjustableAction { direction in
                        nudgeRange(direction == .increment ? frameStep : -frameStep)
                    }
                    .help("Drag to move the whole range without changing its length")
                    .offset(x: left)
            }
        }.frame(height: 24)
    }
    private func rangeSurface(width: Double) -> some View {
        RoundedRectangle(cornerRadius: 5).fill(H3.blue400.opacity(0.16))
            .overlay {
                if width > 120 {
                    Label("Move range", systemImage: "arrow.left.and.right").font(H3.body(size: 10)).foregroundStyle(H3.blue400)
                } else { Image(systemName: "arrow.left.and.right").font(.system(size: 9)).foregroundStyle(H3.blue400) }
            }.frame(width: width, height: 24)
    }
    private func nudgeRange(_ delta: Double) {
        guard enabled else { return }
        onInteractionBegin()
        onMoveSelection(TrimTimelineGeometry.move(TrimSelection(start: start, end: end), by: delta, duration: viewport.duration))
        onInteractionEnd()
    }
    private func rangeDrag(_ geometry: TrimTimelineGeometry) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                focusedControl = nil
                begin(geometry)
                guard let anchor else { return }
                let delta = Double(value.translation.width) / anchor.geometry.trackWidth * anchor.geometry.span
                onMoveSelection(TrimTimelineGeometry.move(anchor.selection, by: delta, duration: geometry.duration))
            }.onEnded { _ in finish() }
    }
    private func begin(_ geometry: TrimTimelineGeometry) {
        if anchor == nil {
            anchor = DragAnchor(geometry: geometry, selection: TrimSelection(start: start, end: end))
            onInteractionBegin()
        }
    }
    private func finish() { anchor = nil; onInteractionEnd() }
    private func update(_ handle: Handle, to time: Double) {
        if handle == .start { start = min(max(0, time), end - minimumRange) }
        else { end = min(viewport.duration, max(start + minimumRange, time)) }
    }
    private func adjust(_ handle: Handle, by seconds: Double) {
        guard enabled else { return }
        onInteractionBegin()
        update(handle, to: (handle == .start ? start : end) + seconds)
        let target = handle == .start ? start : end
        center = viewport.centerKeepingVisible(target); onScrubEnd(target)
        onInteractionEnd()
    }
    private func stamp(_ seconds: Double) -> String {
        let text = MediaTime.format(seconds)
        let short = seconds < 3600 ? String(text.dropFirst(3)) : text
        return viewport.span < 4 ? short : String(short.dropLast(4))
    }
    private func loadThumbnails() async {
        guard let url = previewURL else { thumbnails = []; return }
        let lower = viewport.lower, span = viewport.span
        let key = "\(url.absoluteString)|\(lower)|\(span)"
        if let cached = FilmstripCache.shared.get(key) { thumbnails = cached; return }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 180, height: 100)
        generator.requestedTimeToleranceBefore = CMTime(seconds: min(0.25, span / 48), preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = generator.requestedTimeToleranceBefore
        let times = (0..<24).map { lower + span * (Double($0) + 0.5) / 24 }
        var images = times.map { TimedThumbnail(time: $0, image: nil) }
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

private struct TimelineCursor: NSViewRepresentable {
    let cursor: NSCursor
    func makeNSView(context: Context) -> CursorView { CursorView() }
    func updateNSView(_ view: CursorView, context: Context) { view.cursor = cursor; view.window?.invalidateCursorRects(for: view) }
    final class CursorView: NSView {
        var cursor = NSCursor.arrow
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }
    }
}
