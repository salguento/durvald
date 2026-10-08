import Foundation

struct PlaylistSuggestionSnapshot {
    enum Item: Identifiable {
        case track(Track)
        case album(Release)
        case artist(Artist)

        var id: String {
            switch self {
            case .track(let value): "track-\(value.id)"
            case .album(let value): "album-\(value.id)"
            case .artist(let value): "artist-\(value.id)"
            }
        }

        var title: String {
            switch self {
            case .track(let value): value.title
            case .album(let value): value.title
            case .artist(let value): value.name
            }
        }
    }

    let items: [Item]
    init(items: [Item] = []) { self.items = items }

    static func build(results: SearchResults?, query: String, locale: Locale = .current,
                      normalize: (String, Locale) -> String = {
                          $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: $1)
                      }) -> Self {
        guard let results else { return Self() }
        let term = normalize(query, locale)
        var best: [RankedItem] = []
        best.reserveCapacity(11)
        func include(_ item: Item) {
            let title = normalize(item.title, locale)
            let rank = title == term ? 0 : title.hasPrefix(term) ? 1 : 2
            let candidate = RankedItem(item: item, rank: rank, title: title)
            // Keep just the top ten in order. Strict comparison inserts after
            // equal keys, preserving tracks/albums/artists source order on ties.
            let index = best.firstIndex { candidate.precedes($0) } ?? best.endIndex
            best.insert(candidate, at: index)
            if best.count > 10 { best.removeLast() }
        }
        for track in results.tracks { include(.track(track)) }
        for album in results.releases { include(.album(album)) }
        for artist in results.artists { include(.artist(artist)) }
        return Self(items: best.map(\.item))
    }

    private struct RankedItem {
        let item: Item
        let rank: Int
        let title: String
        func precedes(_ other: Self) -> Bool {
            rank != other.rank ? rank < other.rank : title < other.title
        }
    }
}
