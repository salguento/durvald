import XCTest
@testable import Durvald

final class ClassificationTests: XCTestCase {
    private func term(_ id: Int64, name: String, kind: ClassificationKind = .genre, albums: UInt64 = 1) -> ClassificationTerm {
        ClassificationTerm(id: id, kind: kind, name: name, description: nil, releaseCount: albums,
            trackCount: 1, artistCount: 1, artworkId: nil)
    }
    @MainActor
    func testSearchKindAndStableCountOrder() {
        let state = ClassificationBrowserState()
        state.terms = [term(1, name: "Électronique"), term(2, name: "Ambient", kind: .style, albums: 3), term(3, name: "Rock", albums: 2)]
        state.query = "electronique"
        XCTAssertEqual(state.visibleTerms.map(\.id), [1])
        state.query = ""; state.byCount = true
        XCTAssertEqual(state.visibleTerms.map(\.id), [2, 3, 1])
        state.filter = .genres
        XCTAssertEqual(state.visibleTerms.map(\.id), [3, 1])
    }
    func testGenreAndStyleRoutesKeepSeparateHistoryEntries() {
        var history = LibraryNavigationHistory()
        history.navigate(to: .genres)
        history.navigate(to: .classification(.genre, 1))
        let genreEntry = history.currentEntryID
        history.navigate(to: .classification(.style, 1))
        XCTAssertEqual(history.current, .genres)
        XCTAssertNotEqual(history.currentEntryID, genreEntry)
        history.goBack()
        XCTAssertEqual(history.currentEntryID, genreEntry)
        XCTAssertEqual(history.currentRoute, .classification(.genre, 1))
        history.goForward()
        XCTAssertEqual(history.currentRoute, .classification(.style, 1))
    }
    @MainActor
    func testBridgePersistenceManualExclusionRelationsAndFullPlaybackSet() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DurvaldGenres-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let core = try await RatingIntegrationFixture.openCore(directory: directory)
        for id in [Int64(1), 5] { try await core.setClassification(target: .release, id: id, kind: .genre, names: ["Electronic"]) }
        try await core.setClassification(target: .release, id: 1, kind: .style, names: ["Ambient"])
        let terms = try await core.classificationTerms()
        let genre = try XCTUnwrap(terms.first { $0.kind == .genre })
        let style = try XCTUnwrap(terms.first { $0.kind == .style })
        try await core.setStyleGenres(styleId: style.id, genreIds: [genre.id])
        let page = try await core.classificationPage(kind: .genre, id: genre.id, query: "", offset: 0, pageSize: 1)
        XCTAssertEqual(page.totalReleases, 2); XCTAssertEqual(page.releases.count, 1)
        XCTAssertEqual(page.relatedTerms.map(\.id), [style.id])
        XCTAssertEqual(page.wellRated.map(\.id), [5])
        let all = try await core.classificationTracks(kind: .genre, id: genre.id, query: "")
        XCTAssertEqual(all.count, 2)
        try await core.setClassification(target: .track, id: 1, kind: .genre, names: [])
        let reopened = try await RatingIntegrationFixture.openCore(directory: directory)
        let links = try await reopened.classificationLinks(target: .track, id: 1)
        XCTAssertFalse(links.contains { $0.term.kind == .genre })
        XCTAssertTrue(links.contains { $0.term.kind == .style && $0.origin == "album" })
        let state = ClassificationBrowserState()
        await state.load(core: reopened, kind: .genre, id: genre.id)
        XCTAssertNil(state.error); XCTAssertEqual(state.tracks.count, 1)
    }
}
