import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum CatapocketMode: String, Codable, CaseIterable, Sendable {
    case video
    case audio
}

public enum CatapocketSite: String, Codable, CaseIterable, Sendable {
    case youtube
    case tiktok
    case twitter
    case reddit
    case instagram
    case facebook
    case twitch
    case vimeo
    case soundcloud
    case spotify
    case bilibili
    case bluesky
    case generic
}

public enum CatapocketSyncStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case syncing
    case synced
    case failed
}

public enum CatapocketDownloadProfile: String, Codable, CaseIterable, Sendable {
    case original
    case hevcSameResolution
    case audioOnly
}

public enum CatapocketDownloadStatus: String, Codable, CaseIterable, Sendable {
    case queued
    case active
    case paused
    case completed
    case failed
    case cancelled
}

public struct CatapocketLink: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var url: String
    public var title: String
    public var mode: CatapocketMode
    public var site: CatapocketSite
    public var addedAt: Date
    public var queuedAt: Date?

    public init(id: UUID = UUID(),
                url: String,
                title: String,
                mode: CatapocketMode,
                site: CatapocketSite,
                addedAt: Date = Date(),
                queuedAt: Date? = nil) {
        self.id = id
        self.url = url
        self.title = title
        self.mode = mode
        self.site = site
        self.addedAt = addedAt
        self.queuedAt = queuedAt
    }
}

public struct CatapocketOfflineLink: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var url: String
    public var title: String
    public var mode: CatapocketMode
    public var site: CatapocketSite
    public var thumbnailURL: String?
    public var createdAt: Date
    public var lastSyncAt: Date?
    public var syncStatus: CatapocketSyncStatus
    public var errorMessage: String?

    public init(id: UUID = UUID(),
                url: String,
                title: String,
                mode: CatapocketMode = .video,
                site: CatapocketSite = .generic,
                thumbnailURL: String? = nil,
                createdAt: Date = Date(),
                lastSyncAt: Date? = nil,
                syncStatus: CatapocketSyncStatus = .pending,
                errorMessage: String? = nil) {
        self.id = id
        self.url = url
        self.title = title
        self.mode = mode
        self.site = site
        self.thumbnailURL = thumbnailURL
        self.createdAt = createdAt
        self.lastSyncAt = lastSyncAt
        self.syncStatus = syncStatus
        self.errorMessage = errorMessage
    }
}

public struct CatapocketDownload: Codable, Hashable, Sendable {
    public var title: String
    public var mode: CatapocketMode
    public var status: String
    public var progress: Double

    public init(title: String,
                mode: CatapocketMode,
                status: String,
                progress: Double) {
        self.title = title
        self.mode = mode
        self.status = status
        self.progress = progress
    }
}

public struct CatapocketLibraryItem: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var site: CatapocketSite
    public var mode: CatapocketMode
    public var status: String
    public var sourceURL: String
    public var durationSeconds: Double?
    public var fileSizeBytes: Int64?
    public var finishedAt: Date
    public var thumbnailURL: String?
    public var streamURL: String?
    public var downloadJobURL: String?
    public var canStream: Bool
    public var canDownload: Bool
    public var fileExists: Bool

    public init(id: UUID,
                title: String,
                site: CatapocketSite,
                mode: CatapocketMode,
                status: String,
                sourceURL: String,
                durationSeconds: Double? = nil,
                fileSizeBytes: Int64? = nil,
                finishedAt: Date,
                thumbnailURL: String? = nil,
                streamURL: String? = nil,
                downloadJobURL: String? = nil,
                canStream: Bool,
                canDownload: Bool,
                fileExists: Bool) {
        self.id = id
        self.title = title
        self.site = site
        self.mode = mode
        self.status = status
        self.sourceURL = sourceURL
        self.durationSeconds = durationSeconds
        self.fileSizeBytes = fileSizeBytes
        self.finishedAt = finishedAt
        self.thumbnailURL = thumbnailURL
        self.streamURL = streamURL
        self.downloadJobURL = downloadJobURL
        self.canStream = canStream
        self.canDownload = canDownload
        self.fileExists = fileExists
    }
}

public struct CatapocketStorageSummary: Codable, Hashable, Sendable {
    public var pendingLinkCount: Int
    public var syncedLinkCount: Int
    public var offlineLinkCount: Int
    public var cachedMediaBytes: Int64
    public var cachedThumbnailBytes: Int64
    public var cacheLimitBytes: Int64?
    public var macLibraryBytes: Int64
    public var macLibraryCount: Int

    public init(pendingLinkCount: Int = 0,
                syncedLinkCount: Int = 0,
                offlineLinkCount: Int = 0,
                cachedMediaBytes: Int64 = 0,
                cachedThumbnailBytes: Int64 = 0,
                cacheLimitBytes: Int64? = nil,
                macLibraryBytes: Int64 = 0,
                macLibraryCount: Int = 0) {
        self.pendingLinkCount = pendingLinkCount
        self.syncedLinkCount = syncedLinkCount
        self.offlineLinkCount = offlineLinkCount
        self.cachedMediaBytes = cachedMediaBytes
        self.cachedThumbnailBytes = cachedThumbnailBytes
        self.cacheLimitBytes = cacheLimitBytes
        self.macLibraryBytes = macLibraryBytes
        self.macLibraryCount = macLibraryCount
    }
}

public struct CatapocketDownloadJob: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var libraryItemID: UUID?
    public var remoteJobID: String?
    public var title: String
    public var profile: CatapocketDownloadProfile
    public var status: CatapocketDownloadStatus
    public var progress: Double
    public var bytesReceived: Int64
    public var totalBytes: Int64?
    public var localFilePath: String?
    public var isFavorite: Bool
    public var errorMessage: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(),
                libraryItemID: UUID? = nil,
                remoteJobID: String? = nil,
                title: String,
                profile: CatapocketDownloadProfile = .original,
                status: CatapocketDownloadStatus = .queued,
                progress: Double = 0,
                bytesReceived: Int64 = 0,
                totalBytes: Int64? = nil,
                localFilePath: String? = nil,
                isFavorite: Bool = false,
                errorMessage: String? = nil,
                createdAt: Date = Date(),
                updatedAt: Date = Date()) {
        self.id = id
        self.libraryItemID = libraryItemID
        self.remoteJobID = remoteJobID
        self.title = title
        self.profile = profile
        self.status = status
        self.progress = progress
        self.bytesReceived = bytesReceived
        self.totalBytes = totalBytes
        self.localFilePath = localFilePath
        self.isFavorite = isFavorite
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct CatapocketState: Codable, Hashable, Sendable {
    public var running: Bool
    public var status: String
    public var remoteURL: String
    public var apiVersion: Int
    public var serverID: String
    public var capabilities: [String]
    public var links: [CatapocketLink]
    public var downloads: [CatapocketDownload]
    public var library: [CatapocketLibraryItem]
    public var storage: CatapocketStorageSummary

    public init(running: Bool,
                status: String,
                remoteURL: String,
                apiVersion: Int = 2,
                serverID: String = "",
                capabilities: [String] = [],
                links: [CatapocketLink],
                downloads: [CatapocketDownload],
                library: [CatapocketLibraryItem] = [],
                storage: CatapocketStorageSummary = CatapocketStorageSummary()) {
        self.running = running
        self.status = status
        self.remoteURL = remoteURL
        self.apiVersion = apiVersion
        self.serverID = serverID
        self.capabilities = capabilities
        self.links = links
        self.downloads = downloads
        self.library = library
        self.storage = storage
    }
}

public struct CatapocketPairingPayload: Codable, Hashable, Sendable {
    public var kind: String
    public var version: Int
    public var app: String
    public var displayName: String
    public var platformPriority: String
    public var baseURL: String
    public var remoteURL: String
    public var token: String
    public var serverID: String
    public var apiVersion: Int
    public var endpoints: [String: String]
    public var capabilities: [String]

    public init(kind: String = "xyz.h3nry.catapocket.pairing",
                version: Int = 1,
                app: String = "Catapocket",
                displayName: String,
                platformPriority: String = "ios",
                baseURL: String,
                remoteURL: String,
                token: String,
                serverID: String,
                apiVersion: Int = 2,
                endpoints: [String: String] = [:],
                capabilities: [String] = []) {
        self.kind = kind
        self.version = version
        self.app = app
        self.displayName = displayName
        self.platformPriority = platformPriority
        self.baseURL = baseURL
        self.remoteURL = remoteURL
        self.token = token
        self.serverID = serverID
        self.apiVersion = apiVersion
        self.endpoints = endpoints
        self.capabilities = capabilities
    }

    public var resolvedBaseURL: URL? {
        URL(string: baseURL) ?? URL(string: remoteURL)
    }
}

public struct CatapocketSubmission: Codable, Hashable, Sendable {
    public var url: String
    public var mode: CatapocketMode
    public var title: String?
    public var site: CatapocketSite?
    public var thumbnailURL: String?

    public init(url: String,
                mode: CatapocketMode = .video,
                title: String? = nil,
                site: CatapocketSite? = nil,
                thumbnailURL: String? = nil) {
        self.url = url
        self.mode = mode
        self.title = title
        self.site = site
        self.thumbnailURL = thumbnailURL
    }
}

public struct CatapocketSubmitResponse: Codable, Hashable, Sendable {
    public var ok: Bool
    public var link: CatapocketLink
    public var state: CatapocketState

    public init(ok: Bool, link: CatapocketLink, state: CatapocketState) {
        self.ok = ok
        self.link = link
        self.state = state
    }
}

public struct CatapocketSyncRequest: Codable, Hashable, Sendable {
    public var clientID: String
    public var links: [CatapocketOfflineLink]

    public init(clientID: String, links: [CatapocketOfflineLink]) {
        self.clientID = clientID
        self.links = links
    }
}

public struct CatapocketSyncResponse: Codable, Hashable, Sendable {
    public var ok: Bool
    public var acceptedLocalIDs: [UUID]
    public var state: CatapocketState

    public init(ok: Bool, acceptedLocalIDs: [UUID], state: CatapocketState) {
        self.ok = ok
        self.acceptedLocalIDs = acceptedLocalIDs
        self.state = state
    }
}

public struct CatapocketDownloadJobRequest: Codable, Hashable, Sendable {
    public var profile: CatapocketDownloadProfile

    public init(profile: CatapocketDownloadProfile = .hevcSameResolution) {
        self.profile = profile
    }
}

public struct CatapocketEndpointBuilder: Sendable {
    public var baseURL: URL
    public var token: String

    public init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }

    public func url(path: String) -> URL {
        let normalizedPath = path.hasPrefix("/") ? path : "/" + path
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = normalizedPath
        components?.queryItems = [URLQueryItem(name: "token", value: token)]
        return components?.url ?? baseURL.appendingPathComponent(normalizedPath)
    }

    public func libraryStreamURL(id: UUID) -> URL {
        url(path: "/api/library/\(id.uuidString)/stream")
    }

    public func libraryThumbnailURL(id: UUID) -> URL {
        url(path: "/api/library/\(id.uuidString)/thumbnail")
    }

    public func downloadJobStreamURL(id: UUID) -> URL {
        url(path: "/api/download-jobs/\(id.uuidString)/stream")
    }
}

public struct CatapocketClient: @unchecked Sendable {
    public enum CatapocketClientError: Error, Sendable {
        case badResponse
        case httpStatus(Int)
    }

    public var endpoints: CatapocketEndpointBuilder
    public var urlSession: URLSession
    public var encoder: JSONEncoder
    public var decoder: JSONDecoder

    public init(baseURL: URL,
                token: String,
                urlSession: URLSession = .shared,
                encoder: JSONEncoder = JSONEncoder(),
                decoder: JSONDecoder = JSONDecoder()) {
        self.endpoints = CatapocketEndpointBuilder(baseURL: baseURL, token: token)
        self.urlSession = urlSession
        self.encoder = encoder
        self.decoder = decoder
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public init(pairing: CatapocketPairingPayload,
                urlSession: URLSession = .shared,
                encoder: JSONEncoder = JSONEncoder(),
                decoder: JSONDecoder = JSONDecoder()) throws {
        guard let baseURL = pairing.resolvedBaseURL else {
            throw CatapocketClientError.badResponse
        }
        self.init(baseURL: baseURL,
                  token: pairing.token,
                  urlSession: urlSession,
                  encoder: encoder,
                  decoder: decoder)
    }

    public func fetchPairing() async throws -> CatapocketPairingPayload {
        try await send(method: "GET", path: "/api/pairing", body: Optional<CatapocketSubmission>.none)
    }

    public func fetchState() async throws -> CatapocketState {
        try await send(method: "GET", path: "/api/state", body: Optional<CatapocketSubmission>.none)
    }

    public func fetchLibrary() async throws -> [CatapocketLibraryItem] {
        try await send(method: "GET", path: "/api/library", body: Optional<CatapocketSubmission>.none)
    }

    public func fetchStorage() async throws -> CatapocketStorageSummary {
        try await send(method: "GET", path: "/api/storage", body: Optional<CatapocketSubmission>.none)
    }

    public func save(_ submission: CatapocketSubmission) async throws -> CatapocketSubmitResponse {
        try await send(method: "POST", path: "/api/catapocket", body: submission)
    }

    public func queue(_ submission: CatapocketSubmission) async throws -> CatapocketSubmitResponse {
        try await send(method: "POST", path: "/api/queue", body: submission)
    }

    public func sync(_ request: CatapocketSyncRequest) async throws -> CatapocketSyncResponse {
        try await send(method: "POST", path: "/api/sync", body: request)
    }

    public func queueSavedLink(id: UUID) async throws -> CatapocketState {
        try await send(method: "POST", path: "/api/catapocket/\(id.uuidString)/queue", body: Optional<CatapocketSubmission>.none)
    }

    public func deleteSavedLink(id: UUID) async throws -> CatapocketState {
        try await send(method: "DELETE", path: "/api/catapocket/\(id.uuidString)", body: Optional<CatapocketSubmission>.none)
    }

    public func createDownloadJob(for libraryID: UUID,
                                  profile: CatapocketDownloadProfile = .hevcSameResolution) async throws -> CatapocketDownloadJob {
        try await send(method: "POST",
                       path: "/api/library/\(libraryID.uuidString)/download-jobs",
                       body: CatapocketDownloadJobRequest(profile: profile))
    }

    public func fetchDownloadJob(id: UUID) async throws -> CatapocketDownloadJob {
        try await send(method: "GET", path: "/api/download-jobs/\(id.uuidString)", body: Optional<CatapocketSubmission>.none)
    }

    public func cancelDownloadJob(id: UUID) async throws -> CatapocketDownloadJob {
        try await send(method: "DELETE", path: "/api/download-jobs/\(id.uuidString)", body: Optional<CatapocketSubmission>.none)
    }

    public func libraryStreamURL(id: UUID) -> URL {
        endpoints.libraryStreamURL(id: id)
    }

    public func libraryThumbnailURL(id: UUID) -> URL {
        endpoints.libraryThumbnailURL(id: id)
    }

    public func downloadJobStreamURL(id: UUID) -> URL {
        endpoints.downloadJobStreamURL(id: id)
    }

    private func send<Response: Decodable, Body: Encodable>(method: String,
                                                            path: String,
                                                            body: Body?) async throws -> Response {
        var request = URLRequest(url: endpoints.url(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(endpoints.token, forHTTPHeaderField: "X-Catapult-Token")
        if let body {
            request.httpBody = try encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CatapocketClientError.badResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CatapocketClientError.httpStatus(http.statusCode)
        }
        return try decoder.decode(Response.self, from: data)
    }
}

public actor CatapocketOfflineStore {
    public struct Snapshot: Codable, Hashable, Sendable {
        public var clientID: String
        public var links: [CatapocketOfflineLink]
        public var downloads: [CatapocketDownloadJob]
        public var storage: CatapocketStorageSummary

        public init(clientID: String = UUID().uuidString,
                    links: [CatapocketOfflineLink] = [],
                    downloads: [CatapocketDownloadJob] = [],
                    storage: CatapocketStorageSummary = CatapocketStorageSummary()) {
            self.clientID = clientID
            self.links = links
            self.downloads = downloads
            self.storage = storage
        }
    }

    private var snapshot: Snapshot
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL) async {
        self.fileURL = fileURL
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.sortedKeys]
        self.decoder.dateDecodingStrategy = .iso8601
        self.snapshot = Snapshot()
        await load()
    }

    public func currentSnapshot() -> Snapshot {
        snapshot
    }

    @discardableResult
    public func saveLink(url: String,
                         title: String,
                         mode: CatapocketMode = .video,
                         site: CatapocketSite = .generic,
                         thumbnailURL: String? = nil) async -> CatapocketOfflineLink {
        var link = CatapocketOfflineLink(url: url,
                                         title: title,
                                         mode: mode,
                                         site: site,
                                         thumbnailURL: thumbnailURL)
        if let existing = snapshot.links.first(where: { $0.url == url && $0.mode == mode }) {
            link = existing
        } else {
            snapshot.links.insert(link, at: 0)
        }
        await persist()
        return link
    }

    public func pendingSyncRequest() -> CatapocketSyncRequest {
        CatapocketSyncRequest(clientID: snapshot.clientID,
                              links: snapshot.links.filter { $0.syncStatus != .synced })
    }

    public func markSynced(ids: [UUID], at date: Date = Date()) async {
        for id in ids {
            guard let index = snapshot.links.firstIndex(where: { $0.id == id }) else { continue }
            snapshot.links[index].syncStatus = .synced
            snapshot.links[index].lastSyncAt = date
            snapshot.links[index].errorMessage = nil
        }
        await persist()
    }

    public func markSyncFailed(ids: [UUID], message: String) async {
        for id in ids {
            guard let index = snapshot.links.firstIndex(where: { $0.id == id }) else { continue }
            snapshot.links[index].syncStatus = .failed
            snapshot.links[index].errorMessage = message
        }
        await persist()
    }

    public func removeLink(id: UUID) async {
        snapshot.links.removeAll { $0.id == id }
        await persist()
    }

    @discardableResult
    public func enqueueDownload(_ job: CatapocketDownloadJob) async -> CatapocketDownloadJob {
        snapshot.downloads.removeAll { $0.id == job.id }
        snapshot.downloads.append(job)
        await persist()
        return job
    }

    public func reorderDownloads(ids: [UUID]) async {
        let lookup = Dictionary(uniqueKeysWithValues: snapshot.downloads.map { ($0.id, $0) })
        let ordered = ids.compactMap { lookup[$0] }
        let leftovers = snapshot.downloads.filter { !ids.contains($0.id) }
        snapshot.downloads = ordered + leftovers
        await persist()
    }

    public func updateDownload(id: UUID, mutate: (inout CatapocketDownloadJob) -> Void) async {
        guard let index = snapshot.downloads.firstIndex(where: { $0.id == id }) else { return }
        mutate(&snapshot.downloads[index])
        snapshot.downloads[index].updatedAt = Date()
        await persist()
    }

    public func pauseDownload(id: UUID) async {
        await updateDownload(id: id) { $0.status = .paused }
    }

    public func resumeDownload(id: UUID) async {
        await updateDownload(id: id) { $0.status = .queued }
    }

    public func cancelDownload(id: UUID) async {
        await updateDownload(id: id) { $0.status = .cancelled }
    }

    public func retryDownload(id: UUID) async {
        await updateDownload(id: id) {
            $0.status = .queued
            $0.progress = 0
            $0.errorMessage = nil
        }
    }

    public func deleteDownload(id: UUID) async {
        snapshot.downloads.removeAll { $0.id == id }
        await persist()
    }

    public func updateStorage(_ storage: CatapocketStorageSummary) async {
        snapshot.storage = storage
        await persist()
    }

    private func load() async {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode(Snapshot.self, from: data) else {
            return
        }
        snapshot = decoded
    }

    private func persist() async {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // Catapocket can still run in-memory when local storage is denied.
        }
    }
}

@available(*, deprecated, renamed: "CatapocketMode")
public typealias PocketMode = CatapocketMode
@available(*, deprecated, renamed: "CatapocketSite")
public typealias PocketSite = CatapocketSite
@available(*, deprecated, renamed: "CatapocketLink")
public typealias PocketLink = CatapocketLink
@available(*, deprecated, renamed: "CatapocketDownload")
public typealias PocketDownload = CatapocketDownload
@available(*, deprecated, renamed: "CatapocketState")
public typealias PocketState = CatapocketState
@available(*, deprecated, renamed: "CatapocketSubmission")
public typealias PocketSubmission = CatapocketSubmission
@available(*, deprecated, renamed: "CatapocketSubmitResponse")
public typealias PocketSubmitResponse = CatapocketSubmitResponse
@available(*, deprecated, renamed: "CatapocketEndpointBuilder")
public typealias PocketEndpointBuilder = CatapocketEndpointBuilder
@available(*, deprecated, renamed: "CatapocketClient")
public typealias PocketClient = CatapocketClient
