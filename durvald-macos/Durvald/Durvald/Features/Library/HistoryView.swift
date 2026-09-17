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
            HistoryTrackRow(item: item)
                .task { await store.loadMoreHistory(ifNeededAfter: item.id) }
        }
        .preservesLibraryScrollPosition()
        .task {
            while !Task.isCancelled {
                await store.refreshHistory()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

private struct HistoryTrackRow: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(TrackInfoCoordinator.self) private var trackInfo
    let item: PlaybackHistoryItem
    @State private var loadedTrack: Track?

    var body: some View {
        let track = store.tracks.first { $0.id == item.trackId } ?? loadedTrack
        Group {
            if let track {
                label(track.title)
                    .trackContextMenu(track: track) {
                        Task { await store.play(trackID: track.id) }
                    }
            } else {
                label("Música #\(item.trackId)")
                    .contextMenu {
                        Button("Info") { trackInfo.open(trackID: item.trackId) }
                    }
            }
        }
        .task(id: item.trackId) {
            if track == nil { loadedTrack = try? await store.core?.track(trackId: item.trackId) }
        }
    }

    private func label(_ title: String) -> some View {
        VStack(alignment: .leading) {
            Text(title).activeTrackTitle(trackID: item.trackId)
            Text(playbackDate).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var playbackDate: String {
        let format = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        guard let date = try? format.parse(item.playedAt) else { return item.playedAt }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
