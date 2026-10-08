import XCTest
@testable import Durvald

final class PlaylistSuggestionSnapshotTests: XCTestCase {
    func testExactPrefixAndOtherRanksPreserveAccentsCaseAndSourceTies() {
        let results = payload(tracks: [track(1, "Zebra"), track(2, "CAFÉ"), track(3, "Café da manhã"), track(4, "A café")],
                              releases: [album(2, "cafe")], artists: [Artist(id: 2, name: "Café")])
        let snapshot = PlaylistSuggestionSnapshot.build(results: results, query: "café", locale: Locale(identifier: "pt_BR"))
        XCTAssertEqual(snapshot.items.map(\.id), ["track-2", "album-2", "artist-2", "track-3", "track-4", "track-1"])
        XCTAssertEqual(snapshot.items.map(\.title), ["CAFÉ", "cafe", "Café", "Café da manhã", "A café", "Zebra"])
    }

    func testNormalizesQueryAndEachCandidateOnlyOnceAndSnapshotReadsDoNoWork() {
        let results = payload(tracks: [track(1, "A"), track(2, "B")], releases: [album(1, "C")], artists: [Artist(id: 1, name: "D")])
        var inputs: [String] = []
        let snapshot = PlaylistSuggestionSnapshot.build(results: results, query: "consulta") { value, locale in
            inputs.append(value)
            return value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
        }
        XCTAssertEqual(inputs, ["consulta", "A", "B", "C", "D"])
        for _ in 0..<100 {
            XCTAssertEqual(snapshot.items.count, 4)
            XCTAssertEqual(snapshot.items.last?.id, "artist-1")
        }
        XCTAssertEqual(inputs.count, 5)
    }

    func testBoundedTopTenMatchesPreviousFullSortAcrossLocalesAndQueries() {
        var tracks: [Track] = []
        var releases: [Release] = []
        var artists: [Artist] = []
        let titles = ["Água", "AGUA", "Água viva", "Faixa 10", "Faixa 2", "Istanbul", "İstanbul", "Été", "🙂 música", "Outro"]
        for index in 0..<200 {
            let title = titles[(index * 7) % titles.count]
            tracks.append(track(Int64(index), title))
            releases.append(album(Int64(index), title))
            artists.append(Artist(id: Int64(index), name: title))
        }
        let results = payload(tracks: tracks, releases: releases, artists: artists)
        for locale in [Locale(identifier: "pt_BR"), Locale(identifier: "tr_TR"), Locale(identifier: "en_US")] {
            for query in ["agua", "Faixa", "istanbul", "été", "", "ausente"] {
                let snapshot = PlaylistSuggestionSnapshot.build(results: results, query: query, locale: locale)
                XCTAssertEqual(snapshot.items.map(\.id), legacyIDs(results, query: query, locale: locale))
                XCTAssertEqual(snapshot.items.count, 10)
            }
        }
    }

    func testEqualKeysRetainFirstTenAndMixedTypeIDsRemainDistinct() {
        let tracks = (0..<12).map { track(Int64($0), "Mesmo") }
        let results = payload(tracks: tracks, releases: [album(0, "Mesmo")], artists: [Artist(id: 0, name: "Mesmo")])
        let snapshot = PlaylistSuggestionSnapshot.build(results: results, query: "mesmo")
        XCTAssertEqual(snapshot.items.map(\.id), (0..<10).map { "track-\($0)" })
        let mixed = PlaylistSuggestionSnapshot.build(results: payload(tracks: [tracks[0]], releases: [album(0, "Mesmo")], artists: [Artist(id: 0, name: "Mesmo")]), query: "mesmo")
        XCTAssertEqual(mixed.items.map(\.id), ["track-0", "album-0", "artist-0"])
    }

    func testEmptyAndReplacedPayloadQueryProduceIndependentSnapshots() {
        XCTAssertTrue(PlaylistSuggestionSnapshot.build(results: nil, query: "x").items.isEmpty)
        XCTAssertTrue(PlaylistSuggestionSnapshot.build(results: payload(), query: "x").items.isEmpty)
        let results = payload(tracks: [track(1, "Alpha"), track(2, "Beta")])
        let alpha = PlaylistSuggestionSnapshot.build(results: results, query: "alpha")
        let beta = PlaylistSuggestionSnapshot.build(results: results, query: "beta")
        XCTAssertEqual(alpha.items.first?.id, "track-1")
        XCTAssertEqual(beta.items.first?.id, "track-2")
        let changed = PlaylistSuggestionSnapshot.build(results: payload(tracks: [track(3, "Beta")]), query: "beta")
        XCTAssertEqual(changed.items.map(\.id), ["track-3"])
        XCTAssertEqual(alpha.items.first?.title, "Alpha")
    }

    private func legacyIDs(_ results: SearchResults, query: String, locale: Locale) -> [String] {
        let items = results.tracks.map(PlaylistSuggestionSnapshot.Item.track)
            + results.releases.map(PlaylistSuggestionSnapshot.Item.album)
            + results.artists.map(PlaylistSuggestionSnapshot.Item.artist)
        func relevance(_ item: PlaylistSuggestionSnapshot.Item) -> String {
            let title = item.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
            let term = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
            return (title == term ? "0" : title.hasPrefix(term) ? "1" : "2") + title
        }
        return items.sorted { relevance($0) < relevance($1) }.prefix(10).map(\.id)
    }

    private func payload(tracks: [Track] = [], releases: [Release] = [], artists: [Artist] = []) -> SearchResults {
        SearchResults(tracks: tracks, releases: releases, artists: artists, playlists: [])
    }

    private func track(_ id: Int64, _ title: String) -> Track {
        var value = Fixtures.track(id: id, trackNumber: 1, discNumber: 1)
        value.title = title
        return value
    }

    private func album(_ id: Int64, _ title: String) -> Release {
        var value = Fixtures.release
        value.id = id
        value.title = title
        return value
    }
}
