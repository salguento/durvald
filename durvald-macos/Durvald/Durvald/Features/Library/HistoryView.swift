//
//  HistoryView.swift
//  Durvald
//
//  Created by Humberto Salguento on 21/08/26.
//

import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var store: DurvaldCoreStore

    var body: some View {
        List(store.history, id: \.id) { item in
            let track = store.tracks.first { $0.id == item.trackId }

            VStack(alignment: .leading) {
                Text(track?.title ?? "Música #\(item.trackId)")
                Text(item.playedAt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Histórico")
        .task {
            while !Task.isCancelled {
                store.refreshHistory()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
