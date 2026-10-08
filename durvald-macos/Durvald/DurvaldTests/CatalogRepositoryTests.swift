import XCTest
@testable import Durvald

@MainActor
final class CatalogRepositoryTests: XCTestCase {
    func testStoreSharesAllPagesAcrossConsumersAndPreservesVisiblePagination() async throws {
        let probe = CatalogProbe()
        let fake = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        fake.tracksPageHandler = { _, offset in await probe.tracks(offset: offset) }
        fake.releasesPageHandler = { _, offset in await probe.releases(offset: offset) }
        let store = DurvaldCoreStore(core: fake, tracks: [Fixtures.track])
        async let first = store.completeCatalogTracks()
        async let second = store.completeCatalogTracks()
        let results = try await (first, second)
        XCTAssertEqual(results.0.map(\.id), [1, 2])
        XCTAssertEqual(results.0, results.1)
        let presentation = MusicLibraryPresentation()
        await presentation.refreshCatalog(store: store)
        _ = try await store.completeCatalogReleases()
        _ = try await store.completeCatalogReleases()
        let counts = await probe.offsets()
        XCTAssertEqual(counts.0, [0, 7], "Navigation and concurrent consumers must reuse all pages")
        XCTAssertEqual(counts.1, [0, 3])
        XCTAssertEqual(store.tracks, [Fixtures.track])
        XCTAssertEqual(presentation.catalog?.count, 2)

        await store.setTrackRating(trackID: 1, rating: 5)
        _ = try await store.completeCatalogTracks()
        _ = try await store.completeCatalogReleases()
        let afterEdit = await probe.offsets()
        XCTAssertEqual(afterEdit.0, [0, 7, 0, 7])
        XCTAssertEqual(afterEdit.1, [0, 3, 0, 3])

        await store.refreshLibraryCatalog()
        _ = try await store.completeCatalogTracks()
        let afterReload = await probe.offsets()
        XCTAssertEqual(afterReload.0, [0, 7, 0, 7, 0, 0, 7], "Scan/reload must invalidate even without a metadata edit")
    }

    func testAlreadyCompleteVisibleTracksAvoidAnotherFFIRead() async throws {
        let probe = CatalogProbe(allTracksFit: true)
        let fake = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        fake.tracksPageHandler = { _, offset in await probe.tracks(offset: offset) }
        let store = DurvaldCoreStore(core: fake)
        await store.refreshLibraryCatalog()
        XCTAssertTrue(store.hasLoadedAllTracks)
        _ = try await store.completeCatalogTracks()
        await store.setTrackRating(trackID: 1, rating: 4)
        let updated = try await store.completeCatalogTracks()
        XCTAssertEqual(updated.first?.rating, 4)
        let counts = await probe.offsets()
        XCTAssertEqual(counts.0, [0])
    }

    func testM3U8ImportReusesSnapshotAndFindsTracksOnLaterPages() async throws {
        let probe = CatalogProbe()
        let fake = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        fake.tracksPageHandler = { _, offset in await probe.tracks(offset: offset) }
        fake.playlistResult = Playlist(id: 1, name: "Import", description: "", artworkId: nil,
                                      isFavorite: false, suggestLess: false, trackCount: 0,
                                      createdAt: "", updatedAt: "", isSmart: false, smartDefinition: nil)
        let store = DurvaldCoreStore(core: fake)
        let tracks = try await store.completeCatalogTracks()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m3u8")
        let document = "#EXTM3U\n\(tracks[1].filePath)\n\(tracks[0].filePath)\n\(tracks[1].filePath)\n/missing/music.flac\n"
        try Data(document.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let report = try await store.importM3U8(from: url)
        XCTAssertEqual(report.importedCount, 3)
        XCTAssertEqual(report.missingPaths, ["/missing/music.flac"])
        XCTAssertEqual(fake.playlistAdditions.map(\.trackID), [2, 1, 2])
        XCTAssertEqual(fake.playlistAdditions.map(\.position), [0, 1, 2])
        let counts = await probe.offsets()
        XCTAssertEqual(counts.0, [0, 7])
    }

    func testCancelledConsumerDoesNotCancelSharedLoad() async throws {
        let cache = CatalogPageCache<Int>()
        let gate = CatalogGate()
        let first = Task { try await cache.load { _ in await gate.page() } }
        await gate.waitUntilStarted()
        first.cancel()
        let second = Task { try await cache.load { _ in XCTFail("Shared worker was discarded"); return ([], nil) } }
        await gate.resume()
        do { _ = try await first.value; XCTFail("Cancelled consumer published a result") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let items = try await second.value
        XCTAssertEqual(items, [1])
        let cached = try await cache.load { _ in XCTFail("Completed snapshot was discarded"); return ([], nil) }
        XCTAssertEqual(cached, [1])
    }

    func testInvalidationRejectsLateResultWithoutReplacingNewSnapshot() async throws {
        let cache = CatalogPageCache<Int>()
        let gate = CatalogGate()
        let old = Task { try await cache.load { _ in await gate.page() } }
        await gate.waitUntilStarted()
        cache.invalidate()
        let updated = try await cache.load { _ in ([9], nil) }
        XCTAssertEqual(updated, [9])
        await gate.resume()
        do { _ = try await old.value; XCTFail("Stale snapshot was returned") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let cached = try await cache.load { _ in XCTFail("New snapshot was discarded"); return ([], nil) }
        XCTAssertEqual(cached, [9])
    }

    func testFailedOrNonAdvancingPageDoesNotCachePartialCatalog() async throws {
        let cache = CatalogPageCache<Int>()
        do {
            _ = try await cache.load { offset in
                if offset == 0 { return ([1], 7) }
                throw NSError(domain: "test", code: 1)
            }
            XCTFail("Page failure was ignored")
        } catch {}
        do {
            _ = try await cache.load { _ in ([2], 0) }
            XCTFail("Non-advancing page was accepted")
        } catch {}
        let retried = try await cache.load { _ in ([3], nil) }
        XCTAssertEqual(retried, [3])
    }
}

private actor CatalogProbe {
    private let allTracksFit: Bool
    init(allTracksFit: Bool = false) { self.allTracksFit = allTracksFit }
    private var trackOffsets: [UInt64] = []
    private var releaseOffsets: [UInt64] = []
    func tracks(offset: UInt64) -> TrackPage {
        trackOffsets.append(offset)
        var track = Fixtures.track(id: offset == 0 ? 1 : 2, trackNumber: 1, discNumber: 1)
        track.filePath = "/tmp/catalog-track-\(track.id).flac"
        return TrackPage(items: [track], nextOffset: !allTracksFit && offset == 0 ? 7 : nil)
    }
    func releases(offset: UInt64) -> ReleasePage {
        releaseOffsets.append(offset)
        var release = Fixtures.release
        release.id = offset == 0 ? 1 : 2
        return ReleasePage(items: [release], nextOffset: offset == 0 ? 3 : nil)
    }
    func offsets() -> ([UInt64], [UInt64]) { (trackOffsets, releaseOffsets) }
}

private actor CatalogGate {
    private var result: CheckedContinuation<([Int], UInt64?), Never>?
    private var started: CheckedContinuation<Void, Never>?
    func page() async -> ([Int], UInt64?) {
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
    func resume() { result?.resume(returning: ([1], nil)); result = nil }
}
