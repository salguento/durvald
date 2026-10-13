import Foundation

enum RetrospectivePeriod: String, CaseIterable, Identifiable {
    case daily, weekly, monthly, yearly

    static let storageKey = "retrospective.period"
    static let defaultValue: Self = .weekly
    var id: Self { self }
    var title: String {
        switch self {
        case .daily: "Diário"
        case .weekly: "Semanal"
        case .monthly: "Mensal"
        case .yearly: "Anual"
        }
    }
    var currentTitle: String {
        switch self {
        case .daily: "Hoje"
        case .weekly: "Esta semana"
        case .monthly: "Este mês"
        case .yearly: "Este ano"
        }
    }
    var currentDescription: String {
        switch self {
        case .daily: "hoje"
        case .weekly: "nesta semana"
        case .monthly: "neste mês"
        case .yearly: "neste ano"
        }
    }
    var previousDescription: String {
        switch self {
        case .daily: "ontem"
        case .weekly: "semana passada"
        case .monthly: "mês passado"
        case .yearly: "ano passado"
        }
    }
    var previousContext: String {
        switch self {
        case .daily: "ontem"
        case .weekly: "na semana passada"
        case .monthly: "no mês passado"
        case .yearly: "no ano passado"
        }
    }
    var previousComparison: String {
        switch self {
        case .daily: "a ontem"
        case .weekly: "à semana passada"
        case .monthly: "ao mês passado"
        case .yearly: "ao ano passado"
        }
    }
    var previousTitle: String { previousDescription.prefix(1).uppercased() + previousDescription.dropFirst() }
    var component: Calendar.Component {
        switch self {
        case .daily: .day
        case .weekly: .weekOfYear
        case .monthly: .month
        case .yearly: .year
        }
    }
    var bucketTitle: String {
        switch self {
        case .daily: "Hora"
        case .weekly, .monthly: "Dia"
        case .yearly: "Mês"
        }
    }
    func isCurrent(referenceDate: Date?, calendar: Calendar, now: Date = Date()) -> Bool {
        guard let referenceDate, let range = interval(now: referenceDate, calendar: calendar) else { return true }
        return range.start <= now && now < range.end
    }
    func interval(now: Date, calendar: Calendar) -> DateInterval? {
        calendar.dateInterval(of: component, for: now)
    }
    func contains(_ entry: PlaybackHistoryItem, now: Date, calendar: Calendar, selectedInterval: DateInterval? = nil) -> Bool {
        guard let date = Self.playbackDate(entry.playedAt), let interval = selectedInterval ?? interval(now: now, calendar: calendar) else { return false }
        return date >= interval.start && date < interval.end && date <= now
    }
    static func playbackDate(_ value: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
            ?? (try? Date.ISO8601FormatStyle(includingFractionalSeconds: false).parse(value))
    }
}
