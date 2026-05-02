import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Menu bar icon

struct MenuBarLabel: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(ClipboardMonitor.self) private var clipboard

    var body: some View {
        let activeCount = downloads.items.filter {
            if case .downloading = $0.status { return true }
            if case .postProcessing = $0.status { return true }
            return false
        }.count
        let hasPending = clipboard.detectedURL != nil
        HStack(spacing: 4) {
            Image(nsImage: menuBarImage(iconName(active: activeCount > 0, hasPending: hasPending)))
            if activeCount > 0 {
                Text("\(activeCount)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
    }

    private func iconName(active: Bool, hasPending: Bool) -> String {
        if active { return "downloading" }
        if hasPending { return "copylink" }
        return "catapultidle"
    }

    private func menuBarImage(_ name: String) -> NSImage {
        guard let img = NSImage(named: name) else { return NSImage() }
        let sized = img.copy() as! NSImage
        sized.size = NSSize(width: 18, height: 18)
        sized.isTemplate = true
        return sized
    }
}

// MARK: - Popover root

struct MenuBarRootView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(DownloadManager.self) private var downloads
    @Environment(DependencyManager.self) private var dependencies
    @Environment(ClipboardMonitor.self) private var clipboard
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    @State private var manualURL: String = ""
    @FocusState private var urlFieldFocused: Bool
    @State private var showVideoOptions = false
    @State private var showAudioOptions = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            inputCard
            Divider().opacity(0.4)
            contentBody
            Divider().opacity(0.4)
            footer
        }
        .frame(width: 440)
        .frame(minHeight: 220, maxHeight: 640)
        .fixedSize(horizontal: false, vertical: true)
        .background(backgroundLayer)
        // Accept URLs dragged from Safari, Messages, Notes, etc. Dropping a
        // link anywhere on the popover enqueues it as a video download.
        .onDrop(of: [.url, .text, .fileURL],
                isTargeted: nil,
                perform: handleDrop(providers:))
        .onAppear {
            if let url = clipboard.detectedURL { manualURL = url }
            urlFieldFocused = true
            if !settings.hasCompletedOnboarding {
                OnboardingLauncher.present()
            }
        }
        .onChange(of: clipboard.detectedURL) { _, new in
            if let new { manualURL = new }
        }
        .background(
            EscKeyCatcher {
                // Clear focus first; if already clear, close the popover.
                if urlFieldFocused { urlFieldFocused = false }
                else { MenuBarWindowCloser.closeExtra() }
            }
        )
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            AppIconView(size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("Catapult")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text(statusSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Settings")

            Menu {
                Button("Check for yt-dlp Update") {
                    Task { await dependencies.updateYtDlp() }
                }
                Button("Reinstall ffmpeg") {
                    Task { await dependencies.reinstallFfmpeg() }
                }
                Divider()
                Button("Open Downloads Folder") {
                    NSWorkspace.shared.open(settings.downloadFolderURL)
                }
                Button("Clear Finished") { downloads.clearFinished() }
                Divider()
                Button("Quit Catapult") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var statusSubtitle: String {
        switch dependencies.state {
        case .unknown, .checking: return "Checking dependencies…"
        case .downloading(let name, let p): return "Downloading \(name) (\(Int(p * 100))%)"
        case .installing(let name): return "Installing \(name)…"
        case .ready: return "Ready"
        case .error(let msg): return msg
        }
    }

    // MARK: Input card

    private var inputCard: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .foregroundStyle(.secondary)
                TextField("Paste a YouTube link…", text: $manualURL)
                    .textFieldStyle(.plain)
                    .focused($urlFieldFocused)
                    .onSubmit { startDownload(mode: .video) }
                if !manualURL.isEmpty {
                    Button {
                        manualURL = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                quickActionsMenu
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.background.opacity(0.65))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.separator, lineWidth: 0.5)
                    )
            )
            .contextMenu { quickActionItems }

            if let clipURL = clipboard.detectedURL, clipURL != manualURL {
                HStack(spacing: 8) {
                    Image("copylink")
                        .resizable()
                        .renderingMode(.template)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 14, height: 14)
                        .foregroundStyle(Color.accentColor)
                    Text("Detected on clipboard")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Use") { manualURL = clipURL }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    Button {
                        clipboard.clearDetected()
                    } label: {
                        Image(systemName: "xmark").font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                )
            }

            HStack(spacing: 8) {
                ActionButton(title: "Download",
                             icon: "arrow.down.to.line",
                             tint: .accentColor,
                             filled: true,
                             action: { startDownload(mode: .video) },
                             longPress: { showVideoOptions = true })
                    .popover(isPresented: $showVideoOptions, arrowEdge: .bottom) {
                        VideoQuickSettingsPopover()
                    }
                ActionButton(title: "Audio",
                             icon: "music.note",
                             tint: .purple,
                             filled: false,
                             action: { startDownload(mode: .audio) },
                             longPress: { showAudioOptions = true })
                    .popover(isPresented: $showAudioOptions, arrowEdge: .bottom) {
                        AudioQuickSettingsPopover()
                    }
                ActionButton(title: "Cut",
                             icon: "scissors",
                             tint: .orange,
                             filled: false,
                             action: { startCut() },
                             longPress: nil)
            }
            .disabled(manualURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(manualURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: Body (download list)

    @ViewBuilder
    private var contentBody: some View {
        if downloads.items.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(downloads.items) { item in
                        DownloadRowView(item: item)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 340)
        }
    }

    private var emptyState: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 13, weight: .light))
                .foregroundStyle(.tertiary)
            Text("no downloads yet — paste a link to start.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            StatusPill(text: depStatusPillText, color: depStatusPillColor)
            Spacer()
            if !downloads.items.isEmpty {
                Button {
                    downloads.clearFinished()
                } label: {
                    Text("Clear finished").font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var depStatusPillText: String {
        switch dependencies.state {
        case .ready:            return "yt-dlp \(dependencies.ytDlpVersion ?? "ready")"
        case .checking:         return "Checking…"
        case .unknown:          return "Preparing…"
        case .downloading(let n, let p): return "Fetching \(n) \(Int(p * 100))%"
        case .installing(let n):return "Installing \(n)"
        case .error:            return "Dependency error"
        }
    }
    private var depStatusPillColor: Color {
        switch dependencies.state {
        case .ready: return .green
        case .error: return .red
        default:     return .orange
        }
    }

    // MARK: Background

    private var backgroundLayer: some View {
        Rectangle().fill(.ultraThinMaterial)
    }

    // MARK: Actions

    // MARK: Quick actions

    private var quickActionsMenu: some View {
        Menu {
            quickActionItems
        } label: {
            Image(systemName: "bolt.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Quick actions (or right-click the link box)")
    }

    @ViewBuilder
    private var quickActionItems: some View {
        Button("Paste and Download (Best)")      { runQuick(.videoBest) }
        Button("Paste and Download 1080p")       { runQuick(.video1080) }
        Button("Paste and Download (<\(settings.quickSizeLimitMB) MB)") { runQuick(.videoSizeLimited) }
        Divider()
        Button("Paste and Get Audio (MP3)")      { runQuick(.audioMP3) }
        Button("Paste and Get Audio (WAV)")      { runQuick(.audioWAV) }
        Divider()
        Button("Paste and Save Thumbnail (PNG)") { runQuick(.thumbnailPNG) }
        Button("Paste and Save Thumbnail (JPG)") { runQuick(.thumbnailJPG) }
        Divider()
        Menu("Paste and Download for…") {
            ForEach(DevicePreset.allCases.filter { $0 != .none && !$0.isRetro }) { p in
                Button(p.label) { runPreset(p) }
            }
            Divider()
            Section("retro slop") {
                ForEach(DevicePreset.allCases.filter(\.isRetro)) { p in
                    Button(p.label) { runPreset(p) }
                }
            }
        }
    }

    private enum QuickAction {
        case videoBest, video1080, videoSizeLimited
        case audioMP3, audioWAV
        case thumbnailPNG, thumbnailJPG
    }

    private func runPreset(_ preset: DevicePreset) {
        let pb = NSPasteboard.general.string(forType: .string) ?? ""
        let url = ClipboardMonitor.firstYouTubeURL(in: pb)
            ?? ClipboardMonitor.firstURL(in: pb)
            ?? manualURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        var overrides = DownloadOverrides()
        overrides.devicePreset = preset
        downloads.enqueue(url: url, mode: .video, overrides: overrides)
        manualURL = ""
        clipboard.clearDetected()
    }

    private func runQuick(_ action: QuickAction) {
        let pb = NSPasteboard.general.string(forType: .string) ?? ""
        let url = ClipboardMonitor.firstYouTubeURL(in: pb)
            ?? ClipboardMonitor.firstURL(in: pb)
            ?? manualURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }

        switch action {
        case .videoBest:
            downloads.enqueue(url: url, mode: .video,
                              overrides: DownloadOverrides(videoQuality: .best))
        case .video1080:
            downloads.enqueue(url: url, mode: .video,
                              overrides: DownloadOverrides(videoQuality: .p1080))
        case .videoSizeLimited:
            downloads.enqueue(url: url, mode: .video,
                              overrides: DownloadOverrides(maxFilesizeMB: settings.quickSizeLimitMB))
        case .audioMP3:
            downloads.enqueue(url: url, mode: .audio,
                              overrides: DownloadOverrides(audioFormat: .mp3))
        case .audioWAV:
            downloads.enqueue(url: url, mode: .audio,
                              overrides: DownloadOverrides(audioFormat: .wav))
        case .thumbnailPNG:
            downloads.enqueue(url: url, mode: .thumbnailOnly,
                              overrides: DownloadOverrides(thumbnailFormat: "png"))
        case .thumbnailJPG:
            downloads.enqueue(url: url, mode: .thumbnailOnly,
                              overrides: DownloadOverrides(thumbnailFormat: "jpg"))
        }
        manualURL = ""
        clipboard.clearDetected()
    }

    private func startDownload(mode: DownloadMode) {
        guard let url = ClipboardMonitor.firstURL(in: manualURL)
            ?? ClipboardMonitor.firstYouTubeURL(in: manualURL)
            ?? Optional(manualURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              !url.isEmpty else { return }
        downloads.enqueue(url: url, mode: mode)
        manualURL = ""
        clipboard.clearDetected()
    }

    // MARK: Drag-and-drop handler
    //
    // Accepts any NSItemProvider that carries a URL or URL-shaped string.
    // Dropping onto the popover enqueues the first matching URL as a video
    // download (same default as the main Download button).
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { obj, _ in
                    guard let url = obj as? URL else { return }
                    Task { @MainActor in enqueueDropped(urlString: url.absoluteString) }
                }
                return true
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
                _ = provider.loadItem(forTypeIdentifier: UTType.text.identifier,
                                      options: nil) { data, _ in
                    let s: String? = {
                        if let d = data as? Data { return String(data: d, encoding: .utf8) }
                        if let s = data as? String { return s }
                        return nil
                    }()
                    guard let s,
                          let picked = ClipboardMonitor.firstYouTubeURL(in: s)
                                    ?? ClipboardMonitor.firstURL(in: s)
                    else { return }
                    Task { @MainActor in enqueueDropped(urlString: picked) }
                }
                return true
            }
        }
        return false
    }

    @MainActor
    private func enqueueDropped(urlString: String) {
        guard !urlString.isEmpty else { return }
        downloads.enqueue(url: urlString, mode: .video)
        manualURL = ""
        clipboard.clearDetected()
        if settings.showNotifications {
            NotificationHelper.show(title: "Queued from drop",
                                    body: urlString)
        }
    }

    private func startCut() {
        let url = manualURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        CutCoordinator.shared.pendingURL = url
        openWindow(id: "cut")
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Action button

struct ActionButton: View {
    let title: String
    let icon: String
    let tint: Color
    let filled: Bool
    let action: () -> Void
    var longPress: (() -> Void)? = nil

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.system(size: 12, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(filled
                          ? tint.opacity(hovering ? 1 : 0.9)
                          : tint.opacity(hovering ? 0.22 : 0.12))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(tint.opacity(filled ? 0 : 0.35), lineWidth: 0.5)
            }
            .foregroundStyle(filled ? Color.white : tint)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.35).onEnded { _ in
                longPress?()
            }
        )
        .help(longPress != nil ? "\(title) — hold for options" : title)
    }
}

// MARK: - Pill

struct StatusPill: View {
    let text: String
    let color: Color
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Download row

struct DownloadRowView: View {
    @Bindable var item: DownloadItem
    @Environment(DownloadManager.self) private var downloads

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(2)
                    .truncationMode(.tail)
                HStack(spacing: 6) {
                    modeBadge
                    if let d = item.durationSeconds, d > 0 {
                        Text(formatDuration(d))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                progressSection
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.background.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
                )
        )
        .contextMenu {
            if case .finished(let url?) = item.status {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            if case .finished = item.status {
                Button("Remove") { downloads.remove(item) }
            } else if case .failed = item.status {
                Button("Retry") { downloads.retry(item) }
                Button("Remove") { downloads.remove(item) }
            } else {
                Button("Cancel") { downloads.cancel(item) }
            }
            Divider()
            Button("Copy Source URL") {
                let pb = NSPasteboard.general
                pb.clearContents(); pb.setString(item.url, forType: .string)
            }
        }
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.quaternary)
            if let t = item.thumbnailURL {
                AsyncImage(url: t) { phase in
                    if let img = phase.image {
                        img.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "play.rectangle")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Image(systemName: iconFor(item.mode))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 64, height: 42)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func iconFor(_ mode: DownloadMode) -> String {
        switch mode {
        case .video:         return "play.rectangle"
        case .audio:         return "music.note"
        case .cut:           return "scissors"
        case .thumbnailOnly: return "photo"
        }
    }

    private var modeBadge: some View {
        let (text, color): (String, Color) = {
            switch item.mode {
            case .video:         return ("Video", .blue)
            case .audio:         return ("Audio", .purple)
            case .cut:           return ("Cut",   .orange)
            case .thumbnailOnly: return ("Thumb", .teal)
            }
        }()
        return Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }

    @ViewBuilder
    private var progressSection: some View {
        switch item.status {
        case .queued:
            Text("Queued").font(.caption2).foregroundStyle(.secondary)
        case .fetchingInfo:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Fetching info…").font(.caption2).foregroundStyle(.secondary)
            }
        case .downloading, .postProcessing:
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: item.progress)
                    .progressViewStyle(.linear)
                    .tint(Color.accentColor)
                HStack {
                    Text(item.statusLine)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        downloads.cancel(item)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
        case .finished(let url):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Saved").font(.caption2).foregroundStyle(.secondary)
                if let u = url {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([u])
                    } label: {
                        Text("Reveal").font(.caption2)
                    }
                    .buttonStyle(.borderless)
                }
                Spacer()
                Button {
                    downloads.remove(item)
                } label: {
                    Image(systemName: "xmark").font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
            }
        case .failed(let msg):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents(); pb.setString(msg, forType: .string)
                } label: {
                    HStack(spacing: 3) {
                        Text(msg).lineLimit(1).truncationMode(.tail)
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Click to copy error")
                Spacer()
                Button("Retry") { downloads.retry(item) }
                    .buttonStyle(.borderless)
                    .font(.caption2)
            }
        case .cancelled:
            HStack(spacing: 6) {
                Image(systemName: "stop.circle").foregroundStyle(.secondary)
                Text("Cancelled").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Retry") { downloads.retry(item) }
                    .buttonStyle(.borderless)
                    .font(.caption2)
            }
        }
    }

    private func formatDuration(_ t: Double) -> String {
        let total = Int(t)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - App icon view

struct AppIconView: View {
    let size: CGFloat
    var body: some View {
        Group {
            if let ns = NSApplication.shared.applicationIconImage, ns.size.width > 0 {
                Image(nsImage: ns)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .fill(Color.accentColor)
                    Image("catapultidle")
                        .resizable()
                        .renderingMode(.template)
                        .aspectRatio(contentMode: .fit)
                        .foregroundStyle(.white)
                        .padding(size * 0.22)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Esc key catcher (NSViewRepresentable)

struct EscKeyCatcher: NSViewRepresentable {
    let onEsc: () -> Void
    func makeNSView(context: Context) -> NSView {
        let v = EscCatcherView()
        v.onEsc = onEsc
        DispatchQueue.main.async { v.window?.makeFirstResponder(nil) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? EscCatcherView)?.onEsc = onEsc
    }
}

final class EscCatcherView: NSView {
    var onEsc: (() -> Void)?
    private var monitor: Any?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            if ev.keyCode == 53 {
                self?.onEsc?()
                return nil
            }
            return ev
        }
    }
    deinit {
        if let m = monitor { NSEvent.removeMonitor(m) }
    }
}

enum MenuBarWindowCloser {
    static func closeExtra() {
        // MenuBarExtra window types vary; close anything that looks like a panel/popover window.
        for w in NSApp.windows where w.isVisible {
            let name = String(describing: type(of: w))
            if name.contains("MenuBarExtra") || name.contains("NSPopover") || name.contains("MenuBar") {
                w.close()
            }
        }
    }
}

// MARK: - Quick settings popovers

struct VideoQuickSettingsPopover: View {
    @Environment(AppSettings.self) private var settings
    var body: some View {
        @Bindable var s = settings
        VStack(alignment: .leading, spacing: 10) {
            Label("Video quick settings", systemImage: "arrow.down.to.line")
                .font(.system(size: 12, weight: .semibold))
            Picker("Quality", selection: $s.videoQuality) {
                ForEach(VideoQuality.allCases) { q in Text(q.label).tag(q) }
            }
            Picker("Container", selection: $s.videoContainer) {
                ForEach(VideoContainer.allCases) { c in Text(c.label).tag(c) }
            }
            Toggle("Embed thumbnail", isOn: $s.embedThumbnail)
            Toggle("Embed metadata", isOn: $s.embedMetadata)
            Text("Saved as defaults for new downloads.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(width: 260)
    }
}

struct AudioQuickSettingsPopover: View {
    @Environment(AppSettings.self) private var settings
    var body: some View {
        @Bindable var s = settings
        VStack(alignment: .leading, spacing: 10) {
            Label("Audio quick settings", systemImage: "music.note")
                .font(.system(size: 12, weight: .semibold))
            Picker("Format", selection: $s.audioFormat) {
                ForEach(AudioFormat.allCases) { f in Text(f.label).tag(f) }
            }
            HStack {
                Text("Bitrate")
                Spacer()
                Slider(value: Binding(
                    get: { Double(settings.audioQualityKbps) },
                    set: { s.audioQualityKbps = Int($0) }
                ), in: 96...320, step: 32)
                .frame(width: 120)
                Text("\(settings.audioQualityKbps)k")
                    .monospacedDigit().font(.caption)
                    .frame(width: 40, alignment: .trailing)
            }
            Toggle("Embed thumbnail", isOn: $s.embedThumbnail)
            Text("Saved as defaults for new downloads.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(width: 260)
    }
}
