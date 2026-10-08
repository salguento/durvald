//
//  HistoryView.swift
//  Durvald
//
//  Created by Humberto Salguento on 21/08/26.
//

import SwiftUI

struct HistoryView: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Binding var searchText: String
    @AppStorage("history.newestFirst") private var newestFirst = true
    @State private var presentation = PreparedLibraryListing(HistoryListingSnapshot())
    var onSummaryChange: (String) -> Void = { _ in }

    private struct RefreshRequest: Equatable {
        let coreID: ObjectIdentifier?
        let catalogRevision: UInt64
        let tracksRevision: UInt64
    }
    private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var preparationKey: LibraryListingKey {
        LibraryListingKey(storeID: ObjectIdentifier(store), payloadRevision: store.historyRepository.revision,
                          query: query, newestFirst: newestFirst)
    }

    var body: some View {
        let tracks = presentation.value.tracksByID
        List(presentation.value.items, id: \.id) { item in
            HistoryTrackRow(item: item, loadedTrack: tracks[item.trackId])
                .accessibilityIdentifier("history.entry.\(item.id)")
        }
        .overlay {
            if store.historyRepository.isLoading && !query.isEmpty {
                ProgressView("Pesquisando…")
            } else if !query.isEmpty && presentation.value.items.isEmpty && !presentation.isPreparing {
                ContentUnavailableView("Nenhuma reprodução encontrada", systemImage: "magnifyingglass")
            }
        }
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .preservesLibraryScrollPosition()
        .task(id: RefreshRequest(coreID: store.core.map(ObjectIdentifier.init),
                                 catalogRevision: store.libraryCatalogRevision, tracksRevision: store.tracksRevision)) {
            await store.refreshHistory()
        }
        .task(id: preparationKey) {
            let key = preparationKey
            let entries = store.historyRepository.entries
            let tracks = store.historyRepository.tracksByID
            await presentation.prepare(key: key, payload: (entries, tracks)) { payload in
                HistoryListingSnapshot.build(entries: payload.0, tracks: payload.1, key: key)
            }
            guard !Task.isCancelled else { return }
            onSummaryChange(presentation.value.summary)
        }
        .onChange(of: store.historyRepository.isLoading) { _, loading in
            if loading && !query.isEmpty { onSummaryChange("Pesquisando…") }
            else { onSummaryChange(presentation.value.summary) }
        }
    }

}

struct HistoryToolbarOptionsMenu: View {
    @AppStorage("history.newestFirst") private var newestFirst = true

    var body: some View {
        Menu {
            Picker("Ordenar", selection: $newestFirst) {
                Text("Mais recentes").tag(true)
                Text("Mais antigas").tag(false)
            }
        } label: {
            ZStack {
                Color.clear
                Image(systemName: "line.3.horizontal.decrease")
            }
            .frame(width: 36, height: 36)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 36, height: 36)
        .contentShape(Circle())
        .clipShape(Circle())
        .glassEffect(.regular, in: .circle)
        .help("Opções de visualização")
        .accessibilityLabel("Opções de visualização")
        .accessibilityIdentifier("history.viewOptions")
    }
}

private struct HistoryTrackRow: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(TrackInfoCoordinator.self) private var trackInfo
    let item: PlaybackHistoryItem
    let loadedTrack: Track?

    var body: some View {
        let track = loadedTrack
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
