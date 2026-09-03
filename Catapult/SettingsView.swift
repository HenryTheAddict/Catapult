import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CoreImage.CIFilterBuiltins

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(DependencyManager.self) private var dependencies
    @Environment(DownloadManager.self) private var downloads
    @State private var selectedTab: SettingsTab = .general
    @State private var tabRailPage = 0

    private let tabRailPageSize = 8

    var body: some View {
        VStack(spacing: 0) {
            settingsTabRail
            Divider().opacity(0.5)
            selectedTabView
                .id(selectedTab)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .animation(H3.appleDrift, value: selectedTab)
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 560, idealHeight: 650)
        .background(H3.ink50)
        // h3 transparent title bar so settings chrome matches onboarding.
        .h3WindowChrome()
        .environment(settings)
        .environment(dependencies)
        .environment(downloads)
    }

    private var settingsTabRail: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Color.clear
                        .frame(width: 72)
                    SettingsRailArrow(systemName: "chevron.left",
                                      isEnabled: tabRailPage > 0) {
                        scrollTabRail(to: tabRailPage - 1, proxy: proxy)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(SettingsTab.allCases) { tab in
                                SettingsTabButton(tab: tab,
                                                  isSelected: selectedTab == tab) {
                                    withAnimation(H3.appleSnap) {
                                        selectedTab = tab
                                        tabRailPage = pageIndex(for: tab)
                                        proxy.scrollTo(tab.id, anchor: .center)
                                    }
                                }
                                .id(tab.id)
                            }
                        }
                        .padding(.top, 9)
                        .padding(.bottom, 6)
                    }
                    SettingsRailArrow(systemName: "chevron.right",
                                      isEnabled: tabRailPage < tabRailPageCount - 1) {
                        scrollTabRail(to: tabRailPage + 1, proxy: proxy)
                    }
                }
                .padding(.trailing, 18)

                SettingsRailPageIndicator(pageCount: tabRailPageCount,
                                          currentPage: tabRailPage) { page in
                    scrollTabRail(to: page, proxy: proxy)
                }
                .padding(.bottom, 7)
            }
            .onChange(of: selectedTab) { _, tab in
                withAnimation(H3.appleSnap) {
                    tabRailPage = pageIndex(for: tab)
                    proxy.scrollTo(tab.id, anchor: .center)
                }
            }
            .background(
                SettingsRailScrollMonitor { direction in
                    scrollTabRail(to: tabRailPage + direction, proxy: proxy)
                }
            )
        }
        .frame(height: 82)
        .background(settingsRailBackground)
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [.clear, H3.ink50.opacity(0.78)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 12)
                .allowsHitTesting(false)
        }
    }

    private var tabRailPageCount: Int {
        max(1, (SettingsTab.allCases.count + tabRailPageSize - 1) / tabRailPageSize)
    }

    private func pageIndex(for tab: SettingsTab) -> Int {
        guard let index = SettingsTab.allCases.firstIndex(of: tab) else { return 0 }
        return min(tabRailPageCount - 1, index / tabRailPageSize)
    }

    private func firstTab(on page: Int) -> SettingsTab {
        let clampedPage = min(max(page, 0), tabRailPageCount - 1)
        let index = min(clampedPage * tabRailPageSize, SettingsTab.allCases.count - 1)
        return SettingsTab.allCases[index]
    }

    private func scrollTabRail(to page: Int, proxy: ScrollViewProxy) {
        let clampedPage = min(max(page, 0), tabRailPageCount - 1)
        withAnimation(H3.appleSnap) {
            tabRailPage = clampedPage
            proxy.scrollTo(firstTab(on: clampedPage).id, anchor: .leading)
        }
    }

    private var settingsRailBackground: some View {
        ZStack {
            LinearGradient(colors: [
                H3.cardFill.opacity(0.82),
                H3.ink50.opacity(0.95)
            ], startPoint: .top, endPoint: .bottom)
            H3.gradSky.opacity(0.10)
            Rectangle().fill(.ultraThinMaterial)
        }
        .ignoresSafeArea(edges: .top)
    }

    @ViewBuilder
    private var selectedTabView: some View {
        switch selectedTab {
        case .general: GeneralSettingsTab()
        case .quality: QualitySettingsTab()
        case .network: NetworkSettingsTab()
        case .sponsorBlock: SponsorBlockTab()
        case .sites: SitesTab()
        case .subscriptions: SubscriptionsTab()
        case .devices: DevicePresetsTab()
        case .terminal: TerminalTab()
        case .advanced: AdvancedSettingsTab()
        case .dependencies: DependenciesTab()
        case .history: HistoryTab()
        case .about: AboutTab()
        }
    }
}

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case quality
    case network
    case sponsorBlock
    case sites
    case subscriptions
    case devices
    case terminal
    case advanced
    case dependencies
    case history
    case about

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: return "General"
        case .quality: return "Quality"
        case .network: return "Network"
        case .sponsorBlock: return "SponsorBlock"
        case .sites: return "Sites"
        case .subscriptions: return "Subscribe"
        case .devices: return "Devices"
        case .terminal: return "Terminal"
        case .advanced: return "Advanced"
        case .dependencies: return "Dependencies"
        case .history: return "History"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .quality: return "sparkles"
        case .network: return "globe"
        case .sponsorBlock: return "rectangle.on.rectangle.slash"
        case .sites: return "globe.americas.fill"
        case .subscriptions: return "antenna.radiowaves.left.and.right"
        case .devices: return "gamecontroller"
        case .terminal: return "terminal"
        case .advanced: return "slider.horizontal.3"
        case .dependencies: return "shippingbox"
        case .history: return "clock.arrow.circlepath"
        case .about: return "info.circle"
        }
    }

    var iconPointSize: CGFloat {
        switch self {
        case .sponsorBlock, .advanced:
            return 18
        case .dependencies, .devices:
            return 19
        default:
            return 20
        }
    }
}

private struct SettingsTabButton: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false
    private let slotWidth: CGFloat = 92

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: tab.icon)
                    .font(.system(size: tab.iconPointSize, weight: isSelected ? .bold : .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 22, height: 20)
                Text(tab.label)
                    .font(H3.body(size: 10.5, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.66)
            }
            .foregroundStyle(isSelected ? H3.ink900 : H3.ink500)
            .padding(.horizontal, 7)
            .frame(width: slotWidth, height: 54)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? H3.cardFill.opacity(0.86)
                                     : (hovering ? H3.cardFill.opacity(0.42) : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? Color.white.opacity(0.9) : Color.white.opacity(0.0),
                            lineWidth: 1)
            )
            .shadow(color: H3.shadowDrop.opacity(isSelected ? 0.13 : 0),
                    radius: 14, y: 8)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(tab.label)
        .accessibilityLabel(tab.label)
        .onHover { hovering = $0 }
        .animation(H3.appleSnap, value: hovering)
        .animation(H3.appleSnap, value: isSelected)
    }
}

private struct SettingsRailArrow: View {
    let systemName: String
    let isEnabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(isEnabled ? H3.ink700 : H3.ink300)
                .frame(width: 34, height: 42)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(hovering && isEnabled ? H3.cardFill.opacity(0.92) : H3.cardFill.opacity(0.62))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(H3.cardStroke, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(systemName == "chevron.left" ? "Previous settings section" : "Next settings section")
        .onHover { hovering = $0 }
        .animation(H3.appleSnap, value: hovering)
        .animation(H3.appleSnap, value: isEnabled)
    }
}

private struct SettingsRailPageIndicator: View {
    let pageCount: Int
    let currentPage: Int
    let selectPage: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<pageCount, id: \.self) { page in
                Button {
                    selectPage(page)
                } label: {
                    Capsule(style: .continuous)
                        .fill(page == currentPage ? H3.blue400 : H3.ink200)
                        .frame(width: page == currentPage ? 18 : 6, height: 6)
                }
                .buttonStyle(.plain)
                .help("Settings page \(page + 1) of \(pageCount)")
            }
        }
        .animation(H3.appleSnap, value: currentPage)
        .accessibilityLabel("Settings section pages")
    }
}

private struct SettingsRailScrollMonitor: NSViewRepresentable {
    let onPage: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPage: onPage)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.postsFrameChangedNotifications = true
        context.coordinator.view = view
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onPage = onPage
        context.coordinator.view = nsView
        context.coordinator.installMonitor()
    }

    final class Coordinator {
        var onPage: (Int) -> Void
        weak var view: NSView?
        private var monitor: Any?
        private var lastPageAt = Date.distantPast
        private var accumulatedDelta: CGFloat = 0

        init(onPage: @escaping (Int) -> Void) {
            self.onPage = onPage
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let view,
                  let window = view.window,
                  event.window === window else { return event }

            let point = view.convert(event.locationInWindow, from: nil)
            guard view.bounds.contains(point) else { return event }

            let verticalDelta = event.scrollingDeltaY
            let horizontalDelta = event.scrollingDeltaX
            guard abs(verticalDelta) >= abs(horizontalDelta),
                  abs(verticalDelta) > 0.05 else { return event }

            accumulatedDelta += verticalDelta
            let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 18 : 0.8
            let now = Date()
            guard abs(accumulatedDelta) >= threshold,
                  now.timeIntervalSince(lastPageAt) > 0.28 else { return nil }

            let direction = accumulatedDelta < 0 ? 1 : -1
            accumulatedDelta = 0
            lastPageAt = now
            onPage(direction)
            return nil
        }
    }
}

private struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView(showsIndicators: true) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(H3.display(size: 24, weight: .medium))
                        .foregroundStyle(H3.ink900)
                    Text(subtitle)
                        .font(H3.body(size: 12))
                        .foregroundStyle(H3.ink500)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 4)
                .padding(.top, 2)

                content()
            }
            .frame(maxWidth: 1040, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(H3.ink50)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var s = settings
        SettingsPage(title: "general",
                     subtitle: "downloads, speed, clipboard behavior, and the little bits you reach for most.") {
                GeneralSettingsCard(title: "Downloads") {
                    HStack(spacing: 12) {
                        SettingsGlyph(systemName: "folder")
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Save to")
                                .font(H3.body(size: 13, weight: .semibold))
                                .foregroundStyle(H3.ink900)
                            Text((settings.downloadFolderPath as NSString).abbreviatingWithTildeInPath)
                                .font(H3.mono(size: 12))
                                .foregroundStyle(H3.ink500)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 12)
                        SettingsMiniButton(title: "Choose", systemName: "folder.badge.gearshape") {
                            chooseFolder()
                        }
                        SettingsIconButton(systemName: "arrow.up.right.square",
                                           help: "Open folder") {
                            NSWorkspace.shared.open(settings.downloadFolderURL)
                        }
                    }

                    SettingsDivider()

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .center, spacing: 12) {
                            SettingsGlyph(systemName: "textformat")
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Filename")
                                    .font(H3.body(size: 13, weight: .semibold))
                                    .foregroundStyle(H3.ink900)
                                Text(settings.filenamePreset.hint)
                                    .font(H3.body(size: 11))
                                    .foregroundStyle(H3.ink500)
                            }
                            Spacer(minLength: 12)
                            Picker("", selection: $s.filenamePreset) {
                                ForEach(FilenamePreset.allCases) { p in
                                    Text(p.label).tag(p)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 360)
                        }

                        HStack(alignment: .top, spacing: 12) {
                            Text("Template")
                                .font(H3.body(size: 12, weight: .semibold))
                                .foregroundStyle(H3.ink500)
                                .frame(width: 74, alignment: .leading)
                                .padding(.top, 7)
                            if settings.filenamePreset == .custom {
                                TextField("", text: $s.filenameTemplate,
                                          prompt: Text("%(title)s [%(id)s].%(ext)s"))
                                    .textFieldStyle(.plain)
                                    .font(H3.mono(size: 12))
                                    .foregroundStyle(H3.ink900)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .background(templateFieldBackground)
                            } else {
                                Text(settings.filenameTemplate)
                                    .font(H3.mono(size: 12))
                                    .foregroundStyle(H3.ink700)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .background(templateFieldBackground)
                            }
                        }
                        Text("Tokens: %(title)s, %(id)s, %(uploader)s, %(height)s, %(vcodec)s, %(upload_date)s.")
                            .font(H3.body(size: 10))
                            .foregroundStyle(H3.ink300)
                    }
                }

                GeneralSettingsCard(title: "Speed") {
                    SettingsNumberRow(systemName: "square.stack.3d.down.right",
                                      title: "Simultaneous downloads",
                                      detail: "Separate links Catapult can run at the same time.",
                                      value: $s.maxConcurrent,
                                      range: 1...6)
                    SettingsDivider()
                    SettingsNumberRow(systemName: "bolt.horizontal.circle",
                                      title: "Parallel fragments",
                                      detail: "Splits supported streams into multiple fragment requests.",
                                      value: $s.concurrentFragments,
                                      range: 1...16)
                }

                GeneralSettingsCard(title: "Quick Actions") {
                    SettingsNumberRow(systemName: "gauge.with.dots.needle.bottom.50percent",
                                      title: "Size limit action",
                                      detail: "Used by the “<N MB” quick download preset.",
                                      value: $s.quickSizeLimitMB,
                                      range: 5...500,
                                      step: 5,
                                      suffix: " MB")
                    SettingsDivider()
                    SettingsToggleRow(systemName: "play.rectangle.on.rectangle",
                                      title: "Prefer QuickTime-compatible codecs",
                                      detail: "Uses H.264 / AAC for MP4. Slightly slower, much friendlier.",
                                      isOn: $s.preferCompatibleCodecs)
                }

                GeneralSettingsCard(title: "Behavior") {
                    SettingsToggleRow(systemName: "doc.on.clipboard",
                                      title: "Watch clipboard for media links",
                                      isOn: $s.clipboardMonitoring)
                    SettingsDivider()
                    SettingsToggleRow(systemName: "bolt.fill",
                                      title: "Auto-start download on detect",
                                      isOn: $s.autoStartDownload,
                                      isDisabled: !settings.clipboardMonitoring)
                    SettingsDivider()
                    SettingsToggleRow(systemName: "bell.badge",
                                      title: "Show notifications",
                                      isOn: $s.showNotifications)
                    SettingsDivider()
                    SettingsToggleRow(systemName: "speaker.wave.2",
                                      title: "Play sound with notifications",
                                      isOn: $s.notificationSound,
                                      isDisabled: !settings.showNotifications)
                    SettingsDivider()
                    SettingsToggleRow(systemName: "folder",
                                      title: "Reveal in Finder when finished",
                                      isOn: $s.openFolderOnFinish)
                    SettingsDivider()
                    SettingsToggleRow(systemName: "doc.on.doc",
                                      title: "Copy file after download",
                                      detail: "Puts the finished file on the clipboard.",
                                      isOn: $s.copyFileAfterDownload)
                }

                GeneralSettingsCard(title: "Appearance") {
                    HStack(spacing: 12) {
                        SettingsGlyph(systemName: "paintbrush")
                        Text("Theme")
                            .font(H3.body(size: 13, weight: .semibold))
                            .foregroundStyle(H3.ink900)
                        Spacer()
                        Picker("", selection: $s.appearance) {
                            ForEach(AppearanceOverride.allCases) { a in
                                Text(a.label).tag(a)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 280)
                    }
                }

                GeneralSettingsCard(title: "History & Updates") {
                    SettingsNumberRow(systemName: "clock.arrow.circlepath",
                                      title: "Downloads kept in history",
                                      value: $s.historyLimit,
                                      range: 10...500,
                                      step: 10)
                    SettingsDivider()
                    SettingsToggleRow(systemName: "arrow.down.app",
                                      title: "Automatically check for app updates",
                                      isOn: $s.autoCheckForUpdates)
                        .onChange(of: settings.autoCheckForUpdates) { _, new in
                            UpdateController.shared.automaticallyChecksForUpdates = new
                        }
                    SettingsDivider()
                    HStack(spacing: 12) {
                        SettingsGlyph(systemName: "info.circle")
                        Text("App updates")
                            .font(H3.body(size: 12))
                            .foregroundStyle(H3.ink500)
                        Spacer()
                        SettingsMiniButton(title: "Check now", systemName: "arrow.clockwise") {
                            UpdateController.shared.checkForUpdates()
                        }
                    }
                }

                SettingsMiniButton(title: "Replay onboarding", systemName: "sparkles") {
                    settings.hasCompletedOnboarding = false
                    OnboardingLauncher.present()
                }
                .padding(.leading, 4)
        }
    }

    private var templateFieldBackground: some View {
        RoundedRectangle(cornerRadius: H3.radius1, style: .continuous)
            .fill(H3.ink50)
            .overlay(
                RoundedRectangle(cornerRadius: H3.radius1, style: .continuous)
                    .stroke(H3.cardStroke, lineWidth: 1)
            )
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.allowsMultipleSelection = false
        p.prompt = "Use Folder"
        if p.runModal() == .OK, let url = p.url {
            settings.downloadFolderPath = url.path
        }
    }
}



private struct GeneralSettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(H3.body(size: 15, weight: .semibold))
                .foregroundStyle(H3.ink900)
                .padding(.horizontal, 2)
            VStack(spacing: 0) {
                content()
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: H3.radius3, style: .continuous)
                    .fill(H3.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: H3.radius3, style: .continuous)
                    .stroke(H3.cardStroke, lineWidth: 1)
            )
            .shadow(color: H3.shadowDrop.opacity(0.12), radius: 5, y: 2)
        }
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(H3.cardStroke)
            .frame(height: 1)
            .padding(.vertical, 10)
    }
}

private struct SettingsGlyph: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(H3.blue400)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: H3.radius1, style: .continuous)
                    .fill(H3.blue50)
            )
    }
}

private struct SettingsMiniButton: View {
    let title: String
    let systemName: String
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 13, height: 13)
                Text(title)
                    .font(H3.body(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isEnabled ? H3.blue400 : H3.ink300)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: H3.radius1, style: .continuous)
                    .fill(isEnabled && hovering ? H3.blue50 : H3.ink50)
            )
            .overlay(
                RoundedRectangle(cornerRadius: H3.radius1, style: .continuous)
                    .stroke(H3.cardStroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(H3.appleSnap, value: hovering)
    }
}

private struct SettingsIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isEnabled ? H3.blue400 : H3.ink300)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: H3.radius1, style: .continuous)
                        .fill(isEnabled && hovering ? H3.blue50 : H3.ink50)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: H3.radius1, style: .continuous)
                        .stroke(H3.cardStroke, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
        .animation(H3.appleSnap, value: hovering)
    }
}

private struct SettingsNumberRow: View {
    let systemName: String
    let title: String
    var detail: String? = nil
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step: Int = 1
    var suffix: String = ""

    var body: some View {
        HStack(spacing: 12) {
            SettingsGlyph(systemName: systemName)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(H3.body(size: 13, weight: .semibold))
                    .foregroundStyle(H3.ink900)
                if let detail {
                    Text(detail)
                        .font(H3.body(size: 11))
                        .foregroundStyle(H3.ink500)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                NumberAdjustButton(systemName: "minus") {
                    value = max(range.lowerBound, value - step)
                }
                .disabled(value <= range.lowerBound)
                Text("\(value)\(suffix)")
                    .font(H3.mono(size: 13, weight: .semibold))
                    .foregroundStyle(H3.ink900)
                    .frame(minWidth: suffix.isEmpty ? 42 : 70)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: H3.radius1, style: .continuous)
                            .fill(H3.ink50)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: H3.radius1, style: .continuous)
                            .stroke(H3.cardStroke, lineWidth: 1)
                    )
                NumberAdjustButton(systemName: "plus") {
                    value = min(range.upperBound, value + step)
                }
                .disabled(value >= range.upperBound)
            }
        }
    }
}

private struct NumberAdjustButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(H3.blue400)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: H3.radius1, style: .continuous)
                        .fill(H3.blue50)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsToggleRow: View {
    let systemName: String
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool
    var isDisabled: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            SettingsGlyph(systemName: systemName)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(H3.body(size: 13, weight: .semibold))
                    .foregroundStyle(isDisabled ? H3.ink300 : H3.ink900)
                if let detail {
                    Text(detail)
                        .font(H3.body(size: 11))
                        .foregroundStyle(isDisabled ? H3.ink300 : H3.ink500)
                }
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(H3.blue400)
                .disabled(isDisabled)
        }
    }
}

private struct SettingsPickerRow<Control: View>: View {
    let systemName: String
    let title: String
    var detail: String? = nil
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(spacing: 12) {
            SettingsGlyph(systemName: systemName)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(H3.body(size: 13, weight: .semibold))
                    .foregroundStyle(H3.ink900)
                if let detail {
                    Text(detail)
                        .font(H3.body(size: 11))
                        .foregroundStyle(H3.ink500)
                }
            }
            Spacer(minLength: 12)
            control()
        }
    }
}

// MARK: - Quality

private struct QualitySettingsTab: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var s = settings
        SettingsPage(title: "quality",
                     subtitle: "pick the default media shape catapult asks yt-dlp for before presets or quick actions override it.") {
            GeneralSettingsCard(title: "Video") {
                SettingsPickerRow(systemName: "rectangle.on.rectangle",
                                  title: "Max quality") {
                    Picker("", selection: $s.videoQuality) {
                        ForEach(VideoQuality.allCases) { q in
                            Text(q.label).tag(q)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
                SettingsDivider()
                SettingsPickerRow(systemName: "shippingbox",
                                  title: "Container") {
                    Picker("", selection: $s.videoContainer) {
                        ForEach(VideoContainer.allCases) { c in
                            Text(c.label).tag(c)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
            }

            GeneralSettingsCard(title: "Audio") {
                SettingsPickerRow(systemName: "waveform",
                                  title: "Audio format") {
                    Picker("", selection: $s.audioFormat) {
                        ForEach(AudioFormat.allCases) { f in
                            Text(f.label).tag(f)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
                SettingsDivider()
                HStack(spacing: 12) {
                    SettingsGlyph(systemName: "slider.horizontal.3")
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Bitrate")
                            .font(H3.body(size: 13, weight: .semibold))
                            .foregroundStyle(H3.ink900)
                        Text("Used when extracting compressed audio.")
                            .font(H3.body(size: 11))
                            .foregroundStyle(H3.ink500)
                    }
                    Spacer(minLength: 12)
                    Slider(value: Binding(
                        get: { Double(settings.audioQualityKbps) },
                        set: { s.audioQualityKbps = Int($0) }
                    ), in: 96...320, step: 32)
                    .tint(H3.blue400)
                    .frame(width: 190)
                    Text("\(settings.audioQualityKbps) kbps")
                        .font(H3.mono(size: 12, weight: .semibold))
                        .foregroundStyle(H3.ink900)
                        .frame(width: 78, alignment: .trailing)
                }
                SettingsDivider()
                SettingsToggleRow(systemName: "speaker.wave.3",
                                  title: "Match streaming loudness",
                                  detail: "Normalizes quiet downloads toward YouTube / TikTok-style playback volume.",
                                  isOn: $s.normalizeAudio)
            }

            GeneralSettingsCard(title: "Metadata") {
                SettingsToggleRow(systemName: "photo.on.rectangle",
                                  title: "Embed thumbnail",
                                  isOn: $s.embedThumbnail)
                SettingsDivider()
                SettingsToggleRow(systemName: "text.badge.checkmark",
                                  title: "Embed chapters and metadata",
                                  isOn: $s.embedMetadata)
                SettingsDivider()
                SettingsToggleRow(systemName: "captions.bubble",
                                  title: "Embed English subtitles",
                                  detail: "Uses uploaded or auto-generated captions when available.",
                                  isOn: $s.embedSubtitles)
                SettingsDivider()
                SettingsToggleRow(systemName: "photo",
                                  title: "Save thumbnail separately",
                                  isOn: $s.writeThumbnail)
            }
        }
    }
}

// MARK: - Network

private struct NetworkSettingsTab: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var s = settings
        SettingsPage(title: "network",
                     subtitle: "cookies, proxy, and bandwidth rules stay local and only get passed to yt-dlp when a download needs them.") {
            GeneralSettingsCard(title: "Cookies") {
                SettingsPickerRow(systemName: "key",
                                  title: "Import cookies from",
                                  detail: "For age-gated, private, members-only, or logged-in videos.") {
                    Picker("", selection: $s.cookieSource) {
                        ForEach(CookieSource.allCases) { c in
                            Text(c.label).tag(c)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
                if s.cookieSource != .off {
                    SettingsDivider()
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(H3.blue400)
                            .font(.system(size: 12))
                        Text("Active for \(s.siteCookies.count) site\(s.siteCookies.count == 1 ? "" : "s"). If downloads trip bot-checks, make sure you are signed in to \(s.cookieSource.label).")
                            .font(H3.body(size: 11))
                            .foregroundStyle(H3.ink500)
                    }
                    .padding(.top, 2)
                }
            }

            GeneralSettingsCard(title: "Connection") {
                HStack(alignment: .top, spacing: 12) {
                    SettingsGlyph(systemName: "point.3.connected.trianglepath.dotted")
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Proxy URL")
                            .font(H3.body(size: 13, weight: .semibold))
                            .foregroundStyle(H3.ink900)
                        Text("Leave blank unless you already use one.")
                            .font(H3.body(size: 11))
                            .foregroundStyle(H3.ink500)
                    }
                    Spacer(minLength: 12)
                    TextField("", text: $s.proxyURL,
                              prompt: Text("socks5://127.0.0.1:1080"))
                        .textFieldStyle(.plain)
                        .font(H3.mono(size: 12))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(width: 260)
                        .background(
                            RoundedRectangle(cornerRadius: H3.radius1, style: .continuous)
                                .fill(H3.ink50)
                                .overlay(
                                    RoundedRectangle(cornerRadius: H3.radius1, style: .continuous)
                                        .stroke(H3.cardStroke, lineWidth: 1)
                                )
                        )
                }
                SettingsDivider()
                HStack(spacing: 12) {
                    SettingsGlyph(systemName: "speedometer")
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Rate limit")
                            .font(H3.body(size: 13, weight: .semibold))
                            .foregroundStyle(H3.ink900)
                        Text("Useful on shared connections. Zero means unlimited.")
                            .font(H3.body(size: 11))
                            .foregroundStyle(H3.ink500)
                    }
                    Spacer(minLength: 12)
                    Slider(value: Binding(
                        get: { Double(settings.rateLimitKBps) },
                        set: { s.rateLimitKBps = Int($0) }
                    ), in: 0...20000, step: 250)
                    .tint(H3.blue400)
                    .frame(width: 190)
                    Text(settings.rateLimitKBps == 0
                         ? "unlimited"
                         : "\(settings.rateLimitKBps) KB/s")
                        .font(H3.mono(size: 12, weight: .semibold))
                        .foregroundStyle(H3.ink900)
                        .frame(width: 98, alignment: .trailing)
                }
            }

            GeneralSettingsCard(title: "Tool Updates") {
                SettingsToggleRow(systemName: "arrow.triangle.2.circlepath",
                                  title: "Auto-update yt-dlp when Catapult launches",
                                  detail: "Keeps extractors fresh before sites move the furniture around.",
                                  isOn: $s.autoUpdateYtDlpOnLaunch)
            }
        }
    }
}

// MARK: - SponsorBlock

private struct SponsorBlockTab: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var s = settings
        SettingsPage(title: "sponsorblock",
                     subtitle: "mark or remove crowd-sourced sponsor, intro, outro, and interaction segments while yt-dlp processes the video.") {
            GeneralSettingsCard(title: "Mode") {
                SettingsPickerRow(systemName: "rectangle.badge.minus",
                                  title: "Sponsor segments",
                                  detail: "Mark creates chapters. Remove cuts those sections out.") {
                    Picker("", selection: $s.sponsorBlockMode) {
                        ForEach(SponsorBlockMode.allCases) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
            }

            GeneralSettingsCard(title: "Categories") {
                VStack(spacing: 0) {
                    ForEach(Array(SponsorCategory.allCases.enumerated()), id: \.element.id) { index, cat in
                        SettingsToggleRow(systemName: sponsorIcon(for: cat),
                                          title: cat.label,
                                          isOn: Binding(
                                            get: { settings.sponsorBlockCategories.contains(cat) },
                                            set: { on in
                                                if on { s.sponsorBlockCategories.insert(cat) }
                                                else { s.sponsorBlockCategories.remove(cat) }
                                            }
                                          ),
                                          isDisabled: settings.sponsorBlockMode == .off)
                        if index != SponsorCategory.allCases.count - 1 {
                            SettingsDivider()
                        }
                    }
                }
            }
        }
    }

    private func sponsorIcon(for category: SponsorCategory) -> String {
        switch category {
        case .sponsor: return "dollarsign.circle"
        case .selfpromo: return "person.crop.circle.badge.plus"
        case .interaction: return "hand.tap"
        case .intro: return "sparkles"
        case .outro: return "rectangle.portrait.and.arrow.right"
        case .preview: return "eye"
        case .musicOfftopic: return "music.note.slash"
        case .filler: return "ellipsis.bubble"
        }
    }
}

// MARK: - Advanced

private struct AdvancedSettingsTab: View {
    @Environment(DependencyManager.self) private var dependencies
    @Environment(DownloadManager.self) private var downloads

    var body: some View {
        SettingsPage(title: "advanced",
                     subtitle: "paths and queue controls for the parts you only need when something unusual is happening.") {
            GeneralSettingsCard(title: "Tools") {
                toolPathRow(name: "yt-dlp binary",
                            path: dependencies.ytDlpPath,
                            icon: "terminal")
                SettingsDivider()
                toolPathRow(name: "ffmpeg binary",
                            path: dependencies.ffmpegPath,
                            icon: "film")
            }

            GeneralSettingsCard(title: "Queue") {
                HStack(spacing: 12) {
                    SettingsGlyph(systemName: "xmark.circle")
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Cancel running downloads")
                            .font(H3.body(size: 13, weight: .semibold))
                            .foregroundStyle(H3.ink900)
                        Text("Stops active processes and leaves finished history alone.")
                            .font(H3.body(size: 11))
                            .foregroundStyle(H3.ink500)
                    }
                    Spacer(minLength: 12)
                    SettingsMiniButton(title: "Cancel", systemName: "xmark") {
                        for i in downloads.items {
                            if case .downloading = i.status { downloads.cancel(i) }
                        }
                    }
                }
                SettingsDivider()
                HStack(spacing: 12) {
                    SettingsGlyph(systemName: "trash")
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Remove finished from list")
                            .font(H3.body(size: 13, weight: .semibold))
                            .foregroundStyle(H3.ink900)
                        Text("Clears completed, failed, and cancelled rows from the menu.")
                            .font(H3.body(size: 11))
                            .foregroundStyle(H3.ink500)
                    }
                    Spacer(minLength: 12)
                    SettingsMiniButton(title: "Clear", systemName: "trash") {
                        downloads.clearFinished()
                    }
                }
            }
        }
    }

    private func toolPathRow(name: String, path: URL, icon: String) -> some View {
        HStack(spacing: 12) {
            SettingsGlyph(systemName: icon)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(H3.body(size: 13, weight: .semibold))
                    .foregroundStyle(H3.ink900)
                Text(path.path)
                    .font(H3.mono(size: 11))
                    .foregroundStyle(H3.ink500)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 12)
            SettingsIconButton(systemName: "magnifyingglass",
                               help: "Reveal in Finder") {
                revealInFinder(path)
            }
            .disabled(!FileManager.default.fileExists(atPath: path.path))
        }
    }

    /// Reveals a file in Finder if it exists; otherwise opens its parent.
    /// Guarded because `activateFileViewerSelecting` on a missing path can
    /// spawn a ViewBridge RemoteViewService warning in Console.
    private func revealInFinder(_ url: URL) {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }
}

// MARK: - Dependencies

private struct DependenciesTab: View {
    @Environment(DependencyManager.self) private var dependencies

    var body: some View {
        SettingsPage(title: "dependencies",
                     subtitle: "yt-dlp does the site extraction; ffmpeg handles muxing, conversion, clips, and thumbnails.") {
            stateBanner
            GeneralSettingsCard(title: "Tools") {
                dependencyRow(name: "yt-dlp",
                              icon: "arrow.down.circle",
                              version: dependencies.ytDlpVersion,
                              exists: FileManager.default.fileExists(atPath: dependencies.ytDlpPath.path),
                              update: { Task { await dependencies.updateYtDlp() } },
                              reinstall: { Task { await dependencies.updateYtDlp() } })
                SettingsDivider()
                dependencyRow(name: "ffmpeg",
                              icon: "film.stack",
                              version: dependencies.ffmpegVersion,
                              exists: FileManager.default.fileExists(atPath: dependencies.ffmpegPath.path),
                              update: { Task { await dependencies.reinstallFfmpeg() } },
                              reinstall: { Task { await dependencies.reinstallFfmpeg() } })
            }
        }
    }

    @ViewBuilder
    private var stateBanner: some View {
        switch dependencies.state {
        case .ready:
            banner(icon: "checkmark.seal.fill", tint: .green,
                   title: "All dependencies are up to date",
                   subtitle: "Catapult is ready to download.")
        case .downloading(let n, let p):
            banner(icon: "arrow.down.circle.fill", tint: .blue,
                   title: "Downloading \(n)",
                   subtitle: "\(Int(p * 100))% complete",
                   progress: p)
        case .installing(let n):
            banner(icon: "hammer.fill", tint: .orange,
                   title: "Installing \(n)…",
                   subtitle: "Unpacking and signing.")
        case .checking, .unknown:
            banner(icon: "hourglass", tint: .secondary,
                   title: "Checking tools…",
                   subtitle: "")
        case .error(let msg):
            banner(icon: "exclamationmark.triangle.fill", tint: .red,
                   title: "Dependency error",
                   subtitle: msg)
        }
    }

    private func banner(icon: String, tint: Color, title: String,
                        subtitle: String, progress: Double? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: H3.radius2, style: .continuous)
                        .fill(tint.opacity(0.12))
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(H3.body(size: 14, weight: .semibold))
                    .foregroundStyle(H3.ink900)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(H3.body(size: 11))
                        .foregroundStyle(H3.ink500)
                }
                if let p = progress {
                    ProgressView(value: p)
                        .tint(tint)
                        .padding(.top, 4)
                }
            }
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: H3.radius3, style: .continuous)
                .fill(H3.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: H3.radius3, style: .continuous)
                .stroke(H3.cardStroke, lineWidth: 1)
        )
    }

    private func dependencyRow(name: String,
                               icon: String,
                               version: String?,
                               exists: Bool,
                               update: @escaping () -> Void,
                               reinstall: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            SettingsGlyph(systemName: icon)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(H3.body(size: 13, weight: .semibold))
                    .foregroundStyle(H3.ink900)
                Text(version ?? (exists ? "Installed" : "Not installed"))
                    .font(H3.body(size: 11))
                    .foregroundStyle(exists ? H3.ink500 : H3.red)
                    .lineLimit(1)
            }
            Spacer()
            SettingsMiniButton(title: exists ? "Update" : "Install",
                               systemName: "arrow.clockwise",
                               action: update)
            SettingsMiniButton(title: "Reinstall",
                               systemName: "hammer",
                               action: reinstall)
        }
    }
}

// MARK: - Sites
//
// One tile per supported site. Each can opt into cookies from a specific
// browser, independent of the global default. Useful for unlocking
// members-only or private content on a per-service basis.

private struct SitesTab: View {
    @Environment(AppSettings.self) private var settings

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        SettingsPage(title: "sites",
                     subtitle: "catapult works with anything yt-dlp supports. toggle cookies on for a site to pull them from the browser you picked in network settings — handy for private, age-gated, or members-only stuff.") {
            HStack(spacing: 12) {
                if settings.cookieSource == .off {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(H3.orange)
                        Text("Browser cookies are off in Network tab")
                            .font(H3.body(size: 11, weight: .medium))
                            .foregroundStyle(H3.orange)
                    }
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "key.fill")
                            .foregroundStyle(H3.blue400)
                        Text("Importing from \(settings.cookieSource.label)")
                            .font(H3.body(size: 11, weight: .semibold))
                            .foregroundStyle(H3.ink900)
                    }
                }
                Spacer()
                Button("enable all") {
                    settings.siteCookies = Set(SupportedSite.allCases)
                }
                .buttonStyle(.plain)
                .font(H3.body(size: 11, weight: .medium))
                .foregroundStyle(H3.blue400)

                Text("·").foregroundStyle(H3.ink300)

                Button("disable all") {
                    settings.siteCookies.removeAll()
                }
                .buttonStyle(.plain)
                .font(H3.body(size: 11, weight: .medium))
                .foregroundStyle(H3.ink500)
            }
            .padding(.horizontal, 4)

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(SupportedSite.allCases) { site in
                    SiteCard(site: site)
                }
            }
        }
    }
}

private struct SiteCard: View {
    @Environment(AppSettings.self) private var settings
    let site: SupportedSite

    private var gradient: LinearGradient {
        switch site {
        case .youtube:    return H3.gradRainbow
        case .tiktok:     return H3.gradDeep
        case .twitter:    return H3.gradSky
        case .reddit:     return H3.gradRainbow
        case .instagram:  return H3.gradBubble
        case .facebook:   return H3.gradDeep
        case .twitch:     return H3.gradBubble
        case .vimeo:      return H3.gradPool
        case .soundcloud: return H3.gradRainbow
        case .spotify:    return H3.gradDeep
        case .bilibili:   return H3.gradPool
        case .bluesky:    return H3.gradSky
        case .generic:    return H3.gradBubble
        }
    }

    private var hasCookies: Bool { settings.siteCookies.contains(site) }

    private var cookieBinding: Binding<Bool> {
        Binding(
            get: { settings.siteCookies.contains(site) },
            set: { on in
                if on { settings.siteCookies.insert(site) }
                else  { settings.siteCookies.remove(site) }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                GradientGlyph(systemName: site.glyph,
                              gradient: gradient,
                              size: 32)
                Spacer()
                if hasCookies {
                    Image(systemName: "key.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(H3.blue400)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(site.title)
                    .font(H3.body(size: 13, weight: .semibold))
                    .foregroundStyle(H3.ink900)
                Text(site.blurb)
                    .font(H3.body(size: 11))
                    .foregroundStyle(H3.ink500)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)
            }

            Spacer(minLength: 2)

            Toggle(isOn: cookieBinding) {
                HStack(spacing: 4) {
                    Image(systemName: hasCookies ? "key.fill" : "key")
                        .font(.system(size: 10, weight: .semibold))
                    Text("use cookies")
                        .font(H3.body(size: 11, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(hasCookies ? H3.blue400 : H3.ink500)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(H3.blue400)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: H3.radius3, style: .continuous)
                .fill(H3.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: H3.radius3, style: .continuous)
                .stroke(hasCookies ? H3.blue400 : H3.cardStroke,
                        lineWidth: hasCookies ? 1.5 : 1)
        )
        .shadow(color: H3.shadowDrop.opacity(0.15), radius: 4, x: 0, y: 2)
    }
}

// MARK: - Terminal (CLI installer)

private struct TerminalTab: View {
    @State private var status: CLIInstaller.Status = CLIInstaller.currentInstall
    @State private var error: String? = nil
    @State private var lastCopied: Bool = false
    @State private var pathWriteMessage: String? = nil

    private let exampleCommands: [(String, String)] = [
        ("catapult",                      "launch the tui (or use the `capu` alias)"),
        ("capu video <url>",              "download as video"),
        ("capu small <url>",              "download only if it fits the size limit"),
        ("capu audio <url>",              "extract audio"),
        ("capu thumb <url>",              "save the thumbnail"),
        ("capu cut <url> 0:12 0:42",      "clip a section"),

        ("capu doctor",                   "check install, tools, and update route"),
        ("capu queue",                    "list recent downloads"),
    ]

    var body: some View {
        SettingsPage(title: "terminal",
                     subtitle: "prefer the keyboard? install the catapult cli — a tiny tui that shares this app's settings and binaries. works as one-shot commands too.") {
            installCard
            commandsCard
            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 4)
            }
        }
        .onAppear { status = CLIInstaller.currentInstall }
    }

    @ViewBuilder
    private var installCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ChannelTile(gradient: H3.gradDeep, content: {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(H3.blue500)
                }, size: 56)

                VStack(alignment: .leading, spacing: 4) {
                    switch status {
                    case .notInstalled:
                        Text("not installed")
                            .font(H3.body(size: 14, weight: .semibold))
                            .foregroundStyle(H3.ink900)
                        Text("i'll copy a ~8kb script to /usr/local/bin/catapult (or ~/.local/bin if that's not writable). nothing sudo, no background anything.")
                            .font(H3.body(size: 12))
                            .foregroundStyle(H3.ink500)
                            .fixedSize(horizontal: false, vertical: true)
                    case .installed(let path, let onPath, let isCurrent):
                        HStack(spacing: 6) {
                            Circle()
                                .fill(onPath && isCurrent ? H3.green : H3.amber)
                                .frame(width: 8, height: 8)
                            Text(cliStatusLabel(onPath: onPath, isCurrent: isCurrent))
                                .font(H3.body(size: 14, weight: .semibold))
                                .foregroundStyle(H3.ink900)
                        }
                        Text(path)
                            .font(H3.mono(size: 11))
                            .foregroundStyle(H3.ink500)
                            .textSelection(.enabled)
                        if CLIInstaller.hasCapuAlias {
                            Text("also installed as ‘capu’ — same thing, fewer keystrokes.")
                                .font(H3.body(size: 11))
                                .foregroundStyle(H3.ink500)
                        }
                        if !isCurrent {
                            Text("your installed command is from an older app build. reinstall to refresh it.")
                                .font(H3.body(size: 11))
                                .foregroundStyle(H3.amber)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !onPath {
                            Text("add this line to your ~/.zshrc, then restart terminal — or let me do it for you:")
                                .font(H3.body(size: 11))
                                .foregroundStyle(H3.ink500)
                                .fixedSize(horizontal: false, vertical: true)
                            pathHelper(path: path)
                            if let msg = pathWriteMessage {
                                Text(msg)
                                    .font(H3.body(size: 11))
                                    .foregroundStyle(H3.green)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                switch status {
                case .notInstalled:
                    H3Button(gradient: H3.gradDeep) { doInstall() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.to.line")
                            Text("install catapult cli")
                        }
                    }
                case .installed(_, let onPath, _):
                    H3Button(gradient: H3.gradDeep) {
                        CLIInstaller.launchInTerminal()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                            Text("launch in terminal")
                        }
                    }
                    if !onPath {
                        H3Button(gradient: H3.gradDeep, filled: false) { doFixPath() } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "wand.and.stars")
                                Text("do it for me")
                            }
                        }
                    }
                    H3Button(gradient: H3.gradDeep, filled: false) { doInstall() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                            Text("reinstall")
                        }
                    }
                    H3Button(gradient: H3.gradDeep, filled: false) { doUninstall() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "trash")
                            Text("uninstall")
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: H3.radius3, style: .continuous)
                .fill(H3.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: H3.radius3, style: .continuous)
                .stroke(H3.cardStroke, lineWidth: 1)
        )
        .shadow(color: H3.shadowDrop.opacity(0.15), radius: 4, y: 2)
    }

    private func pathHelper(path: String) -> some View {
        let dir = (path as NSString).deletingLastPathComponent
        let line = "export PATH=\"\(dir):$PATH\""
        return HStack(spacing: 8) {
            Text(line)
                .font(H3.mono(size: 11))
                .foregroundStyle(H3.ink700)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(H3.ink100)
                )
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(line, forType: .string)
                lastCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { lastCopied = false }
            } label: {
                Image(systemName: lastCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(lastCopied ? H3.green : H3.blue400)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(H3.blue50)
                    )
            }
            .buttonStyle(.plain)
            .help("Copy to clipboard")
        }
    }

    private func cliStatusLabel(onPath: Bool, isCurrent: Bool) -> String {
        if !isCurrent { return "installed — update available" }
        return onPath ? "installed, on your path" : "installed — not on your path yet"
    }

    private var commandsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("commands")
                .font(H3.body(size: 13, weight: .semibold))
                .foregroundStyle(H3.ink700)
            VStack(spacing: 6) {
                ForEach(exampleCommands, id: \.0) { cmd, desc in
                    HStack(spacing: 12) {
                        Text(cmd)
                            .font(H3.mono(size: 11))
                            .foregroundStyle(H3.blue500)
                            .frame(width: 240, alignment: .leading)
                            .textSelection(.enabled)
                        Text(desc)
                            .font(H3.body(size: 11))
                            .foregroundStyle(H3.ink500)
                        Spacer()
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: H3.radius3, style: .continuous)
                .fill(H3.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: H3.radius3, style: .continuous)
                .stroke(H3.cardStroke, lineWidth: 1)
        )
    }

    private func doInstall() {
        error = nil
        do {
            _ = try CLIInstaller.install()
            status = CLIInstaller.currentInstall
        } catch let e {
            error = e.localizedDescription
        }
    }

    private func doUninstall() {
        CLIInstaller.uninstall()
        status = CLIInstaller.currentInstall
        pathWriteMessage = nil
    }

    private func doFixPath() {
        guard case .installed(let path, _, _) = status else { return }
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        let result = CLIInstaller.addDirectoryToShellPath(dir)
        switch result {
        case .wroteTo(let file):
            let abbreviated = (file as NSString).abbreviatingWithTildeInPath
            pathWriteMessage = "added to \(abbreviated) — open a new terminal tab and `catapult` should work."
        case .alreadyPresent:
            pathWriteMessage = "already in your shell config — open a new terminal tab to pick it up."
        case .noWritableRc:
            error = "couldn't write to your shell config — the file may be read-only."
        }
        // Refresh status so the warning banner updates on the next app relaunch;
        // existing sessions won't pick up the export mid-flight, which is expected.
        status = CLIInstaller.currentInstall
    }
}

// MARK: - Subscriptions
//
// Manage creator subscriptions. YouTube uses public RSS; TikTok and other
// supported profile/playlist URLs use yt-dlp flat playlist polling.

private struct SubscriptionsTab: View {
    @State private var subs = SubscriptionManager.shared
    @State private var newInput: String = ""
    @State private var resolving: Bool = false
    @State private var resolveError: String? = nil
    @State private var checking: Bool = false

    var body: some View {
        SettingsPage(title: "subscriptions",
                     subtitle: "watch creators from youtube, tiktok, instagram, soundcloud, vimeo, x, and more. paste a channel, profile, playlist, or collection url and i'll check for new posts.") {
            addCard
            controlsCard
            if subs.subscriptions.isEmpty {
                emptyCard
            } else {
                VStack(spacing: 8) {
                    ForEach(subs.subscriptions) { sub in
                        SubscriptionRow(sub: sub)
                    }
                }
            }
        }
    }

    private var addCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SettingsGlyph(systemName: "plus")
                TextField("channel, profile, playlist, or collection url",
                          text: $newInput,
                          prompt: Text("https://www.tiktok.com/@h3nryXYZ"))
                    .textFieldStyle(.plain)
                    .font(H3.body(size: 13))
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(settingsFieldBackground)
                    .onSubmit(addChannel)
                SettingsMiniButton(title: resolving ? "Resolving" : "Watch",
                                   systemName: resolving ? "hourglass" : "play.circle") {
                    addChannel()
                }
                    .disabled(newInput.trimmingCharacters(in: .whitespaces).isEmpty || resolving)
            }
            if resolving {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("resolving channel…")
                        .font(H3.body(size: 11))
                        .foregroundStyle(H3.ink500)
                }
            }
            if let msg = resolveError {
                Text(msg)
                    .font(H3.body(size: 11))
                    .foregroundStyle(H3.red)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: H3.radius3, style: .continuous).fill(H3.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: H3.radius3, style: .continuous)
                .stroke(H3.cardStroke, lineWidth: 1)
        )
    }

    private var controlsCard: some View {
        HStack(spacing: 14) {
            SettingsGlyph(systemName: "antenna.radiowaves.left.and.right")
            Text("Auto-check")
                .font(H3.body(size: 13, weight: .semibold))
                .foregroundStyle(H3.ink900)
            Toggle("", isOn: Binding(
                get: { subs.enabled },
                set: { subs.enabled = $0 }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(H3.blue400)
            Divider().frame(height: 20)
            Text("Every")
                .font(H3.body(size: 12, weight: .semibold))
                .foregroundStyle(H3.ink500)
            HStack(spacing: 8) {
                NumberAdjustButton(systemName: "minus") {
                    subs.pollMinutes = max(15, subs.pollMinutes - 15)
                }
                .disabled(subs.pollMinutes <= 15)
                Text("\(subs.pollMinutes) min")
                    .font(H3.mono(size: 12, weight: .semibold))
                    .foregroundStyle(H3.ink900)
                    .frame(width: 74)
                    .frame(height: 30)
                    .background(settingsFieldBackground)
                NumberAdjustButton(systemName: "plus") {
                    subs.pollMinutes = min(720, subs.pollMinutes + 15)
                }
                .disabled(subs.pollMinutes >= 720)
            }
            Spacer()
            if let last = subs.lastCheckAt {
                Text("last: \(last.formatted(date: .omitted, time: .shortened))")
                    .font(H3.body(size: 11))
                    .foregroundStyle(H3.ink500)
            }
            SettingsMiniButton(title: checking ? "Checking" : "Check now",
                               systemName: checking ? "hourglass" : "arrow.clockwise") {
                checkNow()
            }
            .disabled(subs.subscriptions.isEmpty || checking)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: H3.radius3, style: .continuous).fill(H3.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: H3.radius3, style: .continuous)
                .stroke(H3.cardStroke, lineWidth: 1)
        )
    }

    private var settingsFieldBackground: some View {
        RoundedRectangle(cornerRadius: H3.radius1, style: .continuous)
            .fill(H3.ink50)
            .overlay(
                RoundedRectangle(cornerRadius: H3.radius1, style: .continuous)
                    .stroke(H3.cardStroke, lineWidth: 1)
            )
    }

    private var emptyCard: some View {
        HStack(spacing: 8) {
            SettingsGlyph(systemName: "tray")
            Text("no subscriptions yet — paste a creator, profile, or playlist url above.")
                .font(H3.body(size: 12))
                .foregroundStyle(H3.ink500)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: H3.radius3, style: .continuous)
                .fill(H3.cardFill.opacity(0.5))
        )
    }

    private func addChannel() {
        let input = newInput.trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty else { return }
        resolving = true
        resolveError = nil
        Task {
            let resolved = await SubscriptionManager.resolveChannel(from: input)
            await MainActor.run {
                resolving = false
                if let r = resolved {
                    subs.add(channelID: r.id,
                             title: r.title,
                             source: r.source,
                             sourceURL: r.sourceURL)
                    newInput = ""
                } else {
                    resolveError = "couldn't find a supported feed there — try a public profile, channel, playlist, or collection url."
                }
            }
        }
    }

    private func checkNow() {
        checking = true
        Task {
            _ = await subs.checkNow(force: true)
            await MainActor.run { checking = false }
        }
    }
}

private struct SubscriptionRow: View {
    let sub: ChannelSubscription
    @State private var manager = SubscriptionManager.shared
    @State private var showOptions = false

    var body: some View {
        HStack(spacing: 12) {
            GradientGlyph(systemName: sub.source.glyph,
                          gradient: H3.gradRainbow,
                          size: 28)
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(sub.channelTitle)
                    .font(H3.body(size: 13, weight: .semibold))
                    .foregroundStyle(H3.ink900)
                HStack(spacing: 6) {
                    Image(systemName: modeIcon(sub.downloadMode))
                        .font(.system(size: 9))
                    Text(sub.source.label)
                        .font(H3.body(size: 10))
                    Text("·").font(H3.body(size: 10))
                    Text(modeLabel(sub.downloadMode))
                        .font(H3.body(size: 10))
                    Text("·").font(H3.body(size: 10))
                    Text(sub.videoQuality.label.lowercased())
                        .font(H3.body(size: 10))
                    if sub.devicePreset != .none {
                        Text("·").font(H3.body(size: 10))
                        Text(sub.devicePreset.label)
                            .font(H3.body(size: 10))
                    }
                    Text("·").font(H3.body(size: 10))
                    Text(sub.channelID)
                        .font(H3.mono(size: 10))
                        .foregroundStyle(H3.ink300)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(H3.ink500)
            }
            Spacer()
            Menu {
                Picker("mode", selection: Binding(
                    get: { sub.downloadMode },
                    set: { mode in
                        var s = sub; s.downloadMode = mode; manager.update(s)
                    }
                )) {
                    Text("Video").tag(DownloadMode.video)
                    Text("Audio").tag(DownloadMode.audio)
                }
                Picker("max quality", selection: Binding(
                    get: { sub.videoQuality },
                    set: { q in
                        var s = sub; s.videoQuality = q; manager.update(s)
                    }
                )) {
                    ForEach(VideoQuality.allCases) { q in
                        Text(q.label).tag(q)
                    }
                }
                Picker("preset", selection: Binding(
                    get: { sub.devicePreset },
                    set: { p in
                        var s = sub; s.devicePreset = p; manager.update(s)
                    }
                )) {
                    ForEach(DevicePreset.allCases) { p in
                        Text(p.label).tag(p)
                    }
                }
                Divider()
                Button("unsubscribe", role: .destructive) {
                    manager.remove(id: sub.channelID)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(H3.ink500)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: H3.radius3, style: .continuous).fill(H3.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: H3.radius3, style: .continuous)
                .stroke(H3.cardStroke, lineWidth: 1)
        )
    }

    private func modeIcon(_ m: DownloadMode) -> String {
        switch m {
        case .video: return "play.rectangle"
        case .audio: return "music.note"
        case .cut:   return "scissors"
        case .thumbnailOnly: return "photo"
        }
    }
    private func modeLabel(_ m: DownloadMode) -> String {
        switch m {
        case .video: return "video"
        case .audio: return "audio"
        case .cut:   return "cut"
        case .thumbnailOnly: return "thumbnail"
        }
    }
}

// MARK: - Device presets tab
//
// A grid of "download for device X" recipes. Clicking a preset doesn't
// immediately run — it sets the app-wide default so subsequent downloads
// use it. Handy when you're about to download a batch for one device.

private struct DevicePresetsTab: View {
    @Environment(AppSettings.self) private var settings

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    private var modern: [DevicePreset] {
        DevicePreset.allCases.filter { $0 != .none && !$0.isRetro }
    }
    private var retro: [DevicePreset] {
        DevicePreset.allCases.filter { $0.isRetro }
    }

    var body: some View {
        SettingsPage(title: "devices",
                     subtitle: "one-tap recipes for specific hardware. retro presets transcode to h.264 baseline at the exact resolution the device accepts — so a 2006 ipod or a psp actually plays the file.") {
            section(title: "modern", presets: modern)
            section(title: "retro slop", presets: retro)

            Text("tip: hold ⌘-click on the download button to pick a preset per-download. these tiles set your default — clear it by choosing 'no preset'.")
                .font(H3.body(size: 11))
                .foregroundStyle(H3.ink500)
                .padding(.horizontal, 4)
                .padding(.top, 4)
        }
    }

    private func section(title: String, presets: [DevicePreset]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(H3.body(size: 12, weight: .semibold))
                .foregroundStyle(H3.ink700)
                .padding(.horizontal, 4)
            LazyVGrid(columns: columns, spacing: 12) {
                PresetTile(preset: .none)  // "no preset" sentinel
                ForEach(presets) { p in
                    PresetTile(preset: p)
                }
            }
        }
    }
}

private struct PresetTile: View {
    @Environment(AppSettings.self) private var settings
    let preset: DevicePreset

    private var isSelected: Bool {
        settings.defaultDevicePreset == preset
    }

    private var gradient: LinearGradient {
        switch preset {
        case .none, .plex:        return H3.gradBubble
        case .iphone, .ipadPro:   return H3.gradDeep
        case .discord10mb:        return H3.gradPool
        case .psp, .ps3, .psvita: return H3.gradRainbow
        case .ipodClassic, .ipodTouch: return H3.gradPool
        case .oldAndroid:         return H3.gradBubble
        case .pocketPC:           return H3.gradSky
        case .nintendo3ds:        return H3.gradRainbow
        case .gbaVideo:           return H3.gradDeep
        }
    }

    var body: some View {
        Button {
            settings.defaultDevicePreset = preset
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    GradientGlyph(systemName: preset.glyph,
                                  gradient: gradient,
                                  size: 30)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(H3.blue400)
                    }
                }
                Text(preset.label)
                    .font(H3.body(size: 12, weight: .semibold))
                    .foregroundStyle(H3.ink900)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(preset.blurb)
                    .font(H3.body(size: 10))
                    .foregroundStyle(H3.ink500)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(4)
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: H3.radius3, style: .continuous)
                    .fill(isSelected ? H3.blue50 : H3.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: H3.radius3, style: .continuous)
                    .stroke(isSelected ? H3.blue400 : H3.cardStroke,
                            lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - About

private struct AboutTab: View {
    var body: some View {
        SettingsPage(title: "about",
                     subtitle: "the tiny h3-flavored macos companion around yt-dlp, ffmpeg, and your downloads folder.") {
            VStack(spacing: 18) {
                TiltyAppIcon(size: 190)
                    .padding(.top, 6)
                Text("Catapult")
                    .font(H3.display(size: 34, weight: .medium))
                    .foregroundStyle(H3.ink900)
                Text("a beautifully native yt-dlp companion for macos.")
                    .font(H3.body(size: 13))
                    .foregroundStyle(H3.ink500)
                    .multilineTextAlignment(.center)
                HStack(spacing: 16) {
                    Link("yt-dlp", destination: URL(string: "https://github.com/yt-dlp/yt-dlp")!)
                    Link("ffmpeg", destination: URL(string: "https://ffmpeg.org")!)
                    Link("updates", destination: URL(string: "https://github.com/HenryTheAddict/Catapult/releases")!)
                }
                .font(H3.body(size: 12, weight: .semibold))
                .foregroundStyle(H3.blue400)
            }
            .frame(maxWidth: .infinity)
            .padding(22)
            .background(
                RoundedRectangle(cornerRadius: H3.radius3, style: .continuous)
                    .fill(H3.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: H3.radius3, style: .continuous)
                    .stroke(H3.cardStroke, lineWidth: 1)
            )
        }
    }
}

// MARK: - Tilty app icon
//
// The app icon, but it tilts toward the cursor and gets a moving specular
// shine. Hover-driven 3D rotation feels like an iOS lock-screen widget; the
// shine highlight sweeps with the cursor for that "wet plastic" / Frutiger
// Aero polish. Falls back to a static icon when the cursor leaves.

private struct TiltyAppIcon: View {
    let size: CGFloat
    @State private var hoverPoint: CGPoint? = nil

    /// Max tilt angle in degrees — beyond ~16° it starts to look unhinged.
    private let maxTilt: Double = 14
    /// Inset on the shine highlight, as a fraction of size. Wider = softer.
    private let shineHalfWidth: CGFloat = 0.25

    var body: some View {
        let center = CGPoint(x: size / 2, y: size / 2)
        let h = hoverPoint ?? center
        // Normalize to -1…1 across each axis so tilt amount scales with view.
        let nx = clamp((h.x - center.x) / center.x, -1, 1)
        let ny = clamp((h.y - center.y) / center.y, -1, 1)

        // y-cursor tilts on the x-axis (up = top tips toward you).
        // x-cursor tilts on the y-axis. Inverting `ny` keeps "tilt toward
        // cursor" rather than "away" — same feel as iOS widgets.
        let rotX = -Double(ny) * maxTilt
        let rotY =  Double(nx) * maxTilt

        return ZStack {
            AppIconView(size: size)
                .overlay(shineOverlay(normX: nx))
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        }
        .frame(width: size, height: size)
        .rotation3DEffect(.degrees(rotX), axis: (x: 1, y: 0, z: 0),
                          anchor: .center, anchorZ: 0, perspective: 0.6)
        .rotation3DEffect(.degrees(rotY), axis: (x: 0, y: 1, z: 0),
                          anchor: .center, anchorZ: 0, perspective: 0.6)
        .scaleEffect(hoverPoint == nil ? 1.0 : 1.04)
        .shadow(color: .accentColor.opacity(0.35),
                radius: hoverPoint == nil ? 18 : 28,
                y: hoverPoint == nil ? 6 : 12)
        .animation(.interactiveSpring(response: 0.32, dampingFraction: 0.7),
                   value: hoverPoint)
        .onContinuousHover { phase in
            switch phase {
            case .active(let pt): hoverPoint = pt
            case .ended:          hoverPoint = nil
            }
        }
    }

    /// A diagonal highlight band whose center tracks the cursor's x-axis.
    /// `softLight` blends it into the underlying icon without flattening
    /// the existing artwork.
    private func shineOverlay(normX: CGFloat) -> some View {
        // Map -1…1 → 0…1 for placement along the icon's width.
        let p = (normX + 1) / 2
        let start = max(0.0, p - shineHalfWidth)
        let end   = min(1.0, p + shineHalfWidth)
        return LinearGradient(
            stops: [
                .init(color: .white.opacity(0.0),  location: start),
                .init(color: .white.opacity(0.55), location: (start + end) / 2),
                .init(color: .white.opacity(0.0),  location: end),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .blendMode(.softLight)
        .opacity(hoverPoint == nil ? 0.0 : 1.0)
        .allowsHitTesting(false)
    }

    private func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T {
        min(max(v, lo), hi)
    }
}

// MARK: - App version helper

enum AppVersion {
    static var short: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}

// MARK: - History tab

private struct HistoryTab: View {
    @State private var history = HistoryStore.shared
    @State private var query: String = ""
    @State private var filter: Filter = .all

    private enum Filter: String, CaseIterable, Identifiable {
        case all, finished, failed, cancelled
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all:       return "All"
            case .finished:  return "Finished"
            case .failed:    return "Failed"
            case .cancelled: return "Cancelled"
            }
        }
    }

    private var filtered: [HistoryEntry] {
        history.entries.filter { e in
            switch filter {
            case .all: break
            case .finished:  if e.outcome != .finished  { return false }
            case .failed:    if e.outcome != .failed    { return false }
            case .cancelled: if e.outcome != .cancelled { return false }
            }
            guard !query.isEmpty else { return true }
            let q = query.lowercased()
            return e.title.lowercased().contains(q) ||
                   e.url.lowercased().contains(q) ||
                   (e.uploader?.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        SettingsPage(title: "history",
                     subtitle: "recent downloads, failures, and cancelled items stay here so you can retry, reveal, or copy the original link.") {
            GeneralSettingsCard(title: "Search") {
                HStack(spacing: 10) {
                    Picker("", selection: $filter) {
                        ForEach(Filter.allCases) { f in
                            Text(f.label).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()

                    TextField("Search title, channel, URL...", text: $query)
                        .textFieldStyle(.plain)
                        .font(H3.body(size: 12))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: H3.radius1, style: .continuous)
                                .fill(H3.ink50)
                                .overlay(
                                    RoundedRectangle(cornerRadius: H3.radius1, style: .continuous)
                                        .stroke(H3.cardStroke, lineWidth: 1)
                                )
                        )

                    SettingsMiniButton(title: "Clear", systemName: "trash") {
                        HistoryStore.shared.clearAll()
                    }
                    .disabled(history.entries.isEmpty)
                }
            }

            GeneralSettingsCard(title: "Downloads") {
                if filtered.isEmpty {
                    HStack(spacing: 10) {
                        SettingsGlyph(systemName: "tray")
                        Text(history.entries.isEmpty
                             ? "no downloads yet - go grab something."
                             : "no results.")
                            .font(H3.body(size: 13))
                            .foregroundStyle(H3.ink500)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, entry in
                            HistoryRow(entry: entry)
                                .contextMenu {
                                    if let fileURL = entry.outputFile, entry.fileExists {
                                        Button("Show in Finder") {
                                            HistoryStore.shared.reveal(entry)
                                        }
                                        Button("Open in QuickTime") {
                                            NSWorkspace.openInQuickTime(url: fileURL)
                                        }
                                    }
                                    Button("Copy source URL") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(entry.url, forType: .string)
                                    }
                                    Divider()
                                    Button("Remove from history", role: .destructive) {
                                        HistoryStore.shared.remove(entry)
                                    }
                                }
                            if index != filtered.count - 1 {
                                SettingsDivider()
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private var iconName: String {
        switch entry.outcome {
        case .finished:  return "checkmark.circle.fill"
        case .failed:    return "xmark.octagon.fill"
        case .cancelled: return "minus.circle.fill"
        }
    }
    private var iconTint: Color {
        switch entry.outcome {
        case .finished:  return H3.green
        case .failed:    return H3.red
        case .cancelled: return H3.ink300
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(iconTint)
                .font(.system(size: 16))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(H3.body(size: 13, weight: .semibold))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let u = entry.uploader, !u.isEmpty {
                        Text(u).foregroundStyle(.secondary)
                        Text("•").foregroundStyle(.tertiary)
                    }
                    Text(modeLabel)
                        .foregroundStyle(.secondary)
                    if let s = entry.fileSizeBytes {
                        Text("•").foregroundStyle(.tertiary)
                        Text(ByteCountFormatter.string(fromByteCount: s, countStyle: .file))
                            .foregroundStyle(.secondary)
                    }
                    Text("•").foregroundStyle(.tertiary)
                    Text(Self.dateFormatter.string(from: entry.finishedAt))
                        .foregroundStyle(.secondary)
                }
                .font(H3.body(size: 11))
                if let err = entry.errorMessage, !err.isEmpty {
                    Text(err)
                        .font(H3.body(size: 11))
                        .foregroundStyle(H3.red)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            if entry.outputFile != nil, entry.fileExists {
                Button {
                    HistoryStore.shared.reveal(entry)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
            }
        }
        .padding(.vertical, 4)
    }

    private var modeLabel: String {
        switch entry.mode {
        case .video:         return "video"
        case .audio:         return "audio"
        case .cut:           return "clip"
        case .thumbnailOnly: return "thumbnail"
        }
    }
}
