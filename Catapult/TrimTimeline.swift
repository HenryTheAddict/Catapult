import SwiftUI
import AppKit
import AVFoundation

/// Shared time/point mapping for the visible viewport and the full scrollable source.
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
    var documentWidth: Double { trackWidth * duration / span + 2 * inset }
    var scrollOffset: Double { lower / span * trackWidth }
    func documentTime(atViewportX x: Double) -> Double {
        min(duration, max(0, (x + scrollOffset - inset) / trackWidth * span))
    }
    func edgeSpeed(at x: Double) -> Double {
        let margin = min(48, trackWidth / 5)
        if x < inset + margin { return -min(1, max(0, (inset + margin - x) / margin)) }
        if x > width - inset - margin { return min(1, max(0, (x - width + inset + margin) / margin)) }
        return 0
    }

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
    private enum Control: Hashable { case handle(Handle), zoom }
    private enum DragKind { case boundary(Handle), scrub, range }
    private struct DragAnchor {
        let selection: TrimSelection
        let pointerTime: Double
    }
    @State private var anchor: DragAnchor?
    @State private var dragKind: DragKind?
    @State private var pointerX = 0.0
    @State private var thumbnails: [TimedThumbnail] = []
    @State private var timelineWidth = 800.0
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
                let visible = TrimTimelineGeometry(duration: duration, zoom: zoom, center: center, width: proxy.size.width)
                let document = TrimTimelineGeometry(duration: duration, zoom: 1, center: nil, width: visible.documentWidth)
                NativeTrimScrollView(width: visible.documentWidth, offset: visible.scrollOffset,
                                     onScroll: { offset in
                    guard enabled, anchor == nil else { return }
                    let lower = min(visible.panLimit, max(0, offset / visible.trackWidth * visible.span))
                    center = lower + visible.span / 2
                }, onMagnify: { delta, x in
                    guard enabled, anchor == nil else { return }
                    let next = min(50, max(1, zoom * max(0.1, 1 + delta)))
                    let nextCenter = viewport.zoomedCenter(to: next, anchor: viewport.time(at: x))
                    zoom = next; center = nextCenter
                }, onDragStart: { point in
                    guard enabled else { return false }
                    let kind: DragKind
                    if point.y >= 22 && point.y <= 80 {
                        if abs(point.x - document.x(at: start)) <= 14 { kind = .boundary(.start); focusedControl = .handle(.start) }
                        else if abs(point.x - document.x(at: end)) <= 14 { kind = .boundary(.end); focusedControl = .handle(.end) }
                        else { kind = .scrub; focusedControl = nil }
                    } else if point.y >= 86 && point.y <= 110 && point.x >= document.x(at: start) && point.x <= document.x(at: end) {
                        kind = .range; focusedControl = nil
                    } else { return false }
                    begin(kind, location: point.x, geometry: document)
                    pointerX = point.x - viewport.scrollOffset; applyDrag()
                    return true
                }, onDragChange: { point in
                    pointerX = point.x - viewport.scrollOffset; applyDrag()
                }, onDragEnd: { point in
                    pointerX = point.x - viewport.scrollOffset; applyDrag(precise: true); finish()
                }) {
                    VStack(spacing: 6) {
                        ruler(document)
                        filmstrip(document)
                        moveBar(document)
                    }
                    .frame(width: visible.documentWidth, height: 110, alignment: .top)
                }
                .frame(width: proxy.size.width, height: 110)
                .onAppear { timelineWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { _, value in timelineWidth = value }

            }.frame(height: 110)
            HStack(spacing: 12) {
                Text("Drag the ends to trim. Scroll sideways to navigate. Pinch to zoom.")
                    .font(H3.body(size: 10)).foregroundStyle(.secondary)
                Spacer()
                if !viewport.contains(start) { Button("Clip start") { center = start }.help("Show the start handle") }
                if !viewport.contains(end) { Button("Clip end") { center = end }.help("Show the end handle") }
            }.buttonStyle(.borderless)

        }
        .allowsHitTesting(enabled)
        .task(id: "\(previewURL?.absoluteString ?? "")|\(viewport.lower)|\(viewport.span)") {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await loadThumbnails()
        }
        .task(id: anchor != nil) {
            while anchor != nil && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled, anchor != nil else { return }
                let speed = viewport.edgeSpeed(at: pointerX)
                guard speed != 0 else { continue }
                let next = min(viewport.panLimit, max(0, viewport.lower + speed * viewport.span * 0.018))
                if next != viewport.lower { center = next + viewport.span / 2; applyDrag() }
            }
        }
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
            Menu {
                ForEach([1.0, 2, 4, 8, 16, 32, 50], id: \.self) { factor in
                    Button(String(format: "%.0f×", factor)) { setZoom(factor) }
                }
            } label: { Text(String(format: "%.1f×", zoom)).font(H3.mono(size: 11)).frame(width: 48) }
                .accessibilityLabel("Timeline zoom")
                .focusable().focused($focusedControl, equals: .zoom)
                .onKeyPress(keys: [.leftArrow, .rightArrow], phases: [.down, .repeat]) { event in
                    guard enabled, anchor == nil else { return .ignored }
                    setZoom(zoom * (event.key == .leftArrow ? 1 / 1.5 : 1.5)); return .handled
                }
            Button { setZoom(zoom * 1.5) } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom in")
            Spacer()
            if !viewport.contains(currentTime) {
                Button { center = currentTime } label: { Image(systemName: "scope") }.help("Show playhead")
            }
            Button("Fit range") {
                zoom = min(50, max(1, viewport.duration / max(minimumRange, (end - start) * 1.2)))
                center = (start + end) / 2
            }
            Button("Show all") { zoom = 1; center = viewport.duration / 2 }
        }.buttonStyle(MediaActionStyle()).disabled(anchor != nil)
    }
    private func setZoom(_ factor: Double) {
        let next = min(50, max(1, factor))
        let nextCenter = viewport.zoomedCenter(to: next, anchor: currentTime)
        zoom = next; center = nextCenter
    }
    private func ruler(_ geometry: TrimTimelineGeometry) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<5) { index in
                Text(stamp(viewport.lower + Double(index) / 4 * viewport.span))
                    .font(H3.mono(size: 10)).foregroundStyle(.secondary)
                    .frame(width: 80, alignment: index == 0 ? .leading : index == 4 ? .trailing : .center)
                    .offset(x: geometry.x(at: viewport.lower + Double(index) / 4 * viewport.span) - (index == 0 ? 0 : index == 4 ? 80 : 40))
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
        let tileWidth = 70.0
        let first = max(0, Int(floor(viewport.scrollOffset / tileWidth)) - 1)
        let last = min(Int(ceil(geometry.trackWidth / tileWidth)), Int(ceil((viewport.scrollOffset + viewport.width) / tileWidth)) + 1)
        return ZStack(alignment: .leading) {
            Rectangle().fill(.secondary.opacity(0.12))
            ForEach(first..<max(first, last), id: \.self) { index in
                let time = geometry.time(at: geometry.inset + (Double(index) + 0.5) * tileWidth)
                let nearest = thumbnails.min { abs($0.time - time) < abs($1.time - time) }
                let image = nearest.flatMap { abs($0.time - time) <= viewport.span / 12 ? $0.image : nil }
                Group {
                    if let image { Image(nsImage: image).resizable().scaledToFill() }
                    else { Rectangle().fill(.secondary.opacity(0.08)).overlay(Image(systemName: "film").foregroundStyle(.tertiary)) }
                }.frame(width: tileWidth - 1, height: 58).clipped().offset(x: Double(index) * tileWidth)
            }
        }.frame(width: geometry.trackWidth, height: 58).clipped().accessibilityHidden(true)
    }
    @ViewBuilder private func boundary(_ handle: Handle, geometry: TrimTimelineGeometry) -> some View {
        let seconds = handle == .start ? start : end
        let isVisible = geometry.contains(seconds)
        let x = min(geometry.width - geometry.inset, max(geometry.inset, geometry.x(at: seconds)))
        if isVisible {
            handleSurface(handle)
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
    private func moveBar(_ geometry: TrimTimelineGeometry) -> some View {
        let left = min(geometry.width - geometry.inset, max(geometry.inset, geometry.x(at: start)))
        let right = min(geometry.width - geometry.inset, max(geometry.inset, geometry.x(at: end)))
        return ZStack(alignment: .leading) {
            Capsule().fill(.secondary.opacity(0.08)).frame(height: 24).padding(.horizontal, geometry.inset)
            if right > left {
                rangeSurface(width: right - left)
                    .contentShape(Rectangle()).background(TimelineCursor(cursor: .openHand))
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
    private func begin(_ kind: DragKind, location: Double, geometry: TrimTimelineGeometry) {
        if anchor == nil {
            anchor = DragAnchor(selection: TrimSelection(start: start, end: end), pointerTime: geometry.time(at: location))
            dragKind = kind
            onInteractionBegin()
        }
    }
    private func applyDrag(precise: Bool = false) {
        guard let anchor, let dragKind else { return }
        let pointerTime = viewport.documentTime(atViewportX: pointerX)
        let delta = pointerTime - anchor.pointerTime
        switch dragKind {
        case .boundary(let handle):
            update(handle, to: (handle == .start ? anchor.selection.start : anchor.selection.end) + delta)
            let target = handle == .start ? start : end
            if precise { center = viewport.centerKeepingVisible(target); onScrubEnd(target) }
            else { onScrub(target) }
        case .scrub:
            if precise { onScrubEnd(pointerTime) } else { onScrub(pointerTime) }
        case .range:
            onMoveSelection(TrimTimelineGeometry.move(anchor.selection, by: delta, duration: viewport.duration))
        }
    }
    private func finish() { anchor = nil; dragKind = nil; onInteractionEnd() }
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

/// AppKit owns horizontal wheel momentum; vertical events continue to the editor's scroll view.
private struct NativeTrimScrollView<Content: View>: NSViewRepresentable {
    let width: Double
    let offset: Double
    let onScroll: (Double) -> Void
    let onMagnify: (Double, Double) -> Void
    let onDragStart: (CGPoint) -> Bool
    let onDragChange: (CGPoint) -> Void
    let onDragEnd: (CGPoint) -> Void
    @ViewBuilder var content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> HorizontalTimelineScrollView {
        let scroll = HorizontalTimelineScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.horizontalScrollElasticity = .none
        scroll.verticalScrollElasticity = .none
        let host = TimelineHostingView(rootView: content())
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: width, height: 110)
        scroll.documentView = host
        scroll.contentView.postsBoundsChangedNotifications = true
        let coordinator = context.coordinator
        coordinator.host = host
        coordinator.observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak scroll, weak coordinator] _ in
            guard let scroll, let coordinator, !coordinator.updating else { return }
            let x = scroll.contentView.bounds.origin.x
            coordinator.onScroll?(x)
        }
        return scroll
    }
    func updateNSView(_ scroll: HorizontalTimelineScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onScroll = onScroll
        scroll.onMagnify = onMagnify
        coordinator.host?.onDragStart = onDragStart
        coordinator.host?.onDragChange = onDragChange
        coordinator.host?.onDragEnd = onDragEnd
        coordinator.updating = true
        coordinator.host?.rootView = content()
        coordinator.host?.frame = NSRect(x: 0, y: 0, width: width, height: 110)
        if abs(scroll.contentView.bounds.origin.x - offset) > 0.5 {
            scroll.contentView.scroll(to: NSPoint(x: offset, y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        coordinator.updating = false
    }
    static func dismantleNSView(_ scroll: HorizontalTimelineScrollView, coordinator: Coordinator) {
        if let observer = coordinator.observer { NotificationCenter.default.removeObserver(observer) }
        coordinator.observer = nil; coordinator.onScroll = nil; scroll.onMagnify = nil
        coordinator.host?.onDragStart = nil
        coordinator.host?.onDragChange = nil
        coordinator.host?.onDragEnd = nil
    }
    final class Coordinator {
        var host: TimelineHostingView<Content>?
        var observer: Any?
        var updating = false
        var onScroll: ((Double) -> Void)?
    }
}
final class HorizontalTimelineScrollView: NSScrollView {
    var onMagnify: ((Double, Double) -> Void)?
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) || event.modifierFlags.contains(.shift) {
            let delta = event.modifierFlags.contains(.shift) && event.scrollingDeltaX == 0 ? event.scrollingDeltaY : event.scrollingDeltaX
            let movement = delta * (event.hasPreciseScrollingDeltas ? 1 : 12)
            let limit = max(0, (documentView?.frame.width ?? 0) - contentView.bounds.width)
            let x = min(limit, max(0, contentView.bounds.origin.x - movement))
            contentView.scroll(to: NSPoint(x: x, y: 0))
            reflectScrolledClipView(contentView)
        } else { nextResponder?.scrollWheel(with: event) }
    }
    override func magnify(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onMagnify?(event.magnification, point.x)
    }
}

/// Own the pointer stream so replacing thumbnail views cannot cancel a trim drag.
private final class TimelineHostingView<Content: View>: NSHostingView<Content> {
    var onDragStart: ((CGPoint) -> Bool)?
    var onDragChange: ((CGPoint) -> Void)?
    var onDragEnd: ((CGPoint) -> Void)?
    private var dragging = false
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if bounds.contains(local), local.y >= 22 { return self }
        return super.hitTest(point)
    }
    override func mouseDown(with event: NSEvent) {
        dragging = onDragStart?(convert(event.locationInWindow, from: nil)) ?? false
        if !dragging { super.mouseDown(with: event) }
    }
    override func mouseDragged(with event: NSEvent) {
        if dragging { onDragChange?(convert(event.locationInWindow, from: nil)) }
        else { super.mouseDragged(with: event) }
    }
    override func mouseUp(with event: NSEvent) {
        if dragging { onDragEnd?(convert(event.locationInWindow, from: nil)); dragging = false }
        else { super.mouseUp(with: event) }
    }
    override func scrollWheel(with event: NSEvent) { enclosingScrollView?.scrollWheel(with: event) }
    override func magnify(with event: NSEvent) { enclosingScrollView?.magnify(with: event) }
}
