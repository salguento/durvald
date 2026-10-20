import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class PlaylistCreationCoordinator {
    var isPresented = false
    var pendingTrackIDs: [Int64] = []
    var pendingTrackID: Int64?
    var pendingReleaseID: Int64?
    var pendingPlaylistID: Int64?
    var editingPlaylist: Playlist?

    func request(for trackID: Int64?) {
        pendingPlaylistID = nil
        pendingReleaseID = nil
        pendingTrackIDs = []
        pendingTrackID = trackID
        editingPlaylist = nil
        isPresented = true
    }

    func requestTracks(_ ids: [Int64]) {
        request(for: nil)
        pendingTrackIDs = ids
    }

    func requestAlbum(_ releaseID: Int64) {
        request(for: nil)
        pendingReleaseID = releaseID
    }

    func requestPlaylist(_ playlistID: Int64) {
        request(for: nil)
        pendingPlaylistID = playlistID
    }

    func requestEdit(_ playlist: Playlist) {
        pendingPlaylistID = nil
        pendingReleaseID = nil
        pendingTrackIDs = []
        pendingTrackID = nil
        editingPlaylist = playlist
        isPresented = true
    }

    func reset() {
        pendingPlaylistID = nil
        pendingReleaseID = nil
        pendingTrackIDs = []
        pendingTrackID = nil
        editingPlaylist = nil
    }
}

extension View {
    func trackContextMenu(track: Track, onPlay: @escaping () -> Void,
                          additionalActions: [TrackMenuAction] = []) -> some View {
        modifier(TrackContextMenuModifier(
            track: track,
            onPlay: onPlay,
            additionalActions: additionalActions
        ))
    }
}

struct TrackMenuNavigation {
    var artist: (Artist) -> Void = { _ in }
    var album: (Release) -> Void = { _ in }
    var playlist: (Playlist) -> Void = { _ in }
    var deletedPlaylist: (Int64) -> Void = { _ in }
}

private struct TrackMenuNavigationKey: EnvironmentKey {
    static let defaultValue = TrackMenuNavigation()
}

extension EnvironmentValues {
    var trackMenuNavigation: TrackMenuNavigation {
        get { self[TrackMenuNavigationKey.self] }
        set { self[TrackMenuNavigationKey.self] = newValue }
    }
}

private struct TrackContextMenuModifier: ViewModifier {
    @Environment(\.commandFocusRequest) private var commandFocusRequest
    @Environment(\.commandFocusID) private var commandFocusID
    @Environment(\.commandSelectionOverride) private var commandOverride
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(PlaylistCreationCoordinator.self) private var playlistCreation
    @Environment(TrackInfoCoordinator.self) private var trackInfo
    @Environment(\.trackMenuNavigation) private var navigation

    @FocusState private var isCommandFocused: Bool
    let track: Track
    let onPlay: () -> Void
    let additionalActions: [TrackMenuAction]

    func body(content: Content) -> some View {
        content
        .focusable()
        .focused($isCommandFocused)
        .onTapGesture { isCommandFocused = true }
        .onChange(of: commandFocusRequest?.revision) { _, _ in
            if let commandFocusID, commandFocusRequest?.target == commandFocusID { isCommandFocused = true }
        }
        .focusedValue(\.selectionCommands, commandOverride ?? AppCommandTarget.tracks([store.loadedTrack(id: track.id) ?? track],
            store: store, info: trackInfo, creation: playlistCreation, navigation: navigation, play: onPlay))
        .overlay {
            NativeLibraryMenu(mode: .context) { controller in
                controller.configure(track: track, store: store, playlistCreation: playlistCreation,
                    trackInfo: trackInfo, navigation: navigation, additionalActions: additionalActions)
            }
                .accessibilityHidden(true)
        }
    }
}

extension View {
    func albumContextMenu(album: Release?) -> some View {
        modifier(AlbumContextMenuModifier(album: album))
    }
}

private struct AlbumContextMenuModifier: ViewModifier {
    @Environment(\.trackMenuNavigation) private var navigation
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(PlaylistCreationCoordinator.self) private var playlistCreation
    let album: Release?

    func body(content: Content) -> some View {
        content
        .focusable()
        .focusedValue(\.selectionCommands, album.map { AppCommandTarget.album($0, store: store, creation: playlistCreation, navigation: navigation) })
        .overlay {
            if let album {
                NativeLibraryMenu(mode: .context) { controller in
                    controller.configure(album: album, store: store, playlistCreation: playlistCreation)
                }
                    .accessibilityHidden(true)
            }
        }
    }
}

extension View {
    func playlistContextMenu(playlist: Playlist) -> some View {
        modifier(PlaylistContextMenuModifier(playlist: playlist))
    }
}

private struct PlaylistContextMenuModifier: ViewModifier {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(PlaylistCreationCoordinator.self) private var creation
    @Environment(\.trackMenuNavigation) private var navigation
    let playlist: Playlist

    func body(content: Content) -> some View {
        content
        .focusable()
        .focusedValue(\.selectionCommands, AppCommandTarget.playlist(playlist, store: store, creation: creation, navigation: navigation))
        .overlay {
            NativeLibraryMenu(mode: .context) { controller in
                controller.configure(playlist: playlist, store: store, creation: creation, navigation: navigation)
            }.accessibilityHidden(true)
        }
    }
}

extension View {
    func trackOptionsMenu(
        track: Track?,
        onPlay: @escaping () -> Void,
        additionalActions: [TrackMenuAction] = []
    ) -> some View {
        modifier(TrackOptionsMenuModifier(
            track: track,
            onPlay: onPlay,
            additionalActions: additionalActions
        ))
    }

    func albumOptionsMenu(album: Release?) -> some View {
        modifier(AlbumOptionsMenuModifier(album: album))
    }

    func playlistOptionsMenu(playlist: Playlist) -> some View {
        modifier(PlaylistOptionsMenuModifier(playlist: playlist))
    }
}

private struct TrackOptionsMenuModifier: ViewModifier {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(PlaylistCreationCoordinator.self) private var playlistCreation
    @Environment(TrackInfoCoordinator.self) private var trackInfo
    @Environment(\.trackMenuNavigation) private var navigation

    let track: Track?
    let onPlay: () -> Void
    let additionalActions: [TrackMenuAction]

    func body(content: Content) -> some View {
        content.overlay {
            if let track {
                NativeLibraryMenu(mode: .options) { controller in
                    controller.configure(track: track, store: store, playlistCreation: playlistCreation,
                        trackInfo: trackInfo, navigation: navigation, additionalActions: additionalActions)
                }
                .accessibilityHidden(true)
            }
        }
    }
}

private struct AlbumOptionsMenuModifier: ViewModifier {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(PlaylistCreationCoordinator.self) private var playlistCreation
    let album: Release?

    func body(content: Content) -> some View {
        content.overlay {
            if let album {
                NativeLibraryMenu(mode: .options) { controller in
                    controller.configure(album: album, store: store, playlistCreation: playlistCreation)
                }
                .accessibilityHidden(true)
            }
        }
    }
}

private struct PlaylistOptionsMenuModifier: ViewModifier {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(PlaylistCreationCoordinator.self) private var creation
    @Environment(\.trackMenuNavigation) private var navigation
    let playlist: Playlist

    func body(content: Content) -> some View {
        content.overlay {
            NativeLibraryMenu(mode: .options) { controller in
                controller.configure(playlist: playlist, store: store, creation: creation, navigation: navigation)
            }
            .accessibilityHidden(true)
        }
    }
}
