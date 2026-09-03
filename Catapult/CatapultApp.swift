import SwiftUI
import AppKit
import UserNotifications

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
    /// Distributed-notification name used by a second launch to wake the
    /// already-running instance and ask it to surface its menu.
    static let activatePingName = Notification.Name("h3nry.Catapult.activate")

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Single-instance guard. macOS already enforces this for
        // bundle-identical apps in /Applications, but a developer running
        // the .app from DerivedData and from /Applications can end up with
        // two menu-bar icons fighting over the same status item. Bail
        // loudly before any UI spins up.
        enforceSingleInstance()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        FontLoader.registerBundled()
        NotificationHelper.configure(delegate: self)

        // Listen for "another copy tried to launch" pings so we can surface
        // the menu bar window. Posted by the would-be second instance just
        // before it terminates itself in enforceSingleInstance().
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleActivatePing),
            name: AppDelegate.activatePingName,
            object: nil
        )

        // Kick the update backend. Currently a no-op until the replacement
        // updater is wired in.
        UpdateController.shared.start()

        Task { @MainActor in
            CLIInstaller.refreshIfInstalled()
            await DependencyManager.shared.ensureInstalled()
            ClipboardMonitor.shared.start()
            SubscriptionManager.shared.start()
            if AppSettings.shared.autoUpdateYtDlpOnLaunch {
                // Version-checked and throttled — only downloads when a newer
                // yt-dlp actually exists, so launch stays fast.
                await DependencyManager.shared.updateYtDlpIfNeeded()
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

    // MARK: - Single instance

    private func enforceSingleInstance() {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
           ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil ||
           ProcessInfo.processInfo.environment["XCInjectBundleInto"] != nil ||
           NSClassFromString("XCTestCase") != nil {
            return
        }
        let me = ProcessInfo.processInfo.processIdentifier
        guard let bid = Bundle.main.bundleIdentifier else { return }
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: bid)
            .filter { $0.processIdentifier != me }
        guard !others.isEmpty else { return }

        // Tell the existing instance to pop its menu, then quit ourselves.
        DistributedNotificationCenter.default().postNotificationName(
            AppDelegate.activatePingName, object: bid, userInfo: nil,
            deliverImmediately: true
        )
        // Activate the existing one for good measure (works on Sequoia+).
        others.first?.activate(options: [])
        NSApp.terminate(nil)
        // Belt-and-braces: if -terminate is delayed by a pending Scene
        // setup, exit hard so the user doesn't see two menu bar icons.
        exit(0)
    }

    @objc private func handleActivatePing(_ note: Notification) {
        // Bring the menu-bar window forward. NSStatusItem doesn't expose a
        // direct "open" so we fake a click on its button.
        for window in NSApp.windows {
            if let btn = (window.value(forKey: "statusItem") as? NSStatusItem)?.button {
                btn.performClick(nil)
                return
            }
        }
        // Fallback: just bring the app to the front. The user can click
        // the menu bar icon themselves.
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                             didReceive response: UNNotificationResponse,
                                             withCompletionHandler completionHandler: @escaping () -> Void) {
        let actionIdentifier = response.actionIdentifier
        let categoryIdentifier = response.notification.request.content.categoryIdentifier
        let url = response.notification.request.content.userInfo["url"] as? String
        Task { @MainActor in
            NotificationHelper.handleNotificationAction(actionIdentifier: actionIdentifier,
                                                        categoryIdentifier: categoryIdentifier,
                                                        url: url)
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                             willPresent notification: UNNotification,
                                             withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in
            var options: UNNotificationPresentationOptions = [.banner, .list]
            if AppSettings.shared.notificationSound {
                options.insert(.sound)
            }
            completionHandler(options)
        }
    }
}
