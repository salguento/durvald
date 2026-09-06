import SwiftUI

struct PlaylistMusicPicker: View {
    @Environment(DurvaldCoreStore.self) private var store
    @FocusState private var isSearchFocused: Bool

    let playlist: Playlist
    let onTrackAdded: (Track) -> Void

    @State private var isExpanded = false
    @State private var query = ""
    @State private var committedQuery = ""
    @State private var results: SearchResults?
    @State private var isSearching = false
    @State private var selection: Selection?
    @State private var albumTracks: [Track] = []
    @State private var isLoadingAlbum = false

    private enum Selection: Equatable {
        case album(Release)
        case artist(Artist)
    }

    private enum ResultItem: Identifiable {
        case track(Track)
        case album(Release)
        case artist(Artist)

        var id: String {
            switch self {
            case .track(let value): "track-\(value.id)"
            case .album(let value): "album-\(value.id)"
            case .artist(let value): "artist-\(value.id)"
            }
        }

        var title: String {
            switch self {
            case .track(let value): value.title
            case .album(let value): value.title
            case .artist(let value): value.name
            }
        }
    }

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
        .task(id: query) { await search() }
        .task(id: selectedAlbumID) { await loadSelectedAlbum() }
    }

    private var searchHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .frame(width: 14)

            TextField("Pesquisar músicas, álbuns ou artistas", text: $query)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .onSubmit { isSearchFocused = true }
                .accessibilityIdentifier("playlist.addMusic.search")

            Button {
                closeSearch()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Fechar pesquisa")
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(.quaternary, in: .capsule)
        .padding(.horizontal, 6)
    }

    @ViewBuilder
    private var displayedContent: some View {
        if let selection {
            switch selection {
            case .album(let album): albumContent(album)
            case .artist(let artist): artistContent(artist)
            }
        } else if committedQuery.isEmpty {
            EmptyView()
        } else if isSearching {
            ProgressView("Pesquisando…")
                .controlSize(.small)
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

    private var resultItems: [ResultItem] {
        guard let results else { return [] }
        let items = results.tracks.map(ResultItem.track)
            + results.releases.map(ResultItem.album)
            + results.artists.map(ResultItem.artist)
        return Array(items.sorted { relevance(of: $0) < relevance(of: $1) }.prefix(10))
    }

    private func relevance(of item: ResultItem) -> String {
        let title = item.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let term = committedQuery.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let rank = title == term ? "0" : title.hasPrefix(term) ? "1" : "2"
        return rank + title
    }

    @ViewBuilder
    private func resultRow(_ item: ResultItem) -> some View {
        switch item {
        case .track(let track): trackRow(track)
        case .album(let album):
            Button { selection = .album(album) } label: {
                libraryRow(title: album.title, subtitle: album.artist,
                           artworkID: album.artworkId, systemImage: "square.stack")
            }
            .buttonStyle(.plain)
        case .artist(let artist):
            Button { selection = .artist(artist) } label: {
                libraryRow(title: artist.name, subtitle: "Artista",
                           artworkID: nil, systemImage: "music.mic")
            }
            .buttonStyle(.plain)
        }
    }

    private func libraryRow(title: String, subtitle: String, artworkID: String?,
                            systemImage: String) -> some View {
        HStack(spacing: 10) {
            if let artworkID {
                ArtworkView(artworkID: artworkID, size: 40)
            } else {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
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
            submenuLabel(album.title)
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
                                   artworkID: album.artworkId, systemImage: "square.stack")
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

    private func submenuLabel(_ title: String) -> some View {
        Button {
            selection = nil
            albumTracks = []
            isSearchFocused = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                sectionLabel(title)
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
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            committedQuery = ""
            results = nil
            isSearching = false
            return
        }
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        selection = nil
        committedQuery = normalized
        isSearching = true
        let found = await store.searchLibrary(query: normalized)
        guard !Task.isCancelled else { return }
        results = found
        isSearching = false
    }

    private func closeSearch() {
        isSearchFocused = false
        query = ""
        committedQuery = ""
        results = nil
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
