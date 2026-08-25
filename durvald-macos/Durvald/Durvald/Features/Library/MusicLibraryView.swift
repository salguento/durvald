//
//  MusicLibraryView.swift
//  Durvald
//
//  Created by Humberto Salguento on 21/08/26.
//

import SwiftUI

struct MusicLibraryView: View {
    @EnvironmentObject private var store: DurvaldCoreStore
    @State private var selectedTrackIDs = Set<Int64>()

    let searchText: String

    var body: some View {
        List(selection: $selectedTrackIDs) {
            if let progress = store.scanProgress {
                Text(verbatim: "\(progress.phase): \(progress.processedFiles)/\(progress.totalFiles)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Cancelar scan") { store.cancelScan() }
            }
            ForEach(visibleTracks, id: \.id) { track in
                HStack {
                    ArtworkView(artworkID: track.artworkId, size: 42)

                    Button {
                        Task { await store.play(trackID: track.id) }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(track.title)
                            Text(track.artist)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        track.artist.isEmpty
                            ? track.title
                            : "\(track.title), \(track.artist)"
                    )
                    .accessibilityIdentifier("track.\(track.id)")
                    .accessibilityHint("Reproduz esta faixa agora")

                    Button {
                        Task { await store.addToQueue(trackID: track.id) }
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Adicionar \(track.title) à fila")
                    .accessibilityIdentifier("track.\(track.id).addToQueue")
                    .accessibilityHint("Adiciona esta faixa ao fim da fila")
                }
                .tag(track.id)
                .contextMenu {
                    Button("Reproduzir agora") {
                        Task { await store.play(trackID: track.id) }
                    }

                    Button("Adicionar à fila") {
                        Task { await store.addToQueue(trackID: track.id) }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            LibraryStatusFooter(
                allTracks: store.tracks,
                visibleTracks: visibleTracks,
                selectedTrackIDs: selectedTrackIDs,
                isFiltering: !normalizedQuery.isEmpty
            )
        }
        .onChange(of: visibleTracks.map(\.id)) { _, visibleIDs in
            selectedTrackIDs.formIntersection(visibleIDs)
        }
    }
    
    private var normalizedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visibleTracks: [Track] {
        guard !normalizedQuery.isEmpty else { return store.tracks }

        return store.tracks.filter { track in
            track.title.localizedStandardContains(normalizedQuery)
                || track.artist.localizedStandardContains(normalizedQuery)
                || track.release.localizedStandardContains(normalizedQuery)
        }
    }
}
