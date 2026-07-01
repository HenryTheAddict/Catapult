import XCTest
@testable import CatapultPocketCore

final class CatapultPocketCoreTests: XCTestCase {
    func testOfflineLinksPersistAndMarkSynced() async throws {
        let url = temporaryStoreURL()
        let store = await CatapocketOfflineStore(fileURL: url)

        let saved = await store.saveLink(url: "https://youtu.be/example",
                                         title: "Example",
                                         mode: .video,
                                         site: .youtube)
        var request = await store.pendingSyncRequest()
        XCTAssertEqual(request.links.map(\.id), [saved.id])

        await store.markSynced(ids: [saved.id], at: Date(timeIntervalSince1970: 10))
        request = await store.pendingSyncRequest()
        XCTAssertTrue(request.links.isEmpty)

        let reloaded = await CatapocketOfflineStore(fileURL: url)
        let snapshot = await reloaded.currentSnapshot()
        XCTAssertEqual(snapshot.links.first?.syncStatus, .synced)
        XCTAssertEqual(snapshot.links.first?.title, "Example")
    }

    func testDownloadQueueReorderAndRetry() async throws {
        let store = await CatapocketOfflineStore(fileURL: temporaryStoreURL())
        let first = CatapocketDownloadJob(title: "One", profile: .original)
        let second = CatapocketDownloadJob(title: "Two", profile: .hevcSameResolution)

        _ = await store.enqueueDownload(first)
        _ = await store.enqueueDownload(second)
        await store.reorderDownloads(ids: [second.id, first.id])
        await store.pauseDownload(id: second.id)
        await store.retryDownload(id: second.id)

        let snapshot = await store.currentSnapshot()
        XCTAssertEqual(snapshot.downloads.map(\.id), [second.id, first.id])
        XCTAssertEqual(snapshot.downloads.first?.status, .queued)
        XCTAssertNil(snapshot.downloads.first?.errorMessage)
    }

    func testPairingPayloadCreatesClientFromBaseURL() throws {
        let pairing = CatapocketPairingPayload(displayName: "Henry's Mac",
                                               baseURL: "http://192.168.1.23:42173/",
                                               remoteURL: "http://192.168.1.23:42173/?token=ignored",
                                               token: "secret",
                                               serverID: "server-1",
                                               endpoints: ["state": "/api/state"],
                                               capabilities: ["ios-priority", "qr-pairing"])

        let client = try CatapocketClient(pairing: pairing)
        let stateURL = client.endpoints.url(path: "/api/state").absoluteString

        XCTAssertEqual(pairing.platformPriority, "ios")
        XCTAssertEqual(stateURL, "http://192.168.1.23:42173/api/state?token=secret")
    }

    func testStreamURLsIncludeToken() {
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let client = CatapocketClient(baseURL: URL(string: "http://192.168.1.23:42173")!,
                                      token: "secret")

        XCTAssertEqual(client.libraryStreamURL(id: id).absoluteString,
                       "http://192.168.1.23:42173/api/library/11111111-1111-1111-1111-111111111111/stream?token=secret")
        XCTAssertEqual(client.downloadJobStreamURL(id: id).absoluteString,
                       "http://192.168.1.23:42173/api/download-jobs/11111111-1111-1111-1111-111111111111/stream?token=secret")
    }

    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("catapocket.json")
    }
}
