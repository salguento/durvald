import XCTest
@testable import Durvald

final class DurvaldCoreStoreTests: XCTestCase {
    @MainActor
    func testPauseRefreshesSnapshotImmediately() async {
        let snapshot = Fixtures.playingSnapshot
        let fake = FakeDurvaldCore(snapshot: snapshot)

        let store = DurvaldCoreStore(core: fake, playback: snapshot)

        await store.togglePause()

        XCTAssertEqual(fake.pauseCallCount, 1)
        XCTAssertTrue(store.playback?.isPaused == true)
    }

    @MainActor
    func testPlayReleaseReplacesQueueInAlbumOrder() async {
        let snapshot = Fixtures.playingSnapshot
        let fake = FakeDurvaldCore(snapshot: snapshot)
        fake.releaseTrackResults = [
            Fixtures.track(id: 4, trackNumber: 1, discNumber: 2),
            Fixtures.track(id: 3, trackNumber: 2, discNumber: 1),
            Fixtures.track(id: 2, trackNumber: 1, discNumber: 1)
        ]
        let store = DurvaldCoreStore(core: fake, playback: snapshot)

        await store.playRelease(releaseID: 1)

        XCTAssertEqual(
            fake.playbackOperations,
            ["clear", "play:2", "enqueue:3", "enqueue:4"]
        )
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testPlayReleaseRejectsAnAlbumWithoutTracks() async {
        let snapshot = Fixtures.playingSnapshot
        let fake = FakeDurvaldCore(snapshot: snapshot)
        let store = DurvaldCoreStore(core: fake, playback: snapshot)

        await store.playRelease(releaseID: 1)

        XCTAssertTrue(fake.playbackOperations.isEmpty)
        XCTAssertEqual(store.errorMessage, "Este álbum não possui faixas.")
    }
}
