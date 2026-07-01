import SwiftUI
import AppKit
import CoreText

// MARK: - h3 design tokens
// Frutiger Aero / Wii channel inspired. Lowercase first-person copy. Em dashes welcome.

enum H3 {

    // MARK: Colors (from h3-design-system/colors_and_type.css)
    static let blue50  = Color.dynamic(light: Color(hex: 0xe6f5ff), dark: Color(hex: 0x0c2235))
    static let blue100 = Color(hex: 0xb3e2ff)
    static let blue200 = Color(hex: 0x00b3ff)
    static let blue300 = Color(hex: 0x0088ff)
    static let blue400 = Color(hex: 0x0074e0)  // core brand blue
    static let blue500 = Color(hex: 0x004cff)
    static let blue600 = Color(hex: 0x003d99)
    static let blue700 = Color(hex: 0x2d4891)

    static let cyan     = Color(hex: 0x00bbff)
    static let aqua     = Color(hex: 0x00ffc3)
    static let sky      = Color(hex: 0x009dff)
    static let lavender = Color(hex: 0x838dff)
    static let ice      = Color(hex: 0x00b3ff)

    static let red      = Color(hex: 0xe40303)
    static let orange   = Color(hex: 0xff8c00)
    static let yellow   = Color(hex: 0xffed00)
    static let amber    = Color(hex: 0xffc60c)
    static let green    = Color(hex: 0x008026)
    static let lime     = Color(hex: 0x00e01e)
    static let magenta  = Color(hex: 0xd400ff)
    static let pink     = Color(hex: 0xff00fb)
    static let hotRed   = Color(hex: 0xff0000)
    static let purple   = Color(hex: 0x732982)

    // ink ramp adapts: light mode = the original light values, dark mode =
    // an inverted greyscale so labels keep their contrast against the
    // adaptive surfaces below.
    static let ink900 = Color.dynamic(light: Color(hex: 0x0b0b10), dark: Color(hex: 0xf2f3f7))
    static let ink700 = Color.dynamic(light: Color(hex: 0x1e1f26), dark: Color(hex: 0xd6d7de))
    static let ink500 = Color.dynamic(light: Color(hex: 0x555860), dark: Color(hex: 0x9fa1a9))
    static let ink300 = Color.dynamic(light: Color(hex: 0x9a9ba3), dark: Color(hex: 0x6a6c74))
    static let ink200 = Color.dynamic(light: Color(hex: 0xcfd0d7), dark: Color(hex: 0x3a3b42))
    static let ink100 = Color.dynamic(light: Color(hex: 0xe6e7ec), dark: Color(hex: 0x26272d))
    static let ink50  = Color.dynamic(light: Color(hex: 0xf4f5f8), dark: Color(hex: 0x1a1b20))
    static let gray   = Color.dynamic(light: Color(hex: 0xd9d9d9), dark: Color(hex: 0x3f3f44))

    // Semantic surface tokens — use these instead of Color.white / Color.black
    // for cards and strokes so the UI tracks the system appearance.
    static let cardFill   = Color.dynamic(light: .white, dark: Color(hex: 0x202126))
    static let cardStroke = Color.dynamic(light: Color.black.opacity(0.08),
                                          dark:  Color.white.opacity(0.10))

    // MARK: Signature gradients (180deg — always vertical)
    static let gradSky     = LinearGradient(colors: [cyan, .white],
                                            startPoint: .top, endPoint: .bottom)
    static let gradBubble  = LinearGradient(colors: [aqua, lavender],
                                            startPoint: .top, endPoint: .bottom)
    static let gradRainbow = LinearGradient(
        stops: [.init(color: sky, location: 0),
                .init(color: magenta, location: 0.5),
                .init(color: hotRed, location: 1)],
        startPoint: .top, endPoint: .bottom)
    static let gradPool = LinearGradient(
        stops: [.init(color: sky, location: 0),
                .init(color: .white, location: 0.5),
                .init(color: blue500, location: 1)],
        startPoint: .top, endPoint: .bottom)
    static let gradDeep = LinearGradient(colors: [sky, blue600],
                                         startPoint: .top, endPoint: .bottom)

    // Glossy top-light overlay for orb/button highlights.
    static let glossTop = LinearGradient(
        stops: [.init(color: Color.white.opacity(0.55), location: 0.0),
                .init(color: Color.white.opacity(0.08), location: 0.5),
                .init(color: Color.white.opacity(0.0),  location: 0.55)],
        startPoint: .top, endPoint: .bottom)

    // MARK: Shadows
    static let shadowDrop = Color.black.opacity(0.25)

    // MARK: Radii
    static let radius1: CGFloat = 6
    static let radius2: CGFloat = 12
    static let radius3: CGFloat = 20
    static let radius4: CGFloat = 28
    static let radiusBlob: CGFloat = 47

    // MARK: Motion
    static let easeOut    = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.28)
    static let easeBounce = Animation.interpolatingSpring(stiffness: 260, damping: 24)
    static let appleSnap  = Animation.interpolatingSpring(stiffness: 360, damping: 32)
    static let appleDrift = Animation.timingCurve(0.2, 0.9, 0.2, 1, duration: 0.42)

    // MARK: Fonts — uses the bundled TTFs if present, otherwise sensible system fallbacks.
    static func display(size: CGFloat, weight: Font.Weight = .medium) -> Font {
        if FontLoader.didLoad("Lora") {
            return .custom("Lora", size: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: .serif)
    }

    static func body(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if FontLoader.didLoad("Google Sans Flex") {
            return .custom("Google Sans Flex", size: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: .default)
    }

    static func mono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Hex helper

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xff) / 255.0
        let g = Double((hex >>  8) & 0xff) / 255.0
        let b = Double( hex        & 0xff) / 255.0
        self = Color(red: r, green: g, blue: b)
    }

    /// Resolves to `light` when the system appearance is Aqua, `dark` when
    /// DarkAqua. Used to build adaptive design tokens from existing static
    /// Color values without having to thread Environment(\.colorScheme) into
    /// every call site.
    static func dynamic(light: Color, dark: Color) -> Color {
        let dyn = NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.aqua, .darkAqua])
            return match == .darkAqua ? NSColor(dark) : NSColor(light)
        }
        return Color(nsColor: dyn)
    }
}

// MARK: - Adaptive sky background
//
// gradSky is tuned for light mode (cyan to white). In dark mode we want a
// matching deep-night palette. SwiftUI gradients can't be made dynamic at
// the Color layer the way Color.dynamic(...) can, so we wrap the choice
// in a tiny view that picks per colorScheme.

struct H3SkyBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if scheme == .dark {
                // Deep ocean: nearly-black at top, indigo at bottom.
                LinearGradient(
                    colors: [Color(hex: 0x05080f), Color(hex: 0x132037)],
                    startPoint: .top, endPoint: .bottom
                )
            } else {
                H3.gradSky
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - H3 window chrome
//
// Applies the h3 transparent-title-bar treatment to the hosting NSWindow:
// the title bar disappears, the content extends to the very top, and the
// background gradient flows underneath the traffic lights. Drop on the
// root view of any window that wants to feel native h3.

struct H3WindowChrome: ViewModifier {
    func body(content: Content) -> some View {
        content.background(H3WindowChromeAccessor())
    }
}

extension View {
    /// Apply h3-style transparent title bar to the hosting window.
    func h3WindowChrome() -> some View { modifier(H3WindowChrome()) }
}

private struct H3WindowChromeAccessor: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { context.coordinator.attach(to: v.window) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { context.coordinator.attach(to: nsView.window) }
    }

    final class Coordinator {
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }

        func attach(to newWindow: NSWindow?) {
            guard let newWindow else { return }
            if window !== newWindow {
                observers.forEach(NotificationCenter.default.removeObserver)
                observers.removeAll()
                window = newWindow
                let names: [Notification.Name] = [
                    NSWindow.didBecomeKeyNotification,
                    NSWindow.didResignKeyNotification,
                    NSWindow.didBecomeMainNotification,
                    NSWindow.didResignMainNotification
                ]
                observers = names.map { name in
                    NotificationCenter.default.addObserver(
                        forName: name,
                        object: newWindow,
                        queue: .main
                    ) { [weak self] _ in
                        self?.apply()
                    }
                }
            }
            apply()
        }

        private func apply() {
            applyH3WindowChrome(to: window)
        }
    }

    private static func applyH3WindowChrome(to window: NSWindow?) {
        guard let window else { return }
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = nil
        window.toolbarStyle = .unifiedCompact
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isMovableByWindowBackground = false
        if #available(macOS 11.0, *) {
            window.titlebarSeparatorStyle = .none
        }
    }
}

// MARK: - Orb view — the brand's fundamental object

struct Orb: View {
    var gradient: LinearGradient = H3.gradBubble
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            Circle().fill(gradient)
            Circle().fill(H3.glossTop)
        }
        .frame(width: size, height: size)
        .shadow(color: H3.shadowDrop, radius: 6.6, x: 2, y: 7)
    }
}

// MARK: - Wii channel tile

struct ChannelTile<Content: View>: View {
    let gradient: LinearGradient
    @ViewBuilder var content: () -> Content
    var size: CGFloat = 96

    var body: some View {
        ZStack {
            // Outer blob plate w/ gradient
            RoundedRectangle(cornerRadius: H3.radiusBlob, style: .continuous)
                .fill(gradient)
                .shadow(color: H3.shadowDrop, radius: 4, x: 0, y: 4)
            // Inner white disk with inset-top shadow
            Circle()
                .fill(.white)
                .padding(10)
                .overlay(
                    Circle()
                        .stroke(Color.black.opacity(0.06), lineWidth: 1)
                        .padding(10)
                )
                .overlay(
                    // Inset-top: a subtle dark gradient on the top rim of the inner disk
                    Circle()
                        .fill(
                            LinearGradient(colors: [Color.black.opacity(0.18), .clear],
                                           startPoint: .top, endPoint: .center)
                        )
                        .padding(10)
                        .mask(Circle().padding(10))
                )
            content()
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Gradient glyph
//
// A flat SF symbol painted with a gradient. Replaces the heavy orb-and-plate
// ChannelTile in compact contexts (settings tiles, list rows) where the
// channel-tile aesthetic feels too busy. Uses vertical gradients for
// consistency with the rest of the h3 palette.

struct GradientGlyph: View {
    let systemName: String
    var gradient: LinearGradient = H3.gradDeep
    var size: CGFloat = 30
    var weight: Font.Weight = .semibold

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(gradient)
            .shadow(color: H3.shadowDrop.opacity(0.15), radius: 1.5, y: 1)
    }
}

// MARK: - h3 button

struct H3Button<Label: View>: View {
    var gradient: LinearGradient = H3.gradDeep
    var filled: Bool = true
    var action: () -> Void
    @ViewBuilder var label: () -> Label

    @State private var pressing = false
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: H3.radius2, style: .continuous)
                    .fill(filled ? AnyShapeStyle(H3.blue400) : AnyShapeStyle(H3.cardFill.opacity(0.72)))
                    .overlay(
                        RoundedRectangle(cornerRadius: H3.radius2, style: .continuous)
                            .strokeBorder(filled ? H3.blue300.opacity(0.35) : H3.cardStroke, lineWidth: 1)
                    )
                label()
                    .foregroundStyle(filled ? Color.white : H3.blue400)
                    .font(H3.body(size: 13, weight: .semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
            }
            .contentShape(RoundedRectangle(cornerRadius: H3.radius2, style: .continuous))
        }
        .buttonStyle(.plain)
        .scaleEffect(pressing ? 0.98 : (hovering ? 1.01 : 1.0))
        .shadow(color: H3.shadowDrop.opacity(filled ? 0.16 : 0.08),
                radius: hovering ? 8 : 4,
                x: 0,
                y: hovering ? 5 : 2)
        .animation(H3.easeBounce, value: hovering)
        .animation(H3.easeOut, value: pressing)
        .onHover { hovering = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressing = true }
                .onEnded { _ in pressing = false }
        )
    }
}

// MARK: - Soft glass card (used throughout h3 UIs)

struct H3Card<Content: View>: View {
    var tint: Color = H3.ink50
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: H3.radius3, style: .continuous)
                    .fill(H3.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: H3.radius3, style: .continuous)
                    .stroke(H3.cardStroke, lineWidth: 1)
            )
            .shadow(color: H3.shadowDrop.opacity(0.3), radius: 8, x: 0, y: 4)
    }
}

// MARK: - Font registration

enum FontLoader {
    private static var loaded: Set<String> = []
    private static var didRegister = false

    static func registerBundled() {
        guard !didRegister else { return }
        didRegister = true
        let names = [
            "Lora-VariableFont_wght",
            "GoogleSansFlex-VariableFont_GRAD_ROND_opsz_slnt_wdth_wght"
        ]
        for name in names {
            if let url = Bundle.main.url(forResource: name, withExtension: "ttf") {
                var err: Unmanaged<CFError>?
                if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &err) {
                    // Figure out the posted PostScript family name for later lookup.
                    if let desc = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] {
                        for d in desc {
                            if let fam = CTFontDescriptorCopyAttribute(d, kCTFontFamilyNameAttribute) as? String {
                                loaded.insert(fam)
                            }
                        }
                    }
                }
            }
        }
    }

    static func didLoad(_ family: String) -> Bool { loaded.contains(family) }
}
