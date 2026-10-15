import XCTest
@testable import Durvald

final class SearchPreviewTests: XCTestCase {
    func testRecentSearchesPersistNewestFirstWithoutCaseOrAccentDuplicates() {
        var json = RecentSearchHistory.record("  Marína  ", in: "invalid json")
        json = RecentSearchHistory.record("Lua", in: json)
        json = RecentSearchHistory.record("MARINA", in: json)
        XCTAssertEqual(RecentSearchHistory.terms(in: json), ["MARINA", "Lua"])
        XCTAssertEqual(RecentSearchHistory.record(" ", in: json), json)
        for index in 0..<15 { json = RecentSearchHistory.record("termo \(index)", in: json) }
        XCTAssertEqual(RecentSearchHistory.terms(in: json), (5..<15).reversed().map { "termo \($0)" })
        XCTAssertEqual(RecentSearchHistory.terms(in: "{}"), [])
    }

    func testResultsSummaryUsesSubmittedQueryAndShowsLoadingOrActualCounts() {
        XCTAssertEqual(SummaryPresentation.search(results: nil, query: "lua", isPending: false),
                       "Resultados para “lua” • Pesquisando…")
        let empty = SearchResults(tracks: [], releases: [], artists: [], playlists: [])
        XCTAssertEqual(SummaryPresentation.search(results: empty, query: "lua", isPending: false),
                       "Resultados para “lua” • 0 artistas, 0 álbuns, 0 músicas, 0 playlists")
        let results = SearchResults(tracks: [Fixtures.track], releases: [Fixtures.release],
                                    artists: [Artist(id: 1, name: "Lua")], playlists: [])
        XCTAssertEqual(SummaryPresentation.search(results: results, query: "lua", isPending: false),
                       "Resultados para “lua” • 1 artista, 1 álbum, 1 música, 0 playlists")
        XCTAssertEqual(SummaryPresentation.search(results: results, query: "nova", isPending: true),
                       "Resultados para “nova” • Pesquisando…")
    }

    func testTermsIgnoreCaseAccentsAndRepeatedNames() {
        XCTAssertEqual(SearchPreviewItem.suggestedTerms(query: "marina", names: [
            "Marina Sena", "MARINA SENA", "Marína Lima", "Marina", "Outra pessoa"
        ]), ["Marina Sena", "Marína Lima", "marina"])
    }

    func testTermsKeepTheQueryAndExcludeUnrelatedMatches() {
        XCTAssertEqual(SearchPreviewItem.suggestedTerms(query: "  lua  ", names: ["Sol", "Lua"]), ["lua"])
        XCTAssertEqual(SearchPreviewItem.suggestedTerms(query: "  ", names: ["Sol"]), [])
    }

    func testPreviewLimitsArtistsAndKeepsTermsSeparateFromDestinations() {
        let results = SearchResults(tracks: [], releases: [], artists: [
            Artist(id: 1, name: "Marina Sena"), Artist(id: 2, name: "Marina Lima"),
            Artist(id: 3, name: "MARINA"), Artist(id: 4, name: "Marina Quatro")
        ], playlists: [])
        let items = SearchPreviewItem.build(query: "marina", results: results)
        XCTAssertEqual(items.map(\.id), ["query:Marina Sena", "query:Marina Lima", "query:marina",
                                         "artist:1", "artist:2", "artist:3"])
        XCTAssertEqual(Set(items.map(\.id)).count, items.count)
        guard case .artist(let artist) = items[3].destination else { return XCTFail("Expected artist navigation") }
        XCTAssertEqual(artist.id, 1)
    }
    func testNoPreviewItemsAreCreatedWhenTheBackendReturnsNoResults() {
        let empty = SearchResults(tracks: [], releases: [], artists: [], playlists: [])
        XCTAssertTrue(SearchPreviewItem.build(query: "inexistente", results: empty).isEmpty)
    }

}
