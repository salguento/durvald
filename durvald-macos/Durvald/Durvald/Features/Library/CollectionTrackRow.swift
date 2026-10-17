import SwiftUI

/// Collection-specific playback stays with the caller; layout and personal
/// controls are shared by albums, saved playlists and unsaved Replay previews.
struct CollectionTrackRow: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(\.trackMenuNavigation) private var navigation
    let track: Track
    let number: String
    var showsArtwork = true
    var showsAlbum = true
    var activeOverride: Bool? = nil
    var isSelected = false
    let onPlay: () -> Void
    @State private var isHovered = false

    private var currentTrack: Track { store.loadedTrack(id: track.id) ?? track }

    var body: some View {
        let track = currentTrack
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    AlbumTrackPosition(trackID: track.id, number: number, isActiveOverride: activeOverride)
                        .playTrackOnDoubleClick(onPlay)
                    if showsArtwork {
                        ArtworkView(artworkID: track.artworkId, size: 42)
                            .playTrackOnDoubleClick(onPlay)
                    }
                }
                metadata(track)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if showsAlbum && !track.release.isEmpty {
                CollectionTrackMetadataLink(title: track.release, hint: "Abrir álbum \(track.release)") {
                    openAlbum(track)
                }
                .font(.subheadline)
                .frame(maxWidth: 160, alignment: .leading)
                .accessibilityIdentifier("collection.track.\(track.id).album")
            }
            TrackListTrailingControls(track: track, isRowHovered: isHovered, onPlay: onPlay)
                .padding(.trailing, 8)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(isSelected ? 0.10 : (isHovered ? 0.08 : 0)))
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .trackContextMenu(track: track, onPlay: onPlay)
        .accessibilityElement(children: .contain)
    }

    private func metadata(_ track: Track) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(track.title)
                .activeTrackTitle(trackID: track.id, activeOverride: activeOverride, inactiveColor: .primary)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.tail)
                .playTrackOnDoubleClick(onPlay)

            if !track.artist.isEmpty {
                CollectionTrackMetadataLink(title: track.artist, hint: "Abrir artista \(track.artist)") {
                    openArtist(track)
                }
                .font(.subheadline)
                .accessibilityIdentifier("collection.track.\(track.id).artist")
            }
        }
    }

    private func openArtist(_ track: Track) {
        Task {
            do {
                if let artist = try await store.core?.artist(artistId: track.artistId) {
                    navigation.artist(artist)
                }
            } catch { store.errorMessage = String(describing: error) }
        }
    }

    private func openAlbum(_ track: Track) {
        Task {
            do {
                if let album = try await store.core?.release(releaseId: track.releaseId) {
                    navigation.album(album)
                }
            } catch { store.errorMessage = String(describing: error) }
        }
    }
}

private struct CollectionTrackMetadataLink: View {
    let title: String
    let hint: String
    let action: () -> Void
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Text(title)
                .foregroundStyle(.secondary)
                .underline(isHovered || isFocused)
                .lineLimit(1)
                .truncationMode(.tail)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .help(hint)
        .accessibilityLabel(title)
        .accessibilityHint(hint)
        .accessibilityAddTraits(.isLink)
    }
}
