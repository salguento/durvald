import XCTest
@testable import Durvald

final class SearchPreviewTests: XCTestCase {
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
