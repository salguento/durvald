import AppKit
import SwiftUI

@MainActor
@Observable
final class CommandFocusRequest {
    var target: String?
    var revision = 0
    func focus(_ target: String) { self.target = target; revision += 1 }
}
private struct CommandFocusRequestKey: EnvironmentKey { static let defaultValue: CommandFocusRequest? = nil }
private struct CommandFocusIDKey: EnvironmentKey { static let defaultValue: String? = nil }
private struct CommandSelectionOverrideKey: EnvironmentKey { static let defaultValue: AppCommandTarget? = nil }
extension EnvironmentValues {
    var commandFocusRequest: CommandFocusRequest? {
        get { self[CommandFocusRequestKey.self] }
        set { self[CommandFocusRequestKey.self] = newValue }
    }
    var commandFocusID: String? {
        get { self[CommandFocusIDKey.self] }
        set { self[CommandFocusIDKey.self] = newValue }
    }
    var commandSelectionOverride: AppCommandTarget? {
        get { self[CommandSelectionOverrideKey.self] }
        set { self[CommandSelectionOverrideKey.self] = newValue }
    }
}

@MainActor
struct AppCommandTarget {
    var actions: [AppCommandID: () -> Void] = [:]
    func contains(_ id: AppCommandID) -> Bool { actions[id] != nil }
    func perform(_ id: AppCommandID) { actions[id]?() }
}

private struct ProtectedCommandKeysKey: FocusedValueKey { typealias Value = Bool }
private struct WindowCommandKey: FocusedValueKey { typealias Value = AppCommandTarget }
private struct PageCommandKey: FocusedValueKey { typealias Value = AppCommandTarget }
private struct SelectionCommandKey: FocusedValueKey { typealias Value = AppCommandTarget }
extension FocusedValues {
    var protectsBareCommandKeys: Bool? {
        get { self[ProtectedCommandKeysKey.self] }
        set { self[ProtectedCommandKeysKey.self] = newValue }
    }
    var windowCommands: AppCommandTarget? {
        get { self[WindowCommandKey.self] }
        set { self[WindowCommandKey.self] = newValue }
    }
    var pageCommands: AppCommandTarget? {
        get { self[PageCommandKey.self] }
        set { self[PageCommandKey.self] = newValue }
    }
    var selectionCommands: AppCommandTarget? {
        get { self[SelectionCommandKey.self] }
        set { self[SelectionCommandKey.self] = newValue }
    }
}

@MainActor
extension AppCommandTarget {
    static func tracks(_ tracks: [Track], store: DurvaldCoreStore, info: TrackInfoCoordinator,
                       creation: PlaylistCreationCoordinator, navigation: TrackMenuNavigation,
                       play: @escaping () -> Void) -> Self {
        guard !tracks.isEmpty else { return Self() }
        var actions: [AppCommandID: () -> Void] = [
            .playSelection: play,
            .info: {
                if tracks.count == 1 { info.open(trackID: tracks[0].id) }
                else { info.openBatch(trackIDs: Set(tracks.map(\.id))) }
            },
            .playNext: { Task { await store.enqueueSelection(tracks, playNext: true) } },
            .enqueue: { Task { await store.enqueueSelection(tracks) } },
            .copyName: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tracks.map { "\($0.artist) — \($0.title)" }.joined(separator: "\n"), forType: .string)
            },
            .favorite: {
                let favorite = !tracks.allSatisfy(\.isFavorite)
                Task { for track in tracks { await store.setTrackFavorite(trackID: track.id, favorite: favorite, fallbackTrack: track) } }
            },
            .addToPlaylist: { CommandPlaylistPicker.show(tracks: tracks, store: store, creation: creation) }
        ]
        if (UserDefaults.standard.object(forKey: RatingPreferences.enabledKey) as? Bool ?? true), !store.isChangingRatingScale {
            let values = Set(RatingValues.options(store.ratingGranularity).map { UInt8($0) })
            for id in AppCommandID.allCases where id.isRating && (id == .clearRating || values.contains(id.ratingHalfSteps ?? 0)) {
                actions[id] = {
                    guard !store.isChangingRatingScale,
                          UserDefaults.standard.object(forKey: RatingPreferences.enabledKey) as? Bool ?? true else { return }
                    Task { for track in tracks { await store.setTrackRating(trackID: track.id, rating: id.ratingHalfSteps, fallbackTrack: track) } }
                }
            }
        }
        if Set(tracks.map(\.releaseId)).count == 1 {
            actions[.goToAlbum] = {
                Task {
                    do { if let album = try await store.core?.release(releaseId: tracks[0].releaseId) { navigation.album(album) } }
                    catch { store.errorMessage = String(describing: error) }
                }
            }
        }
        if Set(tracks.map(\.artistId)).count == 1 {
            actions[.goToArtist] = {
                Task {
                    do { if let artist = try await store.core?.artist(artistId: tracks[0].artistId) { navigation.artist(artist) } }
                    catch { store.errorMessage = String(describing: error) }
                }
            }
        }
        if store.isChangingTrack { actions.removeValue(forKey: .playSelection) }
        return Self(actions: actions)
    }

    static func playlist(_ playlist: Playlist, store: DurvaldCoreStore, creation: PlaylistCreationCoordinator,
                         navigation: TrackMenuNavigation) -> Self {
        var actions: [AppCommandID: () -> Void] = [
            .playSelection: { Task { await store.playPlaylist(playlistID: playlist.id) } },
            .playNext: { Task { await store.enqueuePlaylist(playlistID: playlist.id, playNext: true) } },
            .enqueue: { Task { await store.enqueuePlaylist(playlistID: playlist.id) } },
            .favorite: { store.setPlaylistFavorite(playlistID: playlist.id, favorite: !playlist.isFavorite) },
            .copyName: { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(playlist.name, forType: .string) },
            .addToPlaylist: {
                let window = NSApp.keyWindow
                Task {
                    let tracks = await store.tracks(forPlaylistID: playlist.id)
                    guard NSApp.keyWindow === window, !tracks.isEmpty else { return }
                    CommandPlaylistPicker.show(tracks: tracks, store: store, creation: creation, excluding: playlist.id)
                }
            },
            .editPlaylist: {
                if playlist.isSmart { navigation.playlist(playlist) }
                else { creation.requestEdit(playlist) }
            },
            .deletePlaylist: {
                guard let window = NSApp.keyWindow else { return }
                let alert = NSAlert()
                alert.messageText = "Excluir playlist “\(playlist.name)”?"
                alert.informativeText = "As músicas da biblioteca serão mantidas."
                alert.addButton(withTitle: "Cancelar")
                alert.addButton(withTitle: "Excluir")
                alert.beginSheetModal(for: window) { result in
                    guard result == .alertSecondButtonReturn else { return }
                    Task { if await store.deletePlaylist(id: playlist.id) { navigation.deletedPlaylist(playlist.id) } }
                }
            }
        ]
        if store.isChangingTrack { actions.removeValue(forKey: .playSelection) }
        // Rule editing belongs to the loaded detail page; opening is explicit.
        if playlist.isSmart { actions.removeValue(forKey: .editPlaylist) }
        return Self(actions: actions)
    }

    static func album(_ album: Release, store: DurvaldCoreStore, creation: PlaylistCreationCoordinator,
                      navigation: TrackMenuNavigation = TrackMenuNavigation()) -> Self {
        var actions: [AppCommandID: () -> Void] = [
            .playSelection: { Task { await store.playRelease(releaseID: album.id) } },
            .playNext: { Task { await store.enqueueRelease(releaseID: album.id, playNext: true) } },
            .enqueue: { Task { await store.enqueueRelease(releaseID: album.id) } },
            .goToAlbum: { navigation.album(album) },
            .goToArtist: {
                Task {
                    do { if let artist = try await store.core?.artist(artistId: album.artistId) { navigation.artist(artist) } }
                    catch { store.errorMessage = String(describing: error) }
                }
            },
            .favorite: { store.setReleaseFavorite(releaseID: album.id, favorite: !album.isFavorite) },
            .addToPlaylist: {
                let window = NSApp.keyWindow
                Task {
                    let tracks = await store.tracks(forReleaseID: album.id)
                    guard NSApp.keyWindow === window, !tracks.isEmpty else { return }
                    CommandPlaylistPicker.show(tracks: tracks, store: store, creation: creation)
                }
            },
            .copyName: { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(album.title, forType: .string) }
        ]
        if RatingPreferences.isEnabled && !store.isChangingRatingScale {
            let values = Set(RatingValues.options(store.ratingGranularity).map { UInt8($0) })
            for id in AppCommandID.allCases where id.isRating && (id == .clearRating || values.contains(id.ratingHalfSteps ?? 0)) {
                actions[id] = {
                    guard RatingPreferences.isEnabled, !store.isChangingRatingScale else { return }
                    Task { _ = await store.setReleaseRating(releaseID: album.id, rating: id.ratingHalfSteps, fallbackRelease: album) }
                }
            }
        }
        if store.isChangingTrack { actions.removeValue(forKey: .playSelection) }
        return Self(actions: actions)
    }
}

/// Keyboard-invoked chooser; selecting a destination is still explicit.
@MainActor
private final class CommandPlaylistPicker: NSObject {
    var actions: [() -> Void] = []
    @objc func choose(_ sender: NSMenuItem) { actions[sender.tag]() }
    static func show(tracks: [Track], store: DurvaldCoreStore, creation: PlaylistCreationCoordinator, excluding excludedID: Int64? = nil) {
        let picker = CommandPlaylistPicker()
        let menu = NSMenu(title: "Adicionar à playlist")
        func add(_ title: String, action: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = picker
            item.tag = picker.actions.count
            picker.actions.append(action)
            menu.addItem(item)
        }
        add("Nova playlist…") { creation.requestTracks(tracks.map(\.id)) }
        menu.addItem(.separator())
        for playlist in store.playlists where !playlist.isSmart && playlist.id != excludedID {
            add(playlist.name) { Task { await store.addSelectionToPlaylist(tracks.map(\.id), playlist: playlist) } }
        }
        _ = withExtendedLifetime(picker) { menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) }
    }
}

@MainActor
@Observable
final class CommandKeyboardState {
    var isEditing = false
    var windowIsKey = false
    weak var window: NSWindow?
    var isMainContext: Bool { windowIsKey && window != nil && NSApp.keyWindow === window && window?.attachedSheet == nil }
    func update() {
        let isKey = window != nil && NSApp.keyWindow === window
        if windowIsKey != isKey { windowIsKey = isKey }
        let editing = window?.firstResponder is NSTextView
        if isEditing != editing { isEditing = editing }
    }
}

/// Only native table bare keys need bridging. SwiftUI controls get first refusal
/// through the parent's onKeyPress; text editors never enter this bridge.
struct CommandKeyboardBridge: NSViewRepresentable {
    let state: CommandKeyboardState
    let perform: (AppCommandID) -> Bool
    func makeNSView(context: Context) -> BridgeView { BridgeView() }
    func updateNSView(_ view: BridgeView, context: Context) {
        view.state = state
        view.perform = perform
        view.install()
    }
    final class BridgeView: NSView {
        var state: CommandKeyboardState?
        var perform: ((AppCommandID) -> Bool)?
        private var monitor: Any?
        private var observers: [NSObjectProtocol] = []
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); install() }
        func install() {
            if state?.window !== window {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.state?.window = self.window
                    self.state?.update()
                }
            }
            guard monitor == nil, window != nil else { return }
            for name in [NSControl.textDidBeginEditingNotification, NSControl.textDidEndEditingNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.state?.update() }
                })
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseUp]) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    guard let self, event.window === self.window else { return false }
                    self.state?.update()
                    DispatchQueue.main.async { [weak self] in self?.state?.update() }
                    guard event.type == .keyDown, self.state?.isMainContext == true,
                          (self.window?.firstResponder is NSTableView || self.window?.firstResponder == nil || self.window?.firstResponder === self.window),
                          event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
                    let id: AppCommandID?
                    switch event.keyCode { case 49: id = .playPause; case 36, 76: id = .playSelection; case 51: id = .removeQueueItem; default: id = nil }
                    guard let id else { return false }
                    if event.isARepeat { return true }
                    return self.perform?(id) == true
                }
                return consumed ? nil : event
            }
        }
        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
