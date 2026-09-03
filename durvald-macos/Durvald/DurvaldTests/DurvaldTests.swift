import XCTest
import AppKit
import Observation
@testable import Durvald

final class DurvaldCoreStoreTests: XCTestCase {
    @MainActor
    func testFavoritePersistsAndUpdatesLibraryAndPlayer() async {
        let snapshot = Fixtures.playingSnapshot
        let fake = FakeDurvaldCore(snapshot: snapshot)
        let store = DurvaldCoreStore(core: fake, playback: snapshot, tracks: [Fixtures.track])

        for favorite in [true, false] {
            store.setTrackFavorite(trackID: Fixtures.track.id, favorite: favorite)
            XCTAssertEqual(store.playback?.currentTrack?.isFavorite, favorite)
            XCTAssertEqual(store.tracks.first?.isFavorite, favorite)
            await store.refreshPlayback()
            XCTAssertEqual(store.playback?.currentTrack?.isFavorite, favorite)
        }
        XCTAssertEqual(fake.favoriteChanges, [true, false])
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testFailedFavoritePreservesCurrentState() {
        let snapshot = Fixtures.playingSnapshot
        let fake = FakeDurvaldCore(snapshot: snapshot)
        fake.favoriteError = NSError(domain: "FavoriteTest", code: 1)
        let store = DurvaldCoreStore(core: fake, playback: snapshot, tracks: [Fixtures.track])

        store.setTrackFavorite(trackID: Fixtures.track.id, favorite: true)

        XCTAssertEqual(store.playback?.currentTrack?.isFavorite, false)
        XCTAssertEqual(store.tracks.first?.isFavorite, false)
        XCTAssertNotNil(store.errorMessage)
    }

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
    func testPlayingAnAlbumTrackQueuesOnlyTheFollowingTracks() async {
        let snapshot = Fixtures.playingSnapshot
        let fake = FakeDurvaldCore(snapshot: snapshot)
        fake.releaseTrackResults = [
            Fixtures.track(id: 4, trackNumber: 1, discNumber: 2),
            Fixtures.track(id: 3, trackNumber: 2, discNumber: 1),
            Fixtures.track(id: 2, trackNumber: 1, discNumber: 1)
        ]
        let store = DurvaldCoreStore(core: fake, playback: snapshot)

        await store.playRelease(releaseID: 1, startingAt: 3)

        XCTAssertEqual(fake.playbackOperations, ["clear", "play:3", "enqueue:4"])
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
            XCTAssertEqual(store.playback?.positionSeconds, 90)
            return reads <= 2 ? original : fake.snapshot
        }
        store.seek(to: 90)
        try await waitForSeekCompletion(store)

        XCTAssertGreaterThanOrEqual(reads, 3)
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
            XCTAssertEqual(store.playback?.positionSeconds, 90)
            return reads == 2 ? original : fake.snapshot
        }
        store.seek(to: 90)
        try await waitForSeekCompletion(store)

        XCTAssertGreaterThanOrEqual(reads, 4)
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
    @MainActor
    func testDetailsPreserveTheirIdentityWhenGoingBackAndForward() {
        let album = Fixtures.release
        let artist = Artist(id: 7, name: "Artista")
        var history = LibraryNavigationHistory()

        history.navigate(to: .songs)
        history.navigate(to: .album(album))
        history.navigate(to: .artist(artist))
        XCTAssertEqual(history.current, .artists)
        history.goBack()
        XCTAssertEqual(history.currentRoute, .album(album))
        history.goBack()
        XCTAssertEqual(history.current, .songs)
        history.goForward()
        XCTAssertEqual(history.currentRoute, .album(album))
        history.goForward()
        XCTAssertEqual(history.currentRoute, .artist(artist))
    }

    func testOpeningANewDetailReplacesForwardHistoryAndDeduplicatesCurrentRoute() {
        var history = LibraryNavigationHistory()
        let first = Artist(id: 1, name: "Mesmo nome")
        let second = Artist(id: 2, name: "Mesmo nome")
        history.navigate(to: .artist(first))
        history.navigate(to: .artist(second))
        history.goBack()
        XCTAssertEqual(history.currentRoute, .artist(first))
        history.navigate(to: .songs)
        XCTAssertFalse(history.canGoForward)
        history.navigate(to: .songs)
        history.goBack()
        XCTAssertEqual(history.currentRoute, .artist(first))
    }

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


final class ScrollObservationTests: XCTestCase {
    @MainActor
    func testPlaybackTicksDoNotInvalidateLibrarySidebarOrQueue() async {
        var snapshot = Fixtures.playingSnapshot
        snapshot.queue = [QueueItem(trackId: 1, position: 0)]
        let fake = FakeDurvaldCore(snapshot: snapshot)
        let store = DurvaldCoreStore(core: fake, playback: snapshot, tracks: [Fixtures.track])

        withObservationTracking {
            _ = store.tracks
            _ = store.releases
            _ = store.artists
            _ = store.playlists
            _ = store.history
            _ = store.scanProgress
            _ = store.errorMessage
            _ = store.core
            _ = store.queue
            _ = store.isPlaybackPaused
            _ = store.activeTrackID
        } onChange: {
            XCTFail("A playback tick invalidated scrolling content")
        }

        let playerUpdated = expectation(description: "Player still receives clock updates")
        withObservationTracking {
            _ = store.playback
        } onChange: {
            playerUpdated.fulfill()
        }

        for tick in 1...120 {
            fake.snapshot.positionSeconds = 10 + Double(tick) * 0.25
            await store.refreshPlayback()
        }
        await fulfillment(of: [playerUpdated], timeout: 1)
        XCTAssertEqual(store.playback?.positionSeconds, 40)
        XCTAssertEqual(store.queue, snapshot.queue)
    }

    @MainActor
    func testQueueAndPauseChangesStillNotifyObservers() async {
        let fake = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        let store = DurvaldCoreStore(core: fake, playback: fake.snapshot)
        let queueUpdated = expectation(description: "Queue insertion updates the table")
        let pauseUpdated = expectation(description: "Pause updates the queue control")
        withObservationTracking {
            _ = store.queue
        } onChange: { queueUpdated.fulfill() }
        withObservationTracking {
            _ = store.isPlaybackPaused
        } onChange: { pauseUpdated.fulfill() }

        fake.snapshot.queue = [QueueItem(trackId: 1, position: 0), QueueItem(trackId: 2, position: 1)]
        await store.refreshPlayback()
        await store.togglePause()

        await fulfillment(of: [queueUpdated, pauseUpdated], timeout: 1)
        XCTAssertEqual(store.queue, fake.snapshot.queue)
        XCTAssertTrue(store.isPlaybackPaused)
    }

    @MainActor
    func testActiveTrackFollowsTransitionsAndClearsWhenPlaybackEnds() async {
        let fake = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        let store = DurvaldCoreStore(core: fake, playback: fake.snapshot)
        XCTAssertEqual(store.activeTrackID, 1)

        let trackChanged = expectation(description: "Titles update on track transition")
        withObservationTracking {
            _ = store.activeTrackID
        } onChange: { trackChanged.fulfill() }

        // Match by identity even when two different tracks have the same title.
        var nextTrack = Fixtures.track(id: 2, trackNumber: 2, discNumber: 1)
        nextTrack.title = Fixtures.track.title
        fake.snapshot.currentTrack = nextTrack
        await store.refreshPlayback()
        await fulfillment(of: [trackChanged], timeout: 1)
        XCTAssertEqual(store.activeTrackID, 2)

        let trackCleared = expectation(description: "Titles restore when no track is active")
        withObservationTracking {
            _ = store.activeTrackID
        } onChange: { trackCleared.fulfill() }
        fake.snapshot.currentTrack = nil
        fake.snapshot.isPlaying = false
        await store.refreshPlayback()
        await fulfillment(of: [trackCleared], timeout: 1)
        XCTAssertNil(store.activeTrackID)
    }

    @MainActor
    func testPauseAndResumeKeepTheSameActiveTrack() async {
        let fake = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        let store = DurvaldCoreStore(core: fake, playback: fake.snapshot)
        withObservationTracking {
            _ = store.activeTrackID
        } onChange: {
            XCTFail("Pause and resume should preserve the active title")
        }

        await store.togglePause()
        XCTAssertEqual(store.activeTrackID, 1)
        await store.togglePause()
        XCTAssertEqual(store.activeTrackID, 1)
        XCTAssertNil(DurvaldCoreStore().activeTrackID)
    }
}

final class ArtworkRepositoryTests: XCTestCase {
    @MainActor
    func testConcurrentRequestsShareDecodedThumbnailAndCache() async throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2048, pixelsHigh: 1024,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let core = ArtworkTestCore(data: data)
        let repository = ArtworkRepository()

        async let firstRequest = repository.image(for: "cover", pixelSize: 128, using: core)
        async let secondRequest = repository.image(for: "cover", pixelSize: 128, using: core)
        let (first, second) = try await (firstRequest, secondRequest)
        let image = try XCTUnwrap(first)
        XCTAssertTrue(image === second)
        XCTAssertEqual(image.size.width, 128)
        XCTAssertEqual(image.size.height, 64)
        XCTAssertEqual(core.readCount, 1)
        XCTAssertFalse(core.readOnMainThread)

        let cached = try await repository.image(for: "cover", pixelSize: 128, using: core)
        XCTAssertTrue(image === cached)
        XCTAssertEqual(core.readCount, 1)

        let larger = try await repository.image(for: "cover", pixelSize: 512, using: core)
        XCTAssertEqual(larger?.size.width, 512)
        XCTAssertEqual(core.readCount, 2)
    }

    @MainActor
    func testMissingArtworkIsCachedWithoutRepeatedDiskReads() async throws {
        let core = ArtworkTestCore(data: nil)
        let repository = ArtworkRepository()
        for _ in 0..<5 {
            let image = try await repository.image(for: "missing", pixelSize: 128, using: core)
            XCTAssertNil(image)
        }
        XCTAssertEqual(core.readCount, 1)
        XCTAssertFalse(core.readOnMainThread)
    }
}

private final class ArtworkTestCore: DurvaldCore {
    private let data: Data?
    private let lock = NSLock()
    private var reads = 0
    private var usedMainThread = false
    var readCount: Int { lock.withLock { reads } }
    var readOnMainThread: Bool { lock.withLock { usedMainThread } }

    init(data: Data?) {
        self.data = data
        super.init(noPointer: .init())
    }

    required init(unsafeFromRawPointer pointer: UnsafeMutableRawPointer) {
        fatalError("ArtworkTestCore does not use the Rust backend")
    }

    override func artworkBytes(artworkId: String) throws -> Data? {
        lock.withLock {
            reads += 1
            usedMainThread = usedMainThread || Thread.isMainThread
        }
        return data
    }
}
