import SwiftUI

struct LibrarySearchView: View {
    @Environment(DurvaldCoreStore.self) private var store

    @Binding var searchText: String
    @State private var committedQuery = ""
    @State private var searchResults: SearchResults?
    @State private var isSearching = false

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
        .task(id: searchText) {
            let query = normalizedSearchText

            guard !query.isEmpty else {
                committedQuery = ""
                searchResults = nil
                isSearching = false
                return
            }

            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }

            isSearching = true
            let results = await store.searchLibrary(query: query)
            guard !Task.isCancelled else { return }
            committedQuery = query
            searchResults = results
            isSearching = false
        }
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
                    HStack(spacing: 10) {
                        ArtworkView(
                            artworkID: release.artworkId,
                            size: 42
                        )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(release.title)
                                .lineLimit(1)
                            Text(release.artist)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
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
                    .accessibilityIdentifier("search.playlist.\(playlist.id)")
                }
            }
        }
    }

    private func trackRow(_ track: Track) -> some View {
        HStack(spacing: 10) {
            ArtworkView(artworkID: track.artworkId, size: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .activeTrackTitle(trackID: track.id)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(
                track.artist.isEmpty
                    ? track.title
                    : "\(track.title), \(track.artist)"
            )
            .accessibilityHint("Reproduz esta faixa agora")
            .accessibilityIdentifier("search.track.\(track.id)")

            Button {
                Task { await store.addToQueue(trackID: track.id) }
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Adicionar \(track.title) à fila")
            .accessibilityIdentifier("search.track.\(track.id).addToQueue")
        }
        .playTrackOnDoubleClick {
            Task { await store.play(trackID: track.id) }
        }
        .trackContextMenu(track: track) {
            Task { await store.play(trackID: track.id) }
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
