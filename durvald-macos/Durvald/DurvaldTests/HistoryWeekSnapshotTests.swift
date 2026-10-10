import Foundation
import XCTest
@testable import Durvald

final class HistoryWeekSnapshotTests: XCTestCase {
    private func calendar(zone: String = "UTC", firstWeekday: Int = 2) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    private func date(_ value: String) -> Date {
        try! Date.ISO8601FormatStyle().parse(value)
    }

    private func entries(_ dates: [String]) -> [PlaybackHistoryItem] {
        dates.enumerated().map {
            PlaybackHistoryItem(id: Int64($0.offset), trackId: 1, playedAt: $0.element, durationSeconds: 10)
        }
    }

    func testCalendarWeekCountsRepeatedListensAndExcludesOutsideDates() {
        let result = HistoryWeekSnapshot.build(entries: entries([
            "2026-10-05T00:00:00Z", "2026-10-05T01:00:00.000Z", "2026-10-10T10:00:00Z",
            "2026-09-28T00:00:00Z", "2026-10-04T23:59:59Z",
            "2026-09-27T23:59:59Z", "2026-10-10T12:00:01Z", "invalid"
        ]), now: date("2026-10-10T12:00:00Z"), calendar: calendar())
        XCTAssertEqual(result.days.count, 7)
        XCTAssertEqual(result.days.first?.date, date("2026-10-05T00:00:00Z"))
        XCTAssertEqual(result.currentTotal, 3)
        XCTAssertEqual(result.previousTotal, 2)
        XCTAssertEqual(result.days.map(\.current), [2, 0, 0, 0, 0, 1, 0])
        XCTAssertEqual(result.days.map(\.previous), [1, 0, 0, 0, 0, 0, 1])
        XCTAssertEqual(result.percentageChange, 50)
        XCTAssertEqual(result.trendIcon, "arrow.up")
    }

    func testFirstWeekdayAndTimeZoneDetermineWeekBoundaries() {
        let calendar = calendar(zone: "America/Sao_Paulo", firstWeekday: 1)
        let result = HistoryWeekSnapshot.build(entries: entries([
            "2026-10-04T02:59:59Z", "2026-10-04T03:00:00Z"
        ]), now: date("2026-10-10T12:00:00Z"), calendar: calendar)
        XCTAssertEqual(result.days.first?.date, date("2026-10-04T03:00:00Z"))
        XCTAssertEqual(result.currentTotal, 1)
        XCTAssertEqual(result.previousTotal, 1)
        XCTAssertEqual(result.days[0].current, 1)
        XCTAssertEqual(result.days[6].previous, 1)
        XCTAssertEqual(result.percentageChange, 0)
        XCTAssertEqual(result.trendIcon, "minus")
    }

    func testDSTAndYearChangesKeepSevenCalendarDays() {
        let result = HistoryWeekSnapshot.build(entries: entries([
            "2026-11-01T05:30:00Z", "2026-11-01T06:30:00Z", "2026-11-02T05:00:00Z"
        ]), now: date("2026-11-08T18:00:00Z"), calendar: calendar(zone: "America/New_York"))
        XCTAssertEqual(result.days.count, 7)
        XCTAssertEqual(result.days[0].current, 1)
        XCTAssertEqual(result.days[6].previous, 2)
        let newYear = HistoryWeekSnapshot.build(entries: entries(["2025-12-29T00:00:00Z"]),
            now: date("2026-01-01T12:00:00Z"), calendar: calendar())
        XCTAssertEqual(newYear.currentTotal, 1)
        XCTAssertEqual(newYear.days.first?.date, date("2025-12-29T00:00:00Z"))
    }

    func testZeroBaselineDoesNotInventPercentageAndDeclineKeepsDirection() {
        let empty = HistoryWeekSnapshot()
        XCTAssertEqual(empty.percentageChange, 0)
        XCTAssertEqual(empty.trendIcon, "minus")
        let newListens = HistoryWeekSnapshot(currentTotal: 3, previousTotal: 0)
        XCTAssertNil(newListens.percentageChange)
        XCTAssertEqual(newListens.trendIcon, "arrow.up")
        let decline = HistoryWeekSnapshot(currentTotal: 1, previousTotal: 4)
        XCTAssertEqual(decline.percentageChange, -75)
        XCTAssertEqual(decline.trendIcon, "arrow.down")
    }

    func testRankingsCountDistinctEntitiesAndAggregateListensAcrossTracks() {
        var first = Fixtures.track
        first.id = 1
        first.artistId = 10
        first.releaseId = 100
        first.title = "Primeira"
        first.artist = "Artista A"
        first.release = "Álbum A"
        var second = first
        second.id = 2
        second.title = "Segunda"
        var third = first
        third.id = 3
        third.artistId = 20
        third.releaseId = 200
        third.artist = "Artista B"
        let history = [1, 1, 2, 3].enumerated().map {
            PlaybackHistoryItem(id: Int64($0.offset), trackId: Int64($0.element),
                playedAt: "2026-10-05T12:00:00Z", durationSeconds: 10)
        } + [PlaybackHistoryItem(id: 99, trackId: 1, playedAt: "2026-09-28T12:00:00Z", durationSeconds: 10)]
        let result = HistoryWeekSnapshot.build(entries: history, now: date("2026-10-10T12:00:00Z"),
            calendar: calendar(), tracksByID: [1: first, 2: second, 3: third]).rankings
        XCTAssertEqual(result[.artists].distinctCount, 2)
        XCTAssertEqual(result[.albums].distinctCount, 2)
        XCTAssertEqual(result[.tracks].distinctCount, 3)
        XCTAssertEqual(result[.artists].top.first?.listens, 3)
        XCTAssertEqual(result[.albums].top.first?.listens, 3)
        XCTAssertEqual(result[.tracks].top.first?.listens, 2)
        XCTAssertEqual(result[.tracks].top.first?.releaseID, 100,
                       "A track name must open its album, not use the track ID as an album ID")
        XCTAssertEqual(result[.albums].top.first?.releaseID, 100)
        XCTAssertEqual(result[.artists].top.first?.artistID, 10)
        XCTAssertEqual(result[.artists].percentageChange, 100)
        XCTAssertEqual(result[.tracks].percentageChange, 200)
    }

    func testRankingFallbacksKeepUnknownTracksWithoutInventingArtistsOrAlbums() {
        var track = Fixtures.track
        track.id = 1
        track.title = "  "
        track.artist = ""
        track.release = ""
        track.artistId = 10
        track.releaseId = 100
        let history = [1, 999, 999].enumerated().map {
            PlaybackHistoryItem(id: Int64($0.offset), trackId: Int64($0.element),
                playedAt: "2026-10-05T12:00:00Z", durationSeconds: 10)
        }
        let result = HistoryWeekSnapshot.build(entries: history, now: date("2026-10-10T12:00:00Z"),
            calendar: calendar(), tracksByID: [1: track]).rankings
        XCTAssertEqual(result.unresolvedListens, 2)
        XCTAssertEqual(result[.tracks].top.first?.title, "Música #999")
        XCTAssertEqual(result[.tracks].top.first?.listens, 2)
        XCTAssertNil(result[.tracks].top.first?.releaseID,
                     "Missing track metadata must not invent a navigation destination")
        XCTAssertEqual(result[.artists].distinctCount, 1)
        XCTAssertEqual(result[.artists].top.first?.title, "Artista desconhecido")
        XCTAssertEqual(result[.albums].top.first?.title, "Álbum desconhecido")
        XCTAssertNil(result[.artists].percentageChange)
    }

    func testRankingTopFiveUsesStableTieBreaksAndDoesNotCollapseEqualNames() {
        var accumulator = HistoryRankingSnapshot.Accumulator(tracks: [:], releases: [:])
        for id: Int64 in [6, 5, 4, 3, 2, 1] {
            accumulator.record(trackID: id, isCurrent: true)
        }
        let unknown = accumulator.snapshot()[.tracks]
        XCTAssertEqual(unknown.distinctCount, 6)
        XCTAssertEqual(unknown.top.map(\.id), [1, 2, 3, 4, 5])
        var first = Fixtures.track
        first.id = 1
        first.artistId = 10
        var second = first
        second.id = 2
        second.artistId = 20
        accumulator = HistoryRankingSnapshot.Accumulator(tracks: [1: first, 2: second], releases: [:])
        accumulator.record(trackID: 2, isCurrent: true)
        accumulator.record(trackID: 1, isCurrent: true)
        XCTAssertEqual(accumulator.snapshot()[.artists].distinctCount, 2)
        XCTAssertEqual(accumulator.snapshot()[.artists].top.map(\.id), [10, 20])
    }

}
