import XCTest
@testable import Durvald

@MainActor
final class FileMetadataRepositoryTests: XCTestCase {
    func testRemoteTracksCountWithoutRequestingFileMetadata() async throws {
        let probe = FileSizeProbe()
        let repository = FileMetadataRepository(reader: { probe.read($0) })
        var remote = Fixtures.track
        remote.filePath = nil
        let store = DurvaldCoreStore(tracks: [remote], fileMetadata: repository)
        let presentation = MusicLibraryPresentation()
        await presentation.refreshCatalog(store: store)
        XCTAssertEqual(probe.count, 0)
        XCTAssertEqual(presentation.librarySummary?.trackCount, 1)
        XCTAssertEqual(presentation.librarySummary?.totalBytes, 0)
    }

    func testConcurrentOverlappingCollectionsReuseUniqueReadsOffMainThread() async throws {
        let probe = FileSizeProbe()
        let repository = FileMetadataRepository(reader: { probe.read($0) })
        async let first = repository.read(["A", "B", "A"], revision: 1)
        async let second = repository.read(["B", "C"], revision: 1)
        let values = try await (first, second)
        XCTAssertEqual(values.0, ["A": 32, "B": 32])
        XCTAssertEqual(values.1, ["B": 32, "C": 32])
        XCTAssertEqual(probe.count, 3)
        XCTAssertFalse(probe.usedMainThread)
    }

    func testRevisionInvalidatesAndOlderRequestCannotRollCacheBackward() async throws {
        let probe = FileSizeProbe()
        let repository = FileMetadataRepository(reader: { probe.read($0) })
        _ = try await repository.read(["A"], revision: 1)
        probe.setSize(64)
        let latest = try await repository.read(["A"], revision: 2)
        XCTAssertEqual(latest["A"], 64)
        do { _ = try await repository.read(["A"], revision: 1); XCTFail("Old revision was accepted") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        _ = try await repository.read(["A"], revision: 2)
        XCTAssertEqual(probe.count, 2)
    }

    func testExpiryRefreshesRealFileChangesAndMissingResults() async throws {
        let clock = FileSizeTestClock()
        let repository = FileMetadataRepository(now: { clock.now })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let missing = try await repository.read([url.path], revision: 1)
        XCTAssertEqual(missing[url.path], -1)
        try Data(repeating: 0, count: 32).write(to: url)
        let cachedMissing = try await repository.read([url.path], revision: 1)
        XCTAssertEqual(cachedMissing[url.path], -1)
        clock.advance()
        let created = try await repository.read([url.path], revision: 1)
        XCTAssertEqual(created[url.path], 32)
        try Data(repeating: 0, count: 64).write(to: url)
        clock.advance()
        let modified = try await repository.read([url.path], revision: 1)
        XCTAssertEqual(modified[url.path], 64)
        try FileManager.default.removeItem(at: url)
        let removed = try await repository.read([url.path], revision: 2)
        XCTAssertEqual(removed[url.path], -1)
    }

    func testBoundedLRUPromotesRecentlyRequestedPaths() async throws {
        let probe = FileSizeProbe()
        let repository = FileMetadataRepository(countLimit: 2, reader: { probe.read($0) })
        for path in ["A", "B", "A", "C", "A"] { _ = try await repository.read([path], revision: 1) }
        XCTAssertEqual(probe.count, 3)
        _ = try await repository.read(["B"], revision: 1)
        XCTAssertEqual(probe.count, 4)
    }

    func testStoreConsumersShareStatsAndDuplicatePathsCountOnceInSummary() async throws {
        let probe = FileSizeProbe()
        let repository = FileMetadataRepository(reader: { probe.read($0) })
        var first = Fixtures.track
        first.filePath = "shared"
        var second = Fixtures.track(id: 2, trackNumber: 2, discNumber: 1)
        second.filePath = "shared"
        let store = DurvaldCoreStore(tracks: [first, second], fileMetadata: repository)
        let presentation = MusicLibraryPresentation()
        await presentation.refreshCatalog(store: store)
        let albumSizes = try await store.fileSizes(for: ["shared"])
        let searchSizes = try await store.fileSizes(for: ["shared", "shared"])
        XCTAssertEqual(probe.count, 1)
        XCTAssertEqual(presentation.librarySummary?.totalBytes, 32)
        XCTAssertEqual(MusicLibrarySummary(tracks: [first, second], kind: .all, fileSizes: albumSizes).totalBytes, 32)
        XCTAssertEqual(searchSizes, albumSizes)
    }

    func testUnchangedCatalogVisitRefreshesExpiredSummaryWithoutReloadingCatalog() async {
        let clock = FileSizeTestClock()
        let probe = FileSizeProbe()
        let repository = FileMetadataRepository(now: { clock.now }, reader: { probe.read($0) })
        let store = DurvaldCoreStore(tracks: [Fixtures.track], fileMetadata: repository)
        let presentation = MusicLibraryPresentation()
        await presentation.refreshCatalog(store: store)
        let version = presentation.catalogVersion
        probe.setSize(64)
        await presentation.refreshCatalog(store: store)
        XCTAssertEqual(presentation.librarySummary?.totalBytes, 32)
        clock.advance()
        await presentation.refreshCatalog(store: store)
        XCTAssertEqual(presentation.librarySummary?.totalBytes, 64)
        XCTAssertEqual(presentation.catalogVersion, version)
        XCTAssertEqual(probe.count, 2)
    }

    func testCancellationDuringReadDoesNotPoisonOtherConsumer() async throws {
        let probe = FileSizeProbe(holdFirstRead: true)
        let repository = FileMetadataRepository(reader: { probe.read($0) })
        let first = Task { try await repository.read(["held"], revision: 1) }
        await waitForRead(probe)
        let other = Task { try await repository.read(["held"], revision: 1) }
        first.cancel()
        probe.release()
        do { _ = try await first.value; XCTFail("Cancelled request returned metadata") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let result = try await other.value
        XCTAssertEqual(result["held"], 32)
        XCTAssertEqual(probe.count, 2)
    }

    func testStoreRejectsReadCompletedAfterCatalogInvalidation() async throws {
        let probe = FileSizeProbe(holdFirstRead: true)
        let repository = FileMetadataRepository(reader: { probe.read($0) })
        let core = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        let store = DurvaldCoreStore(core: core, tracks: [Fixtures.track], fileMetadata: repository)
        let first = Task { try await store.fileSizes(for: ["held"]) }
        await waitForRead(probe)
        await store.setTrackRating(trackID: Fixtures.track.id, rating: 4)
        probe.release()
        do { _ = try await first.value; XCTFail("Old catalog read was published") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        _ = try await store.fileSizes(for: ["held"])
        XCTAssertEqual(probe.count, 2)
    }

    private func waitForRead(_ probe: FileSizeProbe) async {
        for _ in 0..<1000 {
            if probe.started { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        probe.release()
        XCTFail("Timed out waiting for file stat")
    }
}

private final class FileSizeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let barrier = DispatchSemaphore(value: 0)
    private var holdFirstRead: Bool
    private var size: Int64 = 32
    private var reads = 0
    private var mainThread = false
    var count: Int { lock.withLock { reads } }
    var started: Bool { count > 0 }
    var usedMainThread: Bool { lock.withLock { mainThread } }
    init(holdFirstRead: Bool = false) { self.holdFirstRead = holdFirstRead }
    func setSize(_ value: Int64) { lock.withLock { size = value } }
    func release() { barrier.signal() }
    func read(_ path: String) -> Int64 {
        let hold = lock.withLock {
            reads += 1
            mainThread = mainThread || Thread.isMainThread
            let hold = holdFirstRead
            holdFirstRead = false
            return hold
        }
        if hold { barrier.wait() }
        return lock.withLock { size }
    }
}

private final class FileSizeTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    var now: ContinuousClock.Instant { lock.withLock { instant } }
    func advance() { lock.withLock { instant = instant.advanced(by: .seconds(31)) } }
}
