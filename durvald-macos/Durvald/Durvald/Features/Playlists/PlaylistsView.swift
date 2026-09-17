import SwiftUI

struct PlaylistsView: View {
    @Environment(DurvaldCoreStore.self) private var store
    @AppStorage("playlists.listingMode") private var listingMode: CollectionListingMode = .standard
    let onSelectPlaylist: (Playlist) -> Void

    var body: some View {
        CollectionListingLayout(mode: listingMode) { size in
            ForEach(store.playlists, id: \.id) { playlist in
                CollectionListingItem(title: playlist.name, mode: listingMode, artworkSize: size, action: { onSelectPlaylist(playlist) }) {
                    PlaylistArtworkThumbnail(playlistID: playlist.id, artworkBase64: playlist.artworkId, size: size)
                }
                .accessibilityIdentifier("playlist.\(playlist.id)")
            }
        }
    }
}
