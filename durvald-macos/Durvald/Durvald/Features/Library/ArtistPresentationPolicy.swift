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

enum ArtistDiscographyCategory: String, CaseIterable, Identifiable {
    case album, singlesAndEPs, live, broadcast, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .album: "Álbum"
        case .singlesAndEPs: "Singles & EPs"
        case .live: "Ao vivo"
        case .broadcast: "Broadcast"
        case .other: "Outros"
        }
    }

    static func category(for release: ExternalReleaseGroup) -> Self {
        // Broadcasts may also be tagged live; keep them in their own section.
        if release.primaryType?.lowercased() == "broadcast" { return .broadcast }
        if release.secondaryTypes.contains(where: { $0.lowercased() == "live" }) { return .live }
        switch release.primaryType?.lowercased() {
        case "album": return .album
        case "single", "ep": return .singlesAndEPs
        default: return .other
        }
    }
}

enum ArtistPresentationPolicy {
    /// Uses the original release date, not a later reissue's date. Unknown
    /// dates cannot establish recency; future releases aren't out yet.
    static func latestRelease(
        in releases: [ExternalReleaseGroup],
        today: ArtistPartialDate
    ) -> ExternalReleaseGroup? {
        let cutoff = dateKey(today)
        return releases.filter {
            guard let date = $0.firstReleaseDate else { return false }
            return dateKey(date) <= cutoff
        }.sorted {
            let left = dateKey($0.firstReleaseDate!)
            let right = dateKey($1.firstReleaseDate!)
            if left != right { return left > right }
            return $0.musicbrainzId < $1.musicbrainzId
        }.first
    }

    private static func dateKey(_ date: ArtistPartialDate) -> Int {
        Int(date.year) * 10_000 + Int(date.month ?? 1) * 100 + Int(date.day ?? 1)
    }

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
