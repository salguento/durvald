import XCTest
@testable import Durvald

@MainActor
final class SourceManagementPresentationTests: XCTestCase {
    final class Loader: SourceManaging {
        var searches = 0
        var closed = false
        var searchHandler: ((String, CatalogEntry, UInt64) async throws -> SourceSearchPage)?
        func providers() async throws -> [SourceProvider] {
            [SourceProvider(id: "one", name: "One", enabled: true), SourceProvider(id: "two", name: "Two", enabled: true)]
        }
        func setProvider(_ id: String, enabled: Bool) async throws {}
        func search(provider: String, entry: CatalogEntry, link: String?, generation: UInt64) async throws -> SourceSearchPage {
            searches += 1
            return try await searchHandler!(provider, entry, generation)
        }
        func sources(_ track: Int64) async throws -> [TrackSource] { [] }
        func matches(_ query: String) async throws -> [Track] { [] }
        func track(_ id: Int64) async throws -> Track { throw CocoaError(.fileNoSuchFile) }
        func attach(_ candidate: String, track: Int64?) async throws -> TrackSource { throw CocoaError(.fileNoSuchFile) }
        func attachLocal(_ path: String, track: Int64) async throws -> TrackSource { throw CocoaError(.fileNoSuchFile) }
        func enabled(_ source: TrackSource, value: Bool) async throws {}
        func remove(_ source: TrackSource) async throws {}
        func prefer(_ source: TrackSource, value: Bool) async throws {}
        func test(_ source: TrackSource) async throws -> SourceTestResult { throw CocoaError(.fileNoSuchFile) }
        func openURL(_ source: TrackSource) async throws -> String { "https://example.org" }
        func play(_ source: TrackSource) async throws {}
        func close() async { closed = true }
    }
    private func entry(_ id: String) -> CatalogEntry {
        CatalogEntry(reference: CatalogReference(provider: "test", kind: .recording, id: id), title: id, artistCredit: nil, versionLabel: nil, durationSeconds: nil, canonicalUrl: nil)
    }
    func testOpeningDoesNotSearchAndProviderFailureDoesNotBlockOtherResults() async {
        let model = SourceManagementPresentation(), loader = Loader()
        var pending: CheckedContinuation<Void, Never>?
        loader.searchHandler = { provider, _, generation in
            if provider == "two" { await withCheckedContinuation { pending = $0 } }
            return SourceSearchPage(provider: provider, generation: generation, candidates: [], failure: provider == "two" ? .timedOut : nil)
        }
        await model.load(entry: entry("selected"), loader: loader)
        XCTAssertEqual(loader.searches, 0)
        let task = Task { await model.search(link: nil) }
        for _ in 0..<1000 where pending == nil || model.pages["one"] == nil { await Task.yield() }
        XCTAssertNotNil(model.pages["one"])
        XCTAssertTrue(model.loading.contains("two"))
        pending?.resume(); await task.value
        XCTAssertEqual(model.pages["two"]?.failure, .timedOut)
        XCTAssertNotNil(model.pages["one"])
        XCTAssertTrue(model.loading.isEmpty)
        model.cancel()
    }
    func testChangingSelectedItemDiscardsOldResultsAndClearsAssociation() async {
        let model = SourceManagementPresentation(), old = Loader(), fresh = Loader()
        var pending: CheckedContinuation<Void, Never>?
        old.searchHandler = { provider, _, generation in
            if provider == "one" { await withCheckedContinuation { pending = $0 } }
            return SourceSearchPage(provider: provider, generation: generation, candidates: [], failure: nil)
        }
        await model.load(entry: entry("old"), loader: old)
        model.associationTrackID = 42
        let task = Task { await model.search(link: nil) }
        for _ in 0..<1000 where pending == nil { await Task.yield() }
        await model.load(entry: entry("new"), loader: fresh)
        pending?.resume(); await task.value
        XCTAssertTrue(model.pages.isEmpty)
        XCTAssertNil(model.associationTrackID)
        XCTAssertTrue(model.loading.isEmpty)
        XCTAssertEqual(fresh.searches, 0)
        model.cancel()
    }
}
