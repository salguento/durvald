import SwiftUI

struct PlaylistView: View {
    private enum TrackOrder: String, CaseIterable, Identifiable {
        case playlist
        case title
        case artist
        case duration

        var id: Self { self }

        var title: String {
            switch self {
            case .playlist: "Ordem da playlist"
            case .title: "Título"
            case .artist: "Artista"
            case .duration: "Duração"
            }
        }
    }

    private struct TrackEntry: Identifiable {
        let position: Int
        let track: Track

        var id: Int { position }
    }

    @Environment(DurvaldCoreStore.self) private var store
    @Environment(PlaylistCreationCoordinator.self) private var playlistCreation

    let playlist: Playlist

    @State private var tracks: [Track] = []
    @State private var isLoading = true
    @State private var selectedTrackPosition: Int?
    @State private var trackSearchText = ""
    @State private var trackOrder: TrackOrder = .playlist
    @FocusState private var isTrackSearchFocused: Bool

    private let artworkSize: CGFloat = 268

    private var currentPlaylist: Playlist {
        store.playlists.first(where: { $0.id == playlist.id }) ?? playlist
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                trackList
                VStack(alignment: .leading, spacing: 10) {
                    Divider()
                    PlaylistMusicPicker(playlist: currentPlaylist) { track in
                        tracks.append(track)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: playlist.id) {
            isLoading = true
            tracks = await store.tracks(forPlaylistID: playlist.id)
            isLoading = false
        }
        .accessibilityIdentifier("playlist.detail.\(playlist.id)")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(alignment: .top, spacing: 24) {
                PlaylistArtworkThumbnail(
                    playlistID: currentPlaylist.id,
                    artworkBase64: currentPlaylist.artworkId,
                    size: artworkSize
                )

                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        playlistCreation.requestEdit(currentPlaylist)
                    } label: {
                        Text(currentPlaylist.name)
                            .font(.largeTitle)
                            .fontWeight(.bold)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 24)
                    .help("Editar playlist")
                    .accessibilityLabel("Editar playlist \(currentPlaylist.name)")
                    .accessibilityIdentifier("playlist.edit")

                    if !currentPlaylist.description.isEmpty {
                        Text(currentPlaylist.description)
                            .font(.title2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }

                    Text("\(currentPlaylist.trackCount) músicas")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, minHeight: artworkSize, alignment: .topLeading)
            }

            HStack(spacing: 10) {
                CollectionPlaybackControls(
                    isEnabled: !isLoading && !tracks.isEmpty,
                    presentation: .groupedCompactShuffle,
                    isFavorite: currentPlaylist.isFavorite,
                    onToggleFavorite: {
                        store.setPlaylistFavorite(
                            playlistID: playlist.id,
                            favorite: !currentPlaylist.isFavorite
                        )
                    },
                    onPlay: {
                        guard !tracks.isEmpty else { return }
                        Task {
                            await store.playPlaylist(
                                playlistID: playlist.id,
                                startingAtPosition: 0,
                                shuffleEnabled: false
                            )
                        }
                    },
                    onShuffle: {
                        guard !tracks.isEmpty else { return }
                        Task {
                            await store.playPlaylist(
                                playlistID: playlist.id,
                                startingAtPosition: 0,
                                shuffleEnabled: true
                            )
                        }
                    }
                )

                Spacer(minLength: 24)

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
                .accessibilityIdentifier("playlist.tracks.organize")

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
                .accessibilityIdentifier("playlist.tracks.search")
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
                description: Text("Esta playlist ainda não possui músicas.")
            )
            .frame(maxWidth: .infinity)
        } else if visibleTracks.isEmpty {
            ContentUnavailableView.search(text: trackSearchText)
                .frame(maxWidth: .infinity)
        } else {
            LazyVStack(spacing: 1) {
                ForEach(visibleTracks) { entry in
                    trackRow(entry.track, position: entry.position)
                }
            }
        }
    }

    private var visibleTracks: [TrackEntry] {
        let query = trackSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var entries = tracks.enumerated().map {
            TrackEntry(position: $0.offset + 1, track: $0.element)
        }

        if !query.isEmpty {
            entries = entries.filter {
                $0.track.title.localizedStandardContains(query)
                    || $0.track.artist.localizedStandardContains(query)
                    || $0.track.release.localizedStandardContains(query)
            }
        }

        switch trackOrder {
        case .playlist:
            break
        case .title:
            entries.sort { $0.track.title.localizedStandardCompare($1.track.title) == .orderedAscending }
        case .artist:
            entries.sort { $0.track.artist.localizedStandardCompare($1.track.artist) == .orderedAscending }
        case .duration:
            entries.sort { $0.track.durationSeconds < $1.track.durationSeconds }
        }

        return entries
    }

    private func trackRow(_ track: Track, position: Int) -> some View {
        let isActive = activeTrackPosition == position

        return HStack(spacing: 12) {
            AlbumTrackPosition(
                trackID: track.id,
                number: "\(position)",
                isActiveOverride: isActive
            )
                .offset(x: -6)

            ArtworkView(artworkID: track.artworkId, size: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .foregroundStyle(isActive ? Color.accentColor : Color.primary)
                    .lineLimit(1)

                if !track.artist.isEmpty {
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
        .padding(.vertical, 8)
        .padding(.trailing, 16)
        .playTrackOnDoubleClick {
            Task {
                await store.playPlaylist(
                    playlistID: playlist.id,
                    startingAtPosition: position - 1
                )
            }
        }
        .background {
            if selectedTrackPosition == position {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.10))
            }
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                selectedTrackPosition = position
            }
        )
        .trackContextMenu(track: track) {
            Task {
                await store.playPlaylist(
                    playlistID: playlist.id,
                    startingAtPosition: position - 1
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selectedTrackPosition == position ? .isSelected : [])
        .accessibilityIdentifier("playlist.track.\(track.id)")
    }

    private var activeTrackPosition: Int? {
        guard let activeTrackID = store.activeTrackID else { return nil }
        let queueTrackIDs = store.queue.map(\.trackId)

        if !queueTrackIDs.isEmpty,
           let index = tracks.indices.first(where: { index in
               tracks[index...].map(\.id) == queueTrackIDs
           }) {
            return index + 1
        }

        let matchingPositions = tracks.indices.filter { tracks[$0].id == activeTrackID }
        guard matchingPositions.count == 1, let index = matchingPositions.first else { return nil }
        return index + 1
    }

    private func durationText(_ duration: Double) -> String {
        let totalSeconds = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}
