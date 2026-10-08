import Foundation

/// A query may match both the full title and a suffix-free alias. Choose the
/// earliest source record across all matching keys, not the first query key.
struct TrackTitleDurationIndex {
    private struct Match {
        let position: Int
        let duration: Double?
    }
    private var matches: [String: Match] = [:]

    init(_ tracks: [(title: String, duration: Double?)]) {
        for (position, track) in tracks.enumerated() {
            for key in PopularTrackTitle.keys(track.title) where matches[key] == nil {
                matches[key] = Match(position: position, duration: track.duration)
            }
        }
    }

    func duration(for title: String) -> Double? {
        let match = PopularTrackTitle.keys(title).compactMap { matches[$0] }.min { $0.position < $1.position }
        return match?.duration
    }
}

struct ArtistLookupSnapshot {
    var tracksByID: [Int64: Track] = [:]
    var albumsByID: [Int64: Release] = [:]
    var externalByGroupID: [String: ExternalReleaseGroup] = [:]
    var externalByLocalReleaseID: [Int64: ExternalReleaseGroup] = [:]
    private var remoteDurations: [String: TrackTitleDurationIndex] = [:]
    private var localDurations: [Int64: TrackTitleDurationIndex] = [:]

    static func build(tracks: [Track], albums: [Release], discography: [ExternalReleaseGroup],
                      details: [String: ExternalReleaseDetails]) -> Self {
        var result = Self()
        result.tracksByID = firstRecordIndex(tracks, key: { $0.id })
        result.albumsByID = firstRecordIndex(albums, key: { $0.id })
        result.externalByGroupID = firstRecordIndex(discography, key: { $0.musicbrainzId })
        result.externalByLocalReleaseID = firstRecordIndex(discography, key: { $0.localReleaseId })
        result.remoteDurations = details.mapValues {
            TrackTitleDurationIndex($0.tracks.map { (title: $0.title, duration: $0.durationSeconds.map { Double($0) }) })
        }
        // Local fallback skips invalid durations before taking the first match;
        // remote lookup takes the first match before validating its duration.
        result.localDurations = Dictionary(grouping: tracks.filter { $0.durationSeconds > 0 }, by: \.releaseId).mapValues {
            TrackTitleDurationIndex($0.map { (title: $0.title, duration: $0.durationSeconds) })
        }
        return result
    }

    func duration(for title: String, release: ExternalReleaseGroup) -> Double? {
        if let duration = remoteDurations[release.musicbrainzId]?.duration(for: title), duration > 0 { return duration }
        guard let localID = release.localReleaseId else { return nil }
        return localDurations[localID]?.duration(for: title)
    }
}

/// Same punctuation, whitespace and suffix normalization as the artist page.
enum PopularTrackTitle {
    static func keys(_ value: String) -> [String] {
        let normalized = normalized(value)
        guard !normalized.isEmpty else { return [] }

        var keys = [normalized]
        for (opening, closing) in [("(", ")"), ("[", "]")] where normalized.hasSuffix(closing) {
            guard let openingRange = normalized.range(of: opening, options: .backwards) else { continue }
            let base = String(normalized[..<openingRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !base.isEmpty, !keys.contains(base) {
                keys.append(base)
            }
        }
        return keys
    }

    private static func normalized(_ value: String) -> String {
        value
            .replacingOccurrences(of: "‐", with: "-")
            .replacingOccurrences(of: "‑", with: "-")
            .replacingOccurrences(of: "‒", with: "-")
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

}
