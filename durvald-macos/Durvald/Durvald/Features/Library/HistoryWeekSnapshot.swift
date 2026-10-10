import Foundation

struct HistoryWeekSnapshot {
    struct Day: Identifiable {
        let date: Date
        var current = 0
        var previous = 0
        var id: Date { date }
    }

    var days: [Day] = []
    var currentTotal = 0
    var previousTotal = 0
    var rankings = HistoryRankingSnapshot()

    var percentageChange: Double? {
        guard previousTotal > 0 else { return currentTotal == 0 ? 0 : nil }
        return Double(currentTotal - previousTotal) / Double(previousTotal) * 100
    }

    var trendIcon: String {
        currentTotal == previousTotal ? "minus" : currentTotal > previousTotal ? "arrow.up" : "arrow.down"
    }

    /// The current calendar week so far, compared with the complete previous week.
    /// The supplied calendar owns the first weekday and local day boundaries.
    /// Each history entry counts as a listen, including repeated tracks.
    static func build(entries: [PlaybackHistoryItem], now: Date, calendar: Calendar,
                      tracksByID: [Int64: Track] = [:], releases: [Release] = []) -> Self {
        guard let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start,
              let previousStart = calendar.date(byAdding: .day, value: -7, to: start) else { return Self() }
        var days = (0..<7).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: start).map { Day(date: $0) }
        }
        guard days.count == 7 else { return Self() }
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let whole = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
        var ranking = HistoryRankingSnapshot.Accumulator(tracks: tracksByID,
                                                         releases: firstRecordIndex(releases, key: { $0.id }))
        for entry in entries {
            guard let date = (try? fractional.parse(entry.playedAt)) ?? (try? whole.parse(entry.playedAt)),
                  date >= previousStart, date <= now else { continue }
            ranking.record(trackID: entry.trackId, isCurrent: date >= start)
            let day = calendar.startOfDay(for: date)
            if date >= start {
                let index = calendar.dateComponents([.day], from: start, to: day).day ?? -1
                if days.indices.contains(index) { days[index].current += 1 }
            } else {
                let index = calendar.dateComponents([.day], from: previousStart, to: day).day ?? -1
                if days.indices.contains(index) { days[index].previous += 1 }
            }
        }
        return Self(days: days, currentTotal: days.reduce(0) { $0 + $1.current },
                    previousTotal: days.reduce(0) { $0 + $1.previous }, rankings: ranking.snapshot())
    }
}
