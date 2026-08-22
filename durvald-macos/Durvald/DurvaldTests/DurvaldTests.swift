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
}
