//
//  MusicLibraryView.swift
//  Durvald
//
//  Created by Humberto Salguento on 21/08/26.
//

import SwiftUI

struct MusicLibraryView: View {
    @Environment(DurvaldCoreStore.self) private var store
    @State private var selectedTrackIDs = Set<Int64>()

    var body: some View {
        List(selection: $selectedTrackIDs) {
            if let progress = store.scanProgress {
                Text(verbatim: "\(progress.phase): \(progress.processedFiles)/\(progress.totalFiles)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Cancelar scan") { store.cancelScan() }
            }
            ForEach(store.tracks, id: \.id) { track in
                HStack {
                    ArtworkView(artworkID: track.artworkId, size: 42)

                    VStack(alignment: .leading) {
                        Text(track.title)
                            .activeTrackTitle(trackID: track.id)
                        Text(track.artist)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                .playTrackOnDoubleClick {
                    Task { await store.play(trackID: track.id) }
                }
                .trackContextMenu(track: track) {
                    Task { await store.play(trackID: track.id) }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            LibraryStatusFooter(
                allTracks: store.tracks,
                visibleTracks: store.tracks,
                selectedTrackIDs: selectedTrackIDs,
                isFiltering: false
            )
        }
    }
}
