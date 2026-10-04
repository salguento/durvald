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
    @State private var entries: [PlaybackHistoryItem] = []
    @State private var resolvedTracks: [Int64: Track] = [:]
    @State private var resolvedMetadataRevision = -1
    @State private var isSearching = false
    var onSummaryChange: (String) -> Void = { _ in }

    private struct SearchRequest: Equatable {
        let query: String
        let entries: [PlaybackHistoryItem]
        let metadataRevision: Int
    }

    private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var tracksByID: [Int64: Track] {
        store.tracks.reduce(into: resolvedTracks) { $0[$1.id] = $1 }
    }

    private var filteredEntries: [PlaybackHistoryItem] {
        guard !query.isEmpty else { return entries }
        let tracks = tracksByID
        return entries.filter { item in
            guard let track = tracks[item.trackId] else {
                return "Música #\(item.trackId)".localizedCaseInsensitiveContains(query)
            }
            return [track.title, track.artist, track.release].contains {
                $0.localizedCaseInsensitiveContains(query)
            }
        }
    }

    private var orderedEntries: [PlaybackHistoryItem] {
        filteredEntries.sorted { newestFirst ? $0.id > $1.id : $0.id < $1.id }
    }

    var body: some View {
        let tracks = tracksByID
        List(orderedEntries, id: \.id) { item in
            HistoryTrackRow(item: item, loadedTrack: tracks[item.trackId])
                .accessibilityIdentifier("history.entry.\(item.id)")
                .task {
                    if entries.count <= store.history.count {
                        await store.loadMoreHistory(ifNeededAfter: item.id)
                    }
                }
        }
        .overlay {
            if isSearching {
                ProgressView("Pesquisando…")
            } else if !query.isEmpty && filteredEntries.isEmpty {
                ContentUnavailableView("Nenhuma reprodução encontrada", systemImage: "magnifyingglass")
            }
        }
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .preservesLibraryScrollPosition()
        .task(id: store.history) {
            // Search and metadata include older pages, even when filtering
            // removes every visible row that would normally trigger pagination.
            let history = (try? await store.core?.playbackHistory()) ?? store.history
            guard !Task.isCancelled else { return }
            entries = history
            publishSummary()
        }
        .task(id: SearchRequest(query: query, entries: entries, metadataRevision: store.metadataRevision)) {
            if resolvedMetadataRevision != store.metadataRevision {
                resolvedTracks = [:]
                resolvedMetadataRevision = store.metadataRevision
            }
            isSearching = !query.isEmpty
            publishSummary()
            if !query.isEmpty, let core = store.core {
                do {
                    try await Task.sleep(for: .milliseconds(200))
                    let knownIDs = Set(tracksByID.keys)
                    for id in Set(entries.map(\.trackId)).subtracting(knownIDs) {
                        try Task.checkCancellation()
                        if let track = try? await core.track(trackId: id) {
                            resolvedTracks[id] = track
                        }
                    }
                } catch { return }
            }
            guard !Task.isCancelled else { return }
            isSearching = false
            publishSummary()
        }
        .task {
            while !Task.isCancelled {
                await store.refreshHistory()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func publishSummary() {
        if isSearching {
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
    @State var loadedTrack: Track?

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
