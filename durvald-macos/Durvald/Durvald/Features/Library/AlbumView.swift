import SwiftUI

struct AlbumView: View {
    @EnvironmentObject private var store: DurvaldCoreStore

    let album: Release

    @State private var tracks: [Track] = []
    @State private var isLoading = true

    private let artworkSize: CGFloat = 320

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
        HStack(alignment: .center, spacing: 24) {
            ArtworkView(
                artworkID: album.artworkId,
                size: artworkSize
            )

            VStack(alignment: .leading, spacing: 8) {
                Text(album.title)
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.leading)

                Text(album.artist)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
            Text(trackNumber(for: track))
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)

            Button {
                Task { await store.play(trackID: track.id) }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .lineLimit(1)

                    if !track.artist.isEmpty && track.artist != album.artist {
                        Text(track.artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

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
        .contentShape(Rectangle())
        .contextMenu {
            Button("Reproduzir agora") {
                Task { await store.play(trackID: track.id) }
            }

            Button("Adicionar à fila") {
                Task { await store.addToQueue(trackID: track.id) }
            }
        }
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
