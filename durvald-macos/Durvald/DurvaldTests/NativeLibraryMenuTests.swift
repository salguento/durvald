import AppKit
import XCTest
@testable import Durvald

@MainActor
final class NativeLibraryMenuTests: XCTestCase {
    func testContextCapturePreservesNormalClickAndDrag() {
        let context = LibraryMenuCaptureMode.context
        XCTAssertTrue(context.captures(type: .rightMouseDown, modifiers: []))
        XCTAssertTrue(context.captures(type: .leftMouseDown, modifiers: [.control, .shift]))
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .mouseMoved, .scrollWheel] {
            XCTAssertFalse(context.captures(type: type, modifiers: []))
        }
        XCTAssertFalse(context.captures(type: .leftMouseDragged, modifiers: .control))
        let view = LibraryMenuCaptureView(mode: .options)
        view.frame = NSRect(x: 0, y: 0, width: 24, height: 24)
        XCTAssertTrue(view.hitTest(NSPoint(x: 12, y: 12)) === view)
        XCTAssertNil(view.hitTest(NSPoint(x: 40, y: 40)))
    }

    func testReusedControllerReplacesAdditionalActionAndSubjectMenus() {
        let controller = TrackMenuController()
        let store = DurvaldCoreStore()
        let creation = PlaylistCreationCoordinator()
        var calls: [String] = []
        func configure(_ title: String) {
            controller.configure(track: Fixtures.track, store: store, playlistCreation: creation,
                trackInfo: TrackInfoCoordinator(), navigation: TrackMenuNavigation(),
                additionalActions: [TrackMenuAction(title, systemImage: "trash", isEnabled: false) { calls.append(title) }])
        }
        configure("old")
        configure("new")
        let item = controller.rootMenu.items.last!
        XCTAssertEqual(item.title, "new")
        XCTAssertFalse(item.isEnabled)
        XCTAssertNotNil(item.image)
        XCTAssertTrue(item.target === controller)
        _ = controller.perform(item.action!, with: item)
        XCTAssertEqual(calls, ["new"])
        controller.configure(album: Fixtures.release, store: store, playlistCreation: creation, trackInfo: TrackInfoCoordinator())
        XCTAssertTrue(controller.rootMenu.items.contains { $0.title == "Info" })
        XCTAssertFalse(controller.rootMenu.items.contains { $0.title == "new" })
        controller.configure(playlist: playlist(1), store: store, creation: creation, navigation: TrackMenuNavigation())
        XCTAssertFalse(controller.rootMenu.items.contains { $0.title == "Avaliação" || $0.title == "Compartilhar" })
    }

    func testAlbumInfoUsesOriginalInspectorAndAlbumScopedNavigation() async {
        let core = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        let second = Fixtures.track(id: 2, trackNumber: 2, discNumber: 1)
        core.releaseTrackResults = [second, Fixtures.track]
        let store = DurvaldCoreStore(core: core, tracks: [Fixtures.track])
        let info = TrackInfoCoordinator()
        let creation = PlaylistCreationCoordinator()
        let controller = TrackMenuController()
        controller.configure(album: Fixtures.release, store: store, playlistCreation: creation, trackInfo: info)
        let opened = expectation(description: "Album metadata opened")
        info.presentWindow = { opened.fulfill() }
        let item = controller.rootMenu.items.first { $0.title == "Info" }!
        XCTAssertTrue(item.isEnabled)
        _ = controller.perform(item.action!, with: item)
        await fulfillment(of: [opened], timeout: 2)
        XCTAssertEqual(info.trackIDs, [1])
        XCTAssertEqual(info.navigationTrackIDs, [1, 2])

        let keyboardOpened = expectation(description: "Album metadata opened with keyboard")
        info.presentWindow = { keyboardOpened.fulfill() }
        let target = AppCommandTarget.album(Fixtures.release, store: store, info: info, creation: creation)
        XCTAssertTrue(target.contains(.info))
        target.perform(.info)
        await fulfillment(of: [keyboardOpened], timeout: 2)
        XCTAssertEqual(info.trackIDs, [1])
        XCTAssertEqual(info.navigationTrackIDs, [1, 2])
    }

    func testMultiSelectionPreservesNavigationPayloadAndFavoriteMeaning() {
        var first = Fixtures.track
        first.isFavorite = true
        var second = Fixtures.track(id: 2, trackNumber: 2, discNumber: 1)
        second.artistId = 2; second.artist = "Outro artista"; second.releaseId = 2; second.release = "Outro álbum"
        let controller = TrackMenuController()
        controller.configure(track: first, store: DurvaldCoreStore(), playlistCreation: PlaylistCreationCoordinator(),
            trackInfo: TrackInfoCoordinator(), navigation: TrackMenuNavigation(), selectedTracks: [first, second, first])
        XCTAssertTrue(controller.rootMenu.items.contains { $0.title == "Favoritar" })
        let artists = controller.rootMenu.items.first { $0.title == "Ir ao artista" }!.submenu!.items
        XCTAssertEqual(artists.map(\.title), ["Artista", "Outro artista"])
        XCTAssertEqual(artists.map { ($0.representedObject as? Track)?.id }, [1, 2])
        XCTAssertEqual(artists.map(\.tag), [1, 1])
        let albums = controller.rootMenu.items.first { $0.title == "Ir ao álbum" }!.submenu!.items
        XCTAssertEqual(albums.map(\.title), ["Álbum", "Outro álbum"])
        XCTAssertEqual(albums.map(\.tag), [0, 0])
        second.isFavorite = true
        controller.configure(track: first, store: DurvaldCoreStore(), playlistCreation: PlaylistCreationCoordinator(),
            trackInfo: TrackInfoCoordinator(), navigation: TrackMenuNavigation(), selectedTracks: [first, second])
        XCTAssertTrue(controller.rootMenu.items.contains { $0.title == "Desfavoritar" })
    }

    func testRatingDefinitionCarriesSelectionAndCanBeDisabled() {
        for rating: UInt8? in [nil, 0, 1, 3, 5, 10] {
            var album = Fixtures.release
            album.ratingHalfSteps = rating
            let definitions = LibraryMenuDefinition.build(track: nil, selectedTracks: [], album: album,
                playlist: nil, ratingsEnabled: true, additionalActions: [])
            let menu = NSMenu()
            NativeLibraryMenuPresenter.populate(menu, items: definitions, target: NSObject(),
                selector: { _ in NSSelectorFromString("unused:") }, playlistPicker: NSMenu(), containingPlaylists: NSMenu())
            let choices = menu.items.first { $0.title == "Avaliação" }!.submenu!.items.filter { !$0.isSeparatorItem }
            XCTAssertEqual(choices.map(\.tag), [-1] + Array(0...10))
            XCTAssertEqual(choices.filter { $0.state == .on }.map(\.tag), [rating.map(Int.init) ?? -1])
            let disabled = LibraryMenuDefinition.build(track: nil, selectedTracks: [], album: album,
                playlist: nil, ratingsEnabled: false, additionalActions: [])
            NativeLibraryMenuPresenter.populate(menu, items: disabled, target: NSObject(),
                selector: { _ in NSSelectorFromString("unused:") }, playlistPicker: NSMenu(), containingPlaylists: NSMenu())
            XCTAssertFalse(menu.items.contains { $0.title == "Avaliação" })
        }
    }

    func testPlaylistSearchCloseAndCreationContextSurviveReuse() async {
        let controller = TrackMenuController()
        let creation = PlaylistCreationCoordinator()
        let core = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        let store = DurvaldCoreStore(core: core)
        for id: Int64 in [1, 2] {
            core.playlistResult = playlist(id)
            _ = await store.createPlaylist(named: "Playlist \(id)")
        }
        controller.configure(playlist: playlist(1), store: store, creation: creation, navigation: TrackMenuNavigation())
        let picker = controller.rootMenu.items.first { $0.title == "Adicionar à playlist" }!.submenu!
        let search = picker.items[0].view!.subviews.first as! NSSearchField
        XCTAssertEqual(picker.items.dropFirst(4).map(\.title), ["Playlist 2"])
        search.stringValue = "ausente"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        XCTAssertEqual(picker.items.last?.title, "Nenhum resultado")
        controller.menuDidClose(controller.rootMenu)
        XCTAssertEqual(search.stringValue, "")
        XCTAssertEqual(picker.items.last?.title, "Playlist 2")
        let create = picker.items[2]
        _ = controller.perform(create.action!, with: create)
        XCTAssertEqual(creation.pendingPlaylistID, 1)
        controller.configure(album: Fixtures.release, store: store, playlistCreation: creation, trackInfo: TrackInfoCoordinator())
        _ = controller.perform(create.action!, with: create)
        XCTAssertEqual(creation.pendingReleaseID, Fixtures.release.id)
        XCTAssertNil(creation.pendingPlaylistID)
    }

    func testDismantlingClearsMenuAndReleasesCapturedActions() {
        let controller = TrackMenuController()
        let view = LibraryMenuCaptureView(mode: .context)
        weak var released: MenuLifetimeSentinel?
        do {
            let sentinel = MenuLifetimeSentinel()
            released = sentinel
            controller.configure(track: Fixtures.track, store: DurvaldCoreStore(), playlistCreation: PlaylistCreationCoordinator(),
                trackInfo: TrackInfoCoordinator(), navigation: TrackMenuNavigation(),
                additionalActions: [TrackMenuAction("Retained") { _ = sentinel }])
        }
        XCTAssertNotNil(released)
        view.menu = controller.rootMenu
        NativeLibraryMenu.dismantleNSView(view, coordinator: controller)
        XCTAssertNil(view.menu)
        XCTAssertTrue(controller.rootMenu.items.isEmpty)
        XCTAssertNil(released)
        controller.configure(album: Fixtures.release, store: DurvaldCoreStore(), playlistCreation: PlaylistCreationCoordinator(), trackInfo: TrackInfoCoordinator())
        XCTAssertEqual(controller.rootMenu.items.first?.title, "Tocar")
    }

    func testLateAlbumLoadCannotModifyReconfiguredOrDetachedMenu() async {
        for detach in [false, true] {
            let gate = MenuLoadGate()
            let core = MenuLoadCore(gate: gate)
            let controller = TrackMenuController()
            controller.configure(album: Fixtures.release, store: DurvaldCoreStore(core: core),
                                 playlistCreation: PlaylistCreationCoordinator(), trackInfo: TrackInfoCoordinator())
            controller.menuWillOpen(controller.rootMenu)
            let pending = controller.loadingTask
            await gate.started()
            if detach { controller.detach() }
            else {
                var replacement = Fixtures.release
                replacement.id = 2
                controller.configure(album: replacement, store: DurvaldCoreStore(), playlistCreation: PlaylistCreationCoordinator(), trackInfo: TrackInfoCoordinator())
            }
            await gate.release()
            await pending?.value
            if detach { XCTAssertTrue(controller.rootMenu.items.isEmpty) }
            else { XCTAssertTrue(controller.rootMenu.items.contains { $0.title == "Favoritar" }) }
        }
    }

    private func playlist(_ id: Int64) -> Playlist {
        Playlist(id: id, name: "Playlist \(id)", description: "", artworkId: nil, isFavorite: false,
                 suggestLess: false, trackCount: 0, createdAt: "", updatedAt: "", isSmart: false, smartDefinition: nil)
    }
}

private final class MenuLifetimeSentinel {}

private final class MenuLoadCore: DurvaldCore {
    let gate: MenuLoadGate
    init(gate: MenuLoadGate) { self.gate = gate; super.init(noPointer: .init()) }
    required init(unsafeFromRawPointer pointer: UnsafeMutableRawPointer) {
        fatalError("MenuLoadCore only supports fixtures")
    }
    override func release(releaseId: Int64) async throws -> Release {
        await gate.pause()
        var release = Fixtures.release
        release.isFavorite = true
        return release
    }
}

private actor MenuLoadGate {
    private var pending: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func pause() async {
        await withCheckedContinuation { pending = $0; waiter?.resume(); waiter = nil }
    }
    func started() async {
        if pending != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { pending?.resume(); pending = nil }
}
