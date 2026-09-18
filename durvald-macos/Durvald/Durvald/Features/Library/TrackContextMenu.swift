import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class PlaylistCreationCoordinator {
    var isPresented = false
    var pendingTrackID: Int64?
    var pendingReleaseID: Int64?
    var pendingPlaylistID: Int64?
    var editingPlaylist: Playlist?

    func request(for trackID: Int64?) {
        pendingPlaylistID = nil
        pendingReleaseID = nil
        pendingTrackID = trackID
        editingPlaylist = nil
        isPresented = true
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
        pendingTrackID = nil
        editingPlaylist = playlist
        isPresented = true
    }

    func reset() {
        pendingPlaylistID = nil
        pendingReleaseID = nil
        pendingTrackID = nil
        editingPlaylist = nil
    }
}

struct TrackMenuAction {
    let title: String
    let systemImage: String?
    let isEnabled: Bool
    let action: () -> Void

    init(_ title: String, systemImage: String? = nil, isEnabled: Bool = true,
         action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.isEnabled = isEnabled
        self.action = action
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
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(PlaylistCreationCoordinator.self) private var playlistCreation
    @Environment(TrackInfoCoordinator.self) private var trackInfo
    @Environment(\.trackMenuNavigation) private var navigation

    let track: Track
    let onPlay: () -> Void
    let additionalActions: [TrackMenuAction]

    func body(content: Content) -> some View {
        content.overlay {
            NativeTrackContextMenu(track: track, store: store,
                playlistCreation: playlistCreation, trackInfo: trackInfo,
                navigation: navigation, additionalActions: additionalActions)
                .accessibilityHidden(true)
        }
    }
}

private struct NativeTrackContextMenu: NSViewRepresentable {
    let track: Track
    let store: DurvaldCoreStore
    let playlistCreation: PlaylistCreationCoordinator
    let trackInfo: TrackInfoCoordinator
    let navigation: TrackMenuNavigation
    let additionalActions: [TrackMenuAction]

    func makeCoordinator() -> TrackMenuController { TrackMenuController() }

    func makeNSView(context: Context) -> ContextMenuCaptureView {
        let view = ContextMenuCaptureView(frame: .zero)
        view.controller = context.coordinator
        return view
    }

    func updateNSView(_ view: ContextMenuCaptureView, context: Context) {
        context.coordinator.configure(track: track, store: store,
            playlistCreation: playlistCreation, trackInfo: trackInfo,
            navigation: navigation, additionalActions: additionalActions)
        view.menu = context.coordinator.rootMenu
    }
}

extension View {
    func albumContextMenu(album: Release?) -> some View {
        modifier(AlbumContextMenuModifier(album: album))
    }
}

private struct AlbumContextMenuModifier: ViewModifier {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(PlaylistCreationCoordinator.self) private var playlistCreation
    let album: Release?

    func body(content: Content) -> some View {
        content.overlay {
            if let album {
                NativeAlbumContextMenu(album: album, store: store, playlistCreation: playlistCreation)
                    .accessibilityHidden(true)
            }
        }
    }
}

private struct NativeAlbumContextMenu: NSViewRepresentable {
    let album: Release
    let store: DurvaldCoreStore
    let playlistCreation: PlaylistCreationCoordinator

    func makeCoordinator() -> TrackMenuController { TrackMenuController() }
    func makeNSView(context: Context) -> ContextMenuCaptureView {
        let view = ContextMenuCaptureView(frame: .zero)
        view.controller = context.coordinator
        return view
    }
    func updateNSView(_ view: ContextMenuCaptureView, context: Context) {
        context.coordinator.configure(album: album, store: store, playlistCreation: playlistCreation)
        view.menu = context.coordinator.rootMenu
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
        content.overlay {
            NativePlaylistContextMenu(playlist: playlist, store: store,
                creation: creation, navigation: navigation).accessibilityHidden(true)
        }
    }
}

private struct NativePlaylistContextMenu: NSViewRepresentable {
    let playlist: Playlist
    let store: DurvaldCoreStore
    let creation: PlaylistCreationCoordinator
    let navigation: TrackMenuNavigation

    func makeCoordinator() -> TrackMenuController { TrackMenuController() }
    func makeNSView(context: Context) -> ContextMenuCaptureView {
        let view = ContextMenuCaptureView(frame: .zero)
        view.controller = context.coordinator
        return view
    }
    func updateNSView(_ view: ContextMenuCaptureView, context: Context) {
        context.coordinator.configure(playlist: playlist, store: store,
            creation: creation, navigation: navigation)
        view.menu = context.coordinator.rootMenu
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
                NativeTrackOptionsMenu(
                    track: track,
                    store: store,
                    playlistCreation: playlistCreation,
                    trackInfo: trackInfo,
                    navigation: navigation,
                    additionalActions: additionalActions
                )
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
                NativeAlbumOptionsMenu(
                    album: album,
                    store: store,
                    playlistCreation: playlistCreation
                )
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
            NativePlaylistOptionsMenu(
                playlist: playlist,
                store: store,
                creation: creation,
                navigation: navigation
            )
            .accessibilityHidden(true)
        }
    }
}

private struct NativeTrackOptionsMenu: NSViewRepresentable {
    let track: Track
    let store: DurvaldCoreStore
    let playlistCreation: PlaylistCreationCoordinator
    let trackInfo: TrackInfoCoordinator
    let navigation: TrackMenuNavigation
    let additionalActions: [TrackMenuAction]

    func makeCoordinator() -> TrackMenuController { TrackMenuController() }
    func makeNSView(context: Context) -> OptionsMenuCaptureView {
        let view = OptionsMenuCaptureView(frame: .zero)
        view.controller = context.coordinator
        return view
    }
    func updateNSView(_ view: OptionsMenuCaptureView, context: Context) {
        context.coordinator.configure(
            track: track,
            store: store,
            playlistCreation: playlistCreation,
            trackInfo: trackInfo,
            navigation: navigation,
            additionalActions: additionalActions
        )
        view.menu = context.coordinator.rootMenu
    }
}

private struct NativeAlbumOptionsMenu: NSViewRepresentable {
    let album: Release
    let store: DurvaldCoreStore
    let playlistCreation: PlaylistCreationCoordinator

    func makeCoordinator() -> TrackMenuController { TrackMenuController() }
    func makeNSView(context: Context) -> OptionsMenuCaptureView {
        let view = OptionsMenuCaptureView(frame: .zero)
        view.controller = context.coordinator
        return view
    }
    func updateNSView(_ view: OptionsMenuCaptureView, context: Context) {
        context.coordinator.configure(
            album: album,
            store: store,
            playlistCreation: playlistCreation
        )
        view.menu = context.coordinator.rootMenu
    }
}

private struct NativePlaylistOptionsMenu: NSViewRepresentable {
    let playlist: Playlist
    let store: DurvaldCoreStore
    let creation: PlaylistCreationCoordinator
    let navigation: TrackMenuNavigation

    func makeCoordinator() -> TrackMenuController { TrackMenuController() }
    func makeNSView(context: Context) -> OptionsMenuCaptureView {
        let view = OptionsMenuCaptureView(frame: .zero)
        view.controller = context.coordinator
        return view
    }
    func updateNSView(_ view: OptionsMenuCaptureView, context: Context) {
        context.coordinator.configure(
            playlist: playlist,
            store: store,
            creation: creation,
            navigation: navigation
        )
        view.menu = context.coordinator.rootMenu
    }
}

private final class OptionsMenuCaptureView: NSView {
    weak var controller: TrackMenuController?

    override func mouseDown(with event: NSEvent) {
        guard let menu else { return }
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: bounds.minX, y: bounds.minY - 4),
            in: self
        )
    }
}

private final class ContextMenuCaptureView: NSView {
    weak var controller: TrackMenuController?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        if event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) {
            return self
        }
        return nil
    }
}

@MainActor
final class TrackMenuController: NSObject, NSMenuDelegate, NSSearchFieldDelegate {
    var rootMenu = NSMenu()
    private let playlistMenu = NSMenu(title: "Adicionar à playlist")
    private let searchField = NSSearchField(frame: NSRect(x: 8, y: 3, width: 224, height: 26))
    private var playlists: [Playlist] = []
    private var track: Track?
    private var album: Release?
    private var sourcePlaylist: Playlist?
    private var onEditPlaylist: () -> Void = {}
    private var store: DurvaldCoreStore?
    private var navigation = TrackMenuNavigation()
    private var onInfo: () -> Void = {}
    private var loadingTask: Task<Void, Never>?
    private let containingPlaylistsMenu = NSMenu(title: "Ir à playlist")
    private var onAddToQueue: () -> Void = {}
    private var onCreatePlaylist: () -> Void = {}
    private var onAddToPlaylist: (Playlist) -> Void = { _ in }
    private var additionalActions: [TrackMenuAction] = []

    override init() {
        super.init()
        rootMenu.autoenablesItems = false
        playlistMenu.autoenablesItems = false
        rootMenu.delegate = self
        playlistMenu.delegate = self
        searchField.placeholderString = "Pesquisar playlists"
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = true
        searchField.delegate = self

        let searchContainer = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 32))
        searchContainer.addSubview(searchField)
        let searchItem = NSMenuItem()
        searchItem.view = searchContainer
        playlistMenu.addItem(searchItem)
        playlistMenu.addItem(.separator())

        let newPlaylist = NSMenuItem(title: "Nova playlist",
                                     action: #selector(createPlaylist), keyEquivalent: "")
        newPlaylist.target = self
        playlistMenu.addItem(newPlaylist)
        playlistMenu.addItem(.separator())
    }

    func configure(track: Track, store: DurvaldCoreStore,
                   playlistCreation: PlaylistCreationCoordinator,
                   trackInfo: TrackInfoCoordinator,
                   navigation: TrackMenuNavigation,
                   additionalActions: [TrackMenuAction] = []) {
        rootMenu.autoenablesItems = false
        loadingTask?.cancel()
        self.sourcePlaylist = nil
        self.album = nil
        self.track = store.tracks.first { $0.id == track.id } ?? track
        self.store = store
        self.navigation = navigation
        playlists = store.playlists
        onAddToQueue = { Task { await store.addToQueue(trackID: track.id) } }
        onCreatePlaylist = { playlistCreation.request(for: track.id) }
        onAddToPlaylist = { store.addTrack(track.id, to: $0) }
        onInfo = { trackInfo.open(trackID: track.id) }
        self.additionalActions = additionalActions
        rebuildRootMenu()
        rebuildPlaylistItems()
    }

    func configure(album: Release, store: DurvaldCoreStore,
                   playlistCreation: PlaylistCreationCoordinator) {
        loadingTask?.cancel()
        rootMenu.autoenablesItems = false
        self.sourcePlaylist = nil
        self.track = nil
        self.album = store.releases.first { $0.id == album.id } ?? album
        self.store = store
        playlists = store.playlists
        additionalActions = []
        onCreatePlaylist = { playlistCreation.requestAlbum(album.id) }
        onAddToPlaylist = { playlist in
            Task { await store.addRelease(album.id, to: playlist) }
        }
        onAddToQueue = { Task { await store.enqueueRelease(releaseID: album.id) } }
        rebuildRootMenu()
        rebuildPlaylistItems()
    }

    func configure(playlist: Playlist, store: DurvaldCoreStore,
                   creation: PlaylistCreationCoordinator, navigation: TrackMenuNavigation) {
        loadingTask?.cancel()
        rootMenu.autoenablesItems = false
        track = nil
        album = nil
        sourcePlaylist = store.playlists.first { $0.id == playlist.id } ?? playlist
        self.store = store
        self.navigation = navigation
        playlists = store.playlists.filter { $0.id != playlist.id }
        additionalActions = []
        onCreatePlaylist = { creation.requestPlaylist(playlist.id) }
        onEditPlaylist = { creation.requestEdit(store.playlists.first { $0.id == playlist.id } ?? playlist) }
        onAddToPlaylist = { target in
            Task { await store.addPlaylist(playlist.id, to: target) }
        }
        onAddToQueue = { Task { await store.enqueuePlaylist(playlistID: playlist.id) } }
        rebuildRootMenu()
        rebuildPlaylistItems()
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === rootMenu, let album, let store {
            loadingTask = Task { [weak self] in
                guard let self, let current = try? await store.core?.release(releaseId: album.id),
                      !Task.isCancelled else { return }
                self.album = current
                self.rootMenu.items.first { $0.action == #selector(self.toggleFavorite) }?.title =
                    current.isFavorite ? "Desfavoritar" : "Favoritar"
            }
            return
        }
        if menu === rootMenu {
            guard let track, let store else { return }
            containingPlaylistsMenu.removeAllItems()
            containingPlaylistsMenu.autoenablesItems = false
            let loading = NSMenuItem(title: "Carregando…", action: nil, keyEquivalent: "")
            loading.isEnabled = false
            containingPlaylistsMenu.addItem(loading)
            loadingTask = Task { [weak self] in
                guard let self else { return }
                if let current = try? await store.core?.track(trackId: track.id), !Task.isCancelled {
                    self.track = current
                    self.rootMenu.items.first { $0.action == #selector(self.toggleFavorite) }?.title =
                        current.isFavorite ? "Desfavoritar" : "Favoritar"
                }
                var containing: [Playlist] = []
                do {
                    for playlist in store.playlists {
                        guard !Task.isCancelled else { return }
                        if let tracks = try await store.core?.playlistTracks(playlistId: playlist.id),
                           tracks.contains(where: { $0.id == track.id }) {
                            containing.append(playlist)
                        }
                    }
                    guard !Task.isCancelled else { return }
                    containingPlaylistsMenu.removeAllItems()
                    for playlist in containing {
                        let item = actionItem(playlist.name, selector: #selector(goToPlaylist(_:)))
                        item.representedObject = playlist
                        containingPlaylistsMenu.addItem(item)
                    }
                    if containing.isEmpty { addPlaylistPlaceholder("Nenhuma playlist contém esta faixa") }
                } catch {
                    guard !Task.isCancelled else { return }
                    containingPlaylistsMenu.removeAllItems()
                    addPlaylistPlaceholder("Não foi possível carregar as playlists")
                }
            }
        }
        guard menu === playlistMenu else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.searchField.window else { return }
            window.makeFirstResponder(self.searchField)
        }
    }

    private func addPlaylistPlaceholder(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        containingPlaylistsMenu.addItem(item)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === rootMenu else { return }
        loadingTask?.cancel()
        searchField.stringValue = ""
        rebuildPlaylistItems()
    }

    func controlTextDidChange(_ notification: Notification) {
        rebuildPlaylistItems()
    }

    private func rebuildRootMenu() {
        rootMenu.removeAllItems()
        if sourcePlaylist != nil {
            rootMenu.addItem(actionItem("Tocar", selector: #selector(playPlaylist)))
            rootMenu.addItem(actionItem("Aleatório", selector: #selector(shufflePlaylist)))
            rootMenu.addItem(.separator())
            let add = NSMenuItem(title: "Adicionar à playlist", action: nil, keyEquivalent: "")
            add.submenu = playlistMenu
            rootMenu.addItem(add)
            rootMenu.addItem(actionItem("Tocar de próxima", selector: #selector(playNext)))
            rootMenu.addItem(actionItem("Adicionar à fila", selector: #selector(addToQueue)))
            rootMenu.addItem(.separator())
            rootMenu.addItem(actionItem("Editar detalhes", selector: #selector(editPlaylist)))
            rootMenu.addItem(.separator())
            rootMenu.addItem(actionItem("Deletar", selector: #selector(deletePlaylist)))
            return
        }
        if let album {
            rootMenu.addItem(actionItem("Tocar", selector: #selector(playAlbum)))
            rootMenu.addItem(actionItem("Aleatório", selector: #selector(shuffleAlbum)))
            rootMenu.addItem(.separator())
            let playlistsItem = NSMenuItem(title: "Adicionar à playlist", action: nil, keyEquivalent: "")
            playlistsItem.submenu = playlistMenu
            rootMenu.addItem(playlistsItem)
            rootMenu.addItem(actionItem("Tocar de próxima", selector: #selector(playNext)))
            rootMenu.addItem(actionItem("Adicionar à fila", selector: #selector(addToQueue)))
            rootMenu.addItem(.separator())
            rootMenu.addItem(actionItem(album.isFavorite ? "Desfavoritar" : "Favoritar", selector: #selector(toggleFavorite)))
            rootMenu.addItem(.separator())
            let share = NSMenuItem(title: "Compartilhar", action: nil, keyEquivalent: "")
            let shareMenu = NSMenu(title: "Compartilhar")
            shareMenu.addItem(actionItem("Copiar título", selector: #selector(copyName)))
            share.submenu = shareMenu
            rootMenu.addItem(share)
            return
        }
        let playlistsItem = NSMenuItem(title: "Adicionar à playlist", action: nil, keyEquivalent: "")
        playlistsItem.submenu = playlistMenu
        rootMenu.addItem(playlistsItem)
        rootMenu.addItem(actionItem("Tocar de próxima", selector: #selector(playNext)))
        rootMenu.addItem(actionItem("Adicionar à fila", selector: #selector(addToQueue)))
        rootMenu.addItem(.separator())
        rootMenu.addItem(actionItem(track?.isFavorite == true ? "Desfavoritar" : "Favoritar",
                                    selector: #selector(toggleFavorite)))
        rootMenu.addItem(.separator())
        rootMenu.addItem(actionItem("Ir ao artista", selector: #selector(goToArtist)))
        rootMenu.addItem(actionItem("Ir ao álbum", selector: #selector(goToAlbum)))
        let containing = NSMenuItem(title: "Ir à playlist", action: nil, keyEquivalent: "")
        containing.submenu = containingPlaylistsMenu
        rootMenu.addItem(containing)
        rootMenu.addItem(.separator())
        rootMenu.addItem(actionItem("Info", selector: #selector(showInfo)))
        let share = NSMenuItem(title: "Compartilhar", action: nil, keyEquivalent: "")
        let shareMenu = NSMenu(title: "Compartilhar")
        shareMenu.addItem(actionItem("Copiar nome", selector: #selector(copyName)))
        share.submenu = shareMenu
        rootMenu.addItem(share)

        if !additionalActions.isEmpty {
            rootMenu.addItem(.separator())
            for (index, action) in additionalActions.enumerated() {
                let item = NSMenuItem(title: action.title,
                                      action: #selector(performAdditionalAction(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                item.isEnabled = action.isEnabled
                if let systemImage = action.systemImage {
                    item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
                }
                rootMenu.addItem(item)
            }
        }
    }

    private func rebuildPlaylistItems() {
        while playlistMenu.numberOfItems > 4 { playlistMenu.removeItem(at: 4) }
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayed = query.isEmpty
            ? playlists.sorted { $0.createdAt > $1.createdAt }
            : playlists.filter { $0.name.localizedCaseInsensitiveContains(query) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        guard !displayed.isEmpty else {
            let item = NSMenuItem(title: query.isEmpty ? "Nenhuma playlist" : "Nenhum resultado",
                                  action: nil, keyEquivalent: "")
            item.isEnabled = false
            playlistMenu.addItem(item)
            return
        }

        for playlist in displayed {
            let item = NSMenuItem(title: playlist.name,
                                  action: #selector(addToPlaylist(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: playlist.id)
            playlistMenu.addItem(item)
        }
    }

    private func actionItem(_ title: String, selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func playPlaylist() {
        guard let sourcePlaylist, let store else { return }
        Task { await store.playPlaylist(playlistID: sourcePlaylist.id, startingAtPosition: 0, shuffleEnabled: false) }
    }
    @objc private func shufflePlaylist() {
        guard let sourcePlaylist, let store else { return }
        Task { await store.playPlaylist(playlistID: sourcePlaylist.id, startingAtPosition: 0, shuffleEnabled: true) }
    }
    @objc private func editPlaylist() { onEditPlaylist() }
    @objc private func deletePlaylist() {
        guard let sourcePlaylist, let store else { return }
        Task {
            if await store.deletePlaylist(id: sourcePlaylist.id) { navigation.deletedPlaylist(sourcePlaylist.id) }
        }
    }
    @objc private func playAlbum() {
        guard let album, let store else { return }
        Task { await store.playRelease(releaseID: album.id, shuffleEnabled: false) }
    }
    @objc private func shuffleAlbum() {
        guard let album, let store else { return }
        Task { await store.playRelease(releaseID: album.id, shuffleEnabled: true) }
    }
    @objc private func playNext() {
        if let sourcePlaylist, let store {
            Task { await store.enqueuePlaylist(playlistID: sourcePlaylist.id, playNext: true) }
            return
        }
        if let album, let store {
            Task { await store.enqueueRelease(releaseID: album.id, playNext: true) }
            return
        }
        guard let track, let store else { return }
        Task { await store.playNext(trackID: track.id) }
    }
    @objc private func toggleFavorite() {
        if let album, let store {
            store.setReleaseFavorite(releaseID: album.id, favorite: !album.isFavorite)
            return
        }
        guard let track, let store else { return }
        Task {
            await store.setTrackFavorite(trackID: track.id, favorite: !track.isFavorite)
            self.track = try? await store.core?.track(trackId: track.id)
            rebuildRootMenu()
        }
    }
    @objc private func goToArtist() {
        guard let track, let store else { return }
        Task {
            do { if let artist = try await store.core?.artist(artistId: track.artistId) { navigation.artist(artist) } }
            catch { store.errorMessage = String(describing: error) }
        }
    }
    @objc private func goToAlbum() {
        guard let track, let store else { return }
        Task {
            do { if let album = try await store.core?.release(releaseId: track.releaseId) { navigation.album(album) } }
            catch { store.errorMessage = String(describing: error) }
        }
    }
    @objc private func goToPlaylist(_ sender: NSMenuItem) {
        guard let playlist = sender.representedObject as? Playlist else { return }
        navigation.playlist(playlist)
    }
    @objc private func showInfo() { onInfo() }
    @objc private func copyName() {
        guard let title = album?.title ?? track?.title else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(title, forType: .string)
    }
    @objc private func addToQueue() { onAddToQueue() }
    @objc private func createPlaylist() { onCreatePlaylist() }

    @objc private func addToPlaylist(_ sender: NSMenuItem) {
        guard let id = (sender.representedObject as? NSNumber)?.int64Value,
              let playlist = playlists.first(where: { $0.id == id }) else { return }
        onAddToPlaylist(playlist)
    }

    @objc private func performAdditionalAction(_ sender: NSMenuItem) {
        guard additionalActions.indices.contains(sender.tag) else { return }
        additionalActions[sender.tag].action()
    }
}
