import XCTest
@testable import Durvald

@MainActor
final class AlbumCollectionTests: XCTestCase {
    func testCorePersistsManualAndSmartCollectionsAcrossReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AlbumCollections-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let core = try await RatingIntegrationFixture.openCore(directory: directory)
        let manual = try await core.saveAlbumCollection(collectionId: nil, name: "Viagens", description: "Álbuns inteiros", definition: nil)
        try await core.addAlbumToCollection(collectionId: manual.id, releaseId: 2)
        try await core.addAlbumToCollection(collectionId: manual.id, releaseId: 1)
        var page = try await core.albumCollection(collectionId: manual.id)
        XCTAssertEqual(page.items.compactMap { $0.release?.id }, [2, 1])
        let definition = AlbumCollectionDefinition(matchAll: true,
            rules: [SmartPlaylistRule(field: "rating", comparison: "at_least", value: "8")], sortBy: "rating", descending: true)
        let smart = try await core.saveAlbumCollection(collectionId: nil, name: "Bem avaliados", description: "", definition: definition)
        XCTAssertEqual(smart.albumCount, 3)
        try await core.reorderAlbumCollection(collectionId: manual.id, itemIds: page.items.reversed().map(\.id))
        let reopened = try await RatingIntegrationFixture.openCore(directory: directory)
        page = try await reopened.albumCollection(collectionId: manual.id)
        XCTAssertEqual(page.items.compactMap { $0.release?.id }, [1, 2])
        let tracks = try await reopened.albumCollectionTracks(collectionId: manual.id)
        XCTAssertEqual(tracks.map(\.id), [1, 2])
        try await reopened.deleteAlbumCollection(collectionId: smart.id)
        let remaining = try await reopened.albumCollections()
        XCTAssertEqual(remaining.count, 1)
    }

    func testAlbumShufflePreservesEachAlbumsTrackOrderAndMembership() {
        var tracks = [Fixtures.track(id: 1, trackNumber: 1, discNumber: 1), Fixtures.track(id: 2, trackNumber: 2, discNumber: 1), Fixtures.track(id: 3, trackNumber: 1, discNumber: 1)]
        tracks[0].releaseId = 10; tracks[1].releaseId = 10; tracks[2].releaseId = 20
        let grouped = AlbumCollectionsState.playbackTracks(tracks, mode: .albums)
        XCTAssertEqual(Set(grouped.map(\.id)), [1, 2, 3])
        XCTAssertEqual(grouped.filter { $0.releaseId == 10 }.map(\.id), [1, 2])
        let first = grouped.firstIndex { $0.id == 1 }!
        XCTAssertEqual(grouped[first + 1].id, 2)
        XCTAssertEqual(AlbumCollectionsState.playbackTracks(tracks, mode: .ordered), tracks)
        XCTAssertEqual(AlbumCollectionsState.playbackTracks(tracks, mode: .tracks), tracks, "Track shuffle is delegated to the playback engine")
    }

    func testRulesDistinguishAlbumTagsTrackTagsAndYearComparisons() {
        var rule = AlbumRuleDraft()
        rule.field = .albumTag; rule.value = "1"
        XCTAssertEqual(rule.rule.field, "album_tag")
        rule.field = .trackTag
        XCTAssertEqual(rule.rule.field, "track_tag")
        rule.field = .yearTo; rule.value = "2000"
        XCTAssertEqual(rule.rule.comparison, "at_most")
        XCTAssertTrue(rule.valid)
        rule.value = "unknown"
        XCTAssertFalse(rule.valid)
    }

    func testPlaybackCapturesFullSourceAndAlbumStartingPositionWithoutMutatingRunningQueue() async {
        let core = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        var first = Fixtures.track(id: 1, trackNumber: 1, discNumber: 1)
        var second = Fixtures.track(id: 2, trackNumber: 1, discNumber: 1)
        first.releaseId = 10; second.releaseId = 20
        core.albumCollectionTrackResults = [first, second]
        let store = DurvaldCoreStore(core: core)
        let state = AlbumCollectionsState()
        await state.play(id: 7, mode: .ordered, startingAt: 20, using: store)
        XCTAssertEqual(core.collectionRequests.first?.trackIDs, [1, 2])
        XCTAssertEqual(core.collectionRequests.first?.contexts, ["albumCollection:7", "albumCollection:7"])
        XCTAssertEqual(core.collectionRequests.first?.start, 1)
        XCTAssertEqual(core.collectionRequests.first?.shuffle, false)
        core.albumCollectionTrackResults = []
        XCTAssertEqual(core.collectionRequests.count, 1, "Changing a smart result must not replace an already started queue")
        await state.play(id: 7, mode: .tracks, using: store)
        XCTAssertEqual(core.collectionRequests.count, 1, "An empty selection must preserve the current queue")
    }
}
