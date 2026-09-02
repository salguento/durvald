import XCTest
import Combine
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

    @MainActor
    func testSeekPublishesTargetOptimisticallyAndConfirmsCore() async throws {
        let snapshot = Fixtures.playingSnapshot
        let fake = FakeDurvaldCore(snapshot: snapshot)
        let store = DurvaldCoreStore(core: fake, playback: snapshot)
        let seekReachedCore = expectation(description: "Seek chegou ao core")
        fake.onSeek = { _ in seekReachedCore.fulfill() }

        store.seek(to: 90.4)

        let optimistic = try XCTUnwrap(store.playback?.positionSeconds)
        XCTAssertEqual(optimistic, 90, accuracy: 0.001)

        await fulfillment(of: [seekReachedCore], timeout: 1)
        try await waitForSeekCompletion(store)

        XCTAssertEqual(fake.seekCalls, [90])
        let confirmed = try XCTUnwrap(store.playback?.positionSeconds)
        XCTAssertEqual(confirmed, 90, accuracy: 0.001)
    }

    @MainActor
    func testSeekClampsTargetToDuration() async throws {
        let snapshot = Fixtures.playingSnapshot
        let fake = FakeDurvaldCore(snapshot: snapshot)
        let store = DurvaldCoreStore(core: fake, playback: snapshot)
        let seekReachedCore = expectation(description: "Seek limitado chegou ao core")
        fake.onSeek = { _ in seekReachedCore.fulfill() }
        let duration = try XCTUnwrap(snapshot.durationSeconds)

        store.seek(to: 999)
        let optimistic = try XCTUnwrap(store.playback?.positionSeconds)
        XCTAssertEqual(optimistic, duration, accuracy: 0.001)

        await fulfillment(of: [seekReachedCore], timeout: 1)
        XCTAssertEqual(fake.seekCalls, [UInt64(duration)])
        try await waitForSeekCompletion(store)
    }

    @MainActor
    func testSeekKeepsTargetWhileDecoderStillReportsOldPosition() async throws {
        let original = Fixtures.playingSnapshot
        let fake = FakeDurvaldCore(snapshot: original)
        let store = DurvaldCoreStore(core: fake, playback: original)
        var reads = 0
        fake.playbackHandler = {
            reads += 1
            return reads <= 2 ? original : fake.snapshot
        }
        var positions: [Double] = []
        let subscription = store.$playback.dropFirst().sink {
            if let position = $0?.positionSeconds { positions.append(position) }
        }
        defer { subscription.cancel() }

        store.seek(to: 90)
        try await waitForSeekCompletion(store)

        XCTAssertGreaterThanOrEqual(reads, 3)
        XCTAssertFalse(positions.contains(original.positionSeconds))
        XCTAssertEqual(store.playback?.positionSeconds, 90)
    }

    @MainActor
    func testSeekWaitsForStableAcknowledgement() async throws {
        let original = Fixtures.playingSnapshot
        let fake = FakeDurvaldCore(snapshot: original)
        let store = DurvaldCoreStore(core: fake, playback: original)
        var reads = 0
        fake.playbackHandler = {
            reads += 1
            return reads == 2 ? original : fake.snapshot
        }
        var positions: [Double] = []
        let subscription = store.$playback.dropFirst().sink {
            if let position = $0?.positionSeconds { positions.append(position) }
        }
        defer { subscription.cancel() }

        store.seek(to: 90)
        try await waitForSeekCompletion(store)

        XCTAssertGreaterThanOrEqual(reads, 4)
        XCTAssertFalse(positions.contains(original.positionSeconds))
        XCTAssertEqual(store.playback?.positionSeconds, 90)
    }

    @MainActor
    func testSeekWhilePausedDoesNotResumePlayback() async throws {
        var original = Fixtures.playingSnapshot
        original.isPlaying = false
        original.isPaused = true
        let fake = FakeDurvaldCore(snapshot: original)
        let store = DurvaldCoreStore(core: fake, playback: original)

        store.seek(to: 70)
        try await waitForSeekCompletion(store)

        XCTAssertEqual(store.playback?.positionSeconds, 70)
        XCTAssertEqual(store.playback?.isPaused, true)
        XCTAssertEqual(fake.resumeCallCount, 0)
    }

    @MainActor
    func testSeekNeverRoundsPastFractionalDuration() async throws {
        var original = Fixtures.playingSnapshot
        original.durationSeconds = 180.8
        let fake = FakeDurvaldCore(snapshot: original)
        let store = DurvaldCoreStore(core: fake, playback: original)

        store.seek(to: 180.8)
        try await waitForSeekCompletion(store)

        XCTAssertEqual(fake.seekCalls, [180])
        XCTAssertEqual(store.playback?.positionSeconds, 180)
    }

    @MainActor
    func testReadStartedBeforeSeekCannotOverwriteAcknowledgedPosition() async throws {
        let original = Fixtures.playingSnapshot
        let fake = FakeDurvaldCore(snapshot: original)
        let store = DurvaldCoreStore(core: fake, playback: original)
        let readStarted = expectation(description: "Leitura antiga suspensa")
        fake.playbackHandler = {
            fake.playbackHandler = nil
            return await withCheckedContinuation { continuation in
                fake.suspendedPlayback = continuation
                readStarted.fulfill()
            }
        }
        let oldRead = Task { await store.refreshPlayback() }
        await fulfillment(of: [readStarted], timeout: 1)

        store.seek(to: 90)
        try await waitForSeekCompletion(store)
        fake.suspendedPlayback?.resume(returning: original)
        fake.suspendedPlayback = nil
        await oldRead.value

        XCTAssertEqual(store.playback?.positionSeconds, 90)
    }

    @MainActor
    func testRapidSeeksAreSerializedAndIntermediateTargetsAreCoalesced() async throws {
        let fake = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        let store = DurvaldCoreStore(core: fake, playback: fake.snapshot)
        let firstStarted = expectation(description: "Primeiro seek suspenso")
        fake.seekHandler = { seconds in
            if seconds == 20 {
                await withCheckedContinuation { continuation in
                    fake.suspendedSeek = continuation
                    firstStarted.fulfill()
                }
            }
            fake.snapshot.positionSeconds = Double(seconds)
        }

        store.seek(to: 20)
        await fulfillment(of: [firstStarted], timeout: 1)
        store.seek(to: 80)
        store.seek(to: 100)
        XCTAssertEqual(fake.seekCalls, [20])

        // Reads from other controls must not bring back the old position either.
        await store.refreshPlayback()
        XCTAssertEqual(store.playback?.positionSeconds, 100)

        fake.suspendedSeek?.resume()
        fake.suspendedSeek = nil
        try await waitForSeekCompletion(store)

        XCTAssertEqual(fake.seekCalls, [20, 100])
        XCTAssertEqual(fake.maximumConcurrentSeeks, 1)
        XCTAssertEqual(store.playback?.positionSeconds, 100)
    }

    @MainActor
    func testSeekFailureRecoversFromEngineInsteadOfOldSnapshot() async throws {
        enum SeekFailure: Error { case rejected }
        let fake = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        let store = DurvaldCoreStore(core: fake, playback: fake.snapshot)
        fake.seekHandler = { _ in
            fake.snapshot.positionSeconds = 12
            fake.snapshot.volume = 0.75
            throw SeekFailure.rejected
        }

        store.seek(to: 90)
        try await waitForSeekCompletion(store)

        XCTAssertEqual(store.playback?.positionSeconds, 12)
        XCTAssertEqual(store.playback?.volume, 0.75)
        XCTAssertNotNil(store.errorMessage)
    }

    @MainActor
    func testSeekRejectsNonFiniteTargets() {
        let fake = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        let store = DurvaldCoreStore(core: fake, playback: fake.snapshot)
        store.seek(to: .nan)
        store.seek(to: .infinity)
        XCTAssertFalse(store.isSeeking)
        XCTAssertTrue(fake.seekCalls.isEmpty)
        XCTAssertEqual(store.playback?.positionSeconds, 10)
    }

    @MainActor
    private func waitForSeekCompletion(_ store: DurvaldCoreStore) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while store.isSeeking && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(store.isSeeking, "O seek não terminou dentro do prazo")
    }
}

final class LibraryNavigationHistoryTests: XCTestCase {
    func testInitialDestinationIsHome() {
        let history = LibraryNavigationHistory()

        XCTAssertEqual(history.current, .home)
        XCTAssertFalse(history.canGoBack)
        XCTAssertFalse(history.canGoForward)
    }

    func testBackReturnsFromSongsToHome() {
        var history = LibraryNavigationHistory()

        history.navigate(to: .songs)
        history.goBack()

        XCTAssertEqual(history.current, .home)
        XCTAssertTrue(history.canGoForward)
    }
}

final class AlbumGridLayoutTests: XCTestCase {
    func testColumnCountChangesOnlyAtWholeCardThresholds() {
        XCTAssertEqual(AlbumGridLayout.columnCount(for: 379), 1)
        XCTAssertEqual(AlbumGridLayout.columnCount(for: 380), 2)
        XCTAssertEqual(AlbumGridLayout.columnCount(for: 551), 2)
        XCTAssertEqual(AlbumGridLayout.columnCount(for: 552), 3)
    }

    func testColumnsRemainFixedAt160Points() {
        let columns = AlbumGridLayout.columns(for: 900)

        XCTAssertEqual(
            columns.count,
            AlbumGridLayout.columnCount(for: 900)
        )
        XCTAssertEqual(AlbumGridLayout.cardWidth, 160)
        XCTAssertEqual(AlbumGridLayout.spacing, 12)
    }
}
