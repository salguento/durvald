import Foundation

struct RetrospectiveWeekSnapshot {
    struct Day: Identifiable {
        let date: Date
        var current = 0
        var previous = 0
        var id: Date { date }
    }

    var days: [Day] = []
    var currentTotal = 0
    var previousTotal = 0
    var rankings = RetrospectiveRankingSnapshot()
    var period: RetrospectivePeriod = .weekly
    var calendar = Calendar.current
    var referenceDate: Date?
    var listenedSeconds: UInt64 = 0
    var listenedMinutes: UInt64 { listenedSeconds / 60 }
    var listeningAmount: String {
        let amount = listenedMinutes.formatted(.number.locale(Locale(identifier: "pt_BR")))
        return "\(amount) \(listenedMinutes == 1 ? "minuto" : "minutos")"
    }
    var listeningPeriod: String {
        let date = referenceDate ?? days.first?.date ?? Date()
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "pt_BR")
        switch period {
        case .daily:
            formatter.dateFormat = "d 'de' MMMM"
            return "em \(formatter.string(from: date))"
        case .weekly:
            guard let interval = period.interval(now: date, calendar: calendar),
                  let lastDay = calendar.date(byAdding: .day, value: -1, to: interval.end) else { return "nesta semana" }
            formatter.dateFormat = "d 'de' MMMM"
            return "na semana de \(formatter.string(from: interval.start)) a \(formatter.string(from: lastDay))"
        case .monthly:
            formatter.dateFormat = "MMMM 'de' yyyy"
            return "em \(formatter.string(from: date))"
        case .yearly:
            return "em \(calendar.component(.year, from: date))"
        }
    }
    var listeningSentence: String { "Você ouviu por \(listeningAmount) \(listeningPeriod)." }
    private var isCurrent: Bool { period.isCurrent(referenceDate: referenceDate, calendar: calendar) }
    var currentTitle: String { isCurrent ? period.currentTitle : "Período selecionado" }
    var currentDescription: String { isCurrent ? period.currentDescription : "no período selecionado" }
    var previousTitle: String { isCurrent ? period.previousTitle : "Período anterior" }
    var previousDescription: String { isCurrent ? period.previousDescription : "período anterior" }
    var previousContext: String { isCurrent ? period.previousContext : "no período anterior" }
    var previousComparison: String { isCurrent ? period.previousComparison : "ao período anterior" }

    var percentageChange: Double? {
        guard previousTotal > 0 else { return currentTotal == 0 ? 0 : nil }
        return Double(currentTotal - previousTotal) / Double(previousTotal) * 100
    }

    var trendIcon: String {
        currentTotal == previousTotal ? "minus" : currentTotal > previousTotal ? "arrow.up" : "arrow.down"
    }

    /// Compare the current calendar period so far with the complete previous period.
    /// Local calendar components handle time zones, DST and unequal month lengths.
    static func build(entries: [PlaybackHistoryItem], now: Date, calendar: Calendar,
                      tracksByID: [Int64: Track] = [:], releases: [Release] = [],
                      period: RetrospectivePeriod = .weekly, referenceDate: Date? = nil) -> Self {
        guard let interval = period.interval(now: referenceDate ?? now, calendar: calendar),
              let previousStart = calendar.date(byAdding: period.component, value: -1, to: interval.start) else {
            return Self(period: period, calendar: calendar, referenceDate: referenceDate)
        }
        let start = interval.start
        let bucketCount: Int
        let bucketComponent: Calendar.Component
        switch period {
        case .daily: bucketCount = 24; bucketComponent = .hour
        case .weekly: bucketCount = 7; bucketComponent = .day
        case .monthly:
            bucketCount = max(calendar.range(of: .day, in: .month, for: start)?.count ?? 0,
                              calendar.range(of: .day, in: .month, for: previousStart)?.count ?? 0)
            bucketComponent = .day
        case .yearly: bucketCount = 12; bucketComponent = .month
        }
        var days = (0..<bucketCount).compactMap { offset in
            calendar.date(byAdding: bucketComponent, value: offset, to: start).map { Day(date: $0) }
        }
        var listenedSeconds: UInt64 = 0
        var ranking = RetrospectiveRankingSnapshot.Accumulator(tracks: tracksByID,
            releases: firstRecordIndex(releases, key: { $0.id }))
        for entry in entries {
            guard let date = RetrospectivePeriod.playbackDate(entry.playedAt),
                  date >= previousStart, date <= now, date < interval.end else { continue }
            let isCurrent = date >= start
            let index: Int
            switch period {
            case .daily: index = calendar.component(.hour, from: date)
            case .weekly:
                index = calendar.dateComponents([.day], from: isCurrent ? start : previousStart,
                                                 to: calendar.startOfDay(for: date)).day ?? -1
            case .monthly: index = calendar.component(.day, from: date) - 1
            case .yearly: index = calendar.component(.month, from: date) - 1
            }
            guard days.indices.contains(index) else { continue }
            ranking.record(trackID: entry.trackId, isCurrent: isCurrent, durationSeconds: entry.durationSeconds)
            if isCurrent {
                days[index].current += 1
                let sum = listenedSeconds.addingReportingOverflow(entry.durationSeconds)
                listenedSeconds = sum.overflow ? .max : sum.partialValue
            } else {
                days[index].previous += 1
            }
        }
        return Self(days: days, currentTotal: days.reduce(0) { $0 + $1.current },
                    previousTotal: days.reduce(0) { $0 + $1.previous }, rankings: ranking.snapshot(),
                    period: period, calendar: calendar, referenceDate: referenceDate, listenedSeconds: listenedSeconds)
    }

    func bucketLabel(_ day: Day, abbreviated: Bool = false) -> String {
        let index = days.firstIndex(where: { $0.id == day.id }) ?? 0
        switch period {
        case .daily: return String(format: "%02d", index) + "h"
        case .monthly: return String(index + 1)
        case .weekly, .yearly:
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = Locale(identifier: "pt_BR")
            formatter.dateFormat = period == .weekly ? (abbreviated ? "EEE" : "EEEE") : (abbreviated ? "MMM" : "MMMM")
            let label = formatter.string(from: day.date).replacingOccurrences(of: ".", with: "")
            return label.prefix(1).uppercased() + label.dropFirst()
        }
    }
}
