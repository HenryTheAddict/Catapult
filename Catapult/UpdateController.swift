import Foundation
import AppKit

#if canImport(Sparkle)
import Sparkle
#endif

// MARK: - Auto-update controller (Sparkle wrapper, GitHub Releases backed)
//
// Tiny façade around Sparkle's SPUStandardUpdaterController so the rest of
// the app can stay agnostic of whether Sparkle is linked. We use
// `#if canImport(Sparkle)` so the project still builds before you've added
// Sparkle as a Swift Package — `UpdateController.shared.checkForUpdates()`
// becomes a no-op until the dependency is wired in.
//
// **Distribution model:** GitHub Releases. The `release.yml` workflow
// builds the DMG, uploads it as a release asset, and (in a follow-up step)
// generates a signed `appcast.xml` that gets committed to the `gh-pages`
// branch. Sparkle reads that appcast over HTTPS, downloads the DMG asset
// straight from `github.com/.../releases/download/...`, and verifies the
// Ed25519 signature embedded in the appcast.
//
// **One-time setup (do this before your first signed release):**
//   1. Add Sparkle as a Swift Package:
//        File → Add Package Dependencies… →
//        https://github.com/sparkle-project/Sparkle  (pin to 2.x)
//      Link `Sparkle` against the Catapult target.
//
//   2. Generate an Ed25519 signing keypair:
//        ./Sparkle/bin/generate_keys
//      It prints the public key and stores the private key in your
//      macOS Keychain. Copy the public key string (starts with raw
//      base64, ~44 chars).
//
//   3. In Catapult's target → Info, add these custom keys:
//        SUFeedURL              = https://henrytheaddict.github.io/Catapult/appcast.xml
//        SUPublicEDKey          = <paste the public key here>
//        SUEnableInstallerLauncherService = YES   (Sparkle 2 requirement)
//      Replace the SUFeedURL host with your GitHub Pages URL — by default
//      that's https://<user>.github.io/<repo>/appcast.xml when you turn
//      on Pages for the `gh-pages` branch.
//
//   4. Add the Sparkle private key as a repo secret named
//      SPARKLE_ED_PRIVATE_KEY so `release.yml` can sign DMGs in CI.
//
// Until step 3 is done the SUFeedURL key is missing, Sparkle logs a warning,
// and the menu shows "Check for Updates…" disabled. No crashes.

@MainActor
final class UpdateController: NSObject {
    static let shared = UpdateController()

    /// True when Sparkle is linked AND has a feed URL configured. Used by
    /// the menu / settings to gate the "Check for Updates…" item.
    var canCheckForUpdates: Bool {
        #if canImport(Sparkle)
        return updaterController.updater.canCheckForUpdates
        #else
        return false
        #endif
    }

    /// True when the user has opted in to background update checks.
    /// Defaults to true on first launch; controlled via the General tab.
    var automaticallyChecksForUpdates: Bool {
        get {
            #if canImport(Sparkle)
            return updaterController.updater.automaticallyChecksForUpdates
            #else
            return AppSettings.shared.autoCheckForUpdates
            #endif
        }
        set {
            AppSettings.shared.autoCheckForUpdates = newValue
            #if canImport(Sparkle)
            updaterController.updater.automaticallyChecksForUpdates = newValue
            #endif
        }
    }

    #if canImport(Sparkle)
    private lazy var updaterController: SPUStandardUpdaterController = {
        // startingUpdater: false — we kick it ourselves in start() so we
        // can apply the user's preference first.
        SPUStandardUpdaterController(startingUpdater: false,
                                     updaterDelegate: self,
                                     userDriverDelegate: nil)
    }()
    #endif

    private override init() { super.init() }

    /// Called from `applicationDidFinishLaunching`. Safe to call when
    /// Sparkle isn't linked.
    func start() {
        #if canImport(Sparkle)
        updaterController.updater.automaticallyChecksForUpdates =
            AppSettings.shared.autoCheckForUpdates
        updaterController.startUpdater()
        #endif
    }

    /// Wired to the "Check for Updates…" menu item.
    func checkForUpdates() {
        #if canImport(Sparkle)
        updaterController.checkForUpdates(nil)
        #else
        // Soft fallback so the menu item still does *something* helpful in
        // a build that hasn't yet adopted Sparkle.
        if let url = URL(string: "https://github.com/HenryTheAddict/Catapult/releases/latest") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }
}

#if canImport(Sparkle)
extension UpdateController: SPUUpdaterDelegate {
    // Hook left here intentionally — gives us a single seam for future
    // logic like channel selection (stable vs beta) or pre-update checks.
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        // Returning nil falls back to SUFeedURL from Info.plist, which is
        // what we want once that key is configured.
        return nil
    }
}
#endif
