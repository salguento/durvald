import SwiftUI

struct PlaylistsView: View {
    @Environment(DurvaldCoreStore.self) private var store
    @AppStorage("playlists.listingMode") private var listingMode: CollectionListingMode = .standard
    @AppStorage("playlists.listingOrder") private var listingOrder: CollectionListingOrder = .recent
    @State private var tracksByPlaylist: [Int64: [Track]] = [:]
    let onSelectPlaylist: (Playlist) -> Void

    var body: some View {
        CollectionListingLayout(mode: listingMode) { size in
            ForEach(orderedPlaylists, id: \.id) { playlist in
                CollectionListingItem(title: playlist.name, mode: listingMode, artworkSize: size, action: { onSelectPlaylist(playlist) }) {
                    PlaylistArtworkThumbnail(playlistID: playlist.id, artworkBase64: playlist.artworkId, size: size)
                }
                .playlistContextMenu(playlist: playlist)
                .accessibilityIdentifier("playlist.\(playlist.id)")
            }
        }
        .task(id: orderingTaskID) {
            await loadOrderingTracksIfNeeded()
        }
    }

    private var orderedPlaylists: [Playlist] {
        CollectionListingSorter.playlists(
            store.playlists,
            order: listingOrder,
            tracksByPlaylist: tracksByPlaylist,
            releases: store.releases
        )
    }

    private var orderingTaskID: String {
        "\(listingOrder.rawValue):\(store.playlists.map(\.id))"
    }

    private func loadOrderingTracksIfNeeded() async {
        guard listingOrder == .recent || listingOrder == .artist || listingOrder == .releaseDate,
              let core = store.core else { return }
        var loaded: [Int64: [Track]] = [:]
        for playlist in store.playlists {
            guard !Task.isCancelled else { return }
            loaded[playlist.id] = try? await core.playlistTracks(playlistId: playlist.id)
        }
        tracksByPlaylist = loaded
    }
}
