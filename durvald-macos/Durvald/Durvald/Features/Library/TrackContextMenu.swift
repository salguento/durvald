import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class PlaylistCreationCoordinator {
    var isPresented = false
    var pendingTrackID: Int64?
    var editingPlaylist: Playlist?

    func request(for trackID: Int64?) {
        pendingTrackID = trackID
        editingPlaylist = nil
        isPresented = true
    }

    func requestEdit(_ playlist: Playlist) {
        pendingTrackID = nil
        editingPlaylist = playlist
        isPresented = true
    }

    func reset() {
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

private struct TrackContextMenuModifier: ViewModifier {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(PlaylistCreationCoordinator.self) private var playlistCreation

    let track: Track
    let onPlay: () -> Void
    let additionalActions: [TrackMenuAction]

    func body(content: Content) -> some View {
        content.overlay {
            NativeTrackContextMenu(
                playlists: store.playlists,
                onPlay: onPlay,
                onAddToQueue: { Task { await store.addToQueue(trackID: track.id) } },
                onCreatePlaylist: { playlistCreation.request(for: track.id) },
                onAddToPlaylist: { store.addTrack(track.id, to: $0) },
                additionalActions: additionalActions
            )
            .accessibilityHidden(true)
        }
    }
}

private struct NativeTrackContextMenu: NSViewRepresentable {
    let playlists: [Playlist]
    let onPlay: () -> Void
    let onAddToQueue: () -> Void
    let onCreatePlaylist: () -> Void
    let onAddToPlaylist: (Playlist) -> Void
    let additionalActions: [TrackMenuAction]

    func makeCoordinator() -> TrackMenuController { TrackMenuController() }

    func makeNSView(context: Context) -> ContextMenuCaptureView {
        let view = ContextMenuCaptureView(frame: .zero)
        view.controller = context.coordinator
        return view
    }

    func updateNSView(_ view: ContextMenuCaptureView, context: Context) {
        context.coordinator.configure(
            playlists: playlists,
            onPlay: onPlay,
            onAddToQueue: onAddToQueue,
            onCreatePlaylist: onCreatePlaylist,
            onAddToPlaylist: onAddToPlaylist,
            additionalActions: additionalActions
        )
        view.menu = context.coordinator.rootMenu
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
private final class TrackMenuController: NSObject, NSMenuDelegate, NSSearchFieldDelegate {
    let rootMenu = NSMenu()
    private let playlistMenu = NSMenu(title: "Adicionar à playlist")
    private let searchField = NSSearchField(frame: NSRect(x: 8, y: 3, width: 224, height: 26))
    private var playlists: [Playlist] = []
    private var onPlay: () -> Void = {}
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

    func configure(playlists: [Playlist], onPlay: @escaping () -> Void,
                   onAddToQueue: @escaping () -> Void,
                   onCreatePlaylist: @escaping () -> Void,
                   onAddToPlaylist: @escaping (Playlist) -> Void,
                   additionalActions: [TrackMenuAction]) {
        self.playlists = playlists
        self.onPlay = onPlay
        self.onAddToQueue = onAddToQueue
        self.onCreatePlaylist = onCreatePlaylist
        self.onAddToPlaylist = onAddToPlaylist
        self.additionalActions = additionalActions
        rebuildRootMenu()
        rebuildPlaylistItems()
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === playlistMenu else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.searchField.window else { return }
            window.makeFirstResponder(self.searchField)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === rootMenu else { return }
        searchField.stringValue = ""
        rebuildPlaylistItems()
    }

    func controlTextDidChange(_ notification: Notification) {
        rebuildPlaylistItems()
    }

    private func rebuildRootMenu() {
        rootMenu.removeAllItems()
        rootMenu.addItem(actionItem("Reproduzir agora", selector: #selector(play)))
        rootMenu.addItem(actionItem("Adicionar à fila", selector: #selector(addToQueue)))
        let playlistsItem = NSMenuItem(title: "Adicionar à playlist", action: nil, keyEquivalent: "")
        playlistsItem.submenu = playlistMenu
        rootMenu.addItem(playlistsItem)

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

    @objc private func play() { onPlay() }
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
