import Foundation

enum MusicLibrarySort: String, CaseIterable, Identifiable {
    case album, artist, albumByArtist, cloudDownload, favorite, genre, plays, rating, duration, title

    var id: Self { self }
    var label: String {
        switch self {
        case .album: "Álbum"
        case .artist: "Artista"
        case .albumByArtist: "Álbum por artista"
        case .cloudDownload: "Download na nuvem"
        case .favorite: "Favorito"
        case .genre: "Gênero"
        case .plays: "Reproduções"
        case .rating: "Avaliação"
        case .duration: "Tempo"
        case .title: "Título"
        }
    }

    var isAvailable: Bool { self != .cloudDownload && self != .genre }

    func compare(_ lhs: Track, _ rhs: Track) -> ComparisonResult {
        func numeric<Value: Comparable>(_ left: Value, _ right: Value) -> ComparisonResult {
            left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
        }
        switch self {
        case .album: return lhs.release.localizedStandardCompare(rhs.release)
        case .artist: return lhs.artist.localizedStandardCompare(rhs.artist)
        case .albumByArtist:
            let artistOrder = lhs.artist.localizedStandardCompare(rhs.artist)
            return artistOrder == .orderedSame ? lhs.release.localizedStandardCompare(rhs.release) : artistOrder
        case .favorite: return numeric(lhs.isFavorite ? 1 : 0, rhs.isFavorite ? 1 : 0)
        case .plays: return numeric(lhs.playCount, rhs.playCount)
        case .rating: return numeric(lhs.rating ?? 0, rhs.rating ?? 0)
        case .duration: return numeric(lhs.durationSeconds, rhs.durationSeconds)
        case .title: return lhs.title.localizedStandardCompare(rhs.title)
        case .cloudDownload, .genre: return lhs.title.localizedStandardCompare(rhs.title)
        }
    }
}
