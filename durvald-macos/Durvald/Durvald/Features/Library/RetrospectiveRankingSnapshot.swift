import Foundation

/// Prepared together with the daily totals; rendering never groups or sorts history.
struct RetrospectiveRankingSnapshot {
    enum Category: String, CaseIterable, Identifiable {
        case artists, albums, tracks
        var id: Self { self }
        var title: String {
            switch self {
            case .artists: "Artistas"
            case .albums: "Álbuns"
            case .tracks: "Músicas"
            }
        }
        var symbol: String {
            switch self {
            case .artists: "mic.fill"
            case .albums: "square.stack.fill"
            case .tracks: "music.note"
            }
        }
        var topLabel: String {
            switch self {
            case .artists: "Artista mais ouvido"
            case .albums: "Álbum mais ouvido"
            case .tracks: "Música mais ouvida"
            }
        }
    }

    struct Item: Identifiable {
        let id: Int64
        let title: String
        let subtitle: String?
        var artworkID: String?
        var listens = 1
        var listenedSeconds: UInt64 = 0
        var listenedMinutes: UInt64 { listenedSeconds / 60 }
        var minutesLabel: String {
            "\(listenedMinutes.formatted(.number.locale(Locale(identifier: "pt_BR")))) \(listenedMinutes == 1 ? "minuto" : "minutos")"
        }
        var artistID: Int64? = nil
        var releaseID: Int64? = nil
    }

    struct Ranking {
        var distinctCount = 0
        var previousDistinctCount = 0
        var top: [Item] = []
        var percentageChange: Double? {
            guard previousDistinctCount > 0 else { return distinctCount == 0 ? 0 : nil }
            return Double(distinctCount - previousDistinctCount) / Double(previousDistinctCount) * 100
        }
        var trendIcon: String {
            distinctCount == previousDistinctCount ? "minus" : distinctCount > previousDistinctCount ? "arrow.up" : "arrow.down"
        }
    }

    var rankings: [Category: Ranking] = [:]
    var unresolvedListens = 0
    subscript(category: Category) -> Ranking { rankings[category] ?? Ranking() }

    struct Accumulator {
        let tracks: [Int64: Track]
        let releases: [Int64: Release]
        private var current: [Category: [Int64: Item]] = [:]
        private var previous: [Category: Set<Int64>] = [:]
        private var unresolved = 0

        init(tracks: [Int64: Track], releases: [Int64: Release]) {
            self.tracks = tracks
            self.releases = releases
        }

        mutating func record(trackID: Int64, isCurrent: Bool, durationSeconds: UInt64 = 0) {
            guard let track = tracks[trackID] else {
                if isCurrent { unresolved += 1 }
                add(.tracks, item: Item(id: trackID, title: "Música #\(trackID)",
                                       subtitle: "Metadados indisponíveis", artworkID: nil), isCurrent: isCurrent, durationSeconds: durationSeconds)
                return
            }
            let artist = nonempty(track.artist, fallback: "Artista desconhecido")
            let release = releases[track.releaseId]
            let cover = release?.artworkId ?? track.artworkId
            add(.tracks, item: Item(id: track.id, title: nonempty(track.title, fallback: "Música #\(track.id)"),
                                   subtitle: artist, artworkID: cover,
                                   artistID: track.artistId > 0 ? track.artistId : nil,
                                   releaseID: track.releaseId > 0 ? track.releaseId : nil), isCurrent: isCurrent, durationSeconds: durationSeconds)
            if track.artistId > 0 {
                add(.artists, item: Item(id: track.artistId, title: artist, subtitle: nil, artworkID: cover,
                                        artistID: track.artistId),
                    isCurrent: isCurrent, durationSeconds: durationSeconds)
            }
            if track.releaseId > 0 {
                add(.albums, item: Item(id: track.releaseId,
                                       title: nonempty(release?.title ?? track.release, fallback: "Álbum desconhecido"),
                                       subtitle: nonempty(release?.artist ?? track.artist, fallback: "Artista desconhecido"),
                                       artworkID: cover,
                                       artistID: (release?.artistId ?? track.artistId) > 0 ? (release?.artistId ?? track.artistId) : nil,
                                       releaseID: track.releaseId), isCurrent: isCurrent, durationSeconds: durationSeconds)
            }
        }

        private mutating func add(_ category: Category, item: Item, isCurrent: Bool, durationSeconds: UInt64) {
            guard isCurrent else {
                previous[category, default: []].insert(item.id)
                return
            }
            if var existing = current[category]?[item.id] {
                existing.listens += 1
                let sum = existing.listenedSeconds.addingReportingOverflow(durationSeconds)
                existing.listenedSeconds = sum.overflow ? .max : sum.partialValue
                existing.artworkID = existing.artworkID ?? item.artworkID
                current[category, default: [:]][item.id] = existing
            } else {
                var item = item
                item.listenedSeconds = durationSeconds
                current[category, default: [:]][item.id] = item
            }
        }

        func snapshot() -> RetrospectiveRankingSnapshot {
            var result = RetrospectiveRankingSnapshot(unresolvedListens: unresolved)
            for category in Category.allCases {
                let items = current[category] ?? [:]
                let top = items.values.sorted {
                    if category != .tracks && $0.listenedSeconds != $1.listenedSeconds { return $0.listenedSeconds > $1.listenedSeconds }
                    if $0.listens != $1.listens { return $0.listens > $1.listens }
                    let comparison = $0.title.localizedStandardCompare($1.title)
                    return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
                }
                result.rankings[category] = Ranking(distinctCount: items.count,
                    previousDistinctCount: previous[category]?.count ?? 0, top: Array(top.prefix(category == .tracks ? 8 : 5)))
            }
            return result
        }

        private func nonempty(_ text: String, fallback: String) -> String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? fallback : trimmed
        }
    }
}
