//
//  HistoryView.swift
//  Durvald
//
//  Created by Humberto Salguento on 21/08/26.
//

import SwiftUI

struct HistoryView: View {
    @Environment(DurvaldCoreStore.self) private var store

    var body: some View {
        List(store.history, id: \.id) { item in
            let track = store.tracks.first { $0.id == item.trackId }

            VStack(alignment: .leading) {
                Text(track?.title ?? "Música #\(item.trackId)")
                    .activeTrackTitle(trackID: item.trackId)
                Text(item.playedAt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .task {
                await store.loadMoreHistory(ifNeededAfter: item.id)
            }
        }
        .task {
            while !Task.isCancelled {
                await store.refreshHistory()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
