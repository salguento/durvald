import XCTest
@testable import Durvald

@MainActor
final class QueueMenuTrackPresentationTests: XCTestCase {
    func testQueueRequestStaysStableDuringPlaybackTicksAndChangesWithQueue() async {
        var snapshot = Fixtures.playingSnapshot
        snapshot.queue = [QueueItem(trackId: 1, position: 0)]
        let core = FakeDurvaldCore(snapshot: snapshot)
        let store = DurvaldCoreStore(core: core, playback: snapshot)
        let initial = QueueMenuTrackRequest(store: store)
        core.snapshot.positionSeconds = 20
        await store.refreshPlayback()
        XCTAssertEqual(QueueMenuTrackRequest(store: store), initial)
        core.snapshot.queue.append(QueueItem(trackId: 2, position: 1))
        await store.refreshPlayback()
        let appended = QueueMenuTrackRequest(store: store)
        XCTAssertNotEqual(appended, initial)
        core.snapshot.queue = [QueueItem(trackId: 2, position: 0), QueueItem(trackId: 1, position: 1)]
        await store.refreshPlayback()
        XCTAssertNotEqual(QueueMenuTrackRequest(store: store), appended)
        let reordered = QueueMenuTrackRequest(store: store)
        core.snapshot.isPaused = true
        await store.refreshPlayback()
        XCTAssertEqual(QueueMenuTrackRequest(store: store), reordered)
    }

    func testUnchangedRequestAndReorderReuseMetadataAndRemovalPrunesCache() async {
        let model = QueueMenuTrackPresentation()
        let queue = [QueueItem(trackId: 1, position: 0), QueueItem(trackId: 1, position: 1), QueueItem(trackId: 2, position: 2)]
        var calls: [Int64] = []
        let load: (Int64) async throws -> Track? = { id in
            calls.append(id)
            return Fixtures.track(id: id, trackNumber: 1, discNumber: 1)
        }
        await model.refresh(request: .init(queueRevision: 1), queue: queue, knownTracks: [], load: load)
        await model.refresh(request: .init(queueRevision: 1), queue: queue, knownTracks: [], load: load)
        XCTAssertEqual(calls, [1, 2])
        await model.refresh(request: .init(queueRevision: 2), queue: Array(queue.reversed()), knownTracks: [], load: load)
        XCTAssertEqual(calls, [1, 2])
        await model.refresh(request: .init(queueRevision: 3), queue: [queue[0]], knownTracks: [], load: load)
        XCTAssertEqual(Set(model.tracksByID.keys), [1])
    }

    func testKnownMetadataAndRevisionReplaceCachedTrack() async {
        let model = QueueMenuTrackPresentation()
        let queue = [QueueItem(trackId: 1, position: 0)]
        await model.refresh(request: .init(queueRevision: 1), queue: queue, knownTracks: []) { _ in Fixtures.track }
        var current = Fixtures.track
        current.isFavorite = true; current.ratingHalfSteps = 5
        await model.refresh(request: .init(queueRevision: 1, tracksRevision: 1), queue: queue, knownTracks: [current]) { _ in
            XCTFail("Known track must not be fetched"); return nil
        }
        XCTAssertEqual(model.tracksByID[1]?.isFavorite, true)
        XCTAssertEqual(model.tracksByID[1]?.ratingHalfSteps, 5)
        await model.refresh(request: .init(queueRevision: 1, catalogRevision: 1, tracksRevision: 1), queue: queue, knownTracks: []) { _ in
            var refreshed = Fixtures.track
            refreshed.title = "Edited"
            return refreshed
        }
        XCTAssertEqual(model.tracksByID[1]?.title, "Edited")
    }

    func testCoreReplacementReloadsSameTrackIdentifiers() async {
        let model = QueueMenuTrackPresentation()
        let oldCore = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        let newCore = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        let queue = [QueueItem(trackId: 1, position: 0)]
        await model.refresh(request: .init(coreID: ObjectIdentifier(oldCore)), queue: queue, knownTracks: []) { _ in Fixtures.track }
        await model.refresh(request: .init(coreID: ObjectIdentifier(newCore)), queue: queue, knownTracks: []) { _ in
            var track = Fixtures.track
            track.title = "New database"
            return track
        }
        XCTAssertEqual(model.tracksByID[1]?.title, "New database")
    }

    func testCancelledLoadCannotPublishAndCanRetry() async {
        let model = QueueMenuTrackPresentation()
        let gate = QueueTrackLoadGate()
        let queue = [QueueItem(trackId: 1, position: 0)]
        let request = QueueMenuTrackRequest(queueRevision: 1)
        let task = Task {
            await model.refresh(request: request, queue: queue, knownTracks: []) { _ in await gate.load() }
        }
        await gate.waitUntilStarted()
        task.cancel()
        await gate.resume()
        await task.value
        XCTAssertTrue(model.tracksByID.isEmpty)
        await model.refresh(request: request, queue: queue, knownTracks: []) { _ in Fixtures.track }
        XCTAssertEqual(model.tracksByID[1]?.id, 1)
    }

    func testNewerRequestDiscardsLateResults() async {
        let model = QueueMenuTrackPresentation()
        let gate = QueueTrackLoadGate()
        let old = Task {
            await model.refresh(request: .init(queueRevision: 1), queue: [QueueItem(trackId: 1, position: 0)], knownTracks: []) { _ in await gate.load() }
        }
        await gate.waitUntilStarted()
        let track = Fixtures.track(id: 2, trackNumber: 1, discNumber: 1)
        await model.refresh(request: .init(queueRevision: 2), queue: [QueueItem(trackId: 2, position: 0)], knownTracks: [track]) { _ in
            XCTFail("Known track must not be fetched"); return nil
        }
        await gate.resume()
        await old.value
        XCTAssertEqual(Set(model.tracksByID.keys), [2])
    }
}

private actor QueueTrackLoadGate {
    private var result: CheckedContinuation<Track, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func load() async -> Track {
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
    func resume() { result?.resume(returning: Fixtures.track); result = nil }
}
