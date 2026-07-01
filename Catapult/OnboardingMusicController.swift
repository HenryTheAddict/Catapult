import AVFoundation
import Foundation

// MARK: - Onboarding Music Controller
//
// Layered stem player for the five-step onboarding flow.
//
// Behaviour:
//   • step 0: stem 1 audible at full volume
//   • advance to step N: stem N+1 fades in; all previous stems keep playing
//   • go back: stems above the new step fade out
//   • idle (2 full loops of the current step's stem with no step change)
//     or window loses focus: collapse to only the current step's stem
//   • refocus: all stems up to current step fade back in
//
// Audio: M4A (AAC) files live in Catapult/OnboardingMusic/. AAC is decoded
// natively by AVAudioPlayer on every macOS version. If a track fails to
// load it's silently skipped, since music is optional.

@MainActor
final class OnboardingMusicController {

    static let shared = OnboardingMusicController()

    /// Set true before calling start(). Driven by the pre-onboarding prompt.
    var isEnabled = false

    private var players:     [AVAudioPlayer] = []
    private var currentStep: Int  = 0
    private var isIdleMode:  Bool = false
    private var idleTimer:   Timer?

    /// After this many full loops of the current stem, collapse to idle mode.
    private let idleLoopThreshold = 2
    private let fadeDuration: TimeInterval = 1.2

    private init() {}

    // MARK: - Setup

    /// Load all five stem tracks from the app bundle.
    /// Call once before start(). Safe to call again if needed.
    func loadTracks() {
        guard players.isEmpty else { return }
        players = (1...5).compactMap { i in
            // Try with the OnboardingMusic subdirectory first; fall back to
            // a flat lookup in case the bundle copies resources flat.
            let name = "CatapultOnboarding\(i)"
            let url = Bundle.main.url(forResource: name,
                                      withExtension: "m4a",
                                      subdirectory: "OnboardingMusic")
                   ?? Bundle.main.url(forResource: name, withExtension: "m4a")
            guard let url else {
                NSLog("[OnboardingMusic] missing stem %@.m4a", name)
                return nil
            }
            guard let p = try? AVAudioPlayer(contentsOf: url) else {
                NSLog("[OnboardingMusic] failed to load %@", url.lastPathComponent)
                return nil
            }
            p.numberOfLoops = -1   // loop indefinitely; idle counter uses a timer
            p.volume        = 0
            p.prepareToPlay()
            return p
        }
    }

    // MARK: - Lifecycle

    /// Begin playback with step 0's stem.
    func start() {
        guard isEnabled, !players.isEmpty else { return }
        currentStep = 0
        isIdleMode  = false
        players.forEach { $0.play() }
        players[0].setVolume(1, fadeDuration: fadeDuration)
        scheduleIdleTimer()
    }

    /// Call whenever the onboarding page index changes.
    /// `step` is clamped to the available stem count, so adding more
    /// onboarding pages later than there are stems will not crash.
    func stepChanged(to step: Int) {
        guard isEnabled, !players.isEmpty else { return }
        let clamped = max(0, min(step, players.count - 1))
        let prev = currentStep
        currentStep = clamped
        isIdleMode  = false
        scheduleIdleTimer()

        if clamped > prev {
            // Fade in every stem we haven't heard yet.
            for i in (prev + 1)...clamped where players.indices.contains(i) {
                players[i].setVolume(1, fadeDuration: fadeDuration)
            }
        } else if clamped < prev {
            // Fade out stems above the new step.
            for i in (clamped + 1)...prev where players.indices.contains(i) {
                players[i].setVolume(0, fadeDuration: fadeDuration)
            }
        }
    }

    /// Call on window key / app active state changes.
    func focusChanged(isFocused: Bool) {
        guard isEnabled, !players.isEmpty else { return }
        if isFocused {
            if isIdleMode { exitIdleMode() }
        } else {
            if !isIdleMode { enterIdleMode() }
        }
    }

    /// Fade everything out and stop — call when onboarding finishes.
    func stop() {
        idleTimer?.invalidate()
        idleTimer = nil
        let captured = players
        players.removeAll()
        currentStep = 0
        isIdleMode = false
        isEnabled = false
        captured.forEach { $0.setVolume(0, fadeDuration: fadeDuration * 0.6) }
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeDuration * 0.6 + 0.1) {
            captured.forEach {
                $0.stop()
                $0.currentTime = 0
            }
        }
    }

    // MARK: - Private helpers

    private func scheduleIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = nil
        guard players.indices.contains(currentStep) else { return }
        let duration = players[currentStep].duration
        guard duration > 0 else { return }
        idleTimer = Timer.scheduledTimer(
            withTimeInterval: duration * Double(idleLoopThreshold),
            repeats: false
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.enterIdleMode() }
        }
        idleTimer?.tolerance = min(duration * 0.1, 2)
    }

    private func enterIdleMode() {
        guard !isIdleMode else { return }
        isIdleMode = true
        idleTimer?.invalidate()
        idleTimer = nil
        for i in players.indices where i != currentStep {
            players[i].setVolume(0, fadeDuration: fadeDuration)
        }
    }

    private func exitIdleMode() {
        isIdleMode = false
        guard !players.isEmpty else { return }
        let cap = min(currentStep, players.count - 1)
        guard cap >= 0 else { return }
        for i in 0...cap {
            players[i].setVolume(1, fadeDuration: fadeDuration)
        }
        scheduleIdleTimer()
    }
}
