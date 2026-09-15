//
//  HistoryView.swift
//  Durvald
//
//  Created by Humberto Salguento on 21/08/26.
//

import SwiftUI

struct HistoryView: View {
    @Environment(DurvaldCoreStore.self) private var store
    private static let playbackTimestamp = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true
    )

    var body: some View {
        List(store.history, id: \.id) { item in
            let track = store.tracks.first { $0.id == item.trackId }

            VStack(alignment: .leading) {
                Text(track?.title ?? "Música #\(item.trackId)")
                    .activeTrackTitle(trackID: item.trackId)
                Text(formattedPlaybackDate(item.playedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .task {
                await store.loadMoreHistory(ifNeededAfter: item.id)
            }
        }
        .preservesLibraryScrollPosition()
        .task {
            while !Task.isCancelled {
                await store.refreshHistory()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func formattedPlaybackDate(_ timestamp: String) -> String {
        guard let date = try? Self.playbackTimestamp.parse(timestamp) else {
            return timestamp
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
