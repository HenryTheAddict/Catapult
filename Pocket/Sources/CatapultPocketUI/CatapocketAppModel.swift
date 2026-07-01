import CatapultPocketCore
import Foundation

#if canImport(Combine)
import Combine
#endif

@MainActor
public final class CatapocketAppModel: ObservableObject {
    @Published public private(set) var state: CatapocketState?
    @Published public private(set) var snapshot: CatapocketOfflineStore.Snapshot?
    @Published public private(set) var localMedia: [CatapocketLocalMedia] = []
    @Published public var client: CatapocketClient?
    @Published public var activeSection: CatapocketSection = .pocket
    @Published public var selectedLibraryItemID: UUID?
    @Published public var linkText = ""
    @Published public var statusText = "Ready"
    @Published public var isRefreshing = false
    @Published public var isDownloading = false

    private var store: CatapocketOfflineStore?
    private let storeURL: URL
    private let mediaDirectory: URL
    private let downloader: CatapocketMediaDownloader
    private let exporter: CatapocketMediaExporter

    public init(client: CatapocketClient? = nil,
                storeURL: URL? = nil,
                mediaDirectory: URL? = nil,
                downloader: CatapocketMediaDownloader = CatapocketMediaDownloader(),
                exporter: CatapocketMediaExporter = CatapocketMediaExporter()) {
        self.client = client
        self.storeURL = storeURL ?? CatapocketAppModel.defaultStoreURL
        self.mediaDirectory = mediaDirectory ?? CatapocketAppModel.defaultMediaDirectory
        self.downloader = downloader
        self.exporter = exporter
    }

    public static var defaultStoreURL: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Catapocket", isDirectory: true)
            .appendingPathComponent("catapocket.json")
    }

    public static var defaultMediaDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("CatapocketMedia", isDirectory: true)
    }

    public var libraryItems: [CatapocketLibraryItem] {
        state?.library ?? []
    }

    public var offlineLinks: [CatapocketOfflineLink] {
        snapshot?.links ?? []
    }

    public var downloads: [CatapocketDownloadJob] {
        snapshot?.downloads ?? []
    }

    public var selectedLibraryItem: CatapocketLibraryItem? {
        guard let selectedLibraryItemID else { return libraryItems.first }
        return libraryItems.first { $0.id == selectedLibraryItemID }
    }

    public var isConnected: Bool {
        state?.running == true
    }

    public func load() async {
        if store == nil {
            store = await CatapocketOfflineStore(fileURL: storeURL)
        }
        await refreshSnapshot()
        loadLocalMediaIndex()
        if client != nil {
            await refresh()
        }
    }

    public func pair(with payload: CatapocketPairingPayload) {
        do {
            client = try CatapocketClient(pairing: payload)
            statusText = "Paired with \(payload.displayName)"
        } catch {
            statusText = error.localizedDescription
        }
    }

    public func pair(withCode code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else {
            statusText = "That pair code is not valid"
            return
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let payload = try decoder.decode(CatapocketPairingPayload.self, from: data)
            pair(with: payload)
        } catch {
            statusText = "That pair code is not valid"
        }
    }

    public func refresh() async {
        guard let client else {
            statusText = "Scan Catapult's Catapocket QR code to pair."
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            state = try await client.fetchState()
            if let first = state?.library.first, selectedLibraryItemID == nil {
                selectedLibraryItemID = first.id
            }
            statusText = state?.status ?? "Connected"
        } catch {
            statusText = "Offline - saved links still work"
        }
    }

    public func saveOfflineLink() async {
        let trimmed = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if store == nil {
            store = await CatapocketOfflineStore(fileURL: storeURL)
        }
        let title = URL(string: trimmed)?.host ?? "Catapocket link"
        _ = await store?.saveLink(url: trimmed, title: title, mode: .video, site: .generic)
        linkText = ""
        statusText = "Saved offline"
        await refreshSnapshot()
    }

    public func syncPendingLinks() async {
        guard let client else {
            statusText = "Pair with a Mac first"
            return
        }
        if store == nil {
            store = await CatapocketOfflineStore(fileURL: storeURL)
        }
        guard let request = await store?.pendingSyncRequest(), !request.links.isEmpty else {
            statusText = "Nothing pending"
            return
        }
        do {
            let response = try await client.sync(request)
            await store?.markSynced(ids: response.acceptedLocalIDs)
            state = response.state
            statusText = "Synced \(response.acceptedLocalIDs.count) link(s)"
        } catch {
            await store?.markSyncFailed(ids: request.links.map(\.id), message: error.localizedDescription)
            statusText = "Sync failed"
        }
        await refreshSnapshot()
    }

    public func downloadOriginal(_ item: CatapocketLibraryItem) async {
        await download(item, profile: .original)
    }

    public func downloadHEVC(_ item: CatapocketLibraryItem) async {
        await download(item, profile: .hevcSameResolution)
    }

    public func downloadAudio(_ item: CatapocketLibraryItem) async {
        await download(item, profile: .audioOnly)
    }

    public func saveToPhotos(_ media: CatapocketLocalMedia) async {
        do {
            try await exporter.saveVideoToPhotos(fileURL: media.fileURL)
            statusText = "Saved to Photos"
        } catch {
            statusText = error.localizedDescription
        }
    }

    public func deleteLocalMedia(_ media: CatapocketLocalMedia) {
        try? FileManager.default.removeItem(at: media.fileURL)
        localMedia.removeAll { $0.id == media.id }
        persistLocalMediaIndex()
        statusText = "Removed local copy"
    }

    private func download(_ item: CatapocketLibraryItem,
                          profile: CatapocketDownloadProfile) async {
        guard let client else {
            statusText = "Pair with a Mac first"
            return
        }
        guard item.canDownload || profile == .original && item.canStream else {
            statusText = "This item is not downloadable"
            return
        }
        isDownloading = true
        statusText = "Downloading \(item.title)"
        defer { isDownloading = false }
        do {
            let media: CatapocketLocalMedia
            if profile == .original {
                media = try await downloader.downloadOriginal(item,
                                                              using: client,
                                                              destinationDirectory: mediaDirectory)
            } else {
                media = try await downloader.download(item,
                                                      profile: profile,
                                                      using: client,
                                                      destinationDirectory: mediaDirectory)
            }
            localMedia.removeAll { $0.fileURL == media.fileURL || $0.libraryItemID == media.libraryItemID && $0.profile == media.profile }
            localMedia.insert(media, at: 0)
            persistLocalMediaIndex()
            statusText = "Downloaded to Catapocket"
        } catch {
            statusText = error.localizedDescription
        }
    }

    private func refreshSnapshot() async {
        snapshot = await store?.currentSnapshot()
    }

    private var mediaIndexURL: URL {
        mediaDirectory.appendingPathComponent("media-index.json")
    }

    private func loadLocalMediaIndex() {
        guard let data = try? Data(contentsOf: mediaIndexURL),
              let decoded = try? JSONDecoder.catapocket.decode([CatapocketLocalMedia].self, from: data) else {
            localMedia = []
            return
        }
        localMedia = decoded.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
    }

    private func persistLocalMediaIndex() {
        do {
            try FileManager.default.createDirectory(at: mediaDirectory,
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder.catapocket.encode(localMedia)
            try data.write(to: mediaIndexURL, options: [.atomic])
        } catch {
            statusText = error.localizedDescription
        }
    }
}

public enum CatapocketSection: String, CaseIterable, Identifiable, Sendable {
    case pocket
    case library
    case downloads
    case settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .pocket: return "Pocket"
        case .library: return "Library"
        case .downloads: return "Downloads"
        case .settings: return "Settings"
        }
    }

    public var systemImage: String {
        switch self {
        case .pocket: return "tray.and.arrow.down"
        case .library: return "rectangle.stack"
        case .downloads: return "arrow.down.circle"
        case .settings: return "gearshape"
        }
    }
}

private extension JSONEncoder {
    static var catapocket: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var catapocket: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
