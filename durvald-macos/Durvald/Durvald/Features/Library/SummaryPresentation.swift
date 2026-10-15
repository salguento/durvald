import Foundation

/// Domain text policies share duration/count primitives, not identical wording.
enum SummaryPresentation {
    static func music(_ summary: MusicLibrarySummary) -> String {
        let trackCount = summary.trackCount
        let durationSeconds = summary.durationSeconds
        let kind = summary.kind
        let query = summary.query
        let totalBytes = summary.totalBytes
        let isPending = summary.isPending
        let onlyFavorites = summary.onlyFavorites
        let count = "\(trackCount.formatted()) \(trackCount == 1 ? "música" : "músicas")"
        let qualifier: String
        switch kind {
        case .all: qualifier = ""
        case .selected: qualifier = trackCount == 1 ? " selecionada" : " selecionadas"
        case .search: qualifier = ""
        }
        let prefix: String
        if kind == .search {
            prefix = "Resultados para “\(query)” • " + (onlyFavorites ? "Somente favoritas • " : "")
        } else {
            prefix = onlyFavorites ? "Resultados para “Somente favoritas” • " : ""
        }
        if isPending { return "\(prefix)Pesquisando…" }
        if trackCount == 0 { return "\(prefix)Nenhum item" }
        let duration = DurationFormatter.text(seconds: UInt64(max(0, durationSeconds)), context: .library)
        let size: String
        if let totalBytes {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
            size = formatter.string(fromByteCount: totalBytes)
        } else {
            size = "—"
        }
        return "\(prefix)\(count)\(qualifier), \(duration) de duração, \(size)"
    }

    static func albums(count: Int, durationSeconds: Int, totalBytes: Int64?, query: String) -> String {
        let duration = DurationFormatter.text(seconds: UInt64(max(0, durationSeconds)), context: .albumSummary)
        let size = totalBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
        return "\(queryPrefix(query))\(count.formatted()) \(count == 1 ? "item" : "itens"), \(duration), \(size)"
    }

    static func search(results: SearchResults?, query: String, isPending: Bool) -> String {
        let prefix = queryPrefix(query)
        guard !isPending, let results else { return "\(prefix)Pesquisando…" }
        return prefix + [
            "\(results.artists.count.formatted()) \(results.artists.count == 1 ? "artista" : "artistas")",
            "\(results.releases.count.formatted()) \(results.releases.count == 1 ? "álbum" : "álbuns")",
            "\(results.tracks.count.formatted()) \(results.tracks.count == 1 ? "música" : "músicas")",
            "\(results.playlists.count.formatted()) \(results.playlists.count == 1 ? "playlist" : "playlists")"
        ].joined(separator: ", ")
    }

    static func playlists(count: Int, trackCount: UInt64, query: String) -> String {
        let playlists = "\(count.formatted()) \(count == 1 ? "playlist" : "playlists")"
        let tracks = "\(trackCount.formatted()) \(trackCount == 1 ? "música" : "músicas")"
        return "\(queryPrefix(query))\(playlists), \(tracks)"
    }

    static func artists(localCount: Int, indexedCount: Int, query: String) -> String {
        let localText = "\(localCount.formatted()) \(localCount == 1 ? "artista local" : "artistas locais")"
        let indexedText = "\(indexedCount.formatted()) \(indexedCount == 1 ? "artista indexado" : "artistas indexados")"
        return "\(queryPrefix(query))\(localText), \(indexedText)"
    }

    static func retrospective(playCount: Int, songCount: Int, durationSeconds: UInt64, query: String) -> String {
        let duration = DurationFormatter.text(seconds: durationSeconds, context: .retrospective)
        return "\(queryPrefix(query))\(playCount.formatted()) \(playCount == 1 ? "reprodução" : "reproduções"), \(songCount.formatted()) \(songCount == 1 ? "música" : "músicas"), \(duration) de reprodução"
    }

    private static func queryPrefix(_ query: String) -> String { query.isEmpty ? "" : "Resultados para “\(query)” • " }
}
