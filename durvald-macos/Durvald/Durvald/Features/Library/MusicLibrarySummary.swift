import SwiftUI

struct MusicLibrarySummary: Equatable {
    enum Kind: Equatable { case all, selected, search }

    let trackCount: Int
    let durationSeconds: Int
    let kind: Kind
    let query: String
    let totalBytes: Int64?
    let isPending: Bool
    let onlyFavorites: Bool

    init(tracks: [Track], kind: Kind, query: String = "", fileSizes: [String: Int64] = [:], isPending: Bool = false, onlyFavorites: Bool = false) {
        trackCount = tracks.count
        durationSeconds = Int(tracks.reduce(0.0) { $0 + max(0, $1.durationSeconds) }.rounded())
        self.kind = kind
        self.query = query
        self.isPending = isPending
        self.onlyFavorites = onlyFavorites
        let paths = Set(tracks.map(\.filePath))
        totalBytes = paths.allSatisfy { (fileSizes[$0] ?? -1) >= 0 }
            ? paths.reduce(Int64.zero) { $0 + (fileSizes[$1] ?? 0) }
            : nil
    }

    var text: String {
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
        let duration = durationSeconds >= 3600
            ? String(format: "%d:%02d:%02d", durationSeconds / 3600, (durationSeconds / 60) % 60, durationSeconds % 60)
            : String(format: "%d:%02d", durationSeconds / 60, durationSeconds % 60)
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
}

struct MusicLibrarySummaryView: View {
    let summary: MusicLibrarySummary

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Músicas")
                .font(.headline)
            Text(summary.text)
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(maxWidth: 480, alignment: .leading)
        .help(summary.text)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("library.summary")
    }
}

enum MusicLibraryFileSizes {
    static func read(_ paths: [String]) async -> [String: Int64] {
        let task = Task.detached(priority: .utility) {
            var sizes: [String: Int64] = [:]
            for path in paths {
                guard !Task.isCancelled else { break }
                let attributes = try? FileManager.default.attributesOfItem(atPath: path)
                sizes[path] = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
            }
            return sizes
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
