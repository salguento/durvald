import SwiftUI

struct PlaylistMusicPicker: View {
    @Environment(DurvaldCoreStore.self) private var store
    @FocusState private var isSearchFocused: Bool

    let playlist: Playlist
    let onTrackAdded: (Track) -> Void

    @State private var isExpanded = false
    @State private var query = ""
    @State private var searchPresentation = SearchPresentation<PlaylistSuggestionSnapshot>()
    private var committedQuery: String { searchPresentation.committedQuery }
    private var suggestions: PlaylistSuggestionSnapshot { searchPresentation.value ?? PlaylistSuggestionSnapshot() }
    private var isSearching: Bool { searchPresentation.isSearching }
    private var searchRequest: SearchRequest {
        .init(query: query.trimmingCharacters(in: .whitespacesAndNewlines), storeID: ObjectIdentifier(store),
              coreID: store.core.map(ObjectIdentifier.init), metadataRevision: store.metadataRevision, scope: "playlist.suggestions")
    }
    @State private var selection: Selection?
    @State private var albumTracks: [Track] = []
    @State private var isLoadingAlbum = false

    private enum Selection: Equatable {
        case album(Release)
        case artist(Artist)
    }

    private typealias ResultItem = PlaylistSuggestionSnapshot.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isExpanded {
                searchHeader
                displayedContent
            } else {
                Button {
                    isExpanded = true
                    Task { @MainActor in
                        await Task.yield()
                        isSearchFocused = true
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                            .frame(width: 14)

                        Text("Adicionar mais músicas")
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .accessibilityIdentifier("playlist.addMusic.open")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onExitCommand {
            guard isExpanded else { return }
            closeSearch()
        }
        .task(id: searchRequest) { await search() }
        .onDisappear { searchPresentation.cancel() }
        .task(id: selectedAlbumID) { await loadSelectedAlbum() }
    }

    private var searchHeader: some View {
        InlineSearchField(
            text: $query, focus: $isSearchFocused,
            placeholder: "Pesquisar músicas, álbuns ou artistas",
            identifier: "playlist.addMusic.search",
            fieldIdentifier: "playlist.addMusic.search",
            style: .picker, accessory: .close,
            onAction: closeSearch,
            onSubmit: { isSearchFocused = true },
            onExit: closeSearch
        )
        .padding(.horizontal, 6)
    }

    @ViewBuilder
    private var displayedContent: some View {
        let resultItems = suggestions.items
        if let selection {
            switch selection {
            case .album(let album): albumContent(album)
            case .artist(let artist): artistContent(artist)
            }
        } else if isSearching {
            ProgressView("Pesquisando…")
                .controlSize(.small)
        } else if committedQuery.isEmpty {
            EmptyView()
        } else if resultItems.isEmpty {
            ContentUnavailableView.search(text: committedQuery)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(resultItems) { item in
                    resultRow(item)
                    if item.id != resultItems.last?.id { Divider() }
                }
            }
        }
    }

    @ViewBuilder
    private func resultRow(_ item: ResultItem) -> some View {
        switch item {
        case .track(let track): trackRow(track)
        case .album(let album):
            Button { selection = .album(album) } label: {
                libraryRow(title: album.title, subtitle: album.artist,
                           artworkID: album.artworkId, systemImage: "square.stack",
                           isFavorite: album.isFavorite)
            }
            .buttonStyle(.plain)
            .albumContextMenu(album: album)
        case .artist(let artist):
            Button { selection = .artist(artist) } label: {
                libraryRow(title: artist.name, subtitle: "Artista",
                           artworkID: nil, systemImage: "music.mic")
            }
            .buttonStyle(.plain)
        }
    }

    private func libraryRow(title: String, subtitle: String, artworkID: String?,
                            systemImage: String, isFavorite: Bool = false) -> some View {
        HStack(spacing: 10) {
            if let artworkID {
                ArtworkView(artworkID: artworkID, size: 40)
            } else {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
            }
            VStack(alignment: .leading, spacing: 2) {
                AlbumTitleLabel(title: title, isFavorite: isFavorite, font: .body)
                    .lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func trackRow(_ track: Track) -> some View {
        HStack(spacing: 10) {
            ArtworkView(artworkID: track.artworkId, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).lineLimit(1)
                Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            addButton(track)
        }
        .padding(.vertical, 6)
        .playTrackOnDoubleClick {
            Task { await store.play(trackID: track.id) }
        }
        .trackContextMenu(track: track) {
            Task { await store.play(trackID: track.id) }
        }
    }

    private func addButton(_ track: Track) -> some View {
        Button("Adicionar") {
            guard store.addTrack(track.id, to: playlist) else { return }
            onTrackAdded(track)
        }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .accessibilityLabel("Adicionar \(track.title) à playlist")
    }

    private func albumContent(_ album: Release) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            submenuLabel(album.title, isFavorite: album.isFavorite)
            if isLoadingAlbum {
                ProgressView("Carregando músicas…").controlSize(.small)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(albumTracks, id: \.id) { track in
                        trackRow(track)
                        if track.id != albumTracks.last?.id { Divider() }
                    }
                }
            }
        }
    }

    private func artistContent(_ artist: Artist) -> some View {
        let tracks = artistTracks(artist)
        let albums = artistAlbums(artist, tracks: tracks)
        return VStack(alignment: .leading, spacing: 10) {
            submenuLabel("Músicas")
            LazyVStack(spacing: 0) {
                ForEach(tracks.prefix(10), id: \.id) { track in
                    trackRow(track)
                    Divider()
                }
            }

            sectionLabel("Álbuns")
                .padding(.top, 8)
            LazyVStack(spacing: 0) {
                ForEach(albums, id: \.id) { album in
                    Button { selection = .album(album) } label: {
                        libraryRow(title: album.title, subtitle: album.artist,
                                   artworkID: album.artworkId, systemImage: "square.stack",
                                   isFavorite: album.isFavorite)
                    }
                    .buttonStyle(.plain)
                    if album.id != albums.last?.id { Divider() }
                }
            }
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func submenuLabel(_ title: String, isFavorite: Bool = false) -> some View {
        Button {
            selection = nil
            albumTracks = []
            isSearchFocused = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                AlbumTitleLabel(
                    title: title,
                    isFavorite: isFavorite,
                    font: .subheadline,
                    weight: .semibold
                )
                .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Voltar aos resultados")
    }

    private func artistTracks(_ artist: Artist) -> [Track] {
        store.tracks.filter { $0.artistId == artist.id }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func artistAlbums(_ artist: Artist, tracks: [Track]) -> [Release] {
        let releaseIDs = Set(tracks.map(\.releaseId))
        return store.releases.filter { $0.artistId == artist.id || releaseIDs.contains($0.id) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private var selectedAlbumID: Int64? {
        guard case .album(let album) = selection else { return nil }
        return album.id
    }

    private func search() async {
        let current = searchRequest
        await searchPresentation.run(current, timing: .suggestions, isCurrent: { searchRequest == current }) { normalized in
            selection = nil
            let found = await store.searchLibrary(query: normalized)
            try Task.checkCancellation()
            let locale = Locale.current
            let worker = Task.detached(priority: .userInitiated) {
                PlaylistSuggestionSnapshot.build(results: found, query: normalized, locale: locale)
            }
            return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        }
    }

    private func closeSearch() {
        isSearchFocused = false
        query = ""
        searchPresentation.reset()
        selection = nil
        albumTracks = []
        isExpanded = false
    }

    private func loadSelectedAlbum() async {
        guard case .album(let album) = selection else {
            albumTracks = []
            return
        }
        isLoadingAlbum = true
        albumTracks = await store.tracks(forReleaseID: album.id)
        isLoadingAlbum = false
    }
}
