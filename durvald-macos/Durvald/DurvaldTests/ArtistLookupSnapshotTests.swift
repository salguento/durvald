import XCTest
import Observation
@testable import Durvald

final class ArtistLookupSnapshotTests: XCTestCase {
    func testIdentifierIndexesKeepFirstRecord() {
        var first = Fixtures.track
        first.title = "First"; first.isFavorite = false
        var duplicate = first
        duplicate.title = "Duplicate"
        var album = Fixtures.release
        album.title = "First album"
        var duplicateAlbum = album
        duplicateAlbum.title = "Duplicate album"
        let external = release(id: "first", localID: album.id)
        let secondExternal = release(id: "second", localID: album.id)
        let snapshot = ArtistLookupSnapshot.build(tracks: [first, duplicate], albums: [album, duplicateAlbum],
            discography: [external, secondExternal], details: [:])
        XCTAssertEqual(snapshot.tracksByID[first.id]?.title, "First")
        XCTAssertEqual(snapshot.albumsByID[album.id]?.title, "First album")
        XCTAssertEqual(snapshot.externalByLocalReleaseID[album.id]?.musicbrainzId, "first")
        XCTAssertEqual(snapshot.externalByGroupID["second"]?.musicbrainzId, "second")
        XCTAssertNil(snapshot.tracksByID[99])
        XCTAssertNil(snapshot.externalByGroupID["missing"])
    }

    func testArtworkFallbackKeepsFirstReleaseEvenWithoutArtwork() {
        var first = Fixtures.release
        first.artworkId = nil
        var second = first
        second.id = 2; second.artworkId = "later-cover"
        let artists = [Artist(id: 1, name: "First"), Artist(id: 2, name: "Missing")]
        let sidebar = SidebarListingSnapshot.build(albums: [first, second], artists: artists, playlists: [], tracks: [:], recency: [:], key: .init(scope: "artists"))
        let listing = ArtistListingSnapshot.build(artists: artists, releases: [first, second], localIDs: [1], key: .init(), recency: [:])
        XCTAssertNil(sidebar.artistFallbackArtwork[1])
        XCTAssertNil(sidebar.artistFallbackArtwork[2])
        XCTAssertNil(listing.fallbackArtwork[1])
        let reversed = SidebarListingSnapshot.build(albums: [second, first], artists: artists, playlists: [], tracks: [:], recency: [:], key: .init(scope: "artists"))
        XCTAssertEqual(reversed.artistFallbackArtwork[1], "later-cover")
    }

    func testTitleNormalizationPreservesPunctuationWhitespaceAndSuffixRules() {
        XCTAssertEqual(PopularTrackTitle.keys("  DON’T\tGO — Home  (Live)  "), ["don't go - home (live)", "don't go - home"])
        XCTAssertEqual(PopularTrackTitle.keys("Song [Remastered]"), ["song [remastered]", "song"])
        XCTAssertEqual(PopularTrackTitle.keys("Song (Live) [Remastered]"), ["song (live) [remastered]", "song (live)"])
        XCTAssertEqual(PopularTrackTitle.keys("Song (Live) extra"), ["song (live) extra"])
        XCTAssertTrue(PopularTrackTitle.keys(" \n\t").isEmpty)
    }

    func testTitleIndexChoosesSourceOrderAcrossAliasesAndKeepsInvalidFirstMatch() {
        let index = TrackTitleDurationIndex([
            ("Song (Live)", 10), ("Song [Remastered]", 20), ("Unknown", nil), ("Unknown", 30)
        ])
        // The full query key matches the second record, but its alias also
        // matches the first record. The original array scan picked the first.
        XCTAssertEqual(index.duration(for: "Song [Remastered]"), 10)
        XCTAssertEqual(index.duration(for: "SONG"), 10)
        XCTAssertNil(index.duration(for: "Unknown"))
        XCTAssertNil(index.duration(for: "Other"))
    }

    func testRemoteDurationPrecedesLocalAndInvalidFirstRemoteFallsBackLocally() {
        let external = release(id: "remote", localID: 1)
        var local = Fixtures.track
        local.title = "Song"; local.durationSeconds = 50
        let remote = details(id: "remote", tracks: [remoteTrack("Song", duration: 120)])
        let valid = ArtistLookupSnapshot.build(tracks: [local], albums: [], discography: [external], details: ["remote": remote])
        XCTAssertEqual(valid.duration(for: "Song (Live)", release: external), 120)
        for invalidDuration in [nil, 0] as [UInt64?] {
            let invalid = details(id: "remote", tracks: [remoteTrack("Song (Live)", duration: invalidDuration), remoteTrack("Song", duration: 200)])
            let snapshot = ArtistLookupSnapshot.build(tracks: [local], albums: [], discography: [external], details: ["remote": invalid])
            XCTAssertEqual(snapshot.duration(for: "Song", release: external), 50)
            XCTAssertNil(snapshot.duration(for: "Song", release: release(id: "remote", localID: nil)))
        }
    }

    func testLocalDurationSkipsInvalidValuesAndStaysWithinRelease() {
        var wrongRelease = Fixtures.track
        wrongRelease.title = "Song"; wrongRelease.releaseId = 2; wrongRelease.durationSeconds = 300
        var invalid = wrongRelease
        invalid.releaseId = 1; invalid.durationSeconds = 0
        var valid = invalid
        valid.durationSeconds = 60
        var later = valid
        later.durationSeconds = 90
        let snapshot = ArtistLookupSnapshot.build(tracks: [wrongRelease, invalid, valid, later], albums: [], discography: [], details: [:])
        XCTAssertEqual(snapshot.duration(for: "Song [Remastered]", release: release(id: "remote", localID: 1)), 60)
        XCTAssertNil(snapshot.duration(for: "Song", release: release(id: "remote", localID: 3)))
    }

    @MainActor
    func testRevisionRefreshesMetadataAndRemovesObsoleteIdentifiers() async {
        let presentation = PreparedLibraryListing(ArtistLookupSnapshot())
        var first = Fixtures.track
        first.isFavorite = false
        await presentation.prepare(key: .init(payloadRevision: 1), payload: [first]) { tracks in
            ArtistLookupSnapshot.build(tracks: tracks, albums: [], discography: [], details: [:])
        }
        var updated = first
        updated.isFavorite = true
        await presentation.prepare(key: .init(payloadRevision: 2), payload: [updated]) { tracks in
            ArtistLookupSnapshot.build(tracks: tracks, albums: [], discography: [], details: [:])
        }
        XCTAssertEqual(presentation.value.tracksByID[1]?.isFavorite, true)
        await presentation.prepare(key: .init(payloadRevision: 3)) { ArtistLookupSnapshot() }
        XCTAssertNil(presentation.value.tracksByID[1])
    }

    @MainActor
    func testStoreIndexesAreSeededAndKeepFirstIdentifiers() {
        var track = Fixtures.track
        track.title = "First"
        var duplicate = track
        duplicate.title = "Duplicate"
        var album = Fixtures.release
        album.title = "First"
        var duplicateAlbum = album
        duplicateAlbum.title = "Duplicate"
        let store = DurvaldCoreStore(tracks: [track, duplicate], releases: [album, duplicateAlbum],
            artists: [Artist(id: 1, name: "First"), Artist(id: 1, name: "Duplicate")])
        XCTAssertEqual(store.loadedTrack(id: 1)?.title, "First")
        XCTAssertEqual(store.loadedRelease(id: 1)?.title, "First")
        XCTAssertEqual(store.loadedArtist(id: 1)?.name, "First")
        XCTAssertNil(store.loadedTrack(id: 99))
        XCTAssertNil(store.loadedRelease(id: nil))
        XCTAssertNil(store.loadedArtist(id: nil))
    }

    @MainActor
    func testStoreIndexesRefreshAfterArrayReplacementAndRemoveOldRecords() async {
        let core = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        var track = Fixtures.track
        track.id = 2
        var album = Fixtures.release
        album.id = 2
        core.tracksPageHandler = { _, _ in TrackPage(items: [track], nextOffset: nil) }
        core.releasesPageHandler = { _, _ in ReleasePage(items: [album], nextOffset: nil) }
        let store = DurvaldCoreStore(core: core, tracks: [Fixtures.track], releases: [Fixtures.release], artists: [Artist(id: 1, name: "Old")])
        await store.refreshLibraryCatalog()
        XCTAssertNil(store.loadedTrack(id: 1))
        XCTAssertNil(store.loadedRelease(id: 1))
        XCTAssertNil(store.loadedArtist(id: 1))
        XCTAssertEqual(store.loadedTrack(id: 2)?.id, 2)
        XCTAssertEqual(store.loadedRelease(id: 2)?.id, 2)
    }

    @MainActor
    func testStoreIndexReflectsInPlaceMetadataEdits() async {
        let core = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        let store = DurvaldCoreStore(core: core, tracks: [Fixtures.track])
        let revision = store.tracksRevision
        await store.setTrackFavorite(trackID: 1, favorite: true)
        XCTAssertEqual(store.loadedTrack(id: 1)?.isFavorite, true)
        XCTAssertGreaterThan(store.tracksRevision, revision)
        await store.setTrackRating(trackID: 1, rating: 5)
        XCTAssertEqual(store.loadedTrack(id: 1)?.ratingHalfSteps, 5)
    }

    @MainActor
    func testStoreLookupRegistersRevisionForViewUpdates() async {
        let core = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        let store = DurvaldCoreStore(core: core, tracks: [Fixtures.track])
        let changed = expectation(description: "Indexed lookup observes metadata revision")
        withObservationTracking {
            _ = store.loadedTrack(id: 1)
        } onChange: {
            changed.fulfill()
        }
        await store.setTrackFavorite(trackID: 1, favorite: true)
        await fulfillment(of: [changed], timeout: 1)
        XCTAssertEqual(store.loadedTrack(id: 1)?.isFavorite, true)
    }

    private func release(id: String, localID: Int64?) -> ExternalReleaseGroup {
        ExternalReleaseGroup(primaryArtistMbid: nil, musicbrainzId: id, title: id, primaryType: "Album", secondaryTypes: [],
            firstReleaseDate: nil, localReleaseId: localID, artwork: nil, attribution: attribution)
    }

    private func remoteTrack(_ title: String, duration: UInt64?) -> ExternalReleaseTrack {
        ExternalReleaseTrack(discNumber: 1, trackNumber: 1, title: title, artist: "Artist", durationSeconds: duration)
    }

    private func details(id: String, tracks: [ExternalReleaseTrack]) -> ExternalReleaseDetails {
        ExternalReleaseDetails(releaseGroupMbid: id, releaseMbid: id, title: id, artist: "Artist", releaseDate: nil,
            genres: [], composers: [], producers: [], totalDiscs: 1, durationSeconds: 0, tracks: tracks, attribution: attribution)
    }

    private var attribution: EnrichmentAttribution {
        EnrichmentAttribution(sourceUrl: "https://musicbrainz.org", author: nil, licenseName: nil, licenseUrl: nil, revision: nil)
    }
}
