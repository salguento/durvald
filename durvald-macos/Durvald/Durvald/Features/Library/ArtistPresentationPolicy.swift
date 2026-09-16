import Foundation

enum ArtistPopularRanking {
    case lastFm([ArtistPopularTrack])
    case library([Track])
    case empty

    var title: String {
        switch self {
        case .lastFm:
            "Mais populares"
        case .library, .empty:
            "Mais ouvidas nesta biblioteca"
        }
    }
}

struct ArtistBiographySelection {
    let text: String
    let source: ArtistProfileSource?
}

enum ArtistPresentationPolicy {
    static func portraitArtworkID(
        portrait: ArtistImageReference?,
        localArtworkIDs: [String?]
    ) -> String? {
        portrait?.managedPath ?? localArtworkIDs.compactMap { $0 }.first
    }

    static func biography(
        overrides: [ArtistFieldOverride],
        sources: [ArtistProfileSource]
    ) -> ArtistBiographySelection? {
        if let override = overrides.first(where: { $0.field == .biography }) {
            return override.value.map { ArtistBiographySelection(text: $0, source: nil) }
        }
        let source = sources.first {
            $0.provider == .wikipedia && $0.profile.biography != nil
        } ?? sources.first {
            $0.provider == .lastFm && $0.profile.biography != nil
        }
        guard let source, let text = source.profile.biography else { return nil }
        return ArtistBiographySelection(text: text, source: source)
    }

    static func popularRanking(
        lastFm: ArtistPopularTracks?,
        localTracks: [Track]
    ) -> ArtistPopularRanking {
        if let items = lastFm?.items, !items.isEmpty {
            return .lastFm(items)
        }
        if !localTracks.isEmpty {
            return .library(localTracks)
        }
        return .empty
    }
}
