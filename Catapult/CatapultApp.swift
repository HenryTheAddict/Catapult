import SwiftUI
import AppKit

@main
struct CatapultApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings = AppSettings.shared
    @State private var downloads = DownloadManager.shared
    @State private var dependencies = DependencyManager.shared
    @State private var clipboard = ClipboardMonitor.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarRootView()
                .environment(settings)
                .environment(downloads)
                .environment(dependencies)
                .environment(clipboard)
                .preferredColorScheme(preferredScheme)
        } label: {
            MenuBarLabel()
                .environment(downloads)
                .environment(clipboard)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(settings)
                .environment(dependencies)
                .environment(downloads)
                .preferredColorScheme(preferredScheme)
        }

        Window("Catapult — Trim", id: "cut") {
            CutWindowHost()
                .environment(settings)
                .environment(downloads)
                .environment(dependencies)
                .preferredColorScheme(preferredScheme)
        }
        .windowResizability(.contentSize)
    }

    private var preferredScheme: ColorScheme? {
        switch settings.appearance {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        FontLoader.registerBundled()
        NotificationHelper.requestAuthorization()
        Task { @MainActor in
            await DependencyManager.shared.ensureInstalled()
            ClipboardMonitor.shared.start()
            SubscriptionManager.shared.start()
            if AppSettings.shared.autoUpdateYtDlpOnLaunch {
                await DependencyManager.shared.updateYtDlp()
            }
        }
        // First-run: show onboarding immediately on launch (not just after
        // the user clicks the menu bar).
        DispatchQueue.main.async {
            OnboardingLauncher.presentIfNeeded()
        }
        // MenuBarExtra sets up its NSStatusItem asynchronously — give it a
        // beat, then attach a drop receiver to the button so users can drag
        // links directly onto the menu bar icon.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MenuBarDropInstaller.installIfPossible()
        }
    }
}
