import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(DependencyManager.self) private var dependencies
    @Environment(DownloadManager.self) private var downloads

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            QualitySettingsTab()
                .tabItem { Label("Quality", systemImage: "sparkles") }
            NetworkSettingsTab()
                .tabItem { Label("Network", systemImage: "globe") }
            SponsorBlockTab()
                .tabItem { Label("SponsorBlock", systemImage: "rectangle.on.rectangle.slash") }
            SitesTab()
                .tabItem { Label("Sites", systemImage: "globe.americas.fill") }
            SubscriptionsTab()
                .tabItem { Label("Subscribe", systemImage: "antenna.radiowaves.left.and.right") }
            DevicePresetsTab()
                .tabItem { Label("Devices", systemImage: "gamecontroller") }
            TerminalTab()
                .tabItem { Label("Terminal", systemImage: "terminal") }
            AdvancedSettingsTab()
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
            DependenciesTab()
                .tabItem { Label("Dependencies", systemImage: "shippingbox") }
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 500, idealHeight: 560)
        .environment(settings)
        .environment(dependencies)
        .environment(downloads)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var s = settings
        Form {
            Section("Downloads") {
                HStack {
                    Text("Save to:")
                    Spacer()
                    Text((settings.downloadFolderPath as NSString).abbreviatingWithTildeInPath)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose…") { chooseFolder() }
                    Button {
                        NSWorkspace.shared.open(settings.downloadFolderURL)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .help("Open folder")
                }
                Picker("Filename:", selection: $s.filenamePreset) {
                    ForEach(FilenamePreset.allCases) { p in
                        Text(p.label).tag(p)
                    }
                }
                Text(settings.filenamePreset.hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Template:", text: $s.filenameTemplate)
                    .textFieldStyle(.roundedBorder)
                    .disabled(settings.filenamePreset != .custom)
                    .opacity(settings.filenamePreset == .custom ? 1 : 0.55)
                Text("yt-dlp tokens: %(title)s, %(id)s, %(uploader)s, %(height)s, %(vcodec)s, %(upload_date)s.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Section("Quick actions") {
                Stepper("Size limit for “<N MB” action: \(settings.quickSizeLimitMB) MB",
                        value: $s.quickSizeLimitMB, in: 5...500, step: 5)
                Toggle("Prefer QuickTime-compatible codecs (H.264 / AAC for .mp4)",
                       isOn: $s.preferCompatibleCodecs)
                Text("Avoids AV1/VP9 video that QuickTime refuses to open. Slightly slower, but plays everywhere.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Section("Behavior") {
                Toggle("Watch clipboard for YouTube links", isOn: $s.clipboardMonitoring)
                Toggle("Auto-start download on detect", isOn: $s.autoStartDownload)
                    .disabled(!settings.clipboardMonitoring)
                Toggle("Show notifications", isOn: $s.showNotifications)
                Toggle("Play sound with notifications", isOn: $s.notificationSound)
                    .disabled(!settings.showNotifications)
                Toggle("Reveal in Finder when finished", isOn: $s.openFolderOnFinish)
            }
            Section("Appearance") {
                Picker("Theme:", selection: $s.appearance) {
                    ForEach(AppearanceOverride.allCases) { a in
                        Text(a.label).tag(a)
                    }
                }
                .pickerStyle(.segmented)
            }
            Section("Concurrency & history") {
                Stepper("Simultaneous downloads: \(settings.maxConcurrent)",
                        value: $s.maxConcurrent, in: 1...6)
                Stepper("Keep last \(settings.historyLimit) downloads in the list",
                        value: $s.historyLimit, in: 10...500, step: 10)
            }
            Section {
                Button("Replay onboarding") {
                    settings.hasCompletedOnboarding = false
                    OnboardingLauncher.present()
                }
            }
        }
        .formStyle(.grouped)
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

// MARK: - Quality

private struct QualitySettingsTab: View {
    @Environment(AppSettings.self) private var settings
    var body: some View {
        @Bindable var s = settings
        Form {
            Section("Video") {
                Picker("Max quality:", selection: $s.videoQuality) {
                    ForEach(VideoQuality.allCases) { q in
                        Text(q.label).tag(q)
                    }
                }
                Picker("Container:", selection: $s.videoContainer) {
                    ForEach(VideoContainer.allCases) { c in
                        Text(c.label).tag(c)
                    }
                }
            }
            Section("Audio") {
                Picker("Audio format:", selection: $s.audioFormat) {
                    ForEach(AudioFormat.allCases) { f in
                        Text(f.label).tag(f)
                    }
                }
                HStack {
                    Text("Bitrate:")
                    Spacer()
                    Slider(value: Binding(
                        get: { Double(settings.audioQualityKbps) },
                        set: { s.audioQualityKbps = Int($0) }
                    ), in: 96...320, step: 32)
                    .frame(width: 200)
                    Text("\(settings.audioQualityKbps) kbps")
                        .monospacedDigit()
                        .font(.callout)
                        .frame(width: 70, alignment: .trailing)
                }
            }
            Section("Metadata") {
                Toggle("Embed thumbnail", isOn: $s.embedThumbnail)
                Toggle("Embed chapters & metadata", isOn: $s.embedMetadata)
                Toggle("Embed English subtitles when available", isOn: $s.embedSubtitles)
                Toggle("Save thumbnail as a separate file", isOn: $s.writeThumbnail)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Network

private struct NetworkSettingsTab: View {
    @Environment(AppSettings.self) private var settings
    var body: some View {
        @Bindable var s = settings
        Form {
            Section {
                Picker("Import cookies from:", selection: $s.cookieSource) {
                    ForEach(CookieSource.allCases) { c in
                        Text(c.label).tag(c)
                    }
                }
            } header: {
                Text("Cookies")
            } footer: {
                Text("Lets yt-dlp access age-gated or members-only content you're logged into in that browser. Stays on your machine.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("Proxy URL:", text: $s.proxyURL,
                          prompt: Text("socks5://127.0.0.1:1080"))
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Text("Rate limit:")
                    Spacer()
                    Slider(value: Binding(
                        get: { Double(settings.rateLimitKBps) },
                        set: { s.rateLimitKBps = Int($0) }
                    ), in: 0...20000, step: 250)
                    .frame(width: 200)
                    Text(settings.rateLimitKBps == 0
                         ? "unlimited"
                         : "\(settings.rateLimitKBps) KB/s")
                        .monospacedDigit()
                        .font(.callout)
                        .frame(width: 90, alignment: .trailing)
                }
            } header: {
                Text("Network")
            } footer: {
                Text("Set a rate limit if you're sharing a connection. Leave blank and zero for unlimited.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Auto-update yt-dlp when Catapult launches", isOn: $s.autoUpdateYtDlpOnLaunch)
            } header: {
                Text("Updates")
            } footer: {
                Text("yt-dlp moves fast — turning this on keeps you on the latest extractors without thinking about it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - SponsorBlock

private struct SponsorBlockTab: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var s = settings
        Form {
            Section {
                Picker("Sponsor segments:", selection: $s.sponsorBlockMode) {
                    ForEach(SponsorBlockMode.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.inline)
            } header: {
                Text("SponsorBlock")
            } footer: {
                Text("Uses crowd-sourced data from sponsor.ajay.app to identify sponsor, intro, outro, and other skippable segments. \"Mark\" adds them as chapters; \"Remove\" cuts them out of the final file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Categories") {
                ForEach(SponsorCategory.allCases) { cat in
                    Toggle(cat.label, isOn: Binding(
                        get: { settings.sponsorBlockCategories.contains(cat) },
                        set: { on in
                            if on { s.sponsorBlockCategories.insert(cat) }
                            else  { s.sponsorBlockCategories.remove(cat) }
                        }
                    ))
                    .disabled(settings.sponsorBlockMode == .off)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Advanced

private struct AdvancedSettingsTab: View {
    @Environment(DependencyManager.self) private var dependencies
    @Environment(DownloadManager.self) private var downloads

    var body: some View {
        Form {
            Section("Tools") {
                HStack {
                    Text("yt-dlp binary:")
                    Spacer()
                    Text(dependencies.ytDlpPath.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Button {
                        revealInFinder(dependencies.ytDlpPath)
                    } label: { Image(systemName: "magnifyingglass") }
                    .disabled(!FileManager.default.fileExists(atPath: dependencies.ytDlpPath.path))
                }
                HStack {
                    Text("ffmpeg binary:")
                    Spacer()
                    Text(dependencies.ffmpegPath.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Button {
                        revealInFinder(dependencies.ffmpegPath)
                    } label: { Image(systemName: "magnifyingglass") }
                    .disabled(!FileManager.default.fileExists(atPath: dependencies.ffmpegPath.path))
                }
            }
            Section("Queue") {
                Button("Cancel all running downloads") {
                    for i in downloads.items {
                        if case .downloading = i.status { downloads.cancel(i) }
                    }
                }
                .foregroundStyle(.red)
                Button("Remove finished from list") {
                    downloads.clearFinished()
                }
            }
        }
        .formStyle(.grouped)
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
        VStack(alignment: .leading, spacing: 14) {
            stateBanner
            dependencyRow(name: "yt-dlp",
                          version: dependencies.ytDlpVersion,
                          exists: FileManager.default.fileExists(atPath: dependencies.ytDlpPath.path),
                          update: { Task { await dependencies.updateYtDlp() } },
                          reinstall: { Task { await dependencies.updateYtDlp() } })
            dependencyRow(name: "ffmpeg",
                          version: dependencies.ffmpegVersion,
                          exists: FileManager.default.fileExists(atPath: dependencies.ffmpegPath.path),
                          update: { Task { await dependencies.reinstallFfmpeg() } },
                          reinstall: { Task { await dependencies.reinstallFfmpeg() } })
            Spacer()
        }
        .padding(20)
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
            Image(systemName: icon).font(.title2).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                if let p = progress {
                    ProgressView(value: p).tint(tint)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(0.12))
        )
    }

    private func dependencyRow(name: String,
                               version: String?,
                               exists: Bool,
                               update: @escaping () -> Void,
                               reinstall: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(.body, design: .rounded).weight(.semibold))
                Text(version ?? (exists ? "Installed" : "Not installed"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Update", action: update)
            Button("Reinstall", action: reinstall).buttonStyle(.bordered)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.background.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 0.5)
                )
        )
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
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("sites")
                        .font(H3.display(size: 26, weight: .medium))
                        .foregroundStyle(H3.ink900)
                    Text("catapult works with anything yt-dlp supports. toggle cookies on for a site to pull them from the browser you picked in network settings — handy for private, age-gated, or members-only stuff.")
                        .font(H3.body(size: 12))
                        .foregroundStyle(H3.ink500)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 4)
                .padding(.top, 6)

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(SupportedSite.allCases) { site in
                        SiteCard(site: site)
                    }
                }
            }
            .padding(16)
        }
        .background(H3.ink50)
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
        ("capu audio <url>",              "extract audio"),
        ("capu thumb <url>",              "save the thumbnail"),
        ("capu cut <url> 0:12 0:42",      "clip a section"),
        ("capu queue",                    "list recent downloads"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                installCard
                commandsCard
                if let error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 4)
                }
            }
            .padding(16)
        }
        .background(H3.ink50)
        .onAppear { status = CLIInstaller.currentInstall }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("terminal")
                .font(H3.display(size: 26, weight: .medium))
                .foregroundStyle(H3.ink900)
            Text("prefer the keyboard? install the catapult cli — a tiny tui that shares this app's settings and binaries. works as one-shot commands too.")
                .font(H3.body(size: 12))
                .foregroundStyle(H3.ink500)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
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
                    case .installed(let path, let onPath):
                        HStack(spacing: 6) {
                            Circle()
                                .fill(onPath ? H3.green : H3.amber)
                                .frame(width: 8, height: 8)
                            Text(onPath ? "installed, on your path" : "installed — not on your path yet")
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
                case .installed(_, let onPath):
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
        guard case .installed(let path, _) = status else { return }
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
// Manage YouTube channel subscriptions. Catapult polls the public RSS feed
// (https://www.youtube.com/feeds/videos.xml?channel_id=…) every N minutes
// and auto-enqueues new uploads.

private struct SubscriptionsTab: View {
    @State private var subs = SubscriptionManager.shared
    @State private var newInput: String = ""
    @State private var resolving: Bool = false
    @State private var resolveError: String? = nil
    @State private var checking: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("subscriptions")
                        .font(H3.display(size: 26, weight: .medium))
                        .foregroundStyle(H3.ink900)
                    Text("watch a youtube channel — i'll grab every recent upload right away, then poll the rss feed for new ones. no api key, no login. each subscription has its own quality + preset.")
                        .font(H3.body(size: 12))
                        .foregroundStyle(H3.ink500)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 4)
                .padding(.top, 6)

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
            .padding(16)
        }
        .background(H3.ink50)
    }

    private var addCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle")
                    .foregroundStyle(H3.blue400)
                TextField("channel url, @handle, or UC… id",
                          text: $newInput,
                          prompt: Text("https://www.youtube.com/@mkbhd"))
                    .textFieldStyle(.plain)
                    .onSubmit(addChannel)
                Button("watch") { addChannel() }
                    .buttonStyle(.borderedProminent)
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
            RoundedRectangle(cornerRadius: H3.radius3, style: .continuous).fill(.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: H3.radius3, style: .continuous)
                .stroke(H3.cardStroke, lineWidth: 1)
        )
    }

    private var controlsCard: some View {
        HStack(spacing: 12) {
            Toggle("auto-check", isOn: Binding(
                get: { subs.enabled },
                set: { subs.enabled = $0 }
            ))
            .toggleStyle(.switch)
            .tint(H3.blue400)
            Divider().frame(height: 18)
            Stepper("every \(subs.pollMinutes) min",
                    value: Binding(
                        get: { subs.pollMinutes },
                        set: { subs.pollMinutes = max(15, $0) }
                    ),
                    in: 15...720, step: 15)
            Spacer()
            if let last = subs.lastCheckAt {
                Text("last: \(last.formatted(date: .omitted, time: .shortened))")
                    .font(H3.body(size: 11))
                    .foregroundStyle(H3.ink500)
            }
            Button {
                checkNow()
            } label: {
                HStack(spacing: 4) {
                    if checking { ProgressView().controlSize(.mini) }
                    Text("check now")
                }
            }
            .disabled(subs.subscriptions.isEmpty || checking)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: H3.radius3, style: .continuous).fill(.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: H3.radius3, style: .continuous)
                .stroke(H3.cardStroke, lineWidth: 1)
        )
    }

    private var emptyCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray")
                .foregroundStyle(H3.ink300)
            Text("no subscriptions yet — paste a channel url above.")
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
                    subs.add(channelID: r.id, title: r.title)
                    newInput = ""
                } else {
                    resolveError = "couldn't find a channel at that url — check the link and try again."
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
            GradientGlyph(systemName: "play.rectangle.fill",
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
            RoundedRectangle(cornerRadius: H3.radius3, style: .continuous).fill(.white)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("devices")
                        .font(H3.display(size: 26, weight: .medium))
                        .foregroundStyle(H3.ink900)
                    Text("one-tap recipes for specific hardware. retro presets transcode to h.264 baseline at the exact resolution the device accepts — so a 2006 ipod or a psp actually plays the file.")
                        .font(H3.body(size: 12))
                        .foregroundStyle(H3.ink500)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 4)
                .padding(.top, 6)

                section(title: "modern", presets: modern)
                section(title: "retro slop", presets: retro)

                Text("tip: hold ⌘-click on the download button to pick a preset per-download. these tiles set your default — clear it by choosing 'no preset'.")
                    .font(H3.body(size: 11))
                    .foregroundStyle(H3.ink500)
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
            }
            .padding(16)
        }
        .background(H3.ink50)
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
        VStack(spacing: 18) {
            TiltyAppIcon(size: 220)
                .padding(.top, 8)
            Text("Catapult")
                .font(.system(size: 28, weight: .bold, design: .rounded))
            Text("a beautifully native yt-dlp companion for macos.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("version 1.0")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            HStack(spacing: 16) {
                Link("yt-dlp", destination: URL(string: "https://github.com/yt-dlp/yt-dlp")!)
                Link("ffmpeg", destination: URL(string: "https://ffmpeg.org")!)
            }
            .font(.caption)
            .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 24)
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
