import XCTest
@testable import Durvald

@MainActor
final class HomeLibraryRepositoryTests: XCTestCase {
    func testBoundedShelvesRefreshAfterHistoryAndCatalogChangesWithoutLoadingWholeLibrary() async {
        let core = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        var revision: UInt64 = 0
        var reads = 0
        core.historyRevisionHandler = { revision }
        core.homeLibraryHandler = { limit in
            XCTAssertEqual(limit, 24)
            reads += 1
            return HomeLibrary(recentlyPlayed: revision == 0 ? [] : [Fixtures.release], recentlyAdded: [Fixtures.release])
        }
        let store = DurvaldCoreStore(core: core)
        let repository = store.homeRepository
        await repository.refresh(core: core, catalogRevision: 1)
        XCTAssertTrue(repository.hasLoaded)
        XCTAssertTrue(repository.snapshot.recentlyPlayed.isEmpty)
        XCTAssertEqual(repository.snapshot.recentlyAdded.map(\.id), [1])
        await repository.refresh(core: core, catalogRevision: 1)
        XCTAssertEqual(reads, 1)
        revision = 1
        await repository.refresh(core: core, catalogRevision: 1)
        XCTAssertEqual(repository.snapshot.recentlyPlayed.map(\.id), [1])
        await repository.refresh(core: core, catalogRevision: 2)
        XCTAssertEqual(reads, 3)
        XCTAssertTrue(store.tracks.isEmpty)
        XCTAssertTrue(store.releases.isEmpty)
        revision = 0
        await repository.refresh(core: core, catalogRevision: 2)
        XCTAssertTrue(repository.snapshot.recentlyPlayed.isEmpty, "Clearing history removes the shelf entries")
    }

    func testFailureRetainsSnapshotAndRetriesSameRevision() async {
        let core = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        var fail = true
        core.homeLibraryHandler = { _ in
            if fail { throw CocoaError(.fileReadUnknown) }
            return HomeLibrary(recentlyPlayed: [], recentlyAdded: [Fixtures.release])
        }
        let repository = HomeLibraryRepository()
        await repository.refresh(core: core, catalogRevision: 0)
        XCTAssertNotNil(repository.errorMessage)
        XCTAssertFalse(repository.isLoading)
        XCTAssertFalse(repository.hasLoaded)
        fail = false
        await repository.refresh(core: core, catalogRevision: 0)
        XCTAssertNil(repository.errorMessage)
        XCTAssertTrue(repository.hasLoaded)
    }

    func testHistoryChangeDuringReadDoesNotPublishMixedSnapshot() async {
        let core = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        var revision: UInt64 = 0
        core.historyRevisionHandler = { revision }
        core.homeLibraryHandler = { _ in
            revision += 1
            return HomeLibrary(recentlyPlayed: [Fixtures.release], recentlyAdded: [])
        }
        let repository = HomeLibraryRepository()
        await repository.refresh(core: core, catalogRevision: 0)
        XCTAssertFalse(repository.hasLoaded)
        XCTAssertFalse(repository.isLoading)
        XCTAssertTrue(repository.snapshot.recentlyPlayed.isEmpty)
        core.homeLibraryHandler = { _ in HomeLibrary(recentlyPlayed: [Fixtures.release], recentlyAdded: []) }
        await repository.refresh(core: core, catalogRevision: 0)
        XCTAssertEqual(repository.snapshot.recentlyPlayed.map(\.id), [1])
    }
}
