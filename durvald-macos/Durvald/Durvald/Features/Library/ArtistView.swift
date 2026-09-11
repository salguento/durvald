import SwiftUI

struct ArtistView: View {
    private enum TrackOrder: String, CaseIterable, Identifiable {
        case album
        case title
        case artist
        case duration

        var id: Self { self }

        var title: String {
            switch self {
            case .album: "Álbum"
            case .title: "Título"
            case .artist: "Artista"
            case .duration: "Duração"
            }
        }
    }

    @Environment(DurvaldCoreStore.self) private var store
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("followedArtistIDs") private var followedArtistIDs = ""
    @AppStorage("favoriteArtistIDs") private var favoriteArtistIDs = ""

    let artist: Artist
    let onSelectAlbum: (Release) -> Void
    var onSelectArtist: ((Artist) -> Void)? = nil

    @State private var tracks: [Track] = []
    @State private var albums: [Release] = []
    @State private var trackSearchText = ""
    @State private var trackOrder: TrackOrder = .album
    @FocusState private var isTrackSearchFocused: Bool
    @State private var isLoading = true
    @ScaledMetric(relativeTo: .largeTitle) private var artistNameFontSize =
        NSFont.preferredFont(forTextStyle: .largeTitle).pointSize * 1.275

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ArtworkView(
                        artworkID: albums.compactMap(\.artworkId).first,
                        size: geometry.size.width,
                        aspectRatio: 16.0 / 9.0,
                        showsBorder: false
                    )
                    .backgroundExtensionEffect()
                    .overlay(alignment: .bottomLeading) {
                        Text(artist.name)
                            .font(.system(size: artistNameFontSize, weight: .bold))
                            .accessibilityAddTraits(.isHeader)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.6), radius: 4, y: 2)
                            .padding(24)
                    }
                    .accessibilityIdentifier("artist.header.\(artist.id)")

                    VStack(alignment: .leading, spacing: 24) {
                        collectionControls

                        artistHighlights(width: geometry.size.width)

                        if !albums.isEmpty {
                            Text("Álbuns")
                                .font(.title2.bold())

                            LazyVGrid(
                                columns: AlbumGridLayout.columns(for: geometry.size.width),
                                alignment: .leading,
                                spacing: AlbumGridLayout.spacing
                            ) {
                                ForEach(albums, id: \.id) { album in
                                    AlbumCard(
                                        release: album,
                                        onSelectAlbum: onSelectAlbum,
                                        subtitle: releaseYear(for: album)
                                    )
                                }
                            }
                        }

                        if !albums.isEmpty {
                            Text("Singles & EPs")
                                .font(.title2.bold())

                            LazyVGrid(
                                columns: AlbumGridLayout.columns(for: geometry.size.width),
                                alignment: .leading,
                                spacing: AlbumGridLayout.spacing
                            ) {
                                ForEach(albums, id: \.id) { album in
                                    AlbumCard(
                                        release: album,
                                        onSelectAlbum: onSelectAlbum,
                                        subtitle: releaseYear(for: album)
                                    )
                                }
                            }
                        }

                        if !albums.isEmpty {
                            Text("Álbuns ao vivo")
                                .font(.title2.bold())

                            LazyVGrid(
                                columns: AlbumGridLayout.columns(for: geometry.size.width),
                                alignment: .leading,
                                spacing: AlbumGridLayout.spacing
                            ) {
                                ForEach(albums, id: \.id) { album in
                                    AlbumCard(
                                        release: album,
                                        onSelectAlbum: onSelectAlbum,
                                        subtitle: releaseYear(for: album)
                                    )
                                }
                            }
                        }

                        if !albums.isEmpty {
                            Text("Compilações")
                                .font(.title2.bold())

                            LazyVGrid(
                                columns: AlbumGridLayout.columns(for: geometry.size.width),
                                alignment: .leading,
                                spacing: AlbumGridLayout.spacing
                            ) {
                                ForEach(albums, id: \.id) { album in
                                    AlbumCard(
                                        release: album,
                                        onSelectAlbum: onSelectAlbum,
                                        subtitle: releaseYear(for: album)
                                    )
                                }
                            }
                        }

                        if !albums.isEmpty {
                            Text("Playlists")
                                .font(.title2.bold())

                            LazyVGrid(
                                columns: AlbumGridLayout.columns(for: geometry.size.width),
                                alignment: .leading,
                                spacing: AlbumGridLayout.spacing
                            ) {
                                ForEach(albums, id: \.id) { album in
                                    AlbumCard(
                                        release: album,
                                        onSelectAlbum: onSelectAlbum,
                                        subtitle: releaseYear(for: album)
                                    )
                                }
                            }
                        }

                        if !albums.isEmpty {
                            Text("Participações")
                                .font(.title2.bold())

                            LazyVGrid(
                                columns: AlbumGridLayout.columns(for: geometry.size.width),
                                alignment: .leading,
                                spacing: AlbumGridLayout.spacing
                            ) {
                                ForEach(albums, id: \.id) { album in
                                    AlbumCard(
                                        release: album,
                                        onSelectAlbum: onSelectAlbum,
                                        subtitle: releaseYear(for: album)
                                    )
                                }
                            }
                        }

                        if isLoading {
                            ProgressView("Carregando artista…")
                                .frame(maxWidth: .infinity, alignment: .center)
                        } else if albums.isEmpty && tracks.isEmpty {
                            ContentUnavailableView(
                                "Nenhuma música disponível",
                                systemImage: "music.mic",
                                description: Text("Este artista ainda não possui músicas na biblioteca.")
                            )
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    artistFooter(width: geometry.size.width)
                }
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
        }
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        .task(id: artist.id) {
            isLoading = true
            async let loadedTracks = store.tracks(forArtistID: artist.id)
            async let loadedAlbums = store.releases(forArtistID: artist.id)
            let (resolvedTracks, resolvedAlbums) = await (loadedTracks, loadedAlbums)
            tracks = resolvedTracks.sorted {
                if $0.release != $1.release {
                    return $0.release.localizedStandardCompare($1.release) == .orderedAscending
                }
                if $0.discNumber != $1.discNumber { return $0.discNumber < $1.discNumber }
                if $0.trackNumber != $1.trackNumber { return $0.trackNumber < $1.trackNumber }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            albums = resolvedAlbums.sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            isLoading = false
        }
        .accessibilityIdentifier("artist.detail.\(artist.id)")
    }

    private func artistHighlights(width: CGFloat) -> some View {
        // Two columns require twice the content column's 360 pt minimum width.
        let isStacked = width < 720
        let columnWidth = max(0, isStacked ? width - 48 : (width - 72) / 2)
        let layout = isStacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 28))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 24))
        let topTracks = Array(visibleTracks.prefix(10))

        return layout {
            VStack(alignment: .leading, spacing: 16) {
                Text("Mais ouvidas")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)

                if !isLoading && topTracks.isEmpty {
                    if trackSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Nenhuma música disponível")
                            .foregroundStyle(.secondary)
                    } else {
                        ContentUnavailableView.search(text: trackSearchText)
                    }
                }

                LazyVStack(spacing: 0) {
                    ForEach(topTracks, id: \.id) { track in
                        trackRow(track)
                        if track.id != topTracks.last?.id { Divider() }
                    }
                }
            }
            .frame(width: columnWidth, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Último lançamento")
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)

                    if let latestRelease {
                        Button {
                            onSelectAlbum(latestRelease)
                        } label: {
                            HStack(alignment: .center, spacing: 16) {
                                ArtworkView(
                                    artworkID: latestRelease.artworkId,
                                    size: min(140, columnWidth * 0.4)
                                )

                                VStack(alignment: .leading, spacing: 6) {
                                    Text(latestRelease.title)
                                        .font(.headline)
                                        .lineLimit(2)
                                    Text(latestRelease.artist)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Text(releaseYear(for: latestRelease))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("\(latestRelease.totalTracks) músicas")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Abrir álbum \(latestRelease.title)")
                    } else if !isLoading {
                        Text("Nenhum lançamento disponível")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: columnWidth, alignment: .leading)

                VStack(alignment: .leading, spacing: 16) {
                    Text("Álbuns essenciais")
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)

                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 16) {
                            ForEach(essentialAlbums, id: \.id) { album in
                                Button {
                                    onSelectAlbum(album)
                                } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        ArtworkView(artworkID: album.artworkId, size: 144)
                                        Text(album.title)
                                            .font(.headline)
                                            .lineLimit(2)
                                        Text(releaseYear(for: album))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(width: 144, alignment: .leading)
                                    .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Abrir álbum \(album.title)")
                            }
                        }
                        .padding(.leading, isStacked ? 0 : 24)
                    }
                    .scrollIndicators(.hidden)
                    // Extend into the column gap so the fade doesn't cover
                    // the first cover at its initial scroll position.
                    .mask {
                        HStack(spacing: 0) {
                            if !isStacked {
                                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                                    .frame(width: 24)
                            }
                            Rectangle()
                        }
                    }
                    .padding(.leading, isStacked ? 0 : -24)
                    .accessibilityIdentifier("artist.essentialAlbums")
                }
            }
            .frame(width: columnWidth + 24, alignment: .topLeading)
        }
        .padding(.trailing, -24)
    }

    private var latestRelease: Release? {
        albums.sorted {
            let leftDate = $0.releaseDate ?? ""
            let rightDate = $1.releaseDate ?? ""
            if leftDate != rightDate { return leftDate > rightDate }
            return $0.id < $1.id
        }.first
    }

    // Local ratings provide an interim order until editorial recommendations are available.
    private var essentialAlbums: [Release] {
        albums.sorted {
            if ($0.rating ?? 0) != ($1.rating ?? 0) {
                return ($0.rating ?? 0) > ($1.rating ?? 0)
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private var collectionControls: some View {
        HStack(spacing: 10) {
            CollectionPlaybackControls(
                isEnabled: !isLoading && !tracks.isEmpty,
                presentation: .groupedCompactShuffle,
                onPlay: {
                    Task { await store.playTracks(tracks, shuffleEnabled: false) }
                },
                onShuffle: {
                    Task { await store.playTracks(tracks, shuffleEnabled: true) }
                }
            )

            artistRelationshipControls

            Spacer(minLength: 24)

            Menu {
                Button("Adicionar músicas à fila", systemImage: "text.line.last.and.arrowtriangle.forward") {
                    Task {
                        for track in tracks {
                            await store.addToQueue(trackID: track.id)
                        }
                    }
                }
                .disabled(isLoading || tracks.isEmpty)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 34, height: 34)
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .background(Color.primary.opacity(0.08), in: .circle)
            .help("Opções")
            .accessibilityLabel("Opções")
            .accessibilityIdentifier("artist.options")

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Pesquisar", text: $trackSearchText)
                    .textFieldStyle(.plain)
                    .focused($isTrackSearchFocused)
                    .onExitCommand {
                        trackSearchText = ""
                        isTrackSearchFocused = false
                    }
            }
            .padding(.horizontal, 12)
            .frame(width: 147, height: 34)
            .background(Color.primary.opacity(0.08), in: .capsule)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("artist.tracks.search")

            Menu {
                Picker("Organizar", selection: $trackOrder) {
                    ForEach(TrackOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .frame(width: 34, height: 34)
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .background(Color.primary.opacity(0.08), in: .capsule)
            .help("Organizar ou filtrar faixas")
            .accessibilityLabel("Organizar ou filtrar faixas")
            .accessibilityIdentifier("artist.tracks.organize")
        }
    }

    private var isFollowing: Bool {
        followedArtistIDs.split(separator: ",").contains(Substring(String(artist.id)))
    }

    private var isFavorite: Bool {
        favoriteArtistIDs.split(separator: ",").contains(Substring(String(artist.id)))
    }

    private func togglingArtist(in storedIDs: String) -> String {
        var ids = Set(storedIDs.split(separator: ",").map(String.init))
        let id = String(artist.id)
        if ids.contains(id) {
            ids.remove(id)
        } else {
            ids.insert(id)
        }
        return ids.sorted().joined(separator: ",")
    }

    private var artistRelationshipControls: some View {
        HStack(spacing: 10) {
            Button {
                followedArtistIDs = togglingArtist(in: followedArtistIDs)
            } label: {
                Group {
                    if isFollowing {
                        Image(systemName: "person.fill")
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 9, weight: .bold))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.background, Color.accentColor)
                                    .offset(x: 5, y: 2)
                            }
                    } else {
                        Image(systemName: "person.badge.plus")
                    }
                }
                .frame(width: 34, height: 34)
                .background(relationshipBackground, in: .circle)
                .contentShape(.circle)
            }
            .help(isFollowing ? "Deixar de seguir artista" : "Seguir artista")
            .accessibilityLabel(isFollowing ? "Deixar de seguir artista" : "Seguir artista")
            .accessibilityValue(isFollowing ? "Seguindo" : "Não seguindo")
            .accessibilityIdentifier("artist.follow")

            Button {
                favoriteArtistIDs = togglingArtist(in: favoriteArtistIDs)
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .frame(width: 34, height: 34)
                    .background(relationshipBackground, in: .circle)
                    .contentShape(.circle)
            }
            .help(isFavorite ? "Desfavoritar artista" : "Favoritar artista")
            .accessibilityLabel(isFavorite ? "Desfavoritar artista" : "Favoritar artista")
            .accessibilityValue(isFavorite ? "Favorito" : "Não favorito")
            .accessibilityIdentifier("artist.favorite")
        }
        .buttonStyle(.plain)
        .font(.body.weight(.medium))
        .foregroundStyle(Color.accentColor.opacity(appearsActive ? 1 : 0.63))
    }

    private var relationshipBackground: Color {
        Color.primary.opacity(
            colorScheme == .dark
                ? (appearsActive ? 0.08 : 0.10)
                : (appearsActive ? 0.10 : 0.06)
        )
    }

    private var visibleTracks: [Track] {
        let query = trackSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var visibleTracks = tracks

        if !query.isEmpty {
            visibleTracks = visibleTracks.filter {
                $0.title.localizedStandardContains(query)
                    || $0.artist.localizedStandardContains(query)
                    || $0.release.localizedStandardContains(query)
            }
        }

        switch trackOrder {
        case .album:
            break
        case .title:
            visibleTracks.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .artist:
            visibleTracks.sort { $0.artist.localizedStandardCompare($1.artist) == .orderedAscending }
        case .duration:
            visibleTracks.sort { $0.durationSeconds < $1.durationSeconds }
        }

        return visibleTracks
    }

    private func releaseYear(for album: Release) -> String {
        guard let date = album.releaseDate?.trimmingCharacters(in: .whitespacesAndNewlines),
              date.count >= 4,
              let year = Int(date.prefix(4)),
              year > 0 else {
            return "Ano desconhecido"
        }
        return String(year)
    }

    private func trackRow(_ track: Track) -> some View {
        HStack(spacing: 12) {
            ArtworkView(artworkID: track.artworkId, size: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .activeTrackTitle(trackID: track.id)
                Text(track.release)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Reproduzir \(track.title)")

            Button {
                Task { await store.addToQueue(trackID: track.id) }
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Adicionar \(track.title) à fila")
        }
        .padding(.vertical, 8)
        .playTrackOnDoubleClick {
            Task { await store.play(trackID: track.id) }
        }
        .trackContextMenu(track: track) {
            Task { await store.play(trackID: track.id) }
        }
        .accessibilityIdentifier("artist.track.\(track.id)")
    }

    private func artistFooter(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 36) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Sobre \(artist.name)")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Lorem ipsum dolor sit amet, consectetur adipiscing elit. Vivamus lacinia odio vitae vestibulum vestibulum. Cras venenatis euismod malesuada. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur.")
                    Text("Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum. Donec aliquet, nisl sed semper tempor, justo diam cursus libero, vel feugiat nunc purus at odio.")
                    Text("Curabitur pretium tincidunt lacus. Nulla gravida orci a odio. Nullam varius, turpis et commodo pharetra, est eros bibendum elit, nec luctus magna felis sollicitudin mauris.")
                }
                .font(.body)
                .foregroundStyle(.secondary)
                .lineSpacing(4)
                .frame(maxWidth: 800, alignment: .leading)
            }
            .padding(.horizontal, 24)

            VStack(alignment: .leading, spacing: 16) {
                Text("Artistas similares")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, 24)

                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 20) {
                        ForEach(similarArtists, id: \.id) { similar in
                            Button {
                                onSelectArtist?(similar)
                            } label: {
                                VStack(spacing: 10) {
                                    similarArtistAvatar(for: similar)

                                    Text(similar.name)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.center)
                                        .frame(width: 104)
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Abrir artista \(similar.name)")
                        }
                    }
                    .padding(.horizontal, 24)
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(.top, 36)
        .padding(.bottom, 180)
        .frame(width: width, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            Rectangle()
                .fill(.quaternary)
                .ignoresSafeArea(.container, edges: .bottom)
                .padding(.bottom, -1000)
        }
        .backgroundExtensionEffect()
        .accessibilityIdentifier("artist.footer")
    }

    private var similarArtists: [Artist] {
        let candidates = store.artists.filter { $0.id != artist.id }
        if !candidates.isEmpty {
            return Array(candidates.prefix(10))
        }
        return [
            Artist(id: -1, name: "Artista Similar 1"),
            Artist(id: -2, name: "Artista Similar 2"),
            Artist(id: -3, name: "Artista Similar 3"),
            Artist(id: -4, name: "Artista Similar 4"),
            Artist(id: -5, name: "Artista Similar 5")
        ]
    }

    private func similarArtistAvatar(for similar: Artist) -> some View {
        let artID = artworkID(for: similar)
        return Group {
            if let artID {
                ArtworkView(artworkID: artID, size: 104, showsBorder: false)
                    .scaledToFill()
            } else {
                ZStack {
                    Circle()
                        .fill(.tertiary)
                    Image(systemName: "person.fill")
                        .font(.system(size: 38))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 104, height: 104)
        .clipShape(Circle())
        .overlay {
            Circle()
                .strokeBorder(.separator, lineWidth: 0.5)
        }
    }

    private func artworkID(for similar: Artist) -> String? {
        store.releases.first(where: {
            $0.artist.localizedCaseInsensitiveCompare(similar.name) == .orderedSame
        })?.artworkId
    }
}
