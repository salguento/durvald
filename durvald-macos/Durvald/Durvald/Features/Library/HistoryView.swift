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
    @State private var search = SearchPresentation<HistoryListingSnapshot>()
    @State private var selectedTab: HistoryTab = .general
    private var snapshot: HistoryListingSnapshot { search.value ?? HistoryListingSnapshot() }
    private var searchPending: Bool { store.historyRepository.isLoading || search.isPending }
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
        let tracks = snapshot.tracksByID
        List(snapshot.items, id: \.id) { item in
            HistoryTrackRow(item: item, loadedTrack: tracks[item.trackId])
                .accessibilityIdentifier("history.entry.\(item.id)")
        }
        .scrollContentBackground(.hidden)
        .overlay {
            if searchPending && !query.isEmpty {
                ProgressView("Pesquisando…")
            } else if !query.isEmpty && snapshot.items.isEmpty && !search.isPending {
                ContentUnavailableView("Nenhuma reprodução encontrada", systemImage: "magnifyingglass")
            }
        }
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .background {
            HistoryToolbarAccessory(height: 46) {
                HistoryTabPicker(selection: $selectedTab)
            }
        }
        .preservesLibraryScrollPosition()
        .task(id: RefreshRequest(coreID: store.core.map(ObjectIdentifier.init),
                                 catalogRevision: store.libraryCatalogRevision, tracksRevision: store.tracksRevision)) {
            await store.refreshHistory()
        }
        .task(id: preparationKey) {
            let key = preparationKey
            let entries = store.historyRepository.entries
            let tracks = store.historyRepository.tracksByID
            let current = SearchRequest(query: key.query, storeID: ObjectIdentifier(store),
                                        sourceRevision: key.payloadRevision, scope: "history")
            let published = await search.run(current, timing: .history, allowsEmpty: true,
                                             isCurrent: { preparationKey == key }) { _ in
                let worker = Task.detached(priority: .userInitiated) {
                    HistoryListingSnapshot.build(entries: entries, tracks: tracks, key: key)
                }
                return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            }
            guard published else { return }
            onSummaryChange(snapshot.summary)
        }
        .onChange(of: searchPending) { _, loading in
            if loading && !query.isEmpty { onSummaryChange("Pesquisando…") }
            else { onSummaryChange(snapshot.summary) }
        }
        .onDisappear { search.cancel() }
    }

}

private enum HistoryTab: String, CaseIterable, Identifiable {
    case general, artists, albums, tracks

    var id: Self { self }
    var title: String {
        switch self {
        case .general: "Geral"
        case .artists: "Artistas"
        case .albums: "Álbuns"
        case .tracks: "Faixas"
        }
    }
    var icon: String {
        switch self {
        case .general: "clock.fill"
        case .artists: "mic.fill"
        case .albums: "square.stack.fill"
        case .tracks: "music.note"
        }
    }
}

/// Mail-style categories: separate capsules and an expanded selected label.
/// Selection is visual only until the history scopes are implemented.
private struct HistoryTabPicker: View {
    @Binding var selection: HistoryTab

    var body: some View {
        HStack(spacing: 8) {
            ForEach(HistoryTab.allCases) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { selection = tab }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: tab.icon)
                        if selection == tab {
                            Text(tab.title)
                                .fontWeight(.semibold)
                                .lineLimit(1)
                        }
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(selection == tab ? Color.black : Color.secondary)
                    .padding(.horizontal, selection == tab ? 14 : 0)
                    .frame(width: selection == tab ? nil : 52)
                    .frame(height: 30)
                    .background(selection == tab ? Color.white.opacity(0.94) : Color.primary.opacity(0.08),
                                in: .capsule)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(tab.title)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
                .accessibilityIdentifier("history.tab.\(tab.rawValue)")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("history.tabs")
    }
}

struct HistoryToolbarOptionsMenu: View {
    @AppStorage("history.newestFirst") private var newestFirst = true

    var body: some View {
        ToolbarOptionsButton(title: "Opções de visualização") {
            Picker("Ordenar", selection: $newestFirst) {
                Text("Mais recentes").tag(true)
                Text("Mais antigas").tag(false)
            }
        }
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
                        Task { await TrackRowPlayback.track(track.id).perform(using: store) }
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
        TrackRowText(model: TrackRowModel(trackID: item.trackId, title: title),
                     subtitle: playbackDate, spacing: nil, lineLimit: nil)
    }

    private var playbackDate: String {
        let format = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        guard let date = try? format.parse(item.playedAt) else { return item.playedAt }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
