import XCTest
@testable import Durvald

@MainActor
final class CatalogSearchPresentationTests: XCTestCase {
    private final class Loader: CatalogSearchLoading {
        var requests: [(CatalogProvider, CatalogQuery)] = []
        var handler: (CatalogProvider, CatalogQuery) async throws -> CatalogPage
        init(_ handler: @escaping (CatalogProvider, CatalogQuery) async throws -> CatalogPage) { self.handler = handler }
        func page(provider: CatalogProvider, query: CatalogQuery) async throws -> CatalogPage {
            requests.append((provider, query))
            return try await handler(provider, query)
        }
        func cancel(generation: UInt64) async {}
        func close() async {}
    }
    private func page(_ provider: CatalogProvider, _ query: CatalogQuery, title: String = "Result",
                      cursor: String? = nil, cached: Bool = false, failure: CatalogFailure? = nil) -> CatalogPage {
        CatalogPage(provider: provider, generation: query.generation,
                    items: failure == nil ? [CatalogItem(provider: provider, kind: .artist, id: title,
                        localId: provider == .library ? 1 : nil, title: title, artistCredit: nil,
                        versionLabel: nil, durationSeconds: nil, canonicalUrl: nil)] : [],
                    nextCursor: cursor, failure: failure, retryAfterSeconds: nil, fromCache: cached)
    }
    func testLocalResultsPublishBeforeRemoteAndCacheHitAvoidsNetwork() async {
        let model = CatalogSearchPresentation()
        var release: CheckedContinuation<Void, Never>?
        let loader = Loader { provider, query in
            if provider == .musicBrainz {
                await withCheckedContinuation { release = $0 }
                return self.page(provider, query, cached: true)
            }
            return self.page(provider, query)
        }
        let task = Task { await model.run(query: "Artist", filter: .all, language: "pt", loader: loader) }
        for _ in 0..<100 where model.library.items.isEmpty || release == nil { await Task.yield() }
        XCTAssertEqual(model.library.items.count, 1)
        XCTAssertTrue(model.musicBrainz.items.isEmpty)
        release?.resume()
        await task.value
        XCTAssertTrue(model.musicBrainz.fromCache)
        XCTAssertEqual(loader.requests.filter { $0.0 == .musicBrainz }.count, 1)
        XCTAssertTrue(loader.requests.first { $0.0 == .musicBrainz }!.1.cacheOnly)
    }
    func testOldResultCannotReplaceNewSubmission() async {
        let model = CatalogSearchPresentation()
        var release: CheckedContinuation<Void, Never>?
        let old = Loader { provider, query in
            if provider == .musicBrainz { await withCheckedContinuation { release = $0 } }
            return self.page(provider, query, title: "Old", cached: true)
        }
        let first = Task { await model.run(query: "Old", filter: .artists, language: "und", loader: old) }
        for _ in 0..<100 where release == nil { await Task.yield() }
        let fresh = Loader { provider, query in self.page(provider, query, title: "New", cached: true) }
        await model.run(query: "New", filter: .artists, language: "und", loader: fresh)
        release?.resume()
        await first.value
        XCTAssertEqual(model.library.items.map(\.title), ["New"])
        XCTAssertEqual(model.musicBrainz.items.map(\.title), ["New"])
    }
    func testProviderFailureRetryAndPaginationPreserveLocalResultsAndDeduplicate() async {
        let model = CatalogSearchPresentation()
        var remoteAttempt = 0
        let loader = Loader { provider, query in
            if provider == .library { return self.page(provider, query, title: "Local") }
            remoteAttempt += 1
            if remoteAttempt == 1 { return self.page(provider, query, failure: .timedOut) }
            return self.page(provider, query, cursor: query.cursor == nil ? "next" : nil, cached: true)
        }
        await model.run(query: "Music", filter: .all, language: "und", loader: loader)
        XCTAssertEqual(model.musicBrainz.failure, .timedOut)
        XCTAssertEqual(model.library.items.first?.title, "Local")
        await model.retry(.musicBrainz)
        XCTAssertNil(model.musicBrainz.failure)
        XCTAssertEqual(model.musicBrainz.nextCursor, "next")
        await model.loadMore(.musicBrainz)
        XCTAssertEqual(model.musicBrainz.items.count, 1)
        XCTAssertNil(model.musicBrainz.nextCursor)
        XCTAssertEqual(model.library.items.first?.title, "Local")
    }
}
