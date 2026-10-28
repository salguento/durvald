import XCTest
@testable import Durvald

@MainActor
final class ServiceCollectionsPresentationTests: XCTestCase {
    private func item(_ id: String, position: UInt32, access: ServiceMediaAccess = .unknown, saved: Int64? = nil) -> ServiceCollectionItem {
        ServiceCollectionItem(occurrenceId: id, position: position, entry: CatalogEntry(reference: CatalogReference(provider: "youtube", kind: .video, id: "abcdefghijk"), title: "Cover / remix", artistCredit: "Uploader", versionLabel: nil, durationSeconds: 10, canonicalUrl: "https://www.youtube.com/watch?v=abcdefghijk"), access: access, savedTrackId: saved, failure: nil)
    }
    private func job(_ id: String, items: [ServiceCollectionItem] = [], failure: ServiceImportFailure? = nil) -> ServiceCollectionJob {
        ServiceCollectionJob(jobId: id, provider: .youTube, canonicalUrl: "https://www.youtube.com/playlist?list=PLabcdefghijklmnop", title: "Playlist", isCollection: true, items: items, nextCursor: "NEXT", loadedPages: items.isEmpty ? 0 : 1, complete: false, truncated: false, fromCache: false, cancelled: false, playlistId: nil, failure: failure)
    }
    private func loader(_ jobs: [ServiceCollectionJob], page: ((String, Bool) async throws -> ServiceCollectionJob)? = nil, apply: ((String, [String], Bool) async throws -> ServiceCollectionJob)? = nil) -> ServiceCollectionsLoader {
        ServiceCollectionsLoader(list: { jobs }, begin: { _ in jobs[0] }, page: page ?? { id, _ in self.job(id) }, retry: { id, _ in self.job(id) }, apply: apply ?? { id, _, _ in self.job(id) }, cancel: { id in var j = self.job(id); j.cancelled = true; j.failure = .cancelled; return j }, resume: { self.job($0) })
    }
    private func wait(_ predicate: @escaping () -> Bool) async throws {
        for _ in 0..<100 { if predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }; XCTFail("Expected import state was not published")
    }
    func testOpeningDoesNotFetchAndExplicitReviewIsRequiredBeforeSaving() async {
        let model = ServiceCollectionsPresentation(); var saves = 0; var pages = 0
        let snapshot = job("a", items: [item("one", position: 0), item("two", position: 1, access: .unavailable)])
        await model.prepare(loader([snapshot], page: { id, _ in pages += 1; return self.job(id) }, apply: { _, _, confirmed in XCTAssertTrue(confirmed); saves += 1; return snapshot }))
        model.select("a"); XCTAssertEqual(pages, 0); XCTAssertEqual(model.selectedItems, ["one"])
        await model.apply(); XCTAssertEqual(saves, 0)
        model.reviewed = true; await model.apply(); XCTAssertEqual(saves, 1); XCTAssertFalse(model.reviewed)
    }
    func testPaginationKeepsDuplicateOccurrencesAndDoesNotReselectUncheckedItems() async {
        let model = ServiceCollectionsPresentation()
        let first = job("a", items: [item("one", position: 0), item("two", position: 1)])
        let next = job("a", items: first.items + [item("three", position: 2)])
        await model.prepare(loader([first], page: { _, _ in next })); model.select("a"); model.selectedItems.remove("one")
        await model.loadNext(); XCTAssertEqual(model.selectedItems, ["two", "three"]); XCTAssertEqual(model.selected?.items.count, 3)
    }
    func testCancellationDiscardsLatePageAndPreservesSavedItems() async throws {
        let model = ServiceCollectionsPresentation(); var pending: CheckedContinuation<ServiceCollectionJob, Never>?
        let initial = job("a", items: [item("one", position: 0, saved: 42)])
        await model.prepare(loader([initial], page: { _, _ in await withCheckedContinuation { pending = $0 } })); model.select("a")
        let request = Task { await model.loadNext() }; try await wait { pending != nil }
        await model.cancel(); pending?.resume(returning: job("a", items: [item("late", position: 1)])); await request.value
        XCTAssertTrue(model.selected?.cancelled == true); XCTAssertFalse(model.selected?.items.contains { $0.occurrenceId == "late" } ?? false)
    }
    func testDisabledServicesAndForgedImportCannotWriteThroughTheRealSwiftBoundary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("services-ffi-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let core = try await open(config: CoreConfig(databasePath: root.appendingPathComponent("library.sqlite").path, appSupportDir: root.path, coversDir: root.appendingPathComponent("covers").path, keychainService: "services-ffi-\(UUID())"))
        let settings = try await core.serviceImportSettings(); XCTAssertEqual(settings.count, 3); XCTAssertTrue(settings.allSatisfy { !$0.enabled })
        let captured = try await core.beginServiceCollectionImport(url: "https://www.youtube.com/playlist?list=PLabcdefghijklmnop")
        let page = try await core.loadServiceCollectionPage(jobId: captured.jobId, refresh: false); XCTAssertEqual(page.failure, .disabled)
        do { _ = try await core.importServiceCollectionItems(jobId: captured.jobId, occurrenceIds: ["forged"], confirmed: true); XCTFail("Forged occurrence must not import") } catch CoreError.InvalidInput { }
        let tracks = try await core.tracksPage(pageSize: 10, offset: 0); XCTAssertTrue(tracks.items.isEmpty)
    }
}
