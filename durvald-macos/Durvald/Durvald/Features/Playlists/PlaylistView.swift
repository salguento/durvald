import SwiftUI

struct PlaylistView: View {
    @Environment(DurvaldCoreStore.self) private var store

    let playlist: Playlist

    @State private var tracks: [Track] = []
    @State private var isLoading = true
    @State private var selectedTrackPosition: Int?

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
        HStack(alignment: .bottom, spacing: 24) {
            PlaylistArtworkThumbnail(
                playlistID: playlist.id,
                artworkBase64: playlist.artworkId,
                size: artworkSize
            )

            VStack(alignment: .leading, spacing: 8) {
                Text(playlist.name)
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.leading)
                    .padding(.top, 24)

                if !playlist.description.isEmpty {
                    Text(playlist.description)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Text("\(currentPlaylist.trackCount) músicas")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)

                Spacer(minLength: 12)

                CollectionPlaybackControls(
                    isEnabled: !isLoading && !tracks.isEmpty,
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
            }
            .frame(maxWidth: .infinity, minHeight: artworkSize, maxHeight: artworkSize,
                   alignment: .leading)
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
        } else {
            LazyVStack(spacing: 1) {
                ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                    trackRow(track, position: index + 1)
                }
            }
        }
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
