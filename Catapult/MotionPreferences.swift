import SwiftUI
import AppKit
import Observation

@Observable @MainActor final class MotionPreferences {
    static let shared = MotionPreferences()
    var shiftHeld = false
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private init() {}
    func start() {
        guard localMonitor == nil else { return }
        shiftHeld = NSEvent.modifierFlags.contains(.shift)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.shiftHeld = event.modifierFlags.contains(.shift)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in self?.shiftHeld = event.modifierFlags.contains(.shift) }
        }
    }
    var speed: Double { shiftHeld || NSEvent.modifierFlags.contains(.shift) ? 0.15 : 1 }
    func adapt(_ animation: Animation) -> Animation {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return .linear(duration: 0.01) }
        return animation.speed(speed)
    }
}
