import SwiftUI
import AppKit
import UserNotifications

// MARK: - Onboarding host window
//
// First-run welcome flow. Keep it quiet, native, and readable.

struct OnboardingWindow: View {
    @Environment(AppSettings.self) private var settings
    @Environment(DependencyManager.self) private var dependencies
    var onFinish: () -> Void = {}

    @State private var step: Int = 0
    @State private var notificationGranted: Bool? = nil
    @State private var showingMusicPrompt = true

    private let totalSteps = 6
    private let music = OnboardingMusicController.shared

    var body: some View {
        ZStack {
            OnboardingBackground()

            // Step content
            VStack(spacing: 18) {
                stepDots
                    .padding(.top, 24)

                Group {
                    switch step {
                    case 0: welcomeStep
                    case 1: notificationsStep
                    case 2: folderStep
                    case 3: filenameStep
                    case 4: toolsStep
                    default: readyStep
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Horizontal breathing room so headings never kiss the window edge.
                .padding(.horizontal, 36)
                .transition(.opacity.combined(with: .move(edge: .trailing)))

                navBar
                    .padding(.horizontal, 28)
                    .padding(.bottom, 22)
            }

            // Music prompt — floats above everything until the user picks.
            if showingMusicPrompt {
                musicPromptOverlay
                    .transition(.opacity)
            }
        }
        .frame(width: 680, height: 520)
        .animation(H3.easeOut, value: step)
        .animation(H3.easeOut, value: showingMusicPrompt)
        .onAppear {
            FontLoader.registerBundled()
        }
        // Apply h3 transparent title bar so the sky gradient flows up under
        // the traffic lights. Lets the window feel of a piece with the rest
        // of the onboarding rather than wearing default macOS chrome.
        .h3WindowChrome()
        // Wire up music stem player — step changes and app focus events.
        .onChange(of: step) { _, new in music.stepChanged(to: new) }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            music.focusChanged(isFocused: true)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.willResignActiveNotification)) { _ in
            music.focusChanged(isFocused: false)
        }
        .onDisappear { music.stop() }
    }

    // MARK: Step — welcome

    private var welcomeStep: some View {
        VStack(spacing: 18) {
            AppIconMark()
                .padding(.top, 8)

            VStack(spacing: 8) {
                Text("welcome to catapult")
                    .font(H3.display(size: 34, weight: .medium))
                    .foregroundStyle(H3.ink900)
                Text("a tiny menu-bar thing that grabs videos for you. paste a link, i'll do the rest.")
                    .font(H3.body(size: 15))
                    .foregroundStyle(H3.ink500)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(nil)
                    .frame(maxWidth: 480)
                    .padding(.horizontal, 40)
            }
        }
    }

    // MARK: Step — notifications

    private var notificationsStep: some View {
        VStack(spacing: 16) {
            OnboardingGlyph(systemName: "bell.badge.fill")

            Text("let me ping you when a download finishes")
                .font(H3.display(size: 26, weight: .medium))
                .foregroundStyle(H3.ink900)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)

            Text("small, native, and easy to turn off later.")
                .font(H3.body(size: 13))
                .foregroundStyle(H3.ink500)

            HStack(spacing: 10) {
                H3Button(gradient: H3.gradDeep) {
                    requestNotificationPermission()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: notificationGranted == true ? "checkmark" : "bell.fill")
                        Text(notificationGranted == true ? "allowed, thanks" : "allow notifications")
                    }
                }
                .fixedSize()
                H3Button(gradient: H3.gradDeep, filled: false) {
                    step += 1
                } label: {
                    Text("skip for now")
                }
                .fixedSize()
            }
            .padding(.top, 6)
        }
    }

    // MARK: Step — folder

    private var folderStep: some View {
        @Bindable var s = settings
        return VStack(spacing: 14) {
            OnboardingGlyph(systemName: "folder.fill")

            Text("where should i drop your files?")
                .font(H3.display(size: 26, weight: .medium))
                .foregroundStyle(H3.ink900)

            Text("by default, a catapult folder in your downloads.")
                .font(H3.body(size: 13))
                .foregroundStyle(H3.ink500)

            H3Card {
                HStack(spacing: 10) {
                    Image(systemName: "tray.and.arrow.down")
                        .foregroundStyle(H3.blue400)
                    Text((settings.downloadFolderPath as NSString).abbreviatingWithTildeInPath)
                        .font(H3.mono(size: 12))
                        .foregroundStyle(H3.ink700)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button("change…") { chooseFolder() }
                        .buttonStyle(.plain)
                        .font(H3.body(size: 13, weight: .semibold))
                        .foregroundStyle(H3.blue400)
                }
            }
            .frame(maxWidth: 480)
        }
    }

    // MARK: Step — filename preset

    private var filenameStep: some View {
        @Bindable var s = settings
        return VStack(spacing: 14) {
            OnboardingGlyph(systemName: "textformat")

            Text("pick a filename style")
                .font(H3.display(size: 26, weight: .medium))
                .foregroundStyle(H3.ink900)

            Text("you can change this any time in settings.")
                .font(H3.body(size: 13))
                .foregroundStyle(H3.ink500)

            VStack(spacing: 10) {
                ForEach([FilenamePreset.simple, .normal, .nerd], id: \.self) { p in
                    presetRow(p, bind: $s.filenamePreset)
                }
            }
            .frame(maxWidth: 480)
        }
    }

    private func presetRow(_ preset: FilenamePreset, bind: Binding<FilenamePreset>) -> some View {
        let selected = bind.wrappedValue == preset
        return Button {
            bind.wrappedValue = preset
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? H3.blue400 : H3.ink300)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.label.lowercased())
                        .font(H3.body(size: 14, weight: .semibold))
                        .foregroundStyle(H3.ink900)
                    Text(preset.hint)
                        .font(H3.body(size: 12))
                        .foregroundStyle(H3.ink500)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: H3.radius2, style: .continuous)
                    .fill(selected ? H3.blue50 : H3.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: H3.radius2, style: .continuous)
                    .stroke(selected ? H3.blue400 : H3.cardStroke, lineWidth: selected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Step — tools

    private var toolsStep: some View {
        VStack(spacing: 16) {
            OnboardingGlyph(systemName: toolsIcon, tint: toolsTint)

            Text("checking the download engine")
                .font(H3.display(size: 26, weight: .medium))
                .foregroundStyle(H3.ink900)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)

            Text("catapult keeps yt-dlp and ffmpeg in its own app support folder, then repairs them before a download gives up.")
                .font(H3.body(size: 13))
                .foregroundStyle(H3.ink500)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)

            H3Card {
                HStack(spacing: 12) {
                    Image(systemName: toolsIcon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(toolsTint)
                        .frame(width: 30, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: H3.radius2, style: .continuous)
                                .fill(toolsTint.opacity(0.12))
                        )
                    VStack(alignment: .leading, spacing: 3) {
                        Text(toolsTitle)
                            .font(H3.body(size: 13, weight: .semibold))
                            .foregroundStyle(H3.ink900)
                        Text(toolsSubtitle)
                            .font(H3.body(size: 11))
                            .foregroundStyle(H3.ink500)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 10)
                    if toolsCanRefresh {
                        H3Button(gradient: H3.gradDeep, filled: false) {
                            Task { await dependencies.ensureInstalled() }
                        } label: {
                            Text("check")
                        }
                        .fixedSize()
                    }
                }
            }
            .frame(maxWidth: 480)
        }
    }

    private var toolsIcon: String {
        switch dependencies.state {
        case .ready: return "checkmark.seal.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .downloading: return "arrow.down.circle.fill"
        case .installing: return "hammer.fill"
        case .checking, .unknown: return "hourglass"
        }
    }

    private var toolsTint: Color {
        switch dependencies.state {
        case .ready: return .green
        case .error: return .red
        case .installing: return .orange
        default: return H3.blue400
        }
    }

    private var toolsTitle: String {
        switch dependencies.state {
        case .ready: return "tools ready"
        case .downloading(let name, let progress):
            return "downloading \(name) \(Int(progress * 100))%"
        case .installing(let name): return "installing \(name)"
        case .error: return "tools need attention"
        case .checking, .unknown: return "checking tools"
        }
    }

    private var toolsSubtitle: String {
        switch dependencies.state {
        case .ready:
            return "yt-dlp \(dependencies.ytDlpVersion ?? "installed") · ffmpeg ready"
        case .error(let message):
            return message
        case .downloading, .installing:
            return "keep this open or continue; setup runs in the background."
        case .checking, .unknown:
            return "catapult is checking yt-dlp and ffmpeg."
        }
    }

    private var toolsCanRefresh: Bool {
        if case .error = dependencies.state { return true }
        if case .unknown = dependencies.state { return true }
        return false
    }

    // MARK: Step — ready

    private var readyStep: some View {
        VStack(spacing: 18) {
            OnboardingGlyph(systemName: "checkmark.circle.fill", tint: .green)

            Text("you're set")
                .font(H3.display(size: 34, weight: .medium))
                .foregroundStyle(H3.ink900)

            Text("copy a video link, i'll spot it automatically and queue it up. look for the little icon in your menu bar.")
                .font(H3.body(size: 14))
                .foregroundStyle(H3.ink500)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(nil)
                .frame(maxWidth: 480)
                .padding(.horizontal, 40)
        }
    }

    // MARK: Nav

    private var stepDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<totalSteps, id: \.self) { i in
                Capsule(style: .continuous)
                    .fill(i == step ? H3.blue400 : H3.ink200)
                    .frame(width: i == step ? 22 : 7, height: 7)
                    .animation(H3.easeBounce, value: step)
            }
        }
    }

    private var navBar: some View {
        HStack {
            if step > 0 {
                H3Button(gradient: H3.gradDeep, filled: false) {
                    step -= 1
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("back")
                    }
                }
                .fixedSize()
            }
            Spacer()
            if step < totalSteps - 1 {
                H3Button(gradient: H3.gradDeep) {
                    step += 1
                } label: {
                    HStack(spacing: 4) {
                        Text(step == 0 ? "let's go" : "next")
                        Image(systemName: "chevron.right")
                    }
                }
                .fixedSize()
            } else {
                H3Button(gradient: H3.gradDeep) {
                    finish()
                } label: {
                    HStack(spacing: 4) {
                        Text("open the menu bar")
                        Image(systemName: "arrow.up.right")
                    }
                }
                .fixedSize()
            }
        }
    }

    // MARK: Music prompt overlay

    private var musicPromptOverlay: some View {
        ZStack {
            // Frosted scrim hides the welcome content behind the card.
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
                .allowsHitTesting(true)

            VStack(spacing: 22) {
                OnboardingGlyph(systemName: "music.note")

                VStack(spacing: 8) {
                    Text("want some music?")
                        .font(H3.display(size: 28, weight: .medium))
                        .foregroundStyle(H3.ink900)

                    Text("i've got a little soundtrack for the tour. each step fades in a new layer.")
                        .font(H3.body(size: 14, weight: .medium))
                        .foregroundStyle(H3.ink700)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }

                HStack(spacing: 12) {
                    // gradDeep gives white text proper contrast (gradPool's
                    // white midband washed it out at the top of the button).
                    H3Button(gradient: H3.gradDeep) {
                        enableMusic()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "music.note")
                            Text("yes, play it")
                        }
                    }
                    .fixedSize()

                    H3Button(gradient: H3.gradDeep, filled: false) {
                        showingMusicPrompt = false
                    } label: {
                        Text("no thanks")
                    }
                    .fixedSize()
                }
            }
            .padding(36)
            .background(
                RoundedRectangle(cornerRadius: H3.radius3, style: .continuous)
                    .fill(H3.cardFill)   // dynamic: white in light, slate in dark
            )
            .overlay(
                RoundedRectangle(cornerRadius: H3.radius3, style: .continuous)
                    .stroke(H3.cardStroke, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.28), radius: 28, x: 0, y: 10)
        }
    }

    // MARK: Actions

    private func enableMusic() {
        music.isEnabled = true
        music.loadTracks()
        showingMusicPrompt = false
        // Let the dismissal animation complete before the first fade-in.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            music.start()
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async {
                notificationGranted = granted
                if granted { step += 1 }
            }
        }
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

    private func finish() {
        music.stop()
        settings.hasCompletedOnboarding = true
        onFinish()
    }
}

private struct OnboardingBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            H3.ink50
            LinearGradient(
                colors: scheme == .dark
                    ? [Color(hex: 0x20242d).opacity(0.82), Color(hex: 0x15171d)]
                    : [Color.white.opacity(0.92), H3.blue50.opacity(0.58)],
                startPoint: .top,
                endPoint: .bottom
            )
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(scheme == .dark ? 0.24 : 0.32)
        }
        .ignoresSafeArea()
    }
}

private struct AppIconMark: View {
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: 86, height: 86)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: H3.shadowDrop.opacity(0.18), radius: 18, y: 8)
    }
}

private struct OnboardingGlyph: View {
    let systemName: String
    var tint: Color = H3.blue400

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 34, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .frame(width: 84, height: 84)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(H3.cardFill.opacity(0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(H3.cardStroke, lineWidth: 1)
            )
            .shadow(color: H3.shadowDrop.opacity(0.12), radius: 18, y: 8)
    }
}

// MARK: - AppKit launcher — shows the onboarding as a real NSWindow.

@MainActor
enum OnboardingLauncher {
    private static var window: NSWindow?

    static func presentIfNeeded() {
        guard !AppSettings.shared.hasCompletedOnboarding else { return }
        present()
    }

    static func present() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(
            rootView: OnboardingWindow(onFinish: { close() })
                .environment(AppSettings.shared)
                .environment(DependencyManager.shared)
        )
        let w = NSWindow(contentViewController: hosting)
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = false
        w.title = "welcome to catapult"
        w.setContentSize(NSSize(width: 680, height: 520))
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func close() {
        window?.close()
        window = nil
    }
}
