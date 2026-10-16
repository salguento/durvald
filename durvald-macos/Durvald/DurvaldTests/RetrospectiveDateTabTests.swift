import Foundation
import XCTest
@testable import Durvald

final class RetrospectiveDateTabTests: XCTestCase {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: "UTC")!
        result.firstWeekday = 2
        return result
    }
    private func date(_ value: String) -> Date { try! Date.ISO8601FormatStyle().parse(value) }
    private func entry(_ value: String, id: Int64 = 1) -> PlaybackHistoryItem {
        PlaybackHistoryItem(id: id, trackId: 1, playedAt: value, durationSeconds: 10)
    }
    func testDailyIncludesOnlyStartedDaysOfCurrentMonthInDescendingOrder() {
        let now = date("2026-10-13T12:00:00Z")
        let tabs = RetrospectiveDateTab.build(period: .daily, now: now, calendar: calendar, entries: [])
        XCTAssertEqual(tabs.count, 13)
        XCTAssertEqual(tabs.first?.title, "13")
        XCTAssertEqual(tabs.last?.title, "1")
        XCTAssertEqual(RetrospectiveDateTab.selection(in: tabs, preferredDate: nil, now: now)?.title, "13")
        XCTAssertTrue(zip(tabs, tabs.dropFirst()).allSatisfy { $0.id > $1.id })
    }
    func testDailyUsesLeapMonthAndLocalCalendarBoundaries() {
        var local = calendar
        local.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        let tabs = RetrospectiveDateTab.build(period: .daily, now: date("2024-03-01T01:00:00Z"), calendar: local, entries: [])
        XCTAssertEqual(tabs.count, 29)
        XCTAssertEqual(tabs.first?.title, "29")
        XCTAssertEqual(tabs.last?.id, date("2024-02-01T03:00:00Z"))
    }
    func testWeeklyIncludesIntersectingWeeksOnceAndUsesCalendarFirstWeekday() {
        let now = date("2026-10-13T12:00:00Z")
        let tabs = RetrospectiveDateTab.build(period: .weekly, now: now, calendar: calendar, entries: [])
        XCTAssertEqual(tabs.count, 3)
        XCTAssertEqual(tabs.first?.title, "12 - 18 out.")
        XCTAssertEqual(tabs.last?.title, "28 - 04 out.")
        XCTAssertEqual(RetrospectiveDateTab.selection(in: tabs, preferredDate: nil, now: now)?.title, "12 - 18 out.")
        XCTAssertEqual(Set(tabs.map(\.id)).count, tabs.count)
    }
    func testMonthlyIncludesOnlyStartedMonthsOfCurrentYearInDescendingOrder() {
        let tabs = RetrospectiveDateTab.build(period: .monthly, now: date("2026-10-13T12:00:00Z"), calendar: calendar, entries: [])
        XCTAssertEqual(tabs.count, 10)
        XCTAssertEqual(tabs.first?.title, "Outubro")
        XCTAssertEqual(tabs.last?.title, "Janeiro")
        XCTAssertTrue(tabs.allSatisfy { calendar.component(.year, from: $0.id) == 2026 })
    }
    func testFirstInstantOfYearKeepsCurrentPeriodsAndExcludesFuturePeriods() {
        let now = date("2026-01-01T00:00:00Z")
        for period: RetrospectivePeriod in [.daily, .weekly, .monthly] {
            let tabs = RetrospectiveDateTab.build(period: period, now: now, calendar: calendar, entries: [])
            XCTAssertEqual(tabs.count, 1)
            XCTAssertTrue(tabs.allSatisfy { $0.interval.start <= now })
            XCTAssertEqual(tabs.first?.id, period.interval(now: now, calendar: calendar)?.start)
        }
    }
    func testYearlyUsesOnlyUniqueRecordedYearsAndSelectsMostRecentIfCurrentAbsent() {
        let now = date("2026-10-13T12:00:00Z")
        let tabs = RetrospectiveDateTab.build(period: .yearly, now: now, calendar: calendar,
            entries: [entry("2024-01-01T00:00:00Z"), entry("2024-03-01T00:00:00Z"),
                      entry("2021-12-31T23:59:59Z"), entry("2027-01-01T00:00:00Z"), entry("invalid")])
        XCTAssertEqual(tabs.map(\.title), ["2024", "2021"])
        XCTAssertEqual(RetrospectiveDateTab.selection(in: tabs, preferredDate: nil, now: now)?.title, "2024")
        XCTAssertEqual(RetrospectiveDateTab.selection(in: tabs, preferredDate: tabs.last?.id, now: now)?.title, "2021")
        XCTAssertTrue(RetrospectiveDateTab.build(period: .yearly, now: now, calendar: calendar, entries: []).isEmpty)
    }
    func testSelectingPastMonthUpdatesTotalsRankingsAndTrackFilter() throws {
        let now = date("2026-10-13T12:00:00Z")
        let tabs = RetrospectiveDateTab.build(period: .monthly, now: now, calendar: calendar, entries: [])
        let september = try XCTUnwrap(tabs.first { $0.title == "Setembro" })
        let items = [entry("2026-08-31T23:59:59Z", id: 1), entry("2026-09-01T00:00:00Z", id: 2),
                     entry("2026-09-30T23:59:59Z", id: 3), entry("2026-10-01T00:00:00Z", id: 4)]
        let snapshot = RetrospectiveWeekSnapshot.build(entries: items, now: now, calendar: calendar,
            period: .monthly, referenceDate: september.id)
        XCTAssertEqual(snapshot.currentTotal, 2)
        XCTAssertEqual(snapshot.previousTotal, 1)
        XCTAssertEqual(snapshot.rankings[.tracks].top.first?.listens, 2)
        XCTAssertEqual(items.filter { RetrospectivePeriod.monthly.contains($0, now: now, calendar: calendar,
            selectedInterval: september.interval) }.map(\.id), [2, 3])
    }

    func testMonthSelectorOffersOnlyRecordedMonthsAndCurrentMonthAcrossYears() {
        let now = date("2026-10-13T12:00:00Z")
        let entries = [entry("2024-02-29T12:00:00Z"), entry("2024-02-01T12:00:00Z"),
                       entry("2025-12-01T12:00:00Z"), entry("2027-01-01T12:00:00Z"), entry("invalid")]
        for period: RetrospectivePeriod in [.daily, .weekly] {
            let navigation = RetrospectiveDateNavigation.build(period: period, now: now, calendar: calendar,
                entries: entries, preferredScope: date("2024-02-15T12:00:00Z"))
            XCTAssertEqual(navigation.scopes.map(\.title), ["Outubro de 2026", "Dezembro de 2025", "Fevereiro de 2024"])
            XCTAssertEqual(navigation.selectedScope, date("2024-02-01T00:00:00Z"))
            if period == .daily {
                XCTAssertEqual(navigation.tabs.count, 29)
                XCTAssertEqual(navigation.tabs.first?.title, "29")
                XCTAssertEqual(navigation.tabs.last?.title, "1")
            } else {
                XCTAssertEqual(navigation.tabs.first?.title, "26 - 03 mar.")
                XCTAssertEqual(navigation.tabs.last?.title, "29 - 04 fev.")
                // An overlapping January week must not change the selected February scope.
                XCTAssertEqual(navigation.tabs.last?.id, date("2024-01-29T00:00:00Z"))
            }
        }
    }

    func testYearSelectorUsesRecordedYearsAndShowsAllMonthsOfPastYear() {
        let navigation = RetrospectiveDateNavigation.build(period: .monthly,
            now: date("2026-10-13T12:00:00Z"), calendar: calendar,
            entries: [entry("2024-02-29T12:00:00Z"), entry("2021-12-31T23:59:59Z")],
            preferredScope: date("2024-06-01T00:00:00Z"))
        XCTAssertEqual(navigation.scopes.map(\.title), ["2026", "2024", "2021"])
        XCTAssertEqual(navigation.tabs.count, 12)
        XCTAssertEqual(navigation.tabs.first?.title, "Dezembro")
        XCTAssertTrue(navigation.tabs.allSatisfy { calendar.component(.year, from: $0.id) == 2024 })
    }

    func testMissingScopeFallsBackToCurrentAndAnnualHasNoExtraSelector() {
        let now = date("2026-10-13T12:00:00Z")
        let daily = RetrospectiveDateNavigation.build(period: .daily, now: now, calendar: calendar,
            entries: [], preferredScope: date("2020-01-01T00:00:00Z"))
        XCTAssertEqual(daily.scopes.map(\.title), ["Outubro de 2026"])
        XCTAssertEqual(daily.tabs.count, 13)
        let yearly = RetrospectiveDateNavigation.build(period: .yearly, now: now, calendar: calendar,
            entries: [entry("2024-02-29T12:00:00Z")], preferredScope: nil)
        XCTAssertTrue(yearly.scopes.isEmpty)
        XCTAssertNil(yearly.selectedScope)
        XCTAssertEqual(yearly.tabs.map(\.title), ["2024"])
    }

    func testHistoricalDayUsesSelectedIntervalForTotalsAndFiltering() throws {
        let now = date("2026-10-13T12:00:00Z")
        let entries = [entry("2024-02-29T12:00:00Z", id: 1), entry("2026-10-13T12:00:00Z", id: 2)]
        let navigation = RetrospectiveDateNavigation.build(period: .daily, now: now, calendar: calendar,
            entries: entries, preferredScope: date("2024-02-01T00:00:00Z"))
        let selection = try XCTUnwrap(RetrospectiveDateTab.selection(in: navigation.tabs, preferredDate: nil, now: now))
        XCTAssertEqual(selection.title, "29")
        XCTAssertEqual(entries.filter { RetrospectivePeriod.daily.contains($0, now: now,
            calendar: calendar, selectedInterval: selection.interval) }.map(\.id), [1])
        let overview = RetrospectiveWeekSnapshot.build(entries: entries, now: now, calendar: calendar,
            period: .daily, referenceDate: selection.id)
        XCTAssertEqual(overview.currentTotal, 1)
    }
}
