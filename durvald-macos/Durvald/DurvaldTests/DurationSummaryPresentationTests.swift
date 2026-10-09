import XCTest
@testable import Durvald

final class DurationSummaryPresentationTests: XCTestCase {
    func testContextsPreserveClockAndProsePoliciesAtHourBoundary() {
        XCTAssertEqual(DurationFormatter.text(3599.5), "60:00")
        XCTAssertEqual(DurationFormatter.text(seconds: 3600, context: .library), "1:00:00")
        XCTAssertEqual(DurationFormatter.text(seconds: 3661, context: .history), "1:01:01")
        XCTAssertEqual(DurationFormatter.text(seconds: 3661, context: .track), "61:01")
        XCTAssertEqual(DurationFormatter.text(seconds: 3661, context: .albumSummary), "1 hora, 1 minuto")
        XCTAssertEqual(DurationFormatter.text(seconds: 7200, context: .albumSummary), "2 horas, 0 minutos")
        XCTAssertEqual(DurationFormatter.text(seconds: 3600, context: .albumHeader), "1 h")
        XCTAssertEqual(DurationFormatter.text(seconds: 3661, context: .albumHeader), "1 h 1 min")
        XCTAssertEqual(DurationFormatter.text(seconds: 59, context: .albumHeader), "0 min")
    }

    func testTrackUnknownAndPlayerTruncationRemainDistinct() {
        XCTAssertEqual(DurationFormatter.text(59.9), "1:00")
        XCTAssertEqual(DurationFormatter.text(59.9, rounding: .towardZero), "0:59")
        for value: Double? in [nil, 0, -5, .nan, .infinity, -.infinity, Double(Int.max)] {
            XCTAssertEqual(DurationFormatter.text(value), "0:00")
            XCTAssertEqual(DurationFormatter.text(value, unknown: "—"), "—")
        }
    }

    func testAggregateRoundsOnceIgnoresInvalidDurationsAndSaturates() {
        XCTAssertEqual(DurationFormatter.totalSeconds([0.4, 0.4, -1, .nan, .infinity]), 1)
        XCTAssertEqual(DurationFormatter.totalSeconds([Double.greatestFiniteMagnitude, 1]), Int.max)
        let seconds: UInt64 = DurationFormatter.totalSeconds([UInt64.max, 1])
        XCTAssertEqual(seconds, UInt64.max)
        XCTAssertEqual(DurationFormatter.text(seconds: seconds, context: .history), "5124095576030431:00:15")
    }

    func testMusicSummaryPreservesSelectionPendingAndFavoriteSearchWording() {
        var track = Fixtures.track
        track.durationSeconds = 3661
        XCTAssertEqual(MusicLibrarySummary(tracks: [track], kind: .selected).text,
                       "1 música selecionada, 1:01:01 de duração, —")
        XCTAssertEqual(MusicLibrarySummary(tracks: [], kind: .search, query: "rock", isPending: true, onlyFavorites: true).text,
                       "Resultados para “rock” • Somente favoritas • Pesquisando…")
        XCTAssertEqual(MusicLibrarySummary(tracks: [], kind: .all, onlyFavorites: true).text,
                       "Resultados para “Somente favoritas” • Nenhum item")
        track.durationSeconds = .nan
        XCTAssertEqual(MusicLibrarySummary(tracks: [track], kind: .all).durationSeconds, 0)
    }

    func testDomainSummariesRetainCountsQueryAndDistinctDurationWording() {
        XCTAssertEqual(SummaryPresentation.albums(count: 1, durationSeconds: 3661, totalBytes: nil, query: "album"),
                       "Resultados para “album” • 1 item, 1 hora, 1 minuto, —")
        XCTAssertEqual(SummaryPresentation.history(playCount: 3, songCount: 2, durationSeconds: 3661, query: "rock"),
                       "Resultados para “rock” • 3 reproduções, 2 músicas, 1:01:01 de reprodução")
        XCTAssertEqual(SummaryPresentation.history(playCount: 1, songCount: 1, durationSeconds: 60, query: ""),
                       "1 reprodução, 1 música, 1:00 de reprodução")
        XCTAssertEqual(SummaryPresentation.artists(localCount: 1, indexedCount: 2, query: ""),
                       "1 artista local, 2 artistas indexados")
    }
}
