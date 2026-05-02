import AppKit
import UniformTypeIdentifiers

// MARK: - Status bar drop receiver
//
// Lets users drag a URL directly onto the Catapult icon in the menu bar —
// the popover never has to open. SwiftUI's MenuBarExtra doesn't expose its
// NSStatusItem, so we fish out the NSStatusBarButton by walking NSApp.windows
// once the extra is set up, then overlay a transparent NSView that registers
// for dragged types and enqueues whatever lands on it.
//
// If introspection fails (Apple renames the window class in a future macOS),
// drag-and-drop still works inside the popover via SwiftUI `.onDrop` — this
// is the faster path, not the only path.

@MainActor
enum MenuBarDropInstaller {
    private static var installed = false
    private static var receiverView: StatusBarDropReceiver?

    static func installIfPossible() {
        guard !installed else { return }
        guard let button = findStatusButton() else {
            // The extra might not be up yet — try once more shortly. Capped
            // to a handful of attempts so we don't loop forever if something
            // is genuinely wrong.
            retry()
            return
        }
        installed = true
        attach(to: button)
    }

    private static var retries = 0
    private static func retry() {
        retries += 1
        guard retries < 6 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            installIfPossible()
        }
    }

    private static func findStatusButton() -> NSStatusBarButton? {
        for window in NSApp.windows {
            // MenuBarExtra's window class name is an implementation detail,
            // but it reliably hosts an NSStatusBarButton somewhere in its
            // view tree. Walk it, stop at the first match.
            guard let root = window.contentView else { continue }
            if let button = firstStatusButton(in: root) { return button }
            // Some versions park the button directly on the window's
            // superview tree — check the whole hierarchy just in case.
            var v: NSView? = window.contentView?.superview
            while let cur = v {
                if let b = firstStatusButton(in: cur) { return b }
                v = cur.superview
            }
        }
        return nil
    }

    private static func firstStatusButton(in view: NSView) -> NSStatusBarButton? {
        if let b = view as? NSStatusBarButton { return b }
        for sub in view.subviews {
            if let b = firstStatusButton(in: sub) { return b }
        }
        return nil
    }

    private static func attach(to button: NSStatusBarButton) {
        // Remove any previous overlay so repeat installs don't stack.
        for sub in button.subviews where sub is StatusBarDropReceiver {
            sub.removeFromSuperview()
        }
        let receiver = StatusBarDropReceiver(frame: button.bounds)
        receiver.autoresizingMask = [.width, .height]
        button.addSubview(receiver)
        self.receiverView = receiver
    }
}

// MARK: - Drop receiver

final class StatusBarDropReceiver: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.URL, .fileURL, .string])
    }
    required init?(coder: NSCoder) { nil }

    // Transparent — we don't want to cover the button's glyph. Pass mouse
    // events through so regular clicks continue to open the popover.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard extractString(from: sender) != nil else { return [] }
        return .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        extractString(from: sender) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let text = extractString(from: sender) else { return false }
        let picked = ClipboardMonitor.firstYouTubeURL(in: text)
                  ?? ClipboardMonitor.firstURL(in: text)
                  ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !picked.isEmpty else { return false }
        Task { @MainActor in
            DownloadManager.shared.enqueue(url: picked, mode: .video)
            if AppSettings.shared.showNotifications {
                NotificationHelper.show(title: "Queued from drop",
                                        body: picked)
            }
        }
        return true
    }

    /// Accepts URLs, file URLs, or plain strings — whichever the source app
    /// provides. Safari and most browsers send URL; Messages/Notes send
    /// string; Finder files-URL a local media path which we happily support.
    private func extractString(from info: NSDraggingInfo) -> String? {
        let pb = info.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let first = urls.first {
            return first.absoluteString
        }
        if let s = pb.string(forType: .string), !s.isEmpty {
            return s
        }
        return nil
    }
}
