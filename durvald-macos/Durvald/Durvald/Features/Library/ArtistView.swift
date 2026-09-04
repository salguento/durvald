import SwiftUI

struct ArtistView: View {
    @Environment(DurvaldCoreStore.self) private var store

    let artist: Artist
    let onSelectAlbum: (Release) -> Void

    @State private var tracks: [Track] = []
    @State private var albums: [Release] = []
    @State private var isLoading = true

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(artist.name)
                        .font(.largeTitle.bold())

                    if !albums.isEmpty {
                        Text("Álbuns")
                            .font(.title2.bold())

                        LazyVGrid(
                            columns: AlbumGridLayout.columns(for: geometry.size.width),
                            alignment: .leading,
                            spacing: AlbumGridLayout.spacing
                        ) {
                            ForEach(albums, id: \.id) { album in
                                AlbumCard(release: album, onSelectAlbum: onSelectAlbum)
                            }
                        }
                    }

                    if !tracks.isEmpty {
                        Text("Músicas")
                            .font(.title2.bold())

                        LazyVStack(spacing: 0) {
                            ForEach(tracks, id: \.id) { track in
                                trackRow(track)
                                if track.id != tracks.last?.id { Divider() }
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
            }
        }
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
}
