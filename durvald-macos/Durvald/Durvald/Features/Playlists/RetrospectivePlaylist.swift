import Foundation

struct RetrospectivePlaylistDraft: Equatable {
    let period: RetrospectivePeriod
    let interval: DateInterval

    var identity: String {
        "\(period.rawValue):\(Int64(interval.start.timeIntervalSince1970)):\(Int64(interval.end.timeIntervalSince1970))"
    }

    var isCurrent: Bool { interval.start <= Date() && Date() < interval.end }
    var request: ReplayRequest {
        let scope: ReplayPeriod
        switch period {
        case .daily: scope = .daily
        case .weekly: scope = .weekly
        case .monthly: scope = .monthly
        case .yearly: scope = .yearly
        }
        return ReplayRequest(period: scope, startAt: Int64(interval.start.timeIntervalSince1970),
                             endAt: Int64(interval.end.timeIntervalSince1970))
    }
    var title: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        switch period {
        case .daily: formatter.dateFormat = "d 'de' MMMM 'de' yyyy"
        case .weekly: formatter.dateFormat = "d MMM yyyy"
        case .monthly: formatter.dateFormat = "MMMM 'de' yyyy"
        case .yearly: formatter.dateFormat = "yyyy"
        }
        let label = period == .weekly
            ? "\(formatter.string(from: interval.start)) – \(formatter.string(from: interval.end.addingTimeInterval(-1)))"
            : formatter.string(from: interval.start)
        return "Replay · \(label)"
    }

}

struct RetrospectivePlaylistConfiguration: Codable, Equatable {
    let version: Int
    let period: String
    let startAt: Int64
    let endAt: Int64
    let mode: String
    let closeAutomatically: Bool
    let artworkBase64: String?

    enum CodingKeys: String, CodingKey {
        case version, period, mode
        case startAt = "start_at", endAt = "end_at", closeAutomatically = "close_automatically"
        case artworkBase64 = "artwork_base64"
    }

    static func read(_ playlist: Playlist) -> Self? {
        guard let rule = playlist.smartDefinition?.rules.first, rule.field == "retrospective" else { return nil }
        return try? JSONDecoder().decode(Self.self, from: Data(rule.value.utf8))
    }
}
