//
//  MusicLibraryView.swift
//  Durvald
//
//  Created by Humberto Salguento on 21/08/26.
//

import SwiftUI

struct MusicLibraryView: View {
    private enum Order: String, CaseIterable, Identifiable {
        case library, title, artist, rating
        var id: Self { self }
        var title: String {
            switch self {
            case .library: "Biblioteca"
            case .title: "Título"
            case .artist: "Artista"
            case .rating: "Avaliação"
            }
        }
    }

    @Environment(DurvaldCoreStore.self) private var store
    @Environment(TrackInfoCoordinator.self) private var trackInfo
    @State private var selectedTrackIDs = Set<Int64>()
    @State private var order: Order = .library
    @State private var minimumRating: UInt8 = 0
    @AppStorage(RatingPreferences.enabledKey) private var ratingsEnabled = true

    var body: some View {
        List(selection: $selectedTrackIDs) {
            if selectedTrackIDs.count > 1 {
                HStack {
                    Text("\(selectedTrackIDs.count) faixas selecionadas")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Editar metadados…") {
                        trackInfo.openBatch(trackIDs: selectedTrackIDs)
                    }
                    .accessibilityIdentifier("library.batchMetadata")
                }
            }
            if ratingsEnabled {
                HStack {
                    Picker("Ordenar", selection: $order) {
                        ForEach(Order.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Nota mínima", selection: $minimumRating) {
                        Text("Todas").tag(UInt8(0))
                        ForEach(1...5, id: \.self) { Text("\($0)+").tag(UInt8($0)) }
                    }
                    .frame(width: 130)
                }
            }
            if let progress = store.scanProgress {
                Text(verbatim: "\(progress.phase): \(progress.processedFiles)/\(progress.totalFiles)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Cancelar scan") { store.cancelScan() }
            }
            ForEach(visibleTracks, id: \.id) { track in
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

                    TrackListTrailingControls(
                        track: track,
                        onPlay: {
                            Task { await store.play(trackID: track.id) }
                        },
                        onToggleFavorite: { isFavorite in
                            Task {
                                await store.setTrackFavorite(
                                    trackID: track.id,
                                    favorite: isFavorite
                                )
                            }
                        }
                    ) {
                        if ratingsEnabled {
                            RatingControl(
                                rating: track.rating,
                                isEditable: true,
                                onChange: { rating in
                                    Task { await store.setTrackRating(trackID: track.id, rating: rating) }
                                }
                            )
                        }

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
                }
                .tag(track.id)
                .playTrackOnDoubleClick {
                    Task { await store.play(trackID: track.id) }
                }
                .trackContextMenu(track: track) {
                    Task { await store.play(trackID: track.id) }
                }
                .task {
                    await store.loadMoreTracks(ifNeededAfter: track.id)
                }
            }
        }
        .preservesLibraryScrollPosition()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            LibraryStatusFooter(
                allTracks: store.tracks,
                visibleTracks: visibleTracks,
                selectedTrackIDs: selectedTrackIDs,
                isFiltering: ratingsEnabled && minimumRating > 0
            )
        }
    }

    private var visibleTracks: [Track] {
        var result = store.tracks
        if ratingsEnabled, minimumRating > 0 {
            result = result.filter { ($0.rating ?? 0) >= minimumRating }
        }
        switch ratingsEnabled || order != .rating ? order : .library {
        case .library: break
        case .title:
            result.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .artist:
            result.sort { $0.artist.localizedStandardCompare($1.artist) == .orderedAscending }
        case .rating:
            result.sort { ($0.rating ?? 0) > ($1.rating ?? 0) }
        }
        return result
    }
}
