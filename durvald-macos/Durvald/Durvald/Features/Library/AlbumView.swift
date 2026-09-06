import SwiftUI

struct AlbumView: View {
    private enum TrackOrder: String, CaseIterable, Identifiable {
        case album
        case title
        case artist
        case duration

        var id: Self { self }

        var title: String {
            switch self {
            case .album: "Ordem do álbum"
            case .title: "Título"
            case .artist: "Artista"
            case .duration: "Duração"
            }
        }
    }

    @Environment(DurvaldCoreStore.self) private var store

    let album: Release
    let onSelectArtist: (Artist) -> Void

    @State private var tracks: [Track] = []
    @State private var isLoading = true
    @State private var trackSearchText = ""
    @State private var trackOrder: TrackOrder = .album
    @FocusState private var isTrackSearchFocused: Bool

    private let artworkSize: CGFloat = 268

    private var currentAlbum: Release {
        store.releases.first(where: { $0.id == album.id }) ?? album
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                trackList
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: album.id) {
            isLoading = true
            tracks = await store.tracks(forReleaseID: album.id)
            isLoading = false
        }
        .accessibilityIdentifier("album.detail.\(album.id)")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(alignment: .top, spacing: 24) {
                ArtworkView(
                    artworkID: album.artworkId,
                    size: artworkSize
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(album.title)
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .multilineTextAlignment(.leading)
                        .padding(.top, 24)

                    Button {
                        guard let artist = store.artists.first(where: { $0.id == album.artistId }) else {
                            return
                        }
                        onSelectArtist(artist)
                    } label: {
                        Text(album.artist)
                            .font(.title)
                            .foregroundStyle(Color.accentColor)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    .help("Abrir artista \(album.artist)")
                    .accessibilityLabel("Abrir artista \(album.artist)")
                    .accessibilityIdentifier("album.artist")
                }
                .frame(maxWidth: .infinity, minHeight: artworkSize, alignment: .topLeading)
            }

            HStack(spacing: 10) {
                CollectionPlaybackControls(
                    isEnabled: !isLoading && !tracks.isEmpty,
                    presentation: .groupedCompactShuffle,
                    isFavorite: currentAlbum.isFavorite,
                    onToggleFavorite: {
                        store.setReleaseFavorite(
                            releaseID: album.id,
                            favorite: !currentAlbum.isFavorite
                        )
                    },
                    onPlay: {
                        Task {
                            await store.playRelease(
                                releaseID: album.id,
                                shuffleEnabled: false
                            )
                        }
                    },
                    onShuffle: {
                        Task {
                            await store.playRelease(
                                releaseID: album.id,
                                shuffleEnabled: true
                            )
                        }
                    }
                )

                Spacer(minLength: 24)

                Menu {
                    Button(currentAlbum.isFavorite ? "Desfavoritar álbum" : "Favoritar álbum",
                           systemImage: currentAlbum.isFavorite ? "star.slash" : "star") {
                        store.setReleaseFavorite(
                            releaseID: album.id,
                            favorite: !currentAlbum.isFavorite
                        )
                    }
                    Button("Abrir artista", systemImage: "person") {
                        guard let artist = store.artists.first(where: { $0.id == album.artistId }) else {
                            return
                        }
                        onSelectArtist(artist)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 34, height: 34)
                }
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .background(Color.primary.opacity(0.08), in: .circle)
                .help("Opções")
                .accessibilityLabel("Opções")
                .accessibilityIdentifier("album.options")

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
                .accessibilityIdentifier("album.tracks.search")

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
                .accessibilityIdentifier("album.tracks.organize")
            }
        }
    }

    @ViewBuilder
    private var trackList: some View {
        if isLoading {
            ProgressView("Carregando faixas…")
                .frame(maxWidth: .infinity, alignment: .center)
        } else if tracks.isEmpty {
            ContentUnavailableView(
                "Nenhuma faixa",
                systemImage: "music.note",
                description: Text("Este álbum não possui faixas disponíveis.")
            )
            .frame(maxWidth: .infinity)
        } else if visibleTracks.isEmpty {
            ContentUnavailableView.search(text: trackSearchText)
                .frame(maxWidth: .infinity)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(visibleTracks, id: \.id) { track in
                    trackRow(track)

                    if track.id != visibleTracks.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private var visibleTracks: [Track] {
        let query = trackSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var visibleTracks = tracks

        if !query.isEmpty {
            visibleTracks = visibleTracks.filter {
                $0.title.localizedStandardContains(query)
                    || $0.artist.localizedStandardContains(query)
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

    private func trackRow(_ track: Track) -> some View {
        HStack(spacing: 12) {
            AlbumTrackPosition(trackID: track.id, number: trackNumber(for: track))

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .activeTrackTitle(trackID: track.id)
                    .lineLimit(1)

                if !track.artist.isEmpty && track.artist != album.artist {
                    Text(track.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(durationText(track.durationSeconds))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Button {
                Task { await store.addToQueue(trackID: track.id) }
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Adicionar \(track.title) à fila")
        }
        .padding(.vertical, 9)
        .playTrackOnDoubleClick {
            Task { await store.playRelease(releaseID: album.id, startingAt: track.id) }
        }
        .trackContextMenu(track: track) {
            Task { await store.playRelease(releaseID: album.id, startingAt: track.id) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("album.track.\(track.id)")
    }

    private func trackNumber(for track: Track) -> String {
        guard album.totalDiscs > 1 else {
            return "\(track.trackNumber)"
        }

        return "\(track.discNumber).\(track.trackNumber)"
    }

    private func durationText(_ duration: Double) -> String {
        let totalSeconds = max(0, Int(duration.rounded()))
        return String(
            format: "%d:%02d",
            totalSeconds / 60,
            totalSeconds % 60
        )
    }
}
