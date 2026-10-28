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
        durationSeconds = DurationFormatter.totalSeconds(tracks.lazy.map(\.durationSeconds))
        self.kind = kind
        self.query = query
        self.isPending = isPending
        self.onlyFavorites = onlyFavorites
        let paths = Set(tracks.compactMap(\.filePath))
        totalBytes = paths.allSatisfy { (fileSizes[$0] ?? -1) >= 0 }
            ? paths.reduce(Int64.zero) { $0 + (fileSizes[$1] ?? 0) }
            : nil
    }

    var text: String { SummaryPresentation.music(self) }
}

struct MusicLibrarySummaryView: View {
    let summary: MusicLibrarySummary

    var body: some View {
        LibrarySummaryView(title: "Músicas", text: summary.text, identifier: "library.summary")
    }
}
