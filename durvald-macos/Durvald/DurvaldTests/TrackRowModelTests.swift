import XCTest
@testable import Durvald

@MainActor
final class TrackRowModelTests: XCTestCase {
    func testLocalPayloadPreservesMetadataAndPersonalState() {
        var track = Fixtures.track
        track.isFavorite = true
        track.ratingHalfSteps = 4
        let model = TrackRowModel(track)
        XCTAssertEqual(model.trackID, track.id)
        XCTAssertEqual(model.title, track.title)
        XCTAssertEqual(model.artist, track.artist)
        XCTAssertEqual(model.album, track.release)
        XCTAssertEqual(model.artworkID, track.artworkId)
        XCTAssertEqual(model.durationSeconds, track.durationSeconds)
        XCTAssertTrue(model.isFavorite)
        XCTAssertEqual(model.rating, 4)
        track.ratingHalfSteps = nil
        XCTAssertNil(TrackRowModel(track).rating)
        XCTAssertEqual(model.rating, 4, "Presentation is a value snapshot")
    }

    func testMissingAndRemoteTracksDoNotInventLocalIdentity() {
        let missing = TrackRowModel(trackID: 42, title: "Música #42")
        XCTAssertEqual(missing.trackID, 42)
        XCTAssertEqual(missing.accessibilityLabel, "Música #42")
        let remote = TrackRowModel(trackID: nil, title: "Remote", artworkID: "https://example.invalid/art")
        XCTAssertNil(remote.trackID)
        XCTAssertEqual(remote.artworkID, "https://example.invalid/art")
        XCTAssertEqual(remote.durationText(unknown: "—"), "—")
    }

    func testAccessibilityLabelsDoNotAppendEmptyArtist() {
        let model = TrackRowModel(trackID: 1, title: "Title", artist: "Artist")
        XCTAssertEqual(model.accessibilityLabel, "Title, Artist")
        XCTAssertEqual(model.enqueueLabel, "Adicionar Title à fila")
        XCTAssertEqual(TrackRowModel(trackID: 1, title: "Title").accessibilityLabel, "Title")
        XCTAssertEqual(TrackRowModel.favoriteLabel(false), "Favoritar faixa")
        XCTAssertEqual(TrackRowModel.favoriteLabel(true), "Desfavoritar faixa")
    }

    func testDurationRoundingPreservesLocalAndRemotePolicies() {
        for (duration, expected) in [(59.4, "0:59"), (59.5, "1:00"), (125.6, "2:06"), (-5, "0:00")] {
            let model = TrackRowModel(trackID: 1, title: "Title", durationSeconds: duration)
            XCTAssertEqual(model.durationText(), expected)
        }
        for duration: Double in [0, 0.4, -1, .nan, .infinity, Double(Int.max)] {
            let model = TrackRowModel(trackID: nil, title: "Title", durationSeconds: duration)
            XCTAssertEqual(model.durationText(unknown: "—"), "—")
            XCTAssertEqual(model.durationText(), "0:00")
        }
        XCTAssertEqual(TrackRowModel(trackID: nil, title: "Title", durationSeconds: 0.5)
            .durationText(unknown: "—"), "0:01")
    }

    func testQueueOccurrenceIdentityRemainsSeparateFromPresentation() {
        let first = QueueTableRow(trackID: 1, position: 2, title: "Repeated", artist: "Artist",
                                  artworkID: "art", isCurrent: false, isPaused: false)
        let second = QueueTableRow(trackID: 1, position: 5, title: "Repeated", artist: "Artist",
                                   artworkID: "art", isCurrent: false, isPaused: false)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.presentation, second.presentation)
        XCTAssertEqual(first.presentation.artworkID, "art")
    }

    func testStandalonePlaybackDoesNotReplaceQueueWithCollection() async {
        let core = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        await TrackRowPlayback.track(42).perform(using: DurvaldCoreStore(core: core))
        XCTAssertEqual(core.playbackOperations, ["play:42"])
    }

    func testReleasePlaybackStartsAtSelectedTrackInSortedAlbum() async {
        let core = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        core.releaseTrackResults = [Fixtures.track(id: 3, trackNumber: 3, discNumber: 1),
                                   Fixtures.track(id: 1, trackNumber: 1, discNumber: 1),
                                   Fixtures.track(id: 2, trackNumber: 2, discNumber: 1)]
        await TrackRowPlayback.release(7, startingAt: 2).perform(using: DurvaldCoreStore(core: core))
        XCTAssertEqual(core.playbackOperations, ["clear", "play:2", "enqueue:3"])
    }

    func testPlaylistPlaybackUsesOccurrencePositionForRepeatedTracks() async {
        let core = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        let repeated = Fixtures.track(id: 1, trackNumber: 1, discNumber: 1)
        core.playlistResultsByID[7] = [repeated, Fixtures.track(id: 2, trackNumber: 2, discNumber: 1),
                                      repeated, Fixtures.track(id: 3, trackNumber: 3, discNumber: 1)]
        await TrackRowPlayback.playlist(7, position: 2).perform(using: DurvaldCoreStore(core: core))
        XCTAssertEqual(core.playbackOperations, ["clear", "play:1", "enqueue:3"])
    }

    func testInvalidPlaylistPositionKeepsExistingQueue() async {
        let core = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        core.playlistResultsByID[7] = [Fixtures.track]
        let store = DurvaldCoreStore(core: core)
        await TrackRowPlayback.playlist(7, position: -1).perform(using: store)
        XCTAssertTrue(core.playbackOperations.isEmpty)
        XCTAssertNotNil(store.errorMessage)
    }
}
