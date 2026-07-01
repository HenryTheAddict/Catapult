import CatapultPocketCore
import Foundation

#if canImport(Photos)
import Photos
#endif

#if canImport(UIKit)
import UIKit
#endif

#if canImport(SwiftUI)
import SwiftUI
#endif

public enum CatapocketMediaExportError: LocalizedError, Sendable {
    case photosUnavailable
    case photosPermissionDenied
    case downloadDidNotComplete
    case missingLocalFile
    case badServerResponse

    public var errorDescription: String? {
        switch self {
        case .photosUnavailable:
            return "Photos saving is unavailable on this platform."
        case .photosPermissionDenied:
            return "Catapocket does not have permission to add videos to Photos."
        case .downloadDidNotComplete:
            return "The Mac download job did not finish."
        case .missingLocalFile:
            return "The local video file is missing."
        case .badServerResponse:
            return "The Mac sent an unexpected response."
        }
    }
}

public struct CatapocketLocalMedia: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var libraryItemID: UUID?
    public var remoteJobID: UUID?
    public var title: String
    public var profile: CatapocketDownloadProfile
    public var fileURL: URL
    public var byteCount: Int64?
    public var createdAt: Date

    public init(id: UUID = UUID(),
                libraryItemID: UUID? = nil,
                remoteJobID: UUID? = nil,
                title: String,
                profile: CatapocketDownloadProfile,
                fileURL: URL,
                byteCount: Int64? = nil,
                createdAt: Date = Date()) {
        self.id = id
        self.libraryItemID = libraryItemID
        self.remoteJobID = remoteJobID
        self.title = title
        self.profile = profile
        self.fileURL = fileURL
        self.byteCount = byteCount
        self.createdAt = createdAt
    }
}

public struct CatapocketMediaExporter: Sendable {
    public init() {}

    public func saveVideoToPhotos(fileURL: URL) async throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw CatapocketMediaExportError.missingLocalFile
        }

        #if canImport(Photos)
        let status = await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
        guard status == .authorized || status == .limited else {
            throw CatapocketMediaExportError.photosPermissionDenied
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                request.addResource(with: .video, fileURL: fileURL, options: options)
            } completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: CatapocketMediaExportError.badServerResponse)
                }
            }
        }
        #else
        throw CatapocketMediaExportError.photosUnavailable
        #endif
    }
}

public struct CatapocketMediaDownloader: Sendable {
    public var pollIntervalNanoseconds: UInt64
    public var maximumPollCount: Int

    public init(pollIntervalNanoseconds: UInt64 = 750_000_000,
                maximumPollCount: Int = 240) {
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.maximumPollCount = maximumPollCount
    }

    public func download(_ item: CatapocketLibraryItem,
                         profile: CatapocketDownloadProfile,
                         using client: CatapocketClient,
                         destinationDirectory: URL) async throws -> CatapocketLocalMedia {
        try FileManager.default.createDirectory(at: destinationDirectory,
                                                withIntermediateDirectories: true)

        let job = try await client.createDownloadJob(for: item.id, profile: profile)
        let completed = try await waitForCompletedJob(job.id, using: client)
        let streamURL = client.downloadJobStreamURL(id: completed.id)
        let (temporaryURL, response) = try await client.urlSession.download(from: streamURL)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw CatapocketMediaExportError.badServerResponse
        }

        let destination = destinationDirectory
            .appendingPathComponent(filename(for: item.title, profile: profile, response: http))
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)

        let attrs = try? FileManager.default.attributesOfItem(atPath: destination.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value
        return CatapocketLocalMedia(libraryItemID: item.id,
                                    remoteJobID: completed.id,
                                    title: item.title,
                                    profile: profile,
                                    fileURL: destination,
                                    byteCount: size)
    }

    public func downloadOriginal(_ item: CatapocketLibraryItem,
                                 using client: CatapocketClient,
                                 destinationDirectory: URL) async throws -> CatapocketLocalMedia {
        try FileManager.default.createDirectory(at: destinationDirectory,
                                                withIntermediateDirectories: true)

        let streamURL = client.libraryStreamURL(id: item.id)
        let (temporaryURL, response) = try await client.urlSession.download(from: streamURL)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw CatapocketMediaExportError.badServerResponse
        }

        let destination = destinationDirectory
            .appendingPathComponent(filename(for: item.title, profile: .original, response: http))
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)

        let attrs = try? FileManager.default.attributesOfItem(atPath: destination.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value
        return CatapocketLocalMedia(libraryItemID: item.id,
                                    title: item.title,
                                    profile: .original,
                                    fileURL: destination,
                                    byteCount: size)
    }

    private func waitForCompletedJob(_ id: UUID,
                                     using client: CatapocketClient) async throws -> CatapocketDownloadJob {
        for _ in 0..<maximumPollCount {
            let job = try await client.fetchDownloadJob(id: id)
            switch job.status {
            case .completed:
                return job
            case .failed, .cancelled:
                throw CatapocketMediaExportError.downloadDidNotComplete
            case .queued, .active, .paused:
                try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            }
        }
        throw CatapocketMediaExportError.downloadDidNotComplete
    }

    private func filename(for title: String,
                          profile: CatapocketDownloadProfile,
                          response: HTTPURLResponse) -> String {
        let ext = fileExtension(profile: profile, response: response)
        let base = title
            .replacingOccurrences(of: #"[\\/:*?"<>|]+"#,
                                  with: "-",
                                  options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBase = base.isEmpty ? "Catapocket" : base
        if cleanBase.lowercased().hasSuffix(".\(ext)") {
            return cleanBase
        }
        return "\(cleanBase).\(ext)"
    }

    private func fileExtension(profile: CatapocketDownloadProfile,
                               response: HTTPURLResponse) -> String {
        if profile == .audioOnly { return "m4a" }
        if let disposition = response.value(forHTTPHeaderField: "Content-Disposition"),
           let filename = disposition
            .split(separator: ";")
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { $0.lowercased().hasPrefix("filename=") }) {
            let raw = filename.dropFirst("filename=".count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let ext = URL(fileURLWithPath: String(raw)).pathExtension
            if !ext.isEmpty { return ext }
        }
        return "mp4"
    }
}

#if canImport(UIKit) && canImport(SwiftUI)
public struct CatapocketFilesExportSheet: UIViewControllerRepresentable {
    public let fileURL: URL
    public var completion: ((Bool) -> Void)?

    public init(fileURL: URL, completion: ((Bool) -> Void)? = nil) {
        self.fileURL = fileURL
        self.completion = completion
    }

    public func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
        controller.delegate = context.coordinator
        return controller
    }

    public func updateUIViewController(_ uiViewController: UIDocumentPickerViewController,
                                       context: Context) {}

    public func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    public final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: ((Bool) -> Void)?

        init(completion: ((Bool) -> Void)?) {
            self.completion = completion
        }

        public func documentPicker(_ controller: UIDocumentPickerViewController,
                                   didPickDocumentsAt urls: [URL]) {
            completion?(true)
        }

        public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            completion?(false)
        }
    }
}
#endif
