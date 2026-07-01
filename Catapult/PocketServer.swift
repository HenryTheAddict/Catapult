import Foundation
import Observation
import AppKit
import Network
import Darwin

struct PocketLink: Codable, Identifiable, Hashable {
    let id: UUID
    var url: String
    var title: String
    var mode: DownloadMode
    var site: SupportedSite
    var addedAt: Date
    var queuedAt: Date?

    init(id: UUID = UUID(),
         url: String,
         title: String? = nil,
         mode: DownloadMode = .video,
         addedAt: Date = Date(),
         queuedAt: Date? = nil) {
        self.id = id
        self.url = url
        self.title = title ?? Self.displayTitle(for: url)
        self.mode = mode
        self.site = SupportedSite.match(url: url)
        self.addedAt = addedAt
        self.queuedAt = queuedAt
    }

    private static func displayTitle(for url: String) -> String {
        guard let comps = URLComponents(string: url),
              let host = comps.host else {
            return "Catapocket link"
        }
        let path = comps.path.split(separator: "/").last.map(String.init) ?? ""
        if path.isEmpty { return host }
        return "\(host) / \(path)"
    }
}

struct PocketRemoteDownload: Codable, Hashable {
    let title: String
    let mode: DownloadMode
    let status: String
    let progress: Double
}

struct CatapocketLibraryItem: Codable, Identifiable, Hashable {
    let id: UUID
    let title: String
    let site: SupportedSite
    let mode: DownloadMode
    let status: String
    let sourceURL: String
    let durationSeconds: Double?
    let fileSizeBytes: Int64?
    let finishedAt: Date
    let thumbnailURL: String?
    let streamURL: String?
    let downloadJobURL: String?
    let canStream: Bool
    let canDownload: Bool
    let fileExists: Bool
}

struct CatapocketStorageSummary: Codable, Hashable {
    let pendingLinkCount: Int
    let syncedLinkCount: Int
    let offlineLinkCount: Int
    let cachedMediaBytes: Int64
    let cachedThumbnailBytes: Int64
    let cacheLimitBytes: Int64?
    let macLibraryBytes: Int64
    let macLibraryCount: Int
}

enum CatapocketDownloadProfile: String, Codable, CaseIterable {
    case original
    case hevcSameResolution
    case audioOnly
}

enum CatapocketDownloadJobStatus: String, Codable {
    case queued
    case active
    case paused
    case completed
    case failed
    case cancelled
}

struct CatapocketDownloadJob: Codable, Identifiable, Hashable {
    let id: UUID
    var libraryItemID: UUID?
    var title: String
    var profile: CatapocketDownloadProfile
    var status: CatapocketDownloadJobStatus
    var progress: Double
    var bytesReceived: Int64
    var totalBytes: Int64?
    var localFilePath: String?
    var isFavorite: Bool
    var errorMessage: String?
    var createdAt: Date
    var updatedAt: Date
}

@Observable
@MainActor
final class PocketServer {
    static let shared = PocketServer()

    var links: [PocketLink] = [] {
        didSet { persistLinks() }
    }
    var isRunning = false
    var statusLine = "Catapocket is off"
    var lastError: String?
    var lastClientSeenAt: Date?
    var downloadJobs: [CatapocketDownloadJob] = [] {
        didSet { persistDownloadJobs() }
    }

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private let serverQueue = DispatchQueue(label: "h3nry.Catapult.PocketServer")
    @ObservationIgnored private let linksKey = "pocketLinks.v1"
    @ObservationIgnored private let downloadJobsKey = "catapocketDownloadJobs.v1"
    @ObservationIgnored private let serverIDKey = "catapocketServerID.v1"
    @ObservationIgnored private var runningTranscodes: [UUID: Process] = [:]
    @ObservationIgnored private let encoder = JSONEncoder()
    @ObservationIgnored private let decoder = JSONDecoder()

    private init() {
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        loadLinks()
        loadDownloadJobs()
    }

    var publicURL: URL? {
        guard let baseURL,
              var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        comps.queryItems = [URLQueryItem(name: "token", value: AppSettings.shared.pocketRemoteToken)]
        return comps.url
    }

    var baseURL: URL? {
        guard let host = Self.localIPv4Address() ?? Self.localHostname() else { return nil }
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = host
        comps.port = AppSettings.shared.pocketRemotePort
        comps.path = "/"
        return comps.url
    }

    var baseURLString: String {
        baseURL?.absoluteString ?? "http://localhost:\(AppSettings.shared.pocketRemotePort)/"
    }

    var publicURLString: String {
        publicURL?.absoluteString ?? "http://localhost:\(AppSettings.shared.pocketRemotePort)/"
    }

    var pairingPayloadString: String {
        guard let data = try? encoder.encode(pairingPayload()),
              let string = String(data: data, encoding: .utf8) else {
            return publicURLString
        }
        return string
    }

    var serverID: String {
        if let stored = UserDefaults.standard.string(forKey: serverIDKey) {
            return stored
        }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: serverIDKey)
        return generated
    }

    var catapocketCacheDirectory: URL {
        let dir = DependencyManager.shared.supportDirectory
            .appendingPathComponent("Catapocket", isDirectory: true)
            .appendingPathComponent("LibraryDownloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func applySettings() {
        if AppSettings.shared.pocketRemoteEnabled {
            start()
        } else {
            stop()
        }
    }

    func start() {
        stop()
        let portValue = min(max(AppSettings.shared.pocketRemotePort, 1), 65_535)
        guard let port = NWEndpoint.Port(rawValue: UInt16(portValue)) else {
            isRunning = false
            lastError = "Bad port"
            statusLine = "Catapocket port is invalid"
            return
        }

        do {
            let listener = try NWListener(using: .tcp, on: port)
            let queue = serverQueue
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                guard let server = self else { return }
                Task { @MainActor [server] in
                    server.handleState(state)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let server = self else {
                    connection.cancel()
                    return
                }
                connection.start(queue: queue)
                Self.receiveRequest(on: connection) { data, error in
                    guard let data, error == nil else {
                        Self.respond(.text(400, error ?? "empty request"), on: connection)
                        return
                    }
                    Task { @MainActor [server] in
                        let response = server.route(data)
                        Self.respond(response, on: connection)
                    }
                }
            }
            listener.start(queue: serverQueue)
        } catch {
            isRunning = false
            lastError = error.localizedDescription
            statusLine = "Catapocket could not start"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        statusLine = "Catapocket is off"
    }

    func resetToken() {
        AppSettings.shared.pocketRemoteToken = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    @discardableResult
    func add(url rawURL: String,
             title: String? = nil,
             mode: DownloadMode = .video,
             queueNow: Bool = false) -> PocketLink? {
        guard let cleaned = Self.cleanedDownloadURL(rawURL) else {
            lastError = "No usable link found"
            return nil
        }
        var link = PocketLink(url: cleaned, title: title, mode: mode == .audio ? .audio : .video)
        links.removeAll { $0.url == cleaned && $0.mode == link.mode }
        links.insert(link, at: 0)
        if queueNow {
            link = queue(link)
        }
        return link
    }

    @discardableResult
    func queue(_ link: PocketLink) -> PocketLink {
        DownloadManager.shared.enqueue(url: link.url, mode: link.mode == .audio ? .audio : .video)
        var queued = link
        queued.queuedAt = Date()
        if let index = links.firstIndex(where: { $0.id == link.id }) {
            links[index] = queued
        }
        return queued
    }

    func delete(_ id: UUID) {
        links.removeAll { $0.id == id }
    }

    func clearQueued() {
        links.removeAll { $0.queuedAt != nil }
    }

    private func handleState(_ state: NWListener.State) {
        switch state {
        case .ready:
            isRunning = true
            lastError = nil
            statusLine = "Catapocket is live on port \(AppSettings.shared.pocketRemotePort)"
        case .failed(let error):
            isRunning = false
            lastError = error.localizedDescription
            statusLine = "Catapocket stopped"
        case .cancelled:
            isRunning = false
            statusLine = "Catapocket is off"
        case .waiting(let error):
            isRunning = false
            lastError = error.localizedDescription
            statusLine = "Catapocket is waiting"
        case .setup:
            statusLine = "Starting Catapocket..."
        default:
            break
        }
    }

    private nonisolated static func receiveRequest(on connection: NWConnection,
                                                   accumulated: Data = Data(),
                                                   completion: @escaping @Sendable (Data?, String?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            if let error {
                completion(nil, "connection error: \(error.localizedDescription)")
                return
            }

            var buffer = accumulated
            if let data {
                buffer.append(data)
            }

            if let complete = completeHTTPRequest(in: buffer) {
                completion(complete, nil)
                return
            }
            if buffer.count > 1_048_576 {
                completion(nil, "request too large")
                return
            }
            if isComplete {
                completion(buffer.isEmpty ? nil : buffer, buffer.isEmpty ? "empty request" : nil)
                return
            }

            receiveRequest(on: connection, accumulated: buffer, completion: completion)
        }
    }

    private nonisolated static func completeHTTPRequest(in data: Data) -> Data? {
        let terminator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: terminator),
              let header = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            return nil
        }
        let contentLength = header
            .components(separatedBy: "\r\n")
            .compactMap { line -> Int? in
                let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2,
                      parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" else {
                    return nil
                }
                return Int(parts[1].trimmingCharacters(in: .whitespaces))
            }
            .first ?? 0

        let expectedEnd = headerRange.upperBound + contentLength
        guard data.count >= expectedEnd else { return nil }
        return Data(data.prefix(expectedEnd))
    }

    private nonisolated static func respond(_ response: HTTPResponse, on connection: NWConnection) {
        var headerLines = [
            "HTTP/1.1 \(response.status) \(response.reason)",
            "Content-Length: \(response.body.count)",
            "Content-Type: \(response.contentType)",
            "Connection: close",
            "Cache-Control: no-store"
        ]
        for (key, value) in response.headers {
            headerLines.append("\(key): \(value)")
        }
        let header = headerLines.joined(separator: "\r\n") + "\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(response.body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func route(_ data: Data) -> HTTPResponse {
        guard let request = HTTPRequest(data: data) else {
            return .json(400, ["error": "Bad request"])
        }
        if request.method == "OPTIONS" {
            return HTTPResponse(status: 204, reason: "No Content", contentType: "text/plain", body: Data())
        }
        if request.path == "/favicon.ico" {
            return HTTPResponse(status: 204, reason: "No Content", contentType: "text/plain", body: Data())
        }
        guard isAuthorized(request) else {
            return .html(401, Self.lockedHTML())
        }

        switch (request.method, request.path) {
        case ("GET", "/"):
            return .html(200, Self.pocketHTML(token: AppSettings.shared.pocketRemoteToken))
        case ("GET", "/manifest.webmanifest"):
            return .jsonObject(200, manifestPayload())
        case ("GET", "/api/state"):
            return .jsonObject(200, statePayload())
        case ("GET", "/api/pairing"):
            return .jsonObject(200, pairingPayload())
        case ("GET", "/api/library"):
            return .jsonObject(200, libraryPayload())
        case ("GET", "/api/storage"):
            return .jsonObject(200, storagePayload())
        case ("POST", "/api/sync"):
            return syncFromPayload(request.body)
        case ("POST", "/api/pocket"), ("POST", "/api/catapocket"):
            return addFromPayload(request.body, queueNow: false)
        case ("POST", "/api/queue"):
            return addFromPayload(request.body, queueNow: true)
        case ("POST", "/api/pocket/clear"), ("POST", "/api/catapocket/clear"):
            clearQueued()
            return .jsonObject(200, statePayload())
        default:
            if request.method == "POST",
               (request.path.hasPrefix("/api/pocket/") || request.path.hasPrefix("/api/catapocket/")),
               request.path.hasSuffix("/queue"),
               let id = id(in: request.path, suffix: "/queue"),
               let link = links.first(where: { $0.id == id }) {
                _ = queue(link)
                return .jsonObject(200, statePayload())
            }
            if request.method == "DELETE",
               (request.path.hasPrefix("/api/pocket/") || request.path.hasPrefix("/api/catapocket/")),
               let id = id(in: request.path) {
                delete(id)
                return .jsonObject(200, statePayload())
            }
            if request.method == "GET",
               request.path.hasPrefix("/api/library/"),
               request.path.hasSuffix("/stream"),
               let id = id(in: request.path, prefix: "/api/library/", suffix: "/stream") {
                return streamLibraryItem(id, request: request)
            }
            if request.method == "GET",
               request.path.hasPrefix("/api/library/"),
               request.path.hasSuffix("/thumbnail"),
               let id = id(in: request.path, prefix: "/api/library/", suffix: "/thumbnail") {
                return streamLibraryThumbnail(id, request: request)
            }
            if request.method == "POST",
               request.path.hasPrefix("/api/library/"),
               request.path.hasSuffix("/download-jobs"),
               let id = id(in: request.path, prefix: "/api/library/", suffix: "/download-jobs") {
                return createDownloadJob(for: id, body: request.body)
            }
            if request.method == "GET",
               request.path.hasPrefix("/api/download-jobs/"),
               request.path.hasSuffix("/stream"),
               let id = id(in: request.path, prefix: "/api/download-jobs/", suffix: "/stream") {
                return streamDownloadJob(id, request: request)
            }
            if request.method == "GET",
               request.path.hasPrefix("/api/download-jobs/"),
               let id = id(in: request.path, prefix: "/api/download-jobs/"),
               let job = downloadJobs.first(where: { $0.id == id }) {
                return .jsonObject(200, job)
            }
            if request.method == "DELETE",
               request.path.hasPrefix("/api/download-jobs/"),
               let id = id(in: request.path, prefix: "/api/download-jobs/") {
                return cancelDownloadJob(id)
            }
            return .json(404, ["error": "Not found"])
        }
    }

    private func addFromPayload(_ data: Data, queueNow: Bool) -> HTTPResponse {
        do {
            let payload = try JSONDecoder().decode(PocketSubmitPayload.self, from: data)
            guard let link = add(url: payload.url,
                                 title: payload.title,
                                 mode: payload.mode ?? .video,
                                 queueNow: queueNow) else {
                return .json(422, ["error": "No usable link found"])
            }
            return .jsonObject(200, PocketSubmitResponse(ok: true,
                                                          link: link,
                                                          state: statePayload()))
        } catch {
            return .json(400, ["error": "Bad JSON"])
        }
    }

    private func syncFromPayload(_ data: Data) -> HTTPResponse {
        do {
            let payload = try JSONDecoder().decode(CatapocketSyncPayload.self, from: data)
            lastClientSeenAt = Date()
            var accepted: [UUID] = []
            for offline in payload.links {
                guard let cleaned = Self.cleanedDownloadURL(offline.url) else { continue }
                let mode = offline.mode == .audio ? DownloadMode.audio : .video
                let link = PocketLink(id: offline.id,
                                      url: cleaned,
                                      title: offline.title,
                                      mode: mode,
                                      addedAt: offline.createdAt)
                links.removeAll { ($0.url == cleaned && $0.mode == mode) || $0.id == link.id }
                links.insert(link, at: 0)
                accepted.append(offline.id)
            }
            return .jsonObject(200, CatapocketSyncResponse(ok: true,
                                                            acceptedLocalIDs: accepted,
                                                            state: statePayload()))
        } catch {
            return .json(400, ["error": "Bad JSON"])
        }
    }

    private func libraryPayload() -> [CatapocketLibraryItem] {
        HistoryStore.shared.entries.map { libraryItem(from: $0) }
    }

    private func storagePayload() -> CatapocketStorageSummary {
        let entries = HistoryStore.shared.entries
        let existing = entries.filter(\.fileExists)
        let macBytes = existing.reduce(Int64(0)) { partial, entry in
            partial + (entry.fileSizeBytes ?? 0)
        }
        let cacheBytes = downloadJobs.reduce(Int64(0)) { partial, job in
            guard let path = job.localFilePath,
                  let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let number = attrs[.size] as? NSNumber else { return partial }
            return partial + number.int64Value
        }
        return CatapocketStorageSummary(pendingLinkCount: links.filter { $0.queuedAt == nil }.count,
                                        syncedLinkCount: links.filter { $0.queuedAt != nil }.count,
                                        offlineLinkCount: links.count,
                                        cachedMediaBytes: cacheBytes,
                                        cachedThumbnailBytes: 0,
                                        cacheLimitBytes: nil,
                                        macLibraryBytes: macBytes,
                                        macLibraryCount: existing.count)
    }

    private func streamLibraryItem(_ id: UUID, request: HTTPRequest) -> HTTPResponse {
        guard let entry = HistoryStore.shared.entries.first(where: { $0.id == id }),
              entry.fileExists,
              let file = entry.outputFile else {
            return .json(404, ["error": "Library item is unavailable"])
        }
        return .file(200, file, contentType: contentType(for: file), request: request)
    }

    private func streamLibraryThumbnail(_ id: UUID, request: HTTPRequest) -> HTTPResponse {
        guard let entry = HistoryStore.shared.entries.first(where: { $0.id == id }),
              let file = thumbnailCandidate(for: entry),
              FileManager.default.fileExists(atPath: file.path) else {
            return .json(404, ["error": "Thumbnail is unavailable"])
        }
        return .file(200, file, contentType: "image/jpeg", request: request)
    }

    private func createDownloadJob(for libraryID: UUID, body: Data) -> HTTPResponse {
        guard let entry = HistoryStore.shared.entries.first(where: { $0.id == libraryID }),
              entry.fileExists,
              let input = entry.outputFile else {
            return .json(404, ["error": "Library item is unavailable"])
        }
        let payload = (try? decoder.decode(CatapocketDownloadJobRequest.self, from: body))
            ?? CatapocketDownloadJobRequest(profile: .hevcSameResolution)
        let jobID = UUID()
        let output = catapocketCacheDirectory
            .appendingPathComponent(jobID.uuidString, isDirectory: false)
            .appendingPathExtension(payload.profile == .audioOnly ? "m4a" : "mp4")
        var job = CatapocketDownloadJob(id: jobID,
                                        libraryItemID: libraryID,
                                        title: entry.title,
                                        profile: payload.profile,
                                        status: .queued,
                                        progress: 0,
                                        bytesReceived: 0,
                                        totalBytes: entry.fileSizeBytes,
                                        localFilePath: output.path,
                                        isFavorite: false,
                                        errorMessage: nil,
                                        createdAt: Date(),
                                        updatedAt: Date())
        downloadJobs.insert(job, at: 0)

        if payload.profile == .original {
            job.status = .completed
            job.progress = 1
            job.localFilePath = input.path
            job.updatedAt = Date()
            replaceDownloadJob(job)
            return .jsonObject(200, job)
        }

        startTranscode(jobID: jobID, input: input, output: output, profile: payload.profile)
        if let updated = downloadJobs.first(where: { $0.id == jobID }) {
            return .jsonObject(200, updated)
        }
        return .jsonObject(200, job)
    }

    private func streamDownloadJob(_ id: UUID, request: HTTPRequest) -> HTTPResponse {
        guard let job = downloadJobs.first(where: { $0.id == id }),
              let path = job.localFilePath else {
            return .json(404, ["error": "Download job is unavailable"])
        }
        let file = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: file.path) else {
            return .json(404, ["error": "Download file is not ready"])
        }
        return .file(200, file, contentType: contentType(for: file), request: request)
    }

    private func cancelDownloadJob(_ id: UUID) -> HTTPResponse {
        runningTranscodes[id]?.terminate()
        runningTranscodes[id] = nil
        guard var job = downloadJobs.first(where: { $0.id == id }) else {
            return .json(404, ["error": "Download job is unavailable"])
        }
        job.status = .cancelled
        job.updatedAt = Date()
        replaceDownloadJob(job)
        return .jsonObject(200, job)
    }

    private func startTranscode(jobID: UUID,
                                input: URL,
                                output: URL,
                                profile: CatapocketDownloadProfile) {
        guard FileManager.default.isExecutableFile(atPath: DependencyManager.shared.ffmpegPath.path) else {
            updateDownloadJob(jobID, status: .failed, progress: 0, error: "ffmpeg is not installed")
            return
        }
        updateDownloadJob(jobID, status: .active, progress: 0.05, error: nil)
        try? FileManager.default.removeItem(at: output)

        let process = Process()
        process.executableURL = DependencyManager.shared.ffmpegPath
        switch profile {
        case .hevcSameResolution:
            process.arguments = [
                "-hide_banner", "-y",
                "-i", input.path,
                "-map", "0:v:0", "-map", "0:a?",
                "-c:v", "libx265",
                "-tag:v", "hvc1",
                "-preset", "medium",
                "-crf", "28",
                "-c:a", "aac",
                "-b:a", "160k",
                "-movflags", "frag_keyframe+empty_moov+faststart",
                output.path
            ]
        case .audioOnly:
            process.arguments = [
                "-hide_banner", "-y",
                "-i", input.path,
                "-vn",
                "-c:a", "aac",
                "-b:a", "192k",
                output.path
            ]
        case .original:
            return
        }
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        process.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.runningTranscodes[jobID] = nil
                if proc.terminationStatus == 0,
                   FileManager.default.fileExists(atPath: output.path) {
                    let attrs = try? FileManager.default.attributesOfItem(atPath: output.path)
                    let bytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                    self.updateDownloadJob(jobID, status: .completed, progress: 1, bytes: bytes, error: nil)
                } else {
                    self.updateDownloadJob(jobID,
                                           status: .failed,
                                           progress: 0,
                                           error: "ffmpeg exited with code \(proc.terminationStatus)")
                }
            }
        }
        do {
            try process.run()
            runningTranscodes[jobID] = process
        } catch {
            updateDownloadJob(jobID, status: .failed, progress: 0, error: error.localizedDescription)
        }
    }

    private func updateDownloadJob(_ id: UUID,
                                   status: CatapocketDownloadJobStatus,
                                   progress: Double,
                                   bytes: Int64? = nil,
                                   error: String?) {
        guard var job = downloadJobs.first(where: { $0.id == id }) else { return }
        job.status = status
        job.progress = progress
        if let bytes { job.bytesReceived = bytes }
        job.errorMessage = error
        job.updatedAt = Date()
        replaceDownloadJob(job)
    }

    private func replaceDownloadJob(_ job: CatapocketDownloadJob) {
        if let index = downloadJobs.firstIndex(where: { $0.id == job.id }) {
            downloadJobs[index] = job
        } else {
            downloadJobs.insert(job, at: 0)
        }
    }

    private func id(in path: String, prefix: String? = nil, suffix: String = "") -> UUID? {
        var raw = path
        if let prefix {
            raw = raw.replacingOccurrences(of: prefix, with: "")
        } else {
            raw = raw.replacingOccurrences(of: "/api/pocket/", with: "")
            raw = raw.replacingOccurrences(of: "/api/catapocket/", with: "")
        }
        if !suffix.isEmpty, raw.hasSuffix(suffix) {
            raw.removeLast(suffix.count)
        }
        return UUID(uuidString: raw)
    }

    private func isAuthorized(_ request: HTTPRequest) -> Bool {
        let token = AppSettings.shared.pocketRemoteToken
        guard !token.isEmpty else { return false }
        if request.query["token"] == token { return true }
        if request.headers["x-catapult-token"] == token { return true }
        return false
    }

    private func statePayload() -> PocketStatePayload {
        let downloads = DownloadManager.shared.items.prefix(10).map {
            PocketRemoteDownload(title: $0.title,
                                 mode: remoteMode(for: $0.mode),
                                 status: $0.statusLine,
                                 progress: $0.progress)
        }
        return PocketStatePayload(running: isRunning,
                                  status: statusLine,
                                  remoteURL: publicURLString,
                                  apiVersion: 2,
                                  serverID: serverID,
                                  capabilities: catapocketCapabilities,
                                  links: links,
                                  downloads: Array(downloads),
                                  library: Array(libraryPayload().prefix(50)),
                                  storage: storagePayload(),
                                  downloadJobs: downloadJobs)
    }

    private var catapocketCapabilities: [String] {
        [
            "ios-priority",
            "qr-pairing",
            "offline-sync",
            "library",
            "storage",
            "original-stream",
            "hevc-same-resolution-jobs",
            "download-management"
        ]
    }

    private func pairingPayload() -> CatapocketPairingPayload {
        CatapocketPairingPayload(kind: "xyz.h3nry.catapocket.pairing",
                                 version: 1,
                                 app: "Catapocket",
                                 displayName: Host.current().localizedName ?? "Catapult Mac",
                                 platformPriority: "ios",
                                 baseURL: baseURLString,
                                 remoteURL: publicURLString,
                                 token: AppSettings.shared.pocketRemoteToken,
                                 serverID: serverID,
                                 apiVersion: 2,
                                 endpoints: [
                                    "state": "/api/state",
                                    "sync": "/api/sync",
                                    "save": "/api/catapocket",
                                    "queue": "/api/queue",
                                    "library": "/api/library",
                                    "storage": "/api/storage"
                                 ],
                                 capabilities: catapocketCapabilities)
    }

    private func manifestPayload() -> PocketManifestPayload {
        PocketManifestPayload(name: "Catapocket",
                              shortName: "Catapocket",
                              startURL: "/?token=\(AppSettings.shared.pocketRemoteToken)",
                              display: "standalone",
                              themeColor: "#07111f",
                              backgroundColor: "#07111f")
    }

    private func persistLinks() {
        guard let data = try? encoder.encode(links) else { return }
        UserDefaults.standard.set(data, forKey: linksKey)
    }

    private func loadLinks() {
        guard let data = UserDefaults.standard.data(forKey: linksKey),
              let stored = try? decoder.decode([PocketLink].self, from: data) else {
            links = []
            return
        }
        links = stored
    }

    private func persistDownloadJobs() {
        guard let data = try? encoder.encode(downloadJobs) else { return }
        UserDefaults.standard.set(data, forKey: downloadJobsKey)
    }

    private func loadDownloadJobs() {
        guard let data = UserDefaults.standard.data(forKey: downloadJobsKey),
              let stored = try? decoder.decode([CatapocketDownloadJob].self, from: data) else {
            downloadJobs = []
            return
        }
        downloadJobs = stored.map { job in
            var normalized = job
            if normalized.status == .active || normalized.status == .queued {
                normalized.status = .failed
                normalized.errorMessage = "Catapult restarted before this job finished"
            }
            return normalized
        }
    }

    private func libraryItem(from entry: HistoryEntry) -> CatapocketLibraryItem {
        let exists = entry.fileExists
        let site = SupportedSite.match(url: entry.url)
        let stream = exists ? endpointPath("/api/library/\(entry.id.uuidString)/stream") : nil
        let thumb = thumbnailCandidate(for: entry) != nil ? endpointPath("/api/library/\(entry.id.uuidString)/thumbnail") : nil
        let job = exists ? endpointPath("/api/library/\(entry.id.uuidString)/download-jobs") : nil
        return CatapocketLibraryItem(id: entry.id,
                                     title: entry.title,
                                     site: site,
                                     mode: remoteMode(for: entry.mode),
                                     status: entry.outcome.rawValue,
                                     sourceURL: entry.url,
                                     durationSeconds: entry.durationSeconds,
                                     fileSizeBytes: entry.fileSizeBytes,
                                     finishedAt: entry.finishedAt,
                                     thumbnailURL: thumb,
                                     streamURL: stream,
                                     downloadJobURL: job,
                                     canStream: exists,
                                     canDownload: exists,
                                     fileExists: exists)
    }

    private func remoteMode(for mode: DownloadMode) -> DownloadMode {
        mode == .audio ? .audio : .video
    }

    private func endpointPath(_ path: String) -> String {
        "\(path)?token=\(AppSettings.shared.pocketRemoteToken)"
    }

    private func thumbnailCandidate(for entry: HistoryEntry) -> URL? {
        guard let file = entry.outputFile else { return nil }
        let base = file.deletingPathExtension()
        let candidates = ["jpg", "jpeg", "png", "webp"].map { base.appendingPathExtension($0) }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func contentType(for file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "webm": return "video/webm"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "opus": return "audio/ogg"
        case "flac": return "audio/flac"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "webp": return "image/webp"
        default: return "application/octet-stream"
        }
    }

    private static func cleanedDownloadURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return ClipboardMonitor.firstDownloadURL(in: trimmed)
    }

    private static func localHostname() -> String? {
        Host.current().localizedName.map { $0.replacingOccurrences(of: " ", with: "-") + ".local" }
    }

    private static func localIPv4Address() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }

        var fallback: String?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) == IFF_UP
            let isLoopback = (flags & IFF_LOOPBACK) == IFF_LOOPBACK
            guard isUp, !isLoopback,
                  let addr = ptr.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(addr,
                                     socklen_t(addr.pointee.sa_len),
                                     &hostname,
                                     socklen_t(hostname.count),
                                     nil,
                                     0,
                                     NI_NUMERICHOST)
            guard result == 0 else { continue }
            let ip = String(cString: hostname)
            let name = String(cString: ptr.pointee.ifa_name)
            if name == "en0" || name == "en1" {
                return ip
            }
            fallback = fallback ?? ip
        }
        return fallback
    }
}

private struct PocketSubmitPayload: Decodable {
    let url: String
    let title: String?
    let mode: DownloadMode?
    let site: SupportedSite?
    let thumbnailURL: String?
}

private struct PocketStatePayload: Encodable {
    let running: Bool
    let status: String
    let remoteURL: String
    let apiVersion: Int
    let serverID: String
    let capabilities: [String]
    let links: [PocketLink]
    let downloads: [PocketRemoteDownload]
    let library: [CatapocketLibraryItem]
    let storage: CatapocketStorageSummary
    let downloadJobs: [CatapocketDownloadJob]
}

private struct CatapocketPairingPayload: Encodable {
    let kind: String
    let version: Int
    let app: String
    let displayName: String
    let platformPriority: String
    let baseURL: String
    let remoteURL: String
    let token: String
    let serverID: String
    let apiVersion: Int
    let endpoints: [String: String]
    let capabilities: [String]
}

private struct PocketSubmitResponse: Encodable {
    let ok: Bool
    let link: PocketLink
    let state: PocketStatePayload
}

private struct CatapocketSyncPayload: Decodable {
    let clientID: String
    let links: [CatapocketOfflineLinkPayload]
}

private struct CatapocketOfflineLinkPayload: Decodable {
    let id: UUID
    let url: String
    let title: String
    let mode: DownloadMode
    let site: SupportedSite?
    let thumbnailURL: String?
    let createdAt: Date
    let lastSyncAt: Date?
    let syncStatus: String?
    let errorMessage: String?
}

private struct CatapocketSyncResponse: Encodable {
    let ok: Bool
    let acceptedLocalIDs: [UUID]
    let state: PocketStatePayload
}

private struct CatapocketDownloadJobRequest: Decodable {
    let profile: CatapocketDownloadProfile
}

private struct PocketManifestPayload: Encodable {
    let name: String
    let shortName: String
    let startURL: String
    let display: String
    let themeColor: String
    let backgroundColor: String

    enum CodingKeys: String, CodingKey {
        case name
        case shortName = "short_name"
        case startURL = "start_url"
        case display
        case themeColor = "theme_color"
        case backgroundColor = "background_color"
    }
}

private struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data

    init?(data: Data) {
        let terminator = Data("\r\n\r\n".utf8)
        guard let marker = data.range(of: terminator),
              let headerString = String(data: data[..<marker.lowerBound], encoding: .utf8) else {
            return nil
        }
        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }
        method = parts[0].uppercased()

        let target = parts[1]
        var comps = URLComponents(string: target)
        if comps == nil {
            comps = URLComponents(string: "http://catapult.local\(target)")
        }
        path = comps?.path.isEmpty == false ? comps?.path ?? "/" : "/"
        query = Dictionary(uniqueKeysWithValues: (comps?.queryItems ?? []).compactMap { item in
            guard let value = item.value else { return nil }
            return (item.name, value)
        })

        var parsedHeaders: [String: String] = [:]
        for line in lines.dropFirst() {
            let pieces = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else { continue }
            parsedHeaders[pieces[0].trimmingCharacters(in: .whitespaces).lowercased()] =
                pieces[1].trimmingCharacters(in: .whitespaces)
        }
        headers = parsedHeaders
        body = data[data.index(marker.upperBound, offsetBy: 0)..<data.endIndex]
    }
}

private struct HTTPResponse {
    let status: Int
    let reason: String
    let contentType: String
    let body: Data
    var headers: [String: String] = [:]

    static func html(_ status: Int, _ html: String) -> HTTPResponse {
        HTTPResponse(status: status,
                     reason: reason(for: status),
                     contentType: "text/html; charset=utf-8",
                     body: Data(html.utf8))
    }

    static func text(_ status: Int, _ text: String) -> HTTPResponse {
        HTTPResponse(status: status,
                     reason: reason(for: status),
                     contentType: "text/plain; charset=utf-8",
                     body: Data(text.utf8))
    }

    static func json(_ status: Int, _ payload: [String: String]) -> HTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            ?? Data("{}".utf8)
        return HTTPResponse(status: status,
                            reason: reason(for: status),
                            contentType: "application/json; charset=utf-8",
                            body: body,
                            headers: ["Access-Control-Allow-Origin": "*",
                                      "Access-Control-Allow-Headers": "content-type,x-catapult-token",
                                      "Access-Control-Allow-Methods": "GET,POST,DELETE,OPTIONS"])
    }

    static func jsonObject<T: Encodable>(_ status: Int, _ payload: T) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = (try? encoder.encode(payload)) ?? Data("{}".utf8)
        return HTTPResponse(status: status,
                            reason: reason(for: status),
                            contentType: "application/json; charset=utf-8",
                            body: body,
                            headers: ["Access-Control-Allow-Origin": "*",
                                      "Access-Control-Allow-Headers": "content-type,x-catapult-token",
                                      "Access-Control-Allow-Methods": "GET,POST,DELETE,OPTIONS"])
    }

    static func file(_ status: Int,
                     _ url: URL,
                     contentType: String,
                     request: HTTPRequest) -> HTTPResponse {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let sizeNumber = attrs[.size] as? NSNumber else {
            return .json(404, ["error": "File unavailable"])
        }
        let fileSize = sizeNumber.int64Value
        let requested = byteRange(from: request.headers["range"], fileSize: fileSize)
        let start = requested?.lowerBound ?? 0
        let end = requested?.upperBound ?? max(0, fileSize - 1)
        let length = max(0, end - start + 1)

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .json(404, ["error": "File unavailable"])
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(start))
            let body = try handle.read(upToCount: Int(length)) ?? Data()
            var headers = [
                "Accept-Ranges": "bytes",
                "Access-Control-Allow-Origin": "*",
                "Access-Control-Allow-Headers": "content-type,x-catapult-token,range",
                "Access-Control-Allow-Methods": "GET,POST,DELETE,OPTIONS"
            ]
            if requested != nil {
                headers["Content-Range"] = "bytes \(start)-\(end)/\(fileSize)"
            }
            return HTTPResponse(status: requested == nil ? status : 206,
                                reason: requested == nil ? reason(for: status) : "Partial Content",
                                contentType: contentType,
                                body: body,
                                headers: headers)
        } catch {
            return .json(500, ["error": error.localizedDescription])
        }
    }

    private static func byteRange(from header: String?, fileSize: Int64) -> ClosedRange<Int64>? {
        guard let header, header.lowercased().hasPrefix("bytes="), fileSize > 0 else { return nil }
        let raw = header.dropFirst("bytes=".count)
        let pieces = raw.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return nil }
        if pieces[0].isEmpty, let suffix = Int64(pieces[1]) {
            let length = max(0, min(fileSize, suffix))
            return (fileSize - length)...(fileSize - 1)
        }
        guard let start = Int64(pieces[0]) else { return nil }
        let end = pieces[1].isEmpty ? fileSize - 1 : (Int64(pieces[1]) ?? fileSize - 1)
        guard start >= 0, start < fileSize, end >= start else { return nil }
        return start...min(end, fileSize - 1)
    }

    private static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 422: return "Unprocessable Entity"
        default: return "Server Error"
        }
    }
}

private extension PocketServer {
    static func lockedHTML() -> String {
        """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><title>Catapocket</title><style>
        body{margin:0;min-height:100vh;display:grid;place-items:center;background:#07111f;color:#f6f7fb;font:600 18px -apple-system,BlinkMacSystemFont,Inter,sans-serif}
        main{width:min(420px,calc(100vw - 48px));text-align:center}
        p{color:#9aa7b8;line-height:1.45}
        </style></head><body><main><h1>Catapocket is locked</h1><p>Open the Catapocket URL or scan the QR code from Catapult settings.</p></main></body></html>
        """
    }

    static func pocketHTML(token: String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
          <meta name="theme-color" content="#07111f">
          <link rel="manifest" href="/manifest.webmanifest?token=\(token)">
          <title>Catapocket</title>
          <style>
            :root {
              color-scheme: dark;
              --bg: #07111f;
              --bg2: #0d2238;
              --card: rgba(255,255,255,.08);
              --card2: rgba(255,255,255,.12);
              --line: rgba(255,255,255,.16);
              --text: #f8fbff;
              --muted: #9caabd;
              --blue: #39a8ff;
              --green: #21e38b;
              --orange: #ffb45c;
              --danger: #ff5b6b;
            }
            * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
            body {
              margin: 0;
              min-height: 100svh;
              background:
                radial-gradient(circle at 18% -10%, rgba(57,168,255,.30), transparent 34%),
                radial-gradient(circle at 96% 8%, rgba(255,180,92,.18), transparent 30%),
                linear-gradient(180deg, #050b16, var(--bg) 44%, #0a1b2e);
              color: var(--text);
              font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", Inter, sans-serif;
            }
            button, input { font: inherit; }
            .shell {
              width: min(780px, 100%);
              min-height: 100svh;
              margin: 0 auto;
              padding: calc(env(safe-area-inset-top) + 18px) 16px calc(env(safe-area-inset-bottom) + 18px);
            }
            header {
              display: flex;
              align-items: center;
              justify-content: space-between;
              gap: 12px;
              margin-bottom: 18px;
            }
            .brand { display: flex; align-items: center; gap: 12px; min-width: 0; }
            .mark {
              width: 46px; height: 46px; border-radius: 8px;
              display: grid; place-items: center;
              background: linear-gradient(180deg, #ff4b21, #ed1800);
              box-shadow: 0 12px 36px rgba(255,67,23,.26);
              font-size: 25px; font-weight: 900;
            }
            h1 { margin: 0; font-size: 26px; letter-spacing: 0; line-height: 1; }
            .sub { margin-top: 5px; color: var(--muted); font-size: 13px; font-weight: 650; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
            .pill {
              border: 1px solid var(--line); color: var(--muted); background: rgba(255,255,255,.07);
              border-radius: 999px; padding: 9px 12px; font-size: 12px; font-weight: 800;
            }
            .panel {
              border: 1px solid var(--line);
              border-radius: 8px;
              background: linear-gradient(180deg, rgba(255,255,255,.11), rgba(255,255,255,.06));
              box-shadow: 0 20px 60px rgba(0,0,0,.26);
              overflow: hidden;
            }
            .inputbar { padding: 12px; }
            input {
              width: 100%;
              min-height: 58px;
              border: 1px solid rgba(255,255,255,.16);
              border-radius: 8px;
              padding: 0 14px;
              color: var(--text);
              background: rgba(0,0,0,.26);
              outline: none;
              font-size: 16px;
              font-weight: 700;
            }
            input:focus { border-color: rgba(57,168,255,.88); box-shadow: 0 0 0 4px rgba(57,168,255,.16); }
            .modes { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; padding: 0 12px 12px; }
            .mode, .action, .queue, .delete {
              border: 1px solid var(--line);
              border-radius: 8px;
              min-height: 48px;
              color: var(--text);
              background: rgba(255,255,255,.08);
              font-weight: 850;
            }
            .mode.active { background: rgba(57,168,255,.2); border-color: rgba(57,168,255,.7); color: #d9efff; }
            .actions { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; padding: 0 12px 12px; }
            .action.primary { background: linear-gradient(180deg, #39a8ff, #006add); border-color: rgba(255,255,255,.18); }
            .action.secondary { color: #c7d6e8; }
            .list { margin-top: 14px; display: grid; gap: 10px; }
            .empty {
              border: 1px dashed rgba(255,255,255,.20);
              border-radius: 8px;
              padding: 22px 16px;
              color: var(--muted);
              background: rgba(255,255,255,.05);
              text-align: center;
              font-weight: 750;
            }
            .link {
              border: 1px solid var(--line);
              border-radius: 8px;
              background: rgba(255,255,255,.075);
              padding: 12px;
            }
            .row { display: flex; align-items: flex-start; justify-content: space-between; gap: 10px; }
            .title { font-size: 15px; font-weight: 850; line-height: 1.2; overflow-wrap: anywhere; }
            .meta { margin-top: 6px; color: var(--muted); font-size: 12px; font-weight: 700; overflow-wrap: anywhere; }
            .badge { color: var(--green); font-size: 12px; font-weight: 900; white-space: nowrap; }
            .buttons { display: grid; grid-template-columns: 1fr auto; gap: 8px; margin-top: 12px; }
            .queue { color: #dff2ff; background: rgba(57,168,255,.16); border-color: rgba(57,168,255,.42); }
            .delete { width: 48px; color: #ffd7dd; background: rgba(255,91,107,.14); border-color: rgba(255,91,107,.32); }
            .downloads { margin-top: 18px; }
            .download { padding: 10px 12px; border-top: 1px solid var(--line); display: grid; gap: 5px; }
            .download:first-child { border-top: 0; }
            .bar { height: 5px; border-radius: 999px; background: rgba(255,255,255,.14); overflow: hidden; }
            .bar span { display: block; height: 100%; background: var(--blue); width: var(--p); }
            footer { margin-top: 14px; color: var(--muted); font-size: 12px; font-weight: 700; text-align: center; }
            @media (min-width: 680px) {
              .shell { padding-inline: 24px; }
              h1 { font-size: 30px; }
              .grid { display: grid; grid-template-columns: 1fr 320px; gap: 14px; align-items: start; }
              .downloads { margin-top: 0; }
            }
          </style>
        </head>
        <body>
          <main class="shell">
            <header>
              <div class="brand">
                <div class="mark">C</div>
                <div>
                  <h1>Catapocket</h1>
                  <div id="status" class="sub">finding Catapult...</div>
                </div>
              </div>
              <button class="pill" id="refresh" type="button">refresh</button>
            </header>

            <section class="grid">
              <div>
                <section class="panel">
                  <div class="inputbar">
                    <input id="url" inputmode="url" autocomplete="url" autocapitalize="none" spellcheck="false" placeholder="Paste a video, Spotify, TikTok, or playlist link">
                  </div>
                  <div class="modes">
                    <button class="mode active" data-mode="video" type="button">Video</button>
                    <button class="mode" data-mode="audio" type="button">Audio</button>
                  </div>
                  <div class="actions">
                    <button id="save" class="action secondary" type="button">Save to Catapocket</button>
                    <button id="queue" class="action primary" type="button">Queue now</button>
                  </div>
                </section>
                <section id="links" class="list"></section>
              </div>

              <section class="panel downloads" id="downloads"></section>
            </section>
            <footer>Same Wi-Fi only. Saved links stay on this Mac.</footer>
          </main>

          <script>
            const token = new URLSearchParams(location.search).get("token") || "\(token)";
            let mode = "video";
            let state = { links: [], downloads: [] };

            const qs = (s, root = document) => root.querySelector(s);
            const linksEl = qs("#links");
            const downloadsEl = qs("#downloads");
            const urlEl = qs("#url");
            const statusEl = qs("#status");

            async function api(path, options = {}) {
              const sep = path.includes("?") ? "&" : "?";
              const res = await fetch(path + sep + "token=" + encodeURIComponent(token), {
                ...options,
                headers: { "content-type": "application/json", ...(options.headers || {}) }
              });
              if (!res.ok) throw new Error(await res.text());
              return res.status === 204 ? {} : res.json();
            }

            function setMode(next) {
              mode = next;
              document.querySelectorAll(".mode").forEach(btn => btn.classList.toggle("active", btn.dataset.mode === mode));
            }

            async function submit(queueNow) {
              const url = urlEl.value.trim();
              if (!url) {
                urlEl.focus();
                return;
              }
              const endpoint = queueNow ? "/api/queue" : "/api/catapocket";
              await api(endpoint, { method: "POST", body: JSON.stringify({ url, mode }) });
              urlEl.value = "";
              await refresh();
            }

            async function refresh() {
              try {
                Object.assign(state, await api("/api/state"));
                statusEl.textContent = state.status || "Catapocket is live";
                render();
              } catch (error) {
                statusEl.textContent = "Could not reach Catapult";
              }
            }

            function render() {
              if (!state.links.length) {
                linksEl.innerHTML = '<div class="empty">No saved links yet.</div>';
              } else {
                linksEl.innerHTML = state.links.map(link => `
                  <article class="link">
                    <div class="row">
                      <div>
                        <div class="title">${escapeHTML(link.title)}</div>
                        <div class="meta">${escapeHTML(link.site)} · ${escapeHTML(link.mode)} · ${escapeHTML(link.url)}</div>
                      </div>
                      ${link.queuedAt ? '<div class="badge">queued</div>' : ''}
                    </div>
                    <div class="buttons">
                      <button class="queue" data-queue="${link.id}" type="button">Queue</button>
                      <button class="delete" data-delete="${link.id}" type="button">×</button>
                    </div>
                  </article>`).join("");
              }

              const downloads = state.downloads || [];
              downloadsEl.innerHTML = downloads.length ? downloads.map(item => {
                const progress = Math.max(0, Math.min(1, item.progress || 0));
                return `<div class="download">
                  <div class="row"><div class="title">${escapeHTML(item.title)}</div><div class="badge">${escapeHTML(item.mode)}</div></div>
                  <div class="meta">${escapeHTML(item.status)}</div>
                  <div class="bar" style="--p:${Math.round(progress * 100)}%"><span></span></div>
                </div>`;
              }).join("") : '<div class="download"><div class="title">Mac queue</div><div class="meta">Nothing running right now.</div></div>';
            }

            function escapeHTML(value) {
              return String(value ?? "").replace(/[&<>"']/g, char => ({
                "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
              })[char]);
            }

            document.querySelectorAll(".mode").forEach(btn => btn.addEventListener("click", () => setMode(btn.dataset.mode)));
            qs("#save").addEventListener("click", () => submit(false));
            qs("#queue").addEventListener("click", () => submit(true));
            qs("#refresh").addEventListener("click", refresh);
            linksEl.addEventListener("click", async event => {
              const queueId = event.target.closest("[data-queue]")?.dataset.queue;
              const deleteId = event.target.closest("[data-delete]")?.dataset.delete;
              if (queueId) await api(`/api/catapocket/${queueId}/queue`, { method: "POST" });
              if (deleteId) await api(`/api/catapocket/${deleteId}`, { method: "DELETE" });
              if (queueId || deleteId) await refresh();
            });
            urlEl.addEventListener("keydown", event => {
              if (event.key === "Enter") submit(true);
            });
            refresh();
            setInterval(refresh, 3500);
          </script>
        </body>
        </html>
        """
    }
}
