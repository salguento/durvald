import SwiftUI

struct AlbumView: View {
    @Environment(DurvaldCoreStore.self) private var store

    let album: Release
    let onSelectArtist: (Artist) -> Void

    @State private var tracks: [Track] = []
    @State private var isLoading = true

    private let artworkSize: CGFloat = 268

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
        HStack(alignment: .bottom, spacing: 24) {
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

                Spacer(minLength: 12)

                CollectionPlaybackControls(
                    isEnabled: !isLoading && !tracks.isEmpty,
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
                description: Text("Este álbum não possui faixas disponíveis.")
            )
            .frame(maxWidth: .infinity)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(tracks, id: \.id) { track in
                    trackRow(track)

                    if track.id != tracks.last?.id {
                        Divider()
                    }
                }
            }
        }
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
