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

struct TrackListTrailingControls<AdditionalControls: View>: View {
    @Environment(DurvaldCoreStore.self) private var store
    @State private var optimisticFavorite: Bool? = nil

    let track: Track
    let onPlay: () -> Void
    let onToggleFavorite: (Bool) -> Void
    @ViewBuilder let additionalControls: () -> AdditionalControls

    private var isFavorite: Bool {
        optimisticFavorite ?? track.isFavorite
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                let newValue = !isFavorite
                optimisticFavorite = newValue
                onToggleFavorite(newValue)
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .foregroundStyle(isFavorite ? Color.accentColor : .secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(isFavorite ? "Desfavoritar faixa" : "Favoritar faixa")
            .accessibilityLabel(isFavorite ? "Desfavoritar faixa" : "Favoritar faixa")

            Text(durationText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)

            additionalControls()

            Menu {
                Button("Reproduzir", systemImage: "play.fill", action: onPlay)
                Button("Adicionar à fila", systemImage: "text.badge.plus") {
                    Task { await store.addToQueue(trackID: track.id) }
                }
                Button(
                    isFavorite ? "Desfavoritar faixa" : "Favoritar faixa",
                    systemImage: isFavorite ? "star.slash" : "star"
                ) {
                    let newValue = !isFavorite
                    optimisticFavorite = newValue
                    onToggleFavorite(newValue)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(.rect)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Opções da faixa")
            .accessibilityLabel("Opções da faixa")
            .trackOptionsMenu(track: track, onPlay: onPlay)
        }
        .onChange(of: track.isFavorite) { _, newValue in
            if optimisticFavorite == newValue {
                optimisticFavorite = nil
            }
        }
    }

    private var durationText: String {
        let totalSeconds = max(0, Int(track.durationSeconds.rounded()))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
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
    private var selectedTracks: [Track] = []
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
                   additionalActions: [TrackMenuAction] = [],
                   infoAction: (() -> Void)? = nil,
                   selectedTracks: [Track] = []) {
        rootMenu.autoenablesItems = false
        loadingTask?.cancel()
        self.sourcePlaylist = nil
        self.album = nil
        self.selectedTracks = selectedTracks.isEmpty ? [track] : selectedTracks
        self.track = store.tracks.first { $0.id == track.id } ?? track
        self.store = store
        self.navigation = navigation
        playlists = store.playlists
        let tracks = self.selectedTracks
        onAddToQueue = { Task { await store.enqueueSelection(tracks) } }
        onCreatePlaylist = { playlistCreation.requestTracks(tracks.map(\.id)) }
        onAddToPlaylist = { playlist in
            for track in tracks { store.addTrack(track.id, to: playlist) }
        }
        onInfo = infoAction ?? { trackInfo.open(trackID: track.id) }
        self.additionalActions = additionalActions
        rebuildRootMenu()
        rebuildPlaylistItems()
    }

    func configure(album: Release, store: DurvaldCoreStore,
                   playlistCreation: PlaylistCreationCoordinator) {
        loadingTask?.cancel()
        rootMenu.autoenablesItems = false
        self.sourcePlaylist = nil
        self.selectedTracks = []
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
        selectedTracks = []
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
                        self.selectedTracks.allSatisfy(\.isFavorite) ? "Desfavoritar" : "Favoritar"
                }
                var containing: [Playlist] = []
                do {
                    for playlist in store.playlists {
                        guard !Task.isCancelled else { return }
                        if let tracks = try await store.core?.playlistTracks(playlistId: playlist.id),
                           tracks.contains(where: { entry in self.selectedTracks.contains(where: { $0.id == entry.id }) }) {
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
            if RatingPreferences.isEnabled {
                rootMenu.addItem(ratingMenu(current: album.rating))
            }
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
        rootMenu.addItem(actionItem(!selectedTracks.isEmpty && selectedTracks.allSatisfy(\.isFavorite) ? "Desfavoritar" : "Favoritar",
                                    selector: #selector(toggleFavorite)))
        if RatingPreferences.isEnabled {
            rootMenu.addItem(ratingMenu(current: track?.rating))
        }
        rootMenu.addItem(.separator())
        rootMenu.addItem(navigationItem(artist: true))
        rootMenu.addItem(navigationItem(artist: false))
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

    private func ratingMenu(current: UInt8?) -> NSMenuItem {
        let parent = NSMenuItem(title: "Avaliação", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Avaliação")
        let clear = actionItem("Sem avaliação", selector: #selector(setRating(_:)))
        clear.tag = 0
        clear.state = current == nil ? .on : .off
        menu.addItem(clear)
        menu.addItem(.separator())
        for value in 1...5 {
            let item = actionItem("\(value) de 5", selector: #selector(setRating(_:)))
            item.tag = value
            item.state = current == UInt8(value) ? .on : .off
            menu.addItem(item)
        }
        parent.submenu = menu
        return parent
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
        guard let store else { return }
        let tracks = selectedTracks
        Task { await store.enqueueSelection(tracks, playNext: true) }
    }
    @objc private func toggleFavorite() {
        if let album, let store {
            store.setReleaseFavorite(releaseID: album.id, favorite: !album.isFavorite)
            return
        }
        guard let store else { return }
        let tracks = selectedTracks
        let favorite = !tracks.allSatisfy(\.isFavorite)
        Task {
            for track in tracks { await store.setTrackFavorite(trackID: track.id, favorite: favorite) }
        }
    }

    @objc private func setRating(_ sender: NSMenuItem) {
        let rating = sender.tag == 0 ? nil : UInt8(sender.tag)
        if let album, let store {
            store.setReleaseRating(releaseID: album.id, rating: rating)
            self.album?.rating = rating
            rebuildRootMenu()
            return
        }
        guard let store else { return }
        let tracks = selectedTracks
        Task {
            for track in tracks { await store.setTrackRating(trackID: track.id, rating: rating) }
        }
    }

    private func navigationItem(artist: Bool) -> NSMenuItem {
        let title = artist ? "Ir ao artista" : "Ir ao álbum"
        var seen = Set<Int64>()
        let choices = selectedTracks.filter { seen.insert(artist ? $0.artistId : $0.releaseId).inserted }
        guard choices.count > 1 else {
            return actionItem(title, selector: artist ? #selector(goToArtist) : #selector(goToAlbum))
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        for track in choices {
            let choice = actionItem(artist ? track.artist : track.release, selector: #selector(navigateSelection(_:)))
            choice.representedObject = track
            choice.tag = artist ? 1 : 0
            submenu.addItem(choice)
        }
        item.submenu = submenu
        return item
    }

    @objc private func navigateSelection(_ sender: NSMenuItem) {
        guard let track = sender.representedObject as? Track, let store else { return }
        Task {
            do {
                if sender.tag == 1 {
                    if let artist = try await store.core?.artist(artistId: track.artistId) { navigation.artist(artist) }
                } else if let album = try await store.core?.release(releaseId: track.releaseId) { navigation.album(album) }
            } catch { store.errorMessage = String(describing: error) }
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
        let title = album?.title ?? selectedTracks.map(\.title).joined(separator: " ")
        guard !title.isEmpty else { return }
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

@MainActor
enum LibraryTrackDrag {
    static let type = "public.utf8-plain-text"
    static let pasteboardType = NSPasteboard.PasteboardType.string

    private static func decode(_ value: String) -> Int64? {
        guard value.hasPrefix("durvald-track:") else { return nil }
        return Int64(value.dropFirst("durvald-track:".count))
    }

    static func ids(from pasteboard: NSPasteboard) -> [Int64] {
        (pasteboard.pasteboardItems ?? []).compactMap { item in
            item.string(forType: pasteboardType).flatMap(decode)
        }
    }

    static func accept(_ providers: [NSItemProvider], perform: @escaping ([Int64]) -> Void) -> Bool {
        let providers = providers.filter { $0.hasItemConformingToTypeIdentifier(type) }
        guard !providers.isEmpty else { return false }
        Task {
            var ids: [Int64] = []
            for provider in providers {
                let data: Data? = await withCheckedContinuation { continuation in
                    provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                        continuation.resume(returning: data)
                    }
                }
                if let data, let value = String(data: data, encoding: .utf8), let id = decode(value) {
                    ids.append(id)
                }
            }
            if !ids.isEmpty { perform(ids) }
        }
        return true
    }
}

struct PlaylistDropTargetPreference: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

private struct PlaylistTrackDropModifier: ViewModifier {
    @Environment(DurvaldCoreStore.self) private var store
    @State private var isTargeted = false
    let playlist: Playlist

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background {
                if isTargeted && !playlist.isSmart {
                    RoundedRectangle(cornerRadius: 8).fill(Color.accentColor)
                }
            }
            .preference(key: PlaylistDropTargetPreference.self, value: isTargeted)
            .onDrop(of: [LibraryTrackDrag.type], isTargeted: $isTargeted) { providers in
                guard !playlist.isSmart else { return false }
                return LibraryTrackDrag.accept(providers) { ids in
                    Task { await store.addSelectionToPlaylist(ids, playlist: playlist) }
                }
            }
    }
}

extension View {
    func playlistTrackDropTarget(_ playlist: Playlist) -> some View {
        modifier(PlaylistTrackDropModifier(playlist: playlist))
    }
}
