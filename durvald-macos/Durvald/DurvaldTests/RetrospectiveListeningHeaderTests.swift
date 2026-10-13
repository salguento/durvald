import Foundation
import XCTest
@testable import Durvald

final class RetrospectiveListeningHeaderTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }
    private func date(_ value: String) -> Date { try! Date.ISO8601FormatStyle().parse(value) }
    private func entry(_ id: Int64, _ date: String, _ seconds: UInt64) -> PlaybackHistoryItem {
        PlaybackHistoryItem(id: id, trackId: 1, playedAt: date, durationSeconds: seconds)
    }
    func testSumsRecordedDurationsOnlyInSelectedPeriodAndRoundsAfterAggregation() {
        let snapshot = RetrospectiveWeekSnapshot.build(entries: [
            entry(1, "2026-09-01T00:00:00Z", 59), entry(2, "2026-09-30T23:59:59Z", 61),
            entry(3, "2026-08-31T23:59:59Z", 600), entry(4, "2026-10-01T00:00:00Z", 600),
            entry(5, "invalid", 600)
        ], now: date("2026-10-13T12:00:00Z"), calendar: calendar,
           period: .monthly, referenceDate: date("2026-09-01T00:00:00Z"))
        XCTAssertEqual(snapshot.listenedSeconds, 120)
        XCTAssertEqual(snapshot.listenedMinutes, 2)
        XCTAssertEqual(snapshot.listeningSentence, "Você ouviu por 2 minutos em setembro de 2026.")
    }
    func testMinutePluralizationGroupingAndEmptyState() {
        var snapshot = RetrospectiveWeekSnapshot(period: .monthly, calendar: calendar,
            referenceDate: date("2026-02-01T00:00:00Z"))
        XCTAssertEqual(snapshot.listeningSentence, "Você ouviu por 0 minutos em fevereiro de 2026.")
        snapshot.listenedSeconds = 119
        XCTAssertEqual(snapshot.listeningAmount, "1 minuto")
        snapshot.listenedSeconds = 9_334 * 60
        XCTAssertEqual(snapshot.listeningAmount, "9.334 minutos")
    }
    func testHeaderNamesDailyWeeklyAndAnnualSelections() {
        let referenceDate = date("2026-10-13T00:00:00Z")
        XCTAssertEqual(RetrospectiveWeekSnapshot(period: .daily, calendar: calendar, referenceDate: referenceDate).listeningPeriod, "em 13 de outubro")
        XCTAssertEqual(RetrospectiveWeekSnapshot(period: .weekly, calendar: calendar, referenceDate: referenceDate).listeningPeriod, "na semana de 12 de outubro a 18 de outubro")
        XCTAssertEqual(RetrospectiveWeekSnapshot(period: .yearly, calendar: calendar, referenceDate: referenceDate).listeningPeriod, "em 2026")
    }
    func testDurationOverflowSaturatesWithoutCrashing() {
        let snapshot = RetrospectiveWeekSnapshot.build(entries: [
            entry(1, "2026-10-13T00:00:00Z", .max), entry(2, "2026-10-13T01:00:00Z", 1)
        ], now: date("2026-10-13T12:00:00Z"), calendar: calendar, period: .daily)
        XCTAssertEqual(snapshot.listenedSeconds, .max)
    }
}
