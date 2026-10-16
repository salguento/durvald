import Foundation

struct RetrospectiveDateTab: Identifiable, Equatable {
    let interval: DateInterval
    let title: String
    var id: Date { interval.start }

    static func build(period: RetrospectivePeriod, now: Date, calendar: Calendar,
                      entries: [PlaybackHistoryItem], referenceDate: Date? = nil) -> [Self] {
        let reference = referenceDate ?? now
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "pt_BR")
        func tab(_ date: Date) -> Self? {
            guard let interval = period.interval(now: date, calendar: calendar) else { return nil }
            let title: String
            switch period {
            case .daily:
                formatter.dateFormat = "d"
                title = formatter.string(from: interval.start)
            case .weekly:
                formatter.dateFormat = "dd"
                let lastDay = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.start
                let first = formatter.string(from: interval.start)
                formatter.dateFormat = "dd MMM"
                title = "\(first) - \(formatter.string(from: lastDay))"
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
            guard let month = calendar.dateInterval(of: .month, for: reference) else { return [] }
            var day = month.start
            while day < month.end {
                dates.append(day)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
                day = next
            }
        case .monthly:
            guard let year = calendar.dateInterval(of: .year, for: reference) else { return [] }
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

/// Available calendar containers and their tabs are prepared together off the
/// main thread. The selected month stays independent of overlapping week starts.
struct RetrospectiveDateNavigation {
    struct Scope: Identifiable, Equatable {
        let id: Date
        let title: String
    }

    var scopes: [Scope] = []
    var selectedScope: Date?
    var tabs: [RetrospectiveDateTab] = []

    static func build(period: RetrospectivePeriod, now: Date, calendar: Calendar,
                      entries: [PlaybackHistoryItem], preferredScope: Date?) -> Self {
        guard period != .yearly else {
            return Self(tabs: RetrospectiveDateTab.build(period: period, now: now,
                                                         calendar: calendar, entries: entries))
        }
        let component: Calendar.Component = period == .monthly ? .year : .month
        let dates = entries.compactMap { RetrospectivePeriod.playbackDate($0.playedAt) }
            .filter { $0 <= now } + [now]
        let starts = Set(dates.compactMap { calendar.dateInterval(of: component, for: $0)?.start })
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = period == .monthly ? "yyyy" : "MMMM 'de' yyyy"
        let scopes = starts.sorted(by: >).map {
            Scope(id: $0, title: formatter.string(from: $0).prefix(1).uppercased()
                + formatter.string(from: $0).dropFirst())
        }
        let preferred = preferredScope.flatMap { calendar.dateInterval(of: component, for: $0)?.start }
        let selected = scopes.first { $0.id == preferred } ?? scopes.first
        return Self(scopes: scopes, selectedScope: selected?.id,
                    tabs: RetrospectiveDateTab.build(period: period, now: now, calendar: calendar,
                                                     entries: entries, referenceDate: selected?.id))
    }
}
