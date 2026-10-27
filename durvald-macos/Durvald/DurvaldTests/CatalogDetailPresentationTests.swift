import XCTest
@testable import Durvald

@MainActor
final class CatalogDetailPresentationTests: XCTestCase {
    private final class Loader: CatalogDetailLoading {
        var handler: (CatalogDetailRequest) async throws -> CatalogDetailPage
        var saved: CatalogSelection?
        var saveHandler: ((CatalogEntry) async throws -> CatalogSelection)?
        var saves = 0
        init(_ handler: @escaping (CatalogDetailRequest) async throws -> CatalogDetailPage) { self.handler = handler }
        func page(_ request: CatalogDetailRequest) async throws -> CatalogDetailPage { try await handler(request) }
        func selection(_ reference: CatalogReference) async throws -> CatalogSelection? { saved }
        func save(_ entry: CatalogEntry) async throws -> CatalogSelection {
            saves += 1
            let value = if let saveHandler { try await saveHandler(entry) } else { CatalogSelection(entry: entry, localArtistId: 7, savedAt: 1) }
            saved = value; return value
        }
        func followed(_ artistID: Int64) async throws -> Bool { false }
        func follow(_ entry: CatalogEntry, followed: Bool) async throws -> CatalogSelection { try await save(entry) }
        func hasListenIntent(_ entry: CatalogEntry) async throws -> Bool { false }
        func listen(_ entry: CatalogEntry, artist: CatalogEntry) async throws {}
        func close() async {}
    }
    private func entry(_ id: String = "old") -> CatalogEntry { CatalogEntry(reference: CatalogReference(provider: "musicbrainz", kind: .artist, id: id), title: id, artistCredit: nil, versionLabel: nil, durationSeconds: nil, canonicalUrl: nil) }
    private func page(_ request: CatalogDetailRequest, failure: CatalogFailure? = nil) -> CatalogDetailPage {
        CatalogDetailPage(reference: request.reference, section: request.section, generation: request.generation, items: request.section == .basic ? [entry(request.reference.id)] : [], profile: nil, image: nil, attribution: nil, nextCursor: nil, failure: failure, retryAfterSeconds: nil, fromCache: false)
    }
    func testBasicPublishesWhileCoverWaitsAndOpeningDoesNotSave() async {
        let model = CatalogDetailPresentation()
        var cover: CheckedContinuation<Void, Never>?
        let loader = Loader { request in
            if request.section == .cover { await withCheckedContinuation { cover = $0 } }
            return self.page(request, failure: request.section == .profile ? .unavailable : nil)
        }
        let task = Task { await model.run(entry: entry(), language: "und", loader: loader) }
        for _ in 0..<100 where model.blocks[.basic]?.page == nil || cover == nil { await Task.yield() }
        XCTAssertEqual(model.entry?.title, "old")
        XCTAssertNotNil(model.blocks[.basic]?.page)
        XCTAssertEqual(loader.saves, 0)
        cover?.resume(); await task.value
        XCTAssertNotNil(model.blocks[.profile]?.error)
        XCTAssertNotNil(model.blocks[.basic]?.page)
        await model.save()
        XCTAssertEqual(loader.saves, 1)
        XCTAssertNotNil(model.selection)
    }
    func testStaleBlockAndPendingSaveCannotReplaceNewSelection() async {
        let model = CatalogDetailPresentation()
        var cover: CheckedContinuation<Void, Never>?
        let old = Loader { request in
            if request.section == .cover { await withCheckedContinuation { cover = $0 } }
            return self.page(request)
        }
        let first = Task { await model.run(entry: entry(), language: "und", loader: old) }
        for _ in 0..<100 where cover == nil { await Task.yield() }
        var save: CheckedContinuation<Void, Never>?
        old.saveHandler = { entry in await withCheckedContinuation { save = $0 }; return CatalogSelection(entry: entry, localArtistId: 7, savedAt: 1) }
        let saving = Task { await model.save() }
        for _ in 0..<100 where save == nil { await Task.yield() }
        let fresh = Loader { self.page($0) }
        await model.run(entry: entry("new"), language: "und", loader: fresh)
        cover?.resume(); save?.resume(); await first.value; await saving.value
        XCTAssertEqual(model.entry?.title, "new")
        XCTAssertNil(model.selection)
        XCTAssertFalse(model.saving)
    }
    func testFailedSectionRetriesWithoutErasingBasicIdentity() async {
        let model = CatalogDetailPresentation()
        var attempts = 0
        let loader = Loader { request in
            if request.section == .profile { attempts += 1 }
            return self.page(request, failure: request.section == .profile && attempts == 1 ? .timedOut : nil)
        }
        await model.run(entry: entry(), language: "und", loader: loader)
        XCTAssertNotNil(model.blocks[.profile]?.error)
        await model.retry(.profile)
        XCTAssertNil(model.blocks[.profile]?.error)
        XCTAssertEqual(model.entry?.reference.id, "old")
        XCTAssertEqual(loader.saves, 0)
    }
}
