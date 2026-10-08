import XCTest
@testable import Durvald

@MainActor
final class PreparedLibraryListingTests: XCTestCase {
    func testUnchangedKeyReusesSnapshotAndScalarChangesInvalidate() async {
        let model = PreparedLibraryListing(0)
        let counter = ListingBuildCounter()
        var key = LibraryListingKey()
        await model.prepare(key: key) { await counter.build() }
        await model.prepare(key: key) { await counter.build() }
        XCTAssertEqual(model.revision, 1)
        XCTAssertEqual(model.value, 1)
        key.query = "new query"
        await model.prepare(key: key) { await counter.build() }
        key.order = .rating
        await model.prepare(key: key) { await counter.build() }
        key.minimumRating = 4
        await model.prepare(key: key) { await counter.build() }
        key.onlyLocal = true
        await model.prepare(key: key) { await counter.build() }
        key.payloadRevision = 1
        await model.prepare(key: key) { await counter.build() }
        key.releasesRevision = 1
        await model.prepare(key: key) { await counter.build() }
        key.orderingRevision = 1
        await model.prepare(key: key) { await counter.build() }
        key.newestFirst = false
        await model.prepare(key: key) { await counter.build() }
        XCTAssertEqual(model.revision, 9)
        XCTAssertEqual(model.value, 9)
    }

    func testNewerPreparationDiscardsLateResults() async {
        let model = PreparedLibraryListing(0)
        let gate = ListingBuildGate()
        let first = Task { await model.prepare(key: .init(query: "old")) { await gate.build() } }
        await gate.waitUntilStarted()
        await model.prepare(key: .init(query: "new")) { 2 }
        await gate.resume()
        await first.value
        XCTAssertEqual(model.value, 2)
        XCTAssertEqual(model.completedKey?.query, "new")
        XCTAssertEqual(model.revision, 1)
        XCTAssertFalse(model.isPreparing)
    }

    func testReturningToCompletedKeyCancelsPendingDifferentQuery() async {
        let model = PreparedLibraryListing(0)
        let key = LibraryListingKey(query: "original")
        await model.prepare(key: key) { 1 }
        let gate = ListingBuildGate()
        let pending = Task { await model.prepare(key: .init(query: "pending")) { await gate.build() } }
        await gate.waitUntilStarted()
        await model.prepare(key: key) { XCTFail("Cached key was rebuilt"); return 3 }
        await gate.resume()
        await pending.value
        XCTAssertEqual(model.value, 1)
        XCTAssertEqual(model.completedKey, key)
        XCTAssertEqual(model.revision, 1)
    }

    func testCancelledPreparationKeepsSnapshotAndAllowsRetry() async {
        let model = PreparedLibraryListing(0)
        let gate = ListingBuildGate()
        let key = LibraryListingKey(query: "search")
        let pending = Task { await model.prepare(key: key) { await gate.build() } }
        await gate.waitUntilStarted()
        pending.cancel()
        await gate.resume()
        await pending.value
        XCTAssertEqual(model.value, 0)
        XCTAssertNil(model.completedKey)
        await model.prepare(key: key) { 3 }
        XCTAssertEqual(model.value, 3)
    }

    func testAlbumFilteringUsesMetadataOverlayAndPreparedSummary() {
        var first = Fixtures.release
        first.title = "Zulu"
        first.rating = 1
        var second = Fixtures.release
        second.id = 2
        second.title = "Alpha"
        second.rating = 4
        var update = first
        update.rating = 5
        let key = LibraryListingKey(query: "ARTISTA", order: .rating, minimumRating: 5)
        let snapshot = AlbumListingSnapshot.build(releases: [first, second], updates: [update], tracks: [Fixtures.track], sizes: [:], key: key, recency: [:])
        XCTAssertEqual(snapshot.items.map(\.id), [1])
        XCTAssertTrue(snapshot.summary.contains("1 item, 3 minutos"))
        let disabled = AlbumListingSnapshot.build(releases: [first, second], updates: [], tracks: [], sizes: [:], key: .init(order: .alphabetical, minimumRating: 5, ratingsEnabled: false), recency: [:])
        XCTAssertEqual(disabled.items.map(\.id), [2, 1])
    }

    func testArtistRanksUseAllReleasesAndPreserveMissingValueFallbacks() {
        let artists = [Artist(id: 1, name: "Alpha"), Artist(id: 2, name: "Zulu"), Artist(id: 3, name: "Empty")]
        var first = Fixtures.release
        first.id = 4; first.artistId = 1; first.releaseDate = "2020"; first.rating = 3
        var later = first
        later.id = 5; later.releaseDate = "2024"; later.rating = 5
        var other = first
        other.id = 99; other.artistId = 2; other.releaseDate = "2023"; other.rating = 4
        let releases = [first, later, other]
        let expected: [CollectionListingOrder: [Int64]] = [
            .recent: [2, 1, 3], .recentlyAdded: [2, 1, 3], .releaseDate: [1, 2, 3],
            .rating: [1, 2, 3], .alphabetical: [1, 3, 2], .artist: [1, 3, 2]
        ]
        for order in CollectionListingOrder.allCases {
            let items = CollectionListingSorter.artists(artists, order: order, releases: releases, lastPlayedByRelease: [5: "2024", 99: "2025"])
            XCTAssertEqual(items.map(\.id), expected[order], "\(order)")
        }
        let local = ArtistListingSnapshot.build(artists: artists, releases: releases, localIDs: [1, 2], key: .init(query: "ALPHA", onlyLocal: true), recency: [:])
        XCTAssertEqual(local.items.map(\.id), [1])
        XCTAssertTrue(local.summary.contains("1 artista local, 0 artistas indexados"))
    }

    func testPreparationRunsOutsideMainThread() async {
        let model = PreparedLibraryListing(true)
        await model.prepare(key: .init()) { listingWorkerIsOnMainThread() }
        XCTAssertFalse(model.value)
    }

    func testPlaylistRanksPreserveAllOrderingModesAndMissingTracks() {
        let playlists = [
            Playlist(id: 1, name: "Zulu", description: "", artworkId: nil, isFavorite: false, suggestLess: false, trackCount: 0, createdAt: "2024", updatedAt: "2024", isSmart: false, smartDefinition: nil),
            Playlist(id: 2, name: "Alpha", description: "", artworkId: nil, isFavorite: false, suggestLess: false, trackCount: 0, createdAt: "2025", updatedAt: "2025", isSmart: false, smartDefinition: nil),
            Playlist(id: 3, name: "Empty", description: "", artworkId: nil, isFavorite: false, suggestLess: false, trackCount: 0, createdAt: "2020", updatedAt: "2020", isSmart: false, smartDefinition: nil)
        ]
        var first = Fixtures.track
        first.artist = "Zulu"; first.rating = 1; first.lastPlayed = "2020"
        var later = first
        later.id = 2; later.artist = "Alpha"; later.rating = 5; later.lastPlayed = "2025"; later.releaseId = 2
        var other = first
        other.id = 3; other.artist = "Beta"; other.rating = 4; other.lastPlayed = "2024"
        var release = Fixtures.release
        release.releaseDate = "2023"
        var latest = release
        latest.id = 2; latest.releaseDate = "2024"
        let expected: [CollectionListingOrder: [Int64]] = [
            .recent: [1, 2, 3], .recentlyAdded: [2, 1, 3], .releaseDate: [1, 2, 3],
            .rating: [1, 2, 3], .alphabetical: [2, 3, 1], .artist: [1, 2, 3]
        ]
        for order in CollectionListingOrder.allCases {
            let items = CollectionListingSorter.playlists(playlists, order: order, tracksByPlaylist: [1: [first, later], 2: [other]], releases: [release, latest])
            XCTAssertEqual(items.map(\.id), expected[order], "\(order)")
        }
    }

    func testSidebarSnapshotUsesSelectedScopeAndLocalizedSearch() {
        let album = SidebarListingSnapshot.build(albums: [Fixtures.release], artists: [Artist(id: 1, name: "Artista")], playlists: [], tracks: [:], recency: [:], key: .init(scope: "albums", query: "album"))
        XCTAssertEqual(album.albums.map(\.id), [1])
        XCTAssertTrue(album.artists.isEmpty)
        let artist = SidebarListingSnapshot.build(albums: [Fixtures.release], artists: [Artist(id: 1, name: "Artista")], playlists: [], tracks: [:], recency: [:], key: .init(scope: "artists", query: "ARTISTA"))
        XCTAssertEqual(artist.artists.map(\.id), [1])
        XCTAssertTrue(artist.albums.isEmpty)
    }

    func testHistorySnapshotKeepsSearchOlderEntriesAndBothDirections() {
        let entries = [PlaybackHistoryItem(id: 2, trackId: 1, playedAt: "", durationSeconds: 180),
                       PlaybackHistoryItem(id: 1, trackId: 99, playedAt: "", durationSeconds: 60)]
        let tracks = [Int64(1): Fixtures.track]
        let descending = HistoryListingSnapshot.build(entries: entries, tracks: tracks, key: .init())
        XCTAssertEqual(descending.items.map(\.id), [2, 1])
        XCTAssertTrue(descending.summary.contains("2 reproduções, 2 músicas, 4:00"))
        let ascending = HistoryListingSnapshot.build(entries: entries, tracks: tracks, key: .init(newestFirst: false))
        XCTAssertEqual(ascending.items.map(\.id), [1, 2])
        let missing = HistoryListingSnapshot.build(entries: entries, tracks: tracks, key: .init(query: "Música #99"))
        XCTAssertEqual(missing.items.map(\.id), [1])
        let title = HistoryListingSnapshot.build(entries: entries, tracks: tracks, key: .init(query: "FAIXA"))
        XCTAssertEqual(title.items.map(\.id), [2])
    }
}

private actor ListingBuildCounter {
    private var count = 0
    func build() -> Int { count += 1; return count }
}

private actor ListingBuildGate {
    private var result: CheckedContinuation<Int, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func build() async -> Int {
        await withCheckedContinuation { continuation in
            result = continuation
            started?.resume()
            started = nil
        }
    }
    func waitUntilStarted() async {
        if result != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func resume() { result?.resume(returning: 1); result = nil }
}

private func listingWorkerIsOnMainThread() -> Bool { Thread.isMainThread }
