import XCTest
import Observation
@testable import Durvald

@MainActor
final class PlaybackHistoryRepositoryTests: XCTestCase {
    private func fake(_ probe: HistoryProbe) -> FakeDurvaldCore {
        let fake = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        fake.historyRevisionHandler = { await probe.currentRevision() }
        fake.historyHandler = { try await probe.history() }
        fake.tracksByIDsHandler = { try await probe.tracks($0) }
        return fake
    }

    func testUnchangedVisitsReuseHistoryAndBatchResolutionIncludingOldEntries() async throws {
        let probe = HistoryProbe(count: 405)
        let store = DurvaldCoreStore(core: fake(probe), tracks: [Fixtures.track])
        await store.refreshHistory()
        let repository = store.historyRepository
        XCTAssertEqual(repository.entries.count, 405)
        XCTAssertEqual(repository.tracksByID.count, 405)
        XCTAssertEqual(repository.tracksByID[405]?.title, "Old recording")
        XCTAssertEqual(repository.entries(matching: "OLD RECORDING").map(\.trackId), [405])
        XCTAssertEqual(repository.entries(matching: "Álbum").count, 405)
        XCTAssertEqual(repository.entries(matching: "Artista").count, 405)
        let version = repository.revision
        await store.refreshHistory()
        await store.refreshHistory()
        let stats = await probe.stats()
        XCTAssertEqual(stats.historyReads, 1)
        XCTAssertEqual(stats.batches.map(\.count), [200, 200, 4])
        XCTAssertEqual(repository.revision, version, "Unchanged checks must not publish arrays")
        XCTAssertEqual(store.tracks.count, 1, "History must not materialize the whole catalog in the store")
    }

    func testPlaybackReconciliationDetectsHistoryChangesWithoutTrackTransition() async throws {
        let probe = HistoryProbe(count: 1)
        let fake = fake(probe)
        let store = DurvaldCoreStore(core: fake, playback: Fixtures.playingSnapshot)
        await store.refreshHistory()
        let updated = expectation(description: "History revision published by playback reconciliation")
        withObservationTracking {
            _ = store.historyRepository.revision
        } onChange: {
            updated.fulfill()
        }
        await probe.replaceHistory(ids: [1, 1])
        store.startPlaybackPolling()
        await fulfillment(of: [updated], timeout: 5)
        XCTAssertEqual(store.historyRepository.entries.map(\.trackId), [1, 1])
        XCTAssertEqual(store.activeTrackID, Fixtures.track.id)
        let stats = await probe.stats()
        XCTAssertEqual(stats.historyReads, 2)
        XCTAssertEqual(stats.batches, [[1]])
    }

    func testNewEventsResolveOnlyNewIDsAndDeletionReplacesTheSnapshot() async throws {
        let probe = HistoryProbe(count: 2)
        let store = DurvaldCoreStore(core: fake(probe))
        await store.refreshHistory()
        await probe.replaceHistory(ids: [3, 2, 1, 3])
        await store.refreshHistory()
        XCTAssertEqual(store.historyRepository.entries.map(\.trackId), [3, 2, 1, 3])
        var stats = await probe.stats()
        XCTAssertEqual(stats.historyReads, 2)
        XCTAssertEqual(stats.batches, [[1, 2], [3]], "Repeated tracks must be resolved once")
        await probe.replaceHistory(ids: [])
        await store.refreshHistory()
        XCTAssertTrue(store.historyRepository.entries.isEmpty)
        XCTAssertTrue(store.historyRepository.tracksByID.isEmpty)
        stats = await probe.stats()
        XCTAssertEqual(stats.historyReads, 3)
        XCTAssertEqual(stats.batches.count, 2)
    }

    func testMetadataInvalidatesTrackIndexWithoutReloadingHistory() async throws {
        let probe = HistoryProbe(count: 2)
        let store = DurvaldCoreStore(core: fake(probe), tracks: [Fixtures.track])
        await store.refreshHistory()
        await probe.rename(id: 2, title: "Edited old recording")
        await store.setTrackRating(trackID: 1, rating: 5)
        await store.refreshHistory()
        XCTAssertEqual(store.historyRepository.tracksByID[1]?.ratingHalfSteps, 5)
        XCTAssertEqual(store.historyRepository.tracksByID[2]?.title, "Edited old recording")
        let stats = await probe.stats()
        XCTAssertEqual(stats.historyReads, 1)
        XCTAssertEqual(stats.batches, [[2], [2]])
    }

    func testAbsentTracksAreMemoizedUntilCatalogChanges() async throws {
        let probe = HistoryProbe(count: 2)
        await probe.setMissing(id: 2)
        let fake = fake(probe)
        let store = DurvaldCoreStore(core: fake)
        await store.refreshHistory()
        XCTAssertNil(store.historyRepository.tracksByID[2])
        XCTAssertEqual(store.historyRepository.entries(matching: "Música #2").map(\.trackId), [2])
        await probe.replaceHistory(ids: [2, 1, 2])
        await store.refreshHistory()
        var stats = await probe.stats()
        XCTAssertEqual(stats.batches, [[1, 2]], "Absent IDs must not be retried for every row or query")
        await probe.restore(id: 2)
        await store.setTrackRating(trackID: 1, rating: 4)
        await store.refreshHistory()
        XCTAssertNotNil(store.historyRepository.tracksByID[2])
        stats = await probe.stats()
        XCTAssertEqual(stats.batches, [[1, 2], [1, 2]])
    }

    func testConcurrentCancelledConsumerDoesNotCancelSharedSnapshot() async throws {
        let probe = HistoryProbe(count: 2, suspended: true)
        let repository = PlaybackHistoryRepository()
        let core = fake(probe)
        let first = Task { try await repository.refresh(core: core, catalogRevision: 0, tracksRevision: 0, knownTracks: []) }
        await probe.waitUntilStarted()
        let second = Task { try await repository.refresh(core: core, catalogRevision: 0, tracksRevision: 0, knownTracks: []) }
        first.cancel()
        await probe.resume()
        do { try await first.value; XCTFail("Cancelled consumer returned normally") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        try await second.value
        XCTAssertEqual(repository.entries.count, 2)
        let stats = await probe.stats()
        XCTAssertEqual(stats.historyReads, 1)
        XCTAssertEqual(stats.batches, [[1, 2]])
    }

    func testRevisionChangeDuringReadDoesNotPublishMixedSnapshotAndCanRetry() async throws {
        let probe = HistoryProbe(count: 2, suspended: true)
        let store = DurvaldCoreStore(core: fake(probe))
        let refresh = Task { await store.refreshHistory() }
        await probe.waitUntilStarted()
        await probe.replaceHistory(ids: [3])
        await probe.resume()
        await refresh.value
        XCTAssertTrue(store.historyRepository.entries.isEmpty)
        XCTAssertFalse(store.historyRepository.isLoading)
        await store.refreshHistory()
        XCTAssertEqual(store.historyRepository.entries.map(\.trackId), [3])
        XCTAssertNotNil(store.historyRepository.tracksByID[3])
    }

    func testFailedBatchPreservesLastSnapshotAndRetries() async throws {
        let probe = HistoryProbe(count: 1)
        let store = DurvaldCoreStore(core: fake(probe))
        await store.refreshHistory()
        await probe.replaceHistory(ids: [2, 1])
        await probe.failNextBatch()
        await store.refreshHistory()
        XCTAssertEqual(store.historyRepository.entries.map(\.trackId), [1])
        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(store.historyRepository.isLoading)
        await store.refreshHistory()
        XCTAssertEqual(store.historyRepository.entries.map(\.trackId), [2, 1])
    }

    func testOlderCallerCannotReplaceNewerTrackPayload() async throws {
        let probe = HistoryProbe(count: 1)
        let core = fake(probe)
        let repository = PlaybackHistoryRepository()
        var current = Fixtures.track
        current.title = "Updated title"
        try await repository.refresh(core: core, catalogRevision: 0, tracksRevision: 2, knownTracks: [current])
        do {
            try await repository.refresh(core: core, catalogRevision: 0, tracksRevision: 1, knownTracks: [Fixtures.track])
            XCTFail("Older track revision was accepted")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(repository.tracksByID[1]?.title, "Updated title")
        let stats = await probe.stats()
        XCTAssertEqual(stats.historyReads, 1)
        XCTAssertTrue(stats.batches.isEmpty)
    }

    func testInvalidationDiscardsInFlightMetadataAndRetries() async throws {
        let probe = HistoryProbe(count: 1, suspended: true)
        let store = DurvaldCoreStore(core: fake(probe), tracks: [Fixtures.track])
        let refresh = Task { await store.refreshHistory() }
        await probe.waitUntilStarted()
        await store.setTrackRating(trackID: 1, rating: 4)
        await probe.resume()
        await refresh.value
        XCTAssertTrue(store.historyRepository.entries.isEmpty)
        await store.refreshHistory()
        XCTAssertEqual(store.historyRepository.tracksByID[1]?.ratingHalfSteps, 4)
    }
}

private actor HistoryProbe {
    private var coreRevision: UInt64 = 0
    private var entries: [PlaybackHistoryItem]
    private var index: [Int64: Track]
    private var historyReads = 0
    private var batches: [[Int64]] = []
    private var shouldSuspend: Bool
    private var suspended: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var batchFailure = false

    init(count: Int, suspended: Bool = false) {
        entries = (1...count).map {
            PlaybackHistoryItem(id: Int64($0), trackId: Int64($0), playedAt: "2026-10-08T12:00:00.000Z", durationSeconds: 180)
        }
        index = Dictionary((1...count).map {
            var track = Fixtures.track(id: Int64($0), trackNumber: 1, discNumber: 1)
            if $0 == count { track.title = "Old recording" }
            return (track.id, track)
        }, uniquingKeysWith: { _, last in last })
        shouldSuspend = suspended
    }
    func currentRevision() -> UInt64 { coreRevision }
    func history() async throws -> [PlaybackHistoryItem] {
        historyReads += 1
        let snapshot = entries
        if shouldSuspend {
            shouldSuspend = false
            await withCheckedContinuation { continuation in
                suspended = continuation
                started?.resume()
                started = nil
            }
        }
        return snapshot
    }
    func tracks(_ ids: [Int64]) throws -> [Track] {
        batches.append(ids)
        if batchFailure { batchFailure = false; throw NSError(domain: "test", code: 1) }
        return ids.compactMap { index[$0] }
    }
    func replaceHistory(ids: [Int64]) {
        entries = ids.enumerated().map { offset, id in
            PlaybackHistoryItem(id: Int64(offset + 1), trackId: id, playedAt: "2026-10-08T12:00:00.000Z", durationSeconds: 180)
        }
        for id in Set(ids) where index[id] == nil { restore(id: id) }
        coreRevision &+= 1
    }
    func rename(id: Int64, title: String) { index[id]?.title = title }
    func setMissing(id: Int64) { index.removeValue(forKey: id) }
    func restore(id: Int64) { index[id] = Fixtures.track(id: id, trackNumber: 1, discNumber: 1) }
    func failNextBatch() { batchFailure = true }
    func stats() -> (historyReads: Int, batches: [[Int64]]) { (historyReads, batches) }
    func waitUntilStarted() async {
        if suspended != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func resume() { suspended?.resume(); suspended = nil }
}
