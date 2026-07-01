#if canImport(SwiftUI)
import CatapultPocketCore
import SwiftUI

public struct CatapocketRootView: View {
    @StateObject private var model: CatapocketAppModel
    @State private var fileExport: CatapocketLocalMedia?

    public init(model: CatapocketAppModel = CatapocketAppModel()) {
        _model = StateObject(wrappedValue: model)
    }

    public var body: some View {
        Group {
            #if os(iOS)
            CatapocketAdaptiveRoot(model: model, fileExport: $fileExport)
            #else
            CatapocketPadRoot(model: model, fileExport: $fileExport)
            #endif
        }
        .task {
            await model.load()
        }
        .sheet(item: $fileExport) { media in
            fileExportSheet(for: media)
        }
    }

    @ViewBuilder
    private func fileExportSheet(for media: CatapocketLocalMedia) -> some View {
        #if canImport(UIKit)
        CatapocketFilesExportSheet(fileURL: media.fileURL) { saved in
            model.statusText = saved ? "Exported to Files" : "Files export cancelled"
        }
        #else
        Text("Files export is available on iPhone and iPad.")
            .padding()
        #endif
    }
}

#if os(iOS)
private struct CatapocketAdaptiveRoot: View {
    @ObservedObject var model: CatapocketAppModel
    @Binding var fileExport: CatapocketLocalMedia?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        if horizontalSizeClass == .regular {
            CatapocketPadRoot(model: model, fileExport: $fileExport)
        } else {
            CatapocketPhoneRoot(model: model, fileExport: $fileExport)
        }
    }
}
#endif

private struct CatapocketPhoneRoot: View {
    @ObservedObject var model: CatapocketAppModel
    @Binding var fileExport: CatapocketLocalMedia?

    var body: some View {
        TabView(selection: $model.activeSection) {
            NavigationStack {
                PocketView(model: model)
            }
            .tabItem { Label("Pocket", systemImage: CatapocketSection.pocket.systemImage) }
            .tag(CatapocketSection.pocket)

            NavigationStack {
                LibraryView(model: model)
            }
            .tabItem { Label("Library", systemImage: CatapocketSection.library.systemImage) }
            .tag(CatapocketSection.library)

            NavigationStack {
                DownloadsView(model: model, fileExport: $fileExport)
            }
            .tabItem { Label("Downloads", systemImage: CatapocketSection.downloads.systemImage) }
            .tag(CatapocketSection.downloads)

            NavigationStack {
                SettingsPanel(model: model)
            }
            .tabItem { Label("Settings", systemImage: CatapocketSection.settings.systemImage) }
            .tag(CatapocketSection.settings)
        }
        .tint(Color.catapocketOrange)
    }
}

private struct CatapocketPadRoot: View {
    @ObservedObject var model: CatapocketAppModel
    @Binding var fileExport: CatapocketLocalMedia?

    var body: some View {
        NavigationSplitView {
            List(CatapocketSection.allCases, selection: $model.activeSection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationTitle("Catapocket")
            .safeAreaInset(edge: .bottom) {
                ConnectionFooter(model: model)
            }
        } content: {
            sectionContent
                .navigationTitle(model.activeSection.title)
        } detail: {
            if let item = model.selectedLibraryItem {
                LibraryDetailView(model: model, item: item)
            } else {
                EmptyPanel(title: "No selection",
                           detail: "Choose a library item to stream, download, or save it.")
            }
        }
        .tint(Color.catapocketOrange)
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch model.activeSection {
        case .pocket:
            PocketView(model: model)
        case .library:
            LibraryView(model: model)
        case .downloads:
            DownloadsView(model: model, fileExport: $fileExport)
        case .settings:
            SettingsPanel(model: model)
        }
    }
}

private struct PocketView: View {
    @ObservedObject var model: CatapocketAppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HeaderPanel(model: model)

                CatapocketPanel {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Save a link", systemImage: "link")
                            .font(.headline)
                        TextField("Paste a video link", text: $model.linkText)
                            .textFieldStyle(.plain)
                            .padding(14)
                            .background(Color.catapocketElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(.white.opacity(0.08), lineWidth: 1)
                            }
                        HStack {
                            Button {
                                Task { await model.saveOfflineLink() }
                            } label: {
                                Label("Save offline", systemImage: "tray.and.arrow.down.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.catapocketPrimary)

                            Button {
                                Task { await model.syncPendingLinks() }
                            } label: {
                                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.catapocketSecondary)
                        }
                    }
                }

                SectionHeader("Pocketed links", count: model.offlineLinks.count)
                if model.offlineLinks.isEmpty {
                    EmptyPanel(title: "Nothing saved yet",
                               detail: "Links saved away from your Mac will stay here until Wi-Fi sync is back.")
                } else {
                    VStack(spacing: 10) {
                        ForEach(model.offlineLinks) { link in
                            OfflineLinkRow(link: link)
                        }
                    }
                }
            }
            .padding(18)
        }
        .background(Color.catapocketBackground.ignoresSafeArea())
        .navigationTitle("Pocket")
        .toolbar {
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
        }
    }
}

private struct LibraryView: View {
    @ObservedObject var model: CatapocketAppModel

    var body: some View {
        List(selection: $model.selectedLibraryItemID) {
            if model.libraryItems.isEmpty {
                EmptyPanel(title: "Library is empty",
                           detail: "Finished Catapult downloads on your Mac will show up here.")
                .listRowBackground(Color.clear)
            } else {
                ForEach(model.libraryItems) { item in
                    LibraryRow(model: model, item: item)
                        .tag(item.id)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.catapocketBackground.ignoresSafeArea())
        .navigationTitle("Library")
        .toolbar {
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
        }
    }
}

private struct LibraryDetailView: View {
    @ObservedObject var model: CatapocketAppModel
    let item: CatapocketLibraryItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ThumbnailView(model: model, item: item)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 8) {
                    Text(item.title)
                        .font(.title2.weight(.bold))
                    Text("\(item.site.rawValue.capitalized) - \(item.status)")
                        .foregroundStyle(Color.catapocketMuted)
                }

                CatapocketPanel {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Save on this device")
                            .font(.headline)
                        HStack {
                            DownloadButton(title: "Original", systemImage: "arrow.down.circle") {
                                await model.downloadOriginal(item)
                            }
                            DownloadButton(title: "HEVC", systemImage: "film") {
                                await model.downloadHEVC(item)
                            }
                            DownloadButton(title: "Audio", systemImage: "waveform") {
                                await model.downloadAudio(item)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(Color.catapocketBackground.ignoresSafeArea())
    }
}

private struct DownloadsView: View {
    @ObservedObject var model: CatapocketAppModel
    @Binding var fileExport: CatapocketLocalMedia?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader("Saved on this device", count: model.localMedia.count)
                if model.localMedia.isEmpty {
                    EmptyPanel(title: "No device downloads",
                               detail: "Download from Library, then save video files to Photos or Files.")
                } else {
                    ForEach(model.localMedia) { media in
                        LocalMediaRow(media: media,
                                      savePhotos: { Task { await model.saveToPhotos(media) } },
                                      saveFiles: { fileExport = media },
                                      delete: { model.deleteLocalMedia(media) })
                    }
                }

                if !model.downloads.isEmpty {
                    SectionHeader("Queue", count: model.downloads.count)
                    ForEach(model.downloads) { job in
                        DownloadJobRow(job: job)
                    }
                }
            }
            .padding(18)
        }
        .background(Color.catapocketBackground.ignoresSafeArea())
        .navigationTitle("Downloads")
    }
}

private struct SettingsPanel: View {
    @ObservedObject var model: CatapocketAppModel
    @State private var pairCode = ""
    @State private var showingScanner = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HeaderPanel(model: model)
                CatapocketPanel {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Pairing", systemImage: "qrcode.viewfinder")
                            .font(.headline)
                        Text("Scan the Catapocket QR code in Catapult Settings on your Mac. The QR stores the local URL, token, server ID, and supported features.")
                            .foregroundStyle(Color.catapocketMuted)
                        Text(model.client == nil ? "No Mac paired" : "Mac paired")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(model.client == nil ? Color.catapocketDanger : Color.catapocketSuccess)
                        #if os(iOS)
                        Button {
                            showingScanner = true
                        } label: {
                            Label("Scan QR", systemImage: "qrcode.viewfinder")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.catapocketPrimary)
                        #endif
                        TextField("Paste pair code", text: $pairCode, axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(3...6)
                            .padding(12)
                            .background(Color.catapocketElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        Button {
                            model.pair(withCode: pairCode)
                        } label: {
                            Label("Use pair code", systemImage: "link.badge.plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.catapocketSecondary)
                        .disabled(pairCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .padding(18)
        }
        .background(Color.catapocketBackground.ignoresSafeArea())
        .navigationTitle("Settings")
        #if os(iOS)
        .sheet(isPresented: $showingScanner) {
            NavigationStack {
                CatapocketQRScannerView { code in
                    pairCode = code
                    model.pair(withCode: code)
                    showingScanner = false
                }
                .ignoresSafeArea()
                .navigationTitle("Scan QR")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    Button("Cancel") { showingScanner = false }
                }
            }
        }
        #endif
    }
}

private struct HeaderPanel: View {
    @ObservedObject var model: CatapocketAppModel

    var body: some View {
        CatapocketPanel {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.catapocketOrange)
                    .frame(width: 46, height: 46)
                    .overlay {
                        Image(systemName: "tray.and.arrow.down.fill")
                            .font(.system(size: 22, weight: .black))
                            .foregroundStyle(.white)
                    }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Catapocket")
                        .font(.title3.weight(.bold))
                    Text(model.statusText)
                        .font(.subheadline)
                        .foregroundStyle(Color.catapocketMuted)
                        .lineLimit(2)
                }
                Spacer()
                ConnectionChip(connected: model.isConnected)
            }
        }
    }
}

private struct ConnectionFooter: View {
    @ObservedObject var model: CatapocketAppModel

    var body: some View {
        HStack {
            ConnectionChip(connected: model.isConnected)
            Text(model.statusText)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Color.catapocketMuted)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.catapocketPanel)
    }
}

private struct LibraryRow: View {
    @ObservedObject var model: CatapocketAppModel
    let item: CatapocketLibraryItem

    var body: some View {
        CatapocketPanel {
            HStack(spacing: 12) {
                ThumbnailView(model: model, item: item)
                    .frame(width: 88, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title)
                        .font(.headline)
                        .lineLimit(2)
                    Text(meta)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Color.catapocketMuted)
                        .lineLimit(1)
                    HStack {
                        DownloadButton(title: "Original", systemImage: "arrow.down") {
                            await model.downloadOriginal(item)
                        }
                        DownloadButton(title: "HEVC", systemImage: "film") {
                            await model.downloadHEVC(item)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var meta: String {
        let size = item.fileSizeBytes.map(Self.formatBytes) ?? "unknown size"
        return "\(item.site.rawValue.capitalized) - \(size)"
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct LocalMediaRow: View {
    let media: CatapocketLocalMedia
    let savePhotos: () -> Void
    let saveFiles: () -> Void
    let delete: () -> Void

    var body: some View {
        CatapocketPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(media.title)
                            .font(.headline)
                            .lineLimit(2)
                        Text("\(media.profile.label) - \(sizeText)")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Color.catapocketMuted)
                    }
                    Spacer()
                    Button(role: .destructive, action: delete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
                HStack {
                    Button(action: savePhotos) {
                        Label("Photos", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.catapocketPrimary)

                    Button(action: saveFiles) {
                        Label("Files", systemImage: "folder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.catapocketSecondary)
                }
            }
        }
    }

    private var sizeText: String {
        media.byteCount.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            ?? "saved locally"
    }
}

private struct OfflineLinkRow: View {
    let link: CatapocketOfflineLink

    var body: some View {
        CatapocketPanel {
            HStack(spacing: 12) {
                Image(systemName: link.syncStatus == .synced ? "checkmark.circle.fill" : "clock")
                    .foregroundStyle(link.syncStatus == .synced ? Color.catapocketSuccess : Color.catapocketOrange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(link.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(link.url)
                        .font(.caption)
                        .foregroundStyle(Color.catapocketMuted)
                        .lineLimit(1)
                }
                Spacer()
                Text(link.syncStatus.rawValue)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.catapocketElevated, in: Capsule())
            }
        }
    }
}

private struct DownloadJobRow: View {
    let job: CatapocketDownloadJob

    var body: some View {
        CatapocketPanel {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(job.title)
                        .font(.headline)
                    Spacer()
                    Text(job.status.rawValue)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.catapocketMuted)
                }
                ProgressView(value: job.progress)
                    .tint(Color.catapocketOrange)
            }
        }
    }
}

private struct ThumbnailView: View {
    @ObservedObject var model: CatapocketAppModel
    let item: CatapocketLibraryItem

    var body: some View {
        ZStack {
            Color.catapocketElevated
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "play.rectangle.fill")
                            .font(.title)
                            .foregroundStyle(Color.catapocketMuted)
                    }
                }
            } else {
                Image(systemName: "play.rectangle.fill")
                    .font(.title)
                    .foregroundStyle(Color.catapocketMuted)
            }
        }
        .clipped()
    }

    private var url: URL? {
        if let thumbnailURL = item.thumbnailURL,
           let direct = URL(string: thumbnailURL) {
            return direct
        }
        return model.client?.libraryThumbnailURL(id: item.id)
    }
}

private struct DownloadButton: View {
    let title: String
    let systemImage: String
    let action: () async -> Void

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.bold))
        }
        .buttonStyle(.catapocketChip)
    }
}

private struct SectionHeader: View {
    let title: String
    let count: Int

    init(_ title: String, count: Int) {
        self.title = title
        self.count = count
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.headline)
            Spacer()
            Text("\(count)")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.catapocketMuted)
        }
    }
}

private struct EmptyPanel: View {
    let title: String
    let detail: String

    var body: some View {
        CatapocketPanel {
            HStack(spacing: 12) {
                Image(systemName: "tray")
                    .font(.title3)
                    .frame(width: 38, height: 38)
                    .background(Color.catapocketElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(Color.catapocketMuted)
                }
                Spacer()
            }
        }
    }
}

private struct ConnectionChip: View {
    let connected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(connected ? Color.catapocketSuccess : Color.catapocketDanger)
                .frame(width: 8, height: 8)
            Text(connected ? "Connected" : "Offline")
                .font(.caption.weight(.bold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.catapocketElevated, in: Capsule())
    }
}

private struct CatapocketPanel<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.catapocketPanel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.white.opacity(0.08), lineWidth: 1)
            }
    }
}

private extension CatapocketDownloadProfile {
    var label: String {
        switch self {
        case .original: return "Original"
        case .hevcSameResolution: return "HEVC same-res"
        case .audioOnly: return "Audio"
        }
    }
}

private extension Color {
    static let catapocketBackground = Color(red: 0.043, green: 0.059, blue: 0.078)
    static let catapocketPanel = Color(red: 0.071, green: 0.094, blue: 0.125)
    static let catapocketElevated = Color(red: 0.095, green: 0.125, blue: 0.165)
    static let catapocketMuted = Color(red: 0.659, green: 0.690, blue: 0.741)
    static let catapocketOrange = Color(red: 1.0, green: 0.231, blue: 0.071)
    static let catapocketSuccess = Color(red: 0.145, green: 0.820, blue: 0.514)
    static let catapocketDanger = Color(red: 1.0, green: 0.353, blue: 0.400)
}

private struct CatapocketPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.bold))
            .foregroundStyle(.white)
            .padding(.vertical, 12)
            .padding(.horizontal, 12)
            .background(Color.catapocketOrange.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct CatapocketSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.bold))
            .foregroundStyle(.primary)
            .padding(.vertical, 12)
            .padding(.horizontal, 12)
            .background(Color.catapocketElevated.opacity(configuration.isPressed ? 0.65 : 1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct CatapocketChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.catapocketOrange)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(Color.catapocketElevated.opacity(configuration.isPressed ? 0.65 : 1), in: Capsule())
    }
}

private extension ButtonStyle where Self == CatapocketPrimaryButtonStyle {
    static var catapocketPrimary: CatapocketPrimaryButtonStyle { CatapocketPrimaryButtonStyle() }
}

private extension ButtonStyle where Self == CatapocketSecondaryButtonStyle {
    static var catapocketSecondary: CatapocketSecondaryButtonStyle { CatapocketSecondaryButtonStyle() }
}

private extension ButtonStyle where Self == CatapocketChipButtonStyle {
    static var catapocketChip: CatapocketChipButtonStyle { CatapocketChipButtonStyle() }
}
#endif
