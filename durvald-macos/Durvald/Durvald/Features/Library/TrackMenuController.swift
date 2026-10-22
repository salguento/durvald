import AppKit

@MainActor
final class TrackMenuController: NSObject, NSMenuDelegate, NSSearchFieldDelegate {
    var rootMenu = NSMenu()
    private let playlistMenu = NSMenu(title: "Adicionar à playlist")
    private let searchField = NSSearchField(frame: NSRect(x: 8, y: 3, width: 224, height: 26))
    private var playlists: [Playlist] = []
    private var selectedTracks: [Track] = []
    private var track: Track?
    private var album: Release?
    private var albumRatingEdit = PersonalValueEdit<UInt8?>(nil)
    private var sourcePlaylist: Playlist?
    private var onEditPlaylist: () -> Void = {}
    private var store: DurvaldCoreStore?
    private var navigation = TrackMenuNavigation()
    private var onInfo: () -> Void = {}
    private(set) var loadingTask: Task<Void, Never>?
    private var loadingGeneration = UUID()
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
        cancelPendingLoad()
        self.sourcePlaylist = nil
        self.album = nil
        self.selectedTracks = selectedTracks.isEmpty ? [track] : selectedTracks
        self.track = store.loadedTrack(id: track.id) ?? track
        self.store = store
        self.navigation = navigation
        playlists = store.playlists
        let tracks = self.selectedTracks
        onAddToQueue = { Task { await store.enqueueSelection(tracks) } }
        onCreatePlaylist = { playlistCreation.requestTracks(tracks.map(\.id)) }
        onAddToPlaylist = { playlist in
            for track in tracks { store.addTrack(track.id, to: playlist) }
        }
        onInfo = infoAction ?? { trackInfo.open(trackID: track.id, navigationTrackIDs: store.tracks.map(\.id)) }
        self.additionalActions = additionalActions
        rebuildRootMenu()
        rebuildPlaylistItems()
    }

    private var albumRatingRevision: UInt64?

    func configure(album: Release, store: DurvaldCoreStore,
                   playlistCreation: PlaylistCreationCoordinator) {
        cancelPendingLoad()
        rootMenu.autoenablesItems = false
        self.sourcePlaylist = nil
        self.selectedTracks = []
        self.track = nil
        let resolvedAlbum = store.loadedRelease(id: album.id) ?? album
        if self.album?.id != resolvedAlbum.id || albumRatingRevision != store.ratingScaleRevision {
            albumRatingEdit.reset(resolvedAlbum.ratingHalfSteps)
        } else {
            albumRatingEdit.receive(resolvedAlbum.ratingHalfSteps)
        }
        albumRatingRevision = store.ratingScaleRevision
        self.album = resolvedAlbum
        self.album?.ratingHalfSteps = albumRatingEdit.value
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
        cancelPendingLoad()
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

    private func cancelPendingLoad() {
        loadingGeneration = UUID()
        loadingTask?.cancel()
        loadingTask = nil
    }

    /// Called by the bridge when its surface is removed, including while a menu load is suspended.
    func detach() {
        cancelPendingLoad()
        rootMenu.removeAllItems()
        containingPlaylistsMenu.removeAllItems()
        searchField.stringValue = ""
        store = nil
        track = nil
        album = nil
        sourcePlaylist = nil
        selectedTracks = []
        playlists = []
        additionalActions = []
        navigation = TrackMenuNavigation()
        onInfo = {}
        onEditPlaylist = {}
        onCreatePlaylist = {}
        onAddToQueue = {}
        onAddToPlaylist = { _ in }
        rebuildPlaylistItems()
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === rootMenu { cancelPendingLoad() }
        let generation = loadingGeneration
        let coreID = store?.core.map(ObjectIdentifier.init)
        if menu === rootMenu, let album, let store {
            loadingTask = Task { [weak self] in
                guard let self, let current = try? await store.core?.release(releaseId: album.id),
                      !Task.isCancelled, self.loadingGeneration == generation,
                      self.store?.core.map(ObjectIdentifier.init) == coreID else { return }
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
                if let current = try? await store.core?.track(trackId: track.id), !Task.isCancelled,
                   self.loadingGeneration == generation, self.store?.core.map(ObjectIdentifier.init) == coreID {
                    self.track = current
                    self.rootMenu.items.first { $0.action == #selector(self.toggleFavorite) }?.title =
                        self.selectedTracks.allSatisfy(\.isFavorite) ? "Desfavoritar" : "Favoritar"
                }
                guard !Task.isCancelled, self.loadingGeneration == generation,
                      self.store?.core.map(ObjectIdentifier.init) == coreID else { return }
                let selectedIDs = Set(self.selectedTracks.map(\.id))
                var containing: [Playlist] = []
                do {
                    for playlist in store.playlists {
                        guard !Task.isCancelled, self.loadingGeneration == generation,
                              self.store?.core.map(ObjectIdentifier.init) == coreID else { return }
                        let tracks = try await store.core?.playlistTracks(playlistId: playlist.id)
                        guard !Task.isCancelled, self.loadingGeneration == generation,
                              self.store?.core.map(ObjectIdentifier.init) == coreID else { return }
                        if tracks?.contains(where: { selectedIDs.contains($0.id) }) == true {
                            containing.append(playlist)
                        }
                    }
                    guard !Task.isCancelled, self.loadingGeneration == generation,
                          self.store?.core.map(ObjectIdentifier.init) == coreID else { return }
                    containingPlaylistsMenu.removeAllItems()
                    for playlist in containing {
                        let item = actionItem(playlist.name, selector: #selector(goToPlaylist(_:)))
                        item.representedObject = playlist
                        containingPlaylistsMenu.addItem(item)
                    }
                    if containing.isEmpty { addPlaylistPlaceholder("Nenhuma playlist contém esta faixa") }
                } catch {
                    guard !Task.isCancelled, self.loadingGeneration == generation,
                          self.store?.core.map(ObjectIdentifier.init) == coreID else { return }
                    containingPlaylistsMenu.removeAllItems()
                    addPlaylistPlaceholder("Não foi possível carregar as playlists")
                }
            }
        }
        guard menu === playlistMenu else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.loadingGeneration == generation,
                  let window = self.searchField.window else { return }
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
        cancelPendingLoad()
        searchField.stringValue = ""
        rebuildPlaylistItems()
    }

    func controlTextDidChange(_ notification: Notification) {
        rebuildPlaylistItems()
    }

    private func rebuildRootMenu() {
        let items = LibraryMenuDefinition.build(track: track, selectedTracks: selectedTracks, album: album,
            playlist: sourcePlaylist, ratingsEnabled: RatingPreferences.isEnabled, ratingGranularity: store?.ratingGranularity ?? .halfStars,
            ratingEditingEnabled: store?.isChangingRatingScale != true, additionalActions: additionalActions)
        NativeLibraryMenuPresenter.populate(rootMenu, items: items, target: self, selector: selector,
            playlistPicker: playlistMenu, containingPlaylists: containingPlaylistsMenu)
    }

    private func selector(for command: LibraryMenuCommand) -> Selector {
        switch command {
        case .playPlaylist: return #selector(playPlaylist)
        case .shufflePlaylist: return #selector(shufflePlaylist)
        case .editPlaylist: return #selector(editPlaylist)
        case .deletePlaylist: return #selector(deletePlaylist)
        case .playAlbum: return #selector(playAlbum)
        case .shuffleAlbum: return #selector(shuffleAlbum)
        case .playNext: return #selector(playNext)
        case .addToQueue: return #selector(addToQueue)
        case .toggleFavorite: return #selector(toggleFavorite)
        case .setRating: return #selector(setRating(_:))
        case .goToArtist: return #selector(goToArtist)
        case .goToAlbum: return #selector(goToAlbum)
        case .navigateSelection: return #selector(navigateSelection(_:))
        case .showInfo: return #selector(showInfo)
        case .personalTags: return #selector(editPersonalTags)
        case .listenList: return #selector(saveToListenList)
        case .copyName: return #selector(copyName)
        case .additional: return #selector(performAdditionalAction(_:))
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
            for track in tracks { await store.setTrackFavorite(trackID: track.id, favorite: favorite, fallbackTrack: track) }
        }
    }

    @objc private func setRating(_ sender: NSMenuItem) {
        guard store?.isChangingRatingScale != true else { return }
        let scaleRevision = store?.ratingScaleRevision
        let rating = sender.tag < 0 ? nil : UInt8(sender.tag)
        if let album, let store {
            let ticket = albumRatingEdit.begin(rating)
            self.album?.ratingHalfSteps = albumRatingEdit.value
            rebuildRootMenu()
            Task { @MainActor [weak self] in
                let succeeded = await store.setReleaseRating(releaseID: album.id, rating: rating,
                                                            fallbackRelease: album)
                guard let self, self.album?.id == album.id, store.ratingScaleRevision == scaleRevision else { return }
                albumRatingEdit.finish(ticket, succeeded: succeeded)
                self.album?.ratingHalfSteps = albumRatingEdit.value
                rebuildRootMenu()
            }
            return
        }
        guard let store else { return }
        let tracks = selectedTracks
        Task {
            for track in tracks { await store.setTrackRating(trackID: track.id, rating: rating, fallbackTrack: track) }
        }
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
    @objc private func saveToListenList() {
        guard let store, let album else { return }
        Task { await store.saveToListenList(releaseID: album.id) }
    }

    @objc private func editPersonalTags() {
        if let album { store?.personalTagEditor = PersonalTagSelection(releaseIDs: [album.id]) }
        else if !selectedTracks.isEmpty { store?.personalTagEditor = PersonalTagSelection(trackIDs: selectedTracks.map(\.id)) }
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
