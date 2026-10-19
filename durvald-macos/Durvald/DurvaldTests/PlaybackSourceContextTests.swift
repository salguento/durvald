import XCTest
@testable import Durvald

@MainActor
final class PlaybackSourceContextTests: XCTestCase {
    func testSameTrackOnlyMatchesItsSourceAndOccurrence() {
        let active = PlaybackSourceContext.playlist(7, position: 2)
        XCTAssertTrue(PlaybackSourceContext.matches(trackID: 1, activeTrackID: 1, origin: active, activeOrigin: active))
        for other in [PlaybackSourceContext.release(7), PlaybackSourceContext.library,
                      PlaybackSourceContext.playlist(8, position: 2), PlaybackSourceContext.playlist(7, position: 0), ""] {
            XCTAssertFalse(PlaybackSourceContext.matches(trackID: 1, activeTrackID: 1, origin: other, activeOrigin: active))
        }
        XCTAssertFalse(PlaybackSourceContext.matches(trackID: 2, activeTrackID: 1, origin: active, activeOrigin: active))
        XCTAssertFalse(PlaybackSourceContext.matches(trackID: 1, activeTrackID: nil, origin: active, activeOrigin: active))
        XCTAssertFalse(PlaybackSourceContext.matches(trackID: 1, activeTrackID: 1, origin: "", activeOrigin: ""))
    }

    func testChangingOriginOfTheSameTrackPublishesNewHighlightContext() async {
        let core = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        let store = DurvaldCoreStore(core: core)
        await store.play(trackID: 1, sourceContext: PlaybackSourceContext.release(7))
        XCTAssertEqual(store.activeSourceContext, "release:7")
        await store.play(trackID: 1, sourceContext: PlaybackSourceContext.search("jazz"))
        XCTAssertEqual(store.activeSourceContext, "search:jazz")
        XCTAssertEqual(store.activeTrackID, Fixtures.playingSnapshot.currentTrack?.id)
    }

    func testPlaylistStartingAtRepeatedOccurrenceKeepsOriginalPositions() async {
        let core = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        core.playlistResultsByID[7] = [Fixtures.track(id: 1, trackNumber: 1, discNumber: 1), Fixtures.track(id: 2, trackNumber: 2, discNumber: 1), Fixtures.track(id: 1, trackNumber: 1, discNumber: 1)]
        let store = DurvaldCoreStore(core: core)
        await store.playPlaylist(playlistID: 7, startingAtPosition: 2)
        XCTAssertEqual(core.contextualPlayRequests, ["playlist:7#2"])
        XCTAssertTrue(core.contextualQueueRequests.isEmpty)
        XCTAssertEqual(store.activeSourceContext, "playlist:7#2")
    }

    func testShufflingPreservesOriginOfEveryPlaylistOccurrence() async {
        let core = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        core.playlistResultsByID[7] = [Fixtures.track(id: 1, trackNumber: 1, discNumber: 1), Fixtures.track(id: 2, trackNumber: 2, discNumber: 1), Fixtures.track(id: 1, trackNumber: 1, discNumber: 1)]
        let store = DurvaldCoreStore(core: core)
        await store.playPlaylist(playlistID: 7, startingAtPosition: 0, shuffleEnabled: true)
        XCTAssertEqual((core.contextualPlayRequests + core.contextualQueueRequests).sorted(),
                       ["playlist:7#0", "playlist:7#1", "playlist:7#2"])
    }

    func testAlbumQueueKeepsAlbumOriginAndFailedSelectionKeepsPriorOrigin() async {
        let core = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        core.releaseTrackResults = [Fixtures.track(id: 1, trackNumber: 1, discNumber: 1), Fixtures.track(id: 2, trackNumber: 2, discNumber: 1)]
        let store = DurvaldCoreStore(core: core)
        await store.playRelease(releaseID: 7)
        XCTAssertEqual(core.contextualPlayRequests, ["release:7"])
        XCTAssertEqual(core.contextualQueueRequests, ["release:7"])
        await store.playPlaylist(playlistID: 8, startingAtPosition: 99)
        XCTAssertEqual(store.activeSourceContext, "release:7")
    }
}
