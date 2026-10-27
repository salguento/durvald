import Foundation
import SwiftUI
import XCTest
@testable import Durvald

final class RetrospectivePeriodTests: XCTestCase {
    private func calendar(zone: String = "UTC") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        calendar.firstWeekday = 2
        return calendar
    }
    private func date(_ value: String) -> Date { try! Date.ISO8601FormatStyle().parse(value) }
    private func entries(_ values: [String]) -> [PlaybackHistoryItem] {
        values.enumerated().map {
            PlaybackHistoryItem(id: Int64($0.offset), trackId: 1, playedAt: $0.element, durationSeconds: 10)
        }
    }
    func testDailyUsesLocalMidnightAndExcludesFutureListens() {
        let result = RetrospectiveWeekSnapshot.build(entries: entries([
            "2026-10-13T02:59:59Z", "2026-10-13T03:00:00Z", "2026-10-13T10:00:00Z",
            "2026-10-13T15:00:01Z", "2026-10-12T02:59:59Z", "invalid"
        ]), now: date("2026-10-13T15:00:00Z"), calendar: calendar(zone: "America/Sao_Paulo"), period: .daily)
        XCTAssertEqual(result.currentTotal, 2)
        XCTAssertEqual(result.previousTotal, 1)
        XCTAssertEqual(result.rankings[.tracks].top.first?.listens, 2)
    }
    func testMonthlyKeepsLastDayOfLongerPreviousMonth() {
        let result = RetrospectiveWeekSnapshot.build(entries: entries([
            "2026-01-31T12:00:00Z", "2026-02-01T00:00:00Z", "2026-02-10T12:00:00Z",
            "2026-02-10T12:00:01Z", "2025-12-31T23:59:59Z"
        ]), now: date("2026-02-10T12:00:00Z"), calendar: calendar(), period: .monthly)
        XCTAssertEqual(result.previousTotal, 1)
        XCTAssertEqual(result.currentTotal, 2)
    }
    func testYearlyCountsLeapDayAndYearBoundary() {
        let result = RetrospectiveWeekSnapshot.build(entries: entries([
            "2024-02-29T12:00:00Z", "2024-12-31T23:59:59Z", "2025-01-01T00:00:00Z",
            "2023-12-31T23:59:59Z", "2025-03-02T00:00:00Z"
        ]), now: date("2025-03-01T12:00:00Z"), calendar: calendar(), period: .yearly)
        XCTAssertEqual(result.previousTotal, 2)
        XCTAssertEqual(result.currentTotal, 1)
    }
    func testDailyDSTRepeatedHourCountsBothListens() {
        let result = RetrospectiveWeekSnapshot.build(entries: entries([
            "2026-11-01T05:30:00Z", "2026-11-01T06:30:00Z"
        ]), now: date("2026-11-01T18:00:00Z"), calendar: calendar(zone: "America/New_York"), period: .daily)
        XCTAssertEqual(result.currentTotal, 2)
    }
    func testTrackFilterIncludesStartAndExcludesFutureAndOtherPeriods() {
        let now = date("2026-10-13T12:00:00Z")
        let items = entries(["2026-10-12T23:59:59Z", "2026-10-13T00:00:00Z",
                             "2026-10-13T12:00:00Z", "2026-10-13T12:00:01Z", "invalid"])
        XCTAssertEqual(items.filter { RetrospectivePeriod.daily.contains($0, now: now, calendar: calendar()) }.map(\.id), [1, 2])
    }
    @MainActor
    func testSelectionPersistsWhenAppStorageAndDefaultsAreRecreated() throws {
        let suite = "RetrospectivePeriodTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let selection = AppStorage(wrappedValue: RetrospectivePeriod.defaultValue,
                                   RetrospectivePeriod.storageKey, store: defaults)
        XCTAssertEqual(selection.wrappedValue, .weekly)
        for period in RetrospectivePeriod.allCases {
            selection.wrappedValue = period
            let reopenedDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let reopenedSelection = AppStorage(wrappedValue: RetrospectivePeriod.defaultValue,
                                               RetrospectivePeriod.storageKey, store: reopenedDefaults)
            XCTAssertEqual(reopenedSelection.wrappedValue, period)
        }
    }
}
