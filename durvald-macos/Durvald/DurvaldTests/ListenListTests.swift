import XCTest
@testable import Durvald

final class ListenListTests: XCTestCase {
    private func item(_ id: Int64, title: String, heard: Bool = false) -> ListenListEntry {
        ListenListEntry(id: id, localReleaseId: id, title: title, artist: "Artist", artworkId: nil,
            addedAt: "2026-01-01T00:00:00Z", heardAt: heard ? "2026-01-02T00:00:00Z" : nil,
            externalRelease: nil, externalArtist: nil)
    }
    func testManualStatesSearchAndStableOrdering() {
        let entries = [item(1, title: "Zulu"), item(2, title: "Alpha", heard: true), item(3, title: "Beta")]
        XCTAssertEqual(ListenListPresentation.items(entries, status: .pending, order: .title, query: "").map(\.id), [3, 1])
        XCTAssertEqual(ListenListPresentation.items(entries, status: .heard, order: .newest, query: "").map(\.id), [2])
        XCTAssertEqual(ListenListPresentation.items(entries, status: .all, order: .newest, query: "ARTIST").map(\.id), [3, 2, 1])
        XCTAssertEqual(ListenListPresentation.items(entries, status: .all, order: .oldest, query: "alpha").map(\.id), [2])
        XCTAssertTrue(ListenListPresentation.items(entries, status: .all, order: .title, query: "missing").isEmpty)
    }
    @MainActor
    func testBridgePersistsLocalAndOnlineEntriesWithoutChangingPlayback() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DurvaldListenList-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await RatingIntegrationFixture.makeStore(directory: directory)
        let initial = store.playback
        await store.saveToListenList(releaseID: 1)
        await store.saveToListenList(releaseID: 1)
        XCTAssertEqual(store.listenListEntries.count, 1)
        let saved = try XCTUnwrap(store.listenListEntries.first)
        await store.markListenListEntry(saved, heard: true)
        XCTAssertEqual(store.pendingListenListCount, 0)
        await store.saveToListenList(releaseID: 1)
        XCTAssertNotNil(store.listenListEntries.first?.heardAt)
        await store.saveToListenList(release: RatingIntegrationFixture.onlineListenRelease(), artist: Artist(id: 1, name: "Rating fixture"))
        XCTAssertEqual(store.listenListEntries.count, 2)
        let reopened = try await RatingIntegrationFixture.makeStore(directory: directory)
        await reopened.refreshListenList()
        XCTAssertEqual(reopened.listenListEntries, store.listenListEntries)
        XCTAssertEqual(store.playback, initial)
        await store.removeFromListenList(saved)
        XCTAssertEqual(store.listenListEntries.count, 1)
        XCTAssertNotNil(store.listenListEntries.first?.externalRelease)
    }
}
