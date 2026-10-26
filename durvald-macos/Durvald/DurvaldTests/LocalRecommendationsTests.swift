import XCTest
@testable import Durvald

@MainActor
final class LocalRecommendationsTests: XCTestCase {
    private var result: LocalRecommendations {
        LocalRecommendations(items: [LocalAlbumRecommendation(release: Fixtures.release, reason: "Gênero em comum: Jazz")], exploration: false)
    }
    func testRefreshIsBoundedAndCachedUntilPreferencesOrHistoryChange() async {
        let core = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        var reads = 0
        var history: UInt64 = 0
        core.historyRevisionHandler = { history }
        core.localRecommendationsHandler = { limit in XCTAssertEqual(limit, 12); reads += 1; return self.result }
        let repository = LocalRecommendationsRepository()
        await repository.refresh(core: core, signals: "catalog:1")
        await repository.refresh(core: core, signals: "catalog:1")
        XCTAssertEqual(reads, 1)
        history = 1
        await repository.refresh(core: core, signals: "catalog:1")
        await repository.refresh(core: core, signals: "catalog:2")
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(repository.snapshot, result)
        XCTAssertFalse(repository.loading)
    }
    func testFailureCanRetryAndDismissRestoreRefreshTheShelf() async {
        let core = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        var fail = true
        var dismissed = false
        core.localRecommendationsHandler = { _ in
            if fail { throw CocoaError(.fileReadUnknown) }
            return dismissed ? LocalRecommendations(items: [], exploration: false) : self.result
        }
        core.recommendationDismissHandler = { id in XCTAssertEqual(id, Fixtures.release.id); dismissed = true }
        core.recommendationRestoreHandler = { dismissed = false }
        let repository = LocalRecommendationsRepository()
        await repository.refresh(core: core, signals: "1")
        XCTAssertNotNil(repository.error)
        fail = false
        await repository.refresh(core: core, signals: "1")
        XCTAssertNil(repository.error)
        await repository.dismiss(releaseID: Fixtures.release.id, core: core, signals: "1")
        XCTAssertTrue(repository.snapshot.items.isEmpty)
        await repository.restore(core: core, signals: "1")
        XCTAssertEqual(repository.snapshot, result)
    }
    func testPollingDoesNotCancelAForcedRefreshAndOldCoreCannotPublish() async {
        let core = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        let repository = LocalRecommendationsRepository()
        core.localRecommendationsHandler = { _ in self.result }
        await repository.refresh(core: core, signals: "1")
        var pending: CheckedContinuation<LocalRecommendations, Never>?
        core.localRecommendationsHandler = { _ in await withCheckedContinuation { pending = $0 } }
        let forced = Task { await repository.refresh(core: core, signals: "1", force: true) }
        while pending == nil { await Task.yield() }
        await repository.refresh(core: core, signals: "1")
        pending?.resume(returning: result)
        await forced.value
        XCTAssertFalse(repository.loading)
        XCTAssertEqual(repository.snapshot, result)
        pending = nil
        let stale = Task { await repository.refresh(core: core, signals: "old") }
        while pending == nil { await Task.yield() }
        let replacement = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        await repository.refresh(core: replacement, signals: "new")
        pending?.resume(returning: result)
        await stale.value
        XCTAssertTrue(repository.snapshot.items.isEmpty)
        XCTAssertTrue(repository.snapshot.exploration)
    }
    func testRealCorePersistsDismissalAndMeasuresAnAttributedListenLocally() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LocalRecommendations-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let core = try await RatingIntegrationFixture.openCore(directory: directory)
        let batch = try await core.localRecommendations(limit: 12)
        XCTAssertTrue(batch.exploration)
        XCTAssertLessThanOrEqual(batch.items.count, 2)
        let item = try XCTUnwrap(batch.items.first)
        XCTAssertTrue(item.release.ratingHalfSteps == nil || item.release.ratingHalfSteps! >= 4)
        try await core.dismissLocalRecommendation(releaseId: item.release.id)
        let reopened = try await RatingIntegrationFixture.openCore(directory: directory)
        let afterDismiss = try await reopened.localRecommendations(limit: 12)
        XCTAssertFalse(afterDismiss.items.contains { $0.release.id == item.release.id })
        try await reopened.restoreLocalRecommendations()
        try await reopened.recordRecommendationEvent(releaseId: item.release.id, event: .shown)
        try await reopened.recordRecommendationEvent(releaseId: item.release.id, event: .opened)
        let date = ISO8601DateFormatter().string(from: Date())
        try RatingIntegrationFixture.withDatabase(RatingIntegrationFixture.config(directory: directory).databasePath) { database in
            try RatingIntegrationFixture.execute("INSERT INTO play_history(song_id,played_at,play_duration) VALUES(\(item.release.id),'\(date)',180);", database: database)
        }
        let metrics = try await reopened.recommendationMetrics()
        XCTAssertEqual(metrics, RecommendationMetrics(shown: 1, opened: 1, listened: 1))
    }
}
