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
    var onSummaryChange: (String) -> Void = { _ in }

    private struct RefreshRequest: Equatable {
        let coreID: ObjectIdentifier?
        let catalogRevision: UInt64
        let tracksRevision: UInt64
    }
    private struct SummaryRequest: Equatable {
        let query: String
        let revision: UInt64
        let isLoading: Bool
    }
    private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var tracksByID: [Int64: Track] { store.historyRepository.tracksByID }

    private var filteredEntries: [PlaybackHistoryItem] {
        store.historyRepository.entries(matching: query)
    }

    private var orderedEntries: [PlaybackHistoryItem] {
        filteredEntries.sorted { newestFirst ? $0.id > $1.id : $0.id < $1.id }
    }

    var body: some View {
        let tracks = tracksByID
        List(orderedEntries, id: \.id) { item in
            HistoryTrackRow(item: item, loadedTrack: tracks[item.trackId])
                .accessibilityIdentifier("history.entry.\(item.id)")
        }
        .overlay {
            if store.historyRepository.isLoading && !query.isEmpty {
                ProgressView("Pesquisando…")
            } else if !query.isEmpty && filteredEntries.isEmpty {
                ContentUnavailableView("Nenhuma reprodução encontrada", systemImage: "magnifyingglass")
            }
        }
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .preservesLibraryScrollPosition()
        .task(id: RefreshRequest(coreID: store.core.map(ObjectIdentifier.init),
                                 catalogRevision: store.libraryCatalogRevision, tracksRevision: store.tracksRevision)) {
            await store.refreshHistory()
        }
        .task(id: SummaryRequest(query: query, revision: store.historyRepository.revision,
                                 isLoading: store.historyRepository.isLoading)) {
            publishSummary()
        }
    }

    private func publishSummary() {
        if store.historyRepository.isLoading && !query.isEmpty {
            onSummaryChange("Pesquisando…")
            return
        }
        let items = filteredEntries
        let count = items.count
        let songs = Set(items.map(\.trackId)).count
        let duration = items.reduce(UInt64.zero) { $0 + $1.durationSeconds }
        let time = duration >= 3600
            ? String(format: "%llu:%02llu:%02llu", duration / 3600, duration / 60 % 60, duration % 60)
            : String(format: "%llu:%02llu", duration / 60, duration % 60)
        let prefix = query.isEmpty ? "" : "Resultados para “\(query)” • "
        onSummaryChange("\(prefix)\(count.formatted()) \(count == 1 ? "reprodução" : "reproduções"), \(songs.formatted()) \(songs == 1 ? "música" : "músicas"), \(time) de reprodução")
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
