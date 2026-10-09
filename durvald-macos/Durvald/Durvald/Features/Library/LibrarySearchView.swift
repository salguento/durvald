import SwiftUI

struct LibrarySearchView: View {
    @Environment(DurvaldCoreStore.self) private var store

    @Binding var searchText: String
    @State private var search = SearchPresentation<SearchResults>()
    private var committedQuery: String { search.committedQuery }
    private var searchResults: SearchResults? { search.value }
    private var isSearching: Bool { search.isSearching }
    private var request: SearchRequest {
        .init(query: normalizedSearchText, storeID: ObjectIdentifier(store), coreID: store.core.map(ObjectIdentifier.init),
              metadataRevision: store.metadataRevision, scope: "global")
    }

    var body: some View {
        resultsList(searchResults)
            .overlay {
                if normalizedSearchText.isEmpty {
                    ContentUnavailableView(
                        "Pesquisar na biblioteca",
                        systemImage: "magnifyingglass",
                        description: Text("Encontre músicas, álbuns, artistas e playlists.")
                    )
                } else if isSearching && (searchResults?.isEmpty ?? true) {
                    ProgressView("Pesquisando…")
                        .controlSize(.small)
                } else if let searchResults, searchResults.isEmpty {
                    ContentUnavailableView(
                        "Nenhum resultado",
                        systemImage: "magnifyingglass",
                        description: Text(
                            "Não encontramos resultados para “\(committedQuery)”."
                        )
                    )
                }
            }
        .accessibilityIdentifier("search.page")
        .task(id: request) {
            let current = request
            await search.run(current, timing: .global, isCurrent: { request == current }) {
                await store.searchLibrary(query: $0)
            }
        }
        .onDisappear { search.cancel() }
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resultsList(_ results: SearchResults?) -> some View {
        List {
            if let results, !normalizedSearchText.isEmpty {
                resultSections(results)
            }
        }
        .listStyle(.inset)
        .preservesLibraryScrollPosition(
            isContentReady: normalizedSearchText.isEmpty
                || (searchResults != nil && committedQuery == normalizedSearchText)
        )
    }

    @ViewBuilder
    private func resultSections(_ results: SearchResults) -> some View {
        if !results.tracks.isEmpty {
            Section("Músicas") {
                ForEach(results.tracks, id: \.id) { track in
                    trackRow(track)
                }
            }
        }

        if !results.releases.isEmpty {
            Section("Álbuns") {
                ForEach(results.releases, id: \.id) { release in
                    HStack(spacing: 9) {
                        ArtworkView(
                            artworkID: release.artworkId,
                            size: 42
                        )

                        VStack(alignment: .leading, spacing: 0) {
                            AlbumTitleLabel(
                                title: release.title,
                                isFavorite: release.isFavorite,
                                font: LibraryTypography.listingTitle
                            )
                                .lineLimit(1)
                            Text(release.artist)
                                .font(LibraryTypography.listingSecondary)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .albumContextMenu(album: release)
                    .accessibilityIdentifier("search.release.\(release.id)")
                }
            }
        }

        if !results.artists.isEmpty {
            Section("Artistas") {
                ForEach(results.artists, id: \.id) { artist in
                    Label(artist.name, systemImage: "music.mic")
                        .accessibilityIdentifier("search.artist.\(artist.id)")
                }
            }
        }

        if !results.playlists.isEmpty {
            Section("Playlists") {
                ForEach(results.playlists, id: \.id) { playlist in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(playlist.name)
                            .lineLimit(1)
                        Text("\(playlist.trackCount) músicas")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .playlistContextMenu(playlist: playlist)
                    .accessibilityIdentifier("search.playlist.\(playlist.id)")
                }
            }
        }
    }

    private func trackRow(_ track: Track) -> some View {
        let model = TrackRowModel(track)
        return HStack(spacing: 10) {
            ArtworkView(artworkID: model.artworkID, size: 42)

            TrackRowText(model: model, showsEmptySubtitle: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(model.accessibilityLabel)
            .accessibilityHint("Reproduz esta faixa agora")
            .accessibilityIdentifier("search.track.\(track.id)")

            Button {
                Task { await store.addToQueue(trackID: track.id) }
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(model.enqueueLabel)
            .accessibilityIdentifier("search.track.\(track.id).addToQueue")
        }
        .playTrackOnDoubleClick {
            Task { await TrackRowPlayback.track(track.id).perform(using: store) }
        }
        .trackContextMenu(track: track) {
            Task { await TrackRowPlayback.track(track.id).perform(using: store) }
        }
    }
}

private extension SearchResults {
    var isEmpty: Bool {
        tracks.isEmpty
            && releases.isEmpty
            && artists.isEmpty
            && playlists.isEmpty
    }
}
