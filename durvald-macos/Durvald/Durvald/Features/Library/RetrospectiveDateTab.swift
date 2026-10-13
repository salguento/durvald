import Foundation

struct RetrospectiveDateTab: Identifiable, Equatable {
    let interval: DateInterval
    let title: String
    var id: Date { interval.start }

    static func build(period: RetrospectivePeriod, now: Date, calendar: Calendar,
                      entries: [PlaybackHistoryItem]) -> [Self] {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "pt_BR")
        func tab(_ date: Date) -> Self? {
            guard let interval = period.interval(now: date, calendar: calendar) else { return nil }
            let title: String
            switch period {
            case .daily:
                formatter.dateFormat = "dd/MM"
                title = formatter.string(from: interval.start)
            case .weekly:
                formatter.dateFormat = "dd/MM"
                let lastDay = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.start
                title = "\(formatter.string(from: interval.start))–\(formatter.string(from: lastDay))"
            case .monthly:
                formatter.dateFormat = "MMMM"
                title = formatter.string(from: interval.start).capitalized
            case .yearly:
                title = String(calendar.component(.year, from: interval.start))
            }
            return Self(interval: interval, title: title)
        }
        var dates: [Date] = []
        switch period {
        case .daily, .weekly:
            guard let month = calendar.dateInterval(of: .month, for: now) else { return [] }
            var day = month.start
            while day < month.end {
                dates.append(day)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
                day = next
            }
        case .monthly:
            guard let year = calendar.dateInterval(of: .year, for: now) else { return [] }
            var month = year.start
            while month < year.end {
                dates.append(month)
                guard let next = calendar.date(byAdding: .month, value: 1, to: month), next > month else { break }
                month = next
            }
        case .yearly:
            dates = entries.compactMap { RetrospectivePeriod.playbackDate($0.playedAt) }.filter { $0 <= now }
        }
        var seen = Set<Date>()
        return dates.compactMap(tab)
            .filter { $0.interval.start <= now && seen.insert($0.id).inserted }
            .sorted { $0.id > $1.id }
    }

    static func selection(in tabs: [Self], preferredDate: Date?, now: Date) -> Self? {
        if let preferredDate, let matching = tabs.first(where: { $0.id == preferredDate }) { return matching }
        return tabs.first(where: { $0.interval.start <= now && now < $0.interval.end }) ?? tabs.first
    }
}
