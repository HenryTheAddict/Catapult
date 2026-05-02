import SwiftUI
import AppKit
import UserNotifications

// MARK: - Onboarding host window
//
// First-run welcome in the h3 / Frutiger Aero aesthetic.
// Lowercase first-person copy throughout — em dashes welcome.

struct OnboardingWindow: View {
    @Environment(AppSettings.self) private var settings
    var onFinish: () -> Void = {}

    @State private var step: Int = 0
    @State private var notificationGranted: Bool? = nil

    private let totalSteps = 5

    var body: some View {
        ZStack {
            // Signature sky gradient background — vertical, always.
            H3.gradSky.ignoresSafeArea()

            // Soft orb decorations (purely decorative, clipped to window bounds)
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    Orb(gradient: H3.gradBubble, size: 180)
                        .opacity(0.45)
                        .offset(x: -60, y: geo.size.height - 140)
                    Orb(gradient: H3.gradRainbow, size: 90)
                        .opacity(0.35)
                        .offset(x: geo.size.width - 140, y: 40)
                    Orb(gradient: H3.gradDeep, size: 56)
                        .opacity(0.4)
                        .offset(x: geo.size.width - 220, y: geo.size.height - 120)
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
            .clipped()
            .allowsHitTesting(false)

            // Step content
            VStack(spacing: 22) {
                stepDots
                    .padding(.top, 18)

                Group {
                    switch step {
                    case 0: welcomeStep
                    case 1: notificationsStep
                    case 2: folderStep
                    case 3: filenameStep
                    default: readyStep
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity.combined(with: .move(edge: .trailing)))

                navBar
                    .padding(.horizontal, 28)
                    .padding(.bottom, 22)
            }
        }
        .frame(width: 640, height: 520)
        .animation(H3.easeOut, value: step)
        .onAppear {
            FontLoader.registerBundled()
        }
        // Onboarding background uses literal .white in its sky gradient and
        // assorted Frutiger orb art that's tuned for a light surface — pin to
        // light scheme so it stays on-brand even when the system is dark.
        .preferredColorScheme(.light)
    }

    // MARK: Step — welcome

    private var welcomeStep: some View {
        VStack(spacing: 18) {
            Orb(gradient: H3.gradBubble, size: 128)
                .padding(.top, 8)

            VStack(spacing: 8) {
                Text("welcome to catapult")
                    .font(H3.display(size: 40, weight: .medium))
                    .foregroundStyle(H3.ink900)
                Text("a tiny menu-bar thing that grabs videos for you — paste a link, i'll do the rest.")
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
            ChannelTile(gradient: H3.gradPool) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(H3.blue500)
            }

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
                        Text(notificationGranted == true ? "allowed — thanks" : "allow notifications")
                    }
                }
                H3Button(gradient: H3.gradDeep, filled: false) {
                    step += 1
                } label: {
                    Text("skip for now")
                }
            }
            .padding(.top, 6)
        }
    }

    // MARK: Step — folder

    private var folderStep: some View {
        @Bindable var s = settings
        return VStack(spacing: 14) {
            ChannelTile(gradient: H3.gradBubble) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(H3.blue500)
            }

            Text("where should i drop your files?")
                .font(H3.display(size: 26, weight: .medium))
                .foregroundStyle(H3.ink900)

            Text("by default — a catapult folder in your downloads.")
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
            ChannelTile(gradient: H3.gradRainbow) {
                Image(systemName: "textformat")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(.white)
            }

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
                    .fill(selected ? H3.blue50 : Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: H3.radius2, style: .continuous)
                    .stroke(selected ? H3.blue400 : Color.black.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Step — ready

    private var readyStep: some View {
        VStack(spacing: 18) {
            Orb(gradient: H3.gradBubble, size: 128)

            Text("you're set")
                .font(H3.display(size: 40, weight: .medium))
                .foregroundStyle(H3.ink900)

            Text("copy a youtube link — i'll spot it automatically and queue it up. look for the little icon in your menu bar.")
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
                Circle()
                    .fill(i == step ? H3.blue400 : H3.ink200)
                    .frame(width: i == step ? 10 : 7, height: i == step ? 10 : 7)
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
            } else {
                H3Button(gradient: H3.gradDeep) {
                    finish()
                } label: {
                    HStack(spacing: 4) {
                        Text("open the menu bar")
                        Image(systemName: "arrow.up.right")
                    }
                }
            }
        }
    }

    // MARK: Actions

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
        settings.hasCompletedOnboarding = true
        onFinish()
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
        )
        let w = NSWindow(contentViewController: hosting)
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.title = "welcome to catapult"
        w.setContentSize(NSSize(width: 640, height: 520))
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
