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

    static func album(_ album: Release, store: DurvaldCoreStore, info: TrackInfoCoordinator, creation: PlaylistCreationCoordinator,
                      navigation: TrackMenuNavigation = TrackMenuNavigation()) -> Self {
        var actions: [AppCommandID: () -> Void] = [
            .info: { Task { await info.openAlbum(releaseID: album.id, using: store) } },
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
protocol NativeCommandSelectionProviding: AnyObject {
    var nativeCommandTarget: AppCommandTarget? { get set }
}

@MainActor
@Observable
final class CommandKeyboardState {
    var isEditing = false
    var windowIsKey = false
    var nativeSelectionRevision = 0
    private weak var lastResponder: NSResponder?
    var nativeSelection: AppCommandTarget? {
        _ = nativeSelectionRevision
        var view = window?.firstResponder as? NSView
        while let current = view {
            if let source = current as? NativeCommandSelectionProviding { return source.nativeCommandTarget ?? AppCommandTarget() }
            view = current.superview
        }
        return nil
    }
    weak var window: NSWindow?
    var isMainContext: Bool {
        _ = windowIsKey // Invalidates observers when activation changes.
        return window != nil && NSApp.keyWindow === window && window?.attachedSheet == nil
    }
    func update() {
        if lastResponder !== window?.firstResponder {
            lastResponder = window?.firstResponder
            nativeSelectionRevision += 1
        }
        let isKey = window != nil && NSApp.keyWindow === window
        if windowIsKey != isKey { windowIsKey = isKey }
        let editing = window?.firstResponder is NSTextView
        if isEditing != editing { isEditing = editing }
    }
}

/// Native tables and clicked rows bridge bare keys. SwiftUI controls get first refusal
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
            guard let attachedWindow = window else { return }
            if state?.window !== attachedWindow {
                DispatchQueue.main.async { [weak self, weak attachedWindow] in
                    guard let self, let attachedWindow, self.window === attachedWindow else { return }
                    self.state?.window = attachedWindow
                    self.state?.update()
                }
            }
            guard monitor == nil else { return }
            for name in [NSControl.textDidBeginEditingNotification, NSControl.textDidEndEditingNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSTableView.selectionDidChangeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.state?.update()
                        if name == NSTableView.selectionDidChangeNotification {
                            DispatchQueue.main.async { [weak self] in self?.state?.nativeSelectionRevision += 1 }
                        }
                    }
                })
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseUp]) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    guard let self, event.window === self.window else { return false }
                    self.state?.update()
                    DispatchQueue.main.async { [weak self] in self?.state?.update() }
                    guard event.type == .keyDown, self.state?.isMainContext == true,
                          (self.window?.firstResponder is NativeCommandSelectionProviding || self.window?.firstResponder == nil || self.window?.firstResponder === self.window),
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

/// The view publishing window actions must not also observe their focus graph:
/// closures can otherwise embed successive copies of that graph in themselves.
struct CommandInputModifier: ViewModifier {
    let window: AppCommandTarget
    let keyboard: CommandKeyboardState
    let showHelp: (Set<AppCommandID>) -> Void
    @FocusedValue(\.pageCommands) private var page
    @FocusedValue(\.selectionCommands) private var selection
    @FocusedValue(\.protectsBareCommandKeys) private var protectsBareKeys

    private var target: AppCommandTarget {
        var result = window
        let window = window, page = page, selection = keyboard.nativeSelection ?? selection, keyboard = keyboard, showHelp = showHelp
        result.actions[.help] = {
            var available = Set(AppCommandID.allCases.filter {
                AppCommandDispatch.action($0, window: window, page: page, selection: selection,
                    isMain: keyboard.isMainContext, editing: keyboard.isEditing) != nil
            })
            available.insert(.help)
            showHelp(available)
        }
        return result
    }

    func body(content: Content) -> some View {
        content
            .focusable(interactions: .edit)
            .focusEffectDisabled()
            .focusedSceneValue(\.windowCommands, target)
            .background { CommandKeyboardBridge(state: keyboard, perform: perform).frame(width: 0, height: 0) }
            .onKeyPress(keys: [.space, .return, .delete], phases: .down) { press in
                guard press.modifiers.isEmpty else { return .ignored }
                let id: AppCommandID = press.key == .space ? .playPause : press.key == .return ? .playSelection : .removeQueueItem
                return perform(id) ? .handled : .ignored
            }
    }

    private func perform(_ id: AppCommandID) -> Bool {
        keyboard.update()
        if id.isBareKey && (protectsBareKeys == true || keyboard.window?.firstResponder is NSControl && !(keyboard.window?.firstResponder is NSTableView)) { return false }
        guard let action = AppCommandDispatch.action(id, window: target, page: page, selection: keyboard.nativeSelection ?? selection,
            isMain: keyboard.isMainContext, editing: keyboard.isEditing) else { return false }
        action()
        return true
    }
}

/// Gives clicked SwiftUI rows a native responder even with keyboard navigation disabled.
@MainActor
final class CommandSelectionFocus {
    weak var view: NSView?
    func focus() {
        guard let view else { return }
        view.window?.makeFirstResponder(view)
    }
}

struct CommandSelectionFocusBridge: NSViewRepresentable {
    let focus: CommandSelectionFocus
    let target: AppCommandTarget
    func makeNSView(context: Context) -> SelectionView {
        let view = SelectionView()
        focus.view = view
        view.nativeCommandTarget = target
        return view
    }
    func updateNSView(_ view: SelectionView, context: Context) {
        focus.view = view
        view.nativeCommandTarget = target
    }
    final class SelectionView: NSView, NativeCommandSelectionProviding {
        var nativeCommandTarget: AppCommandTarget?
        override var acceptsFirstResponder: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 48 {
                if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
                else { window?.selectNextKeyView(self) }
            } else { super.keyDown(with: event) }
        }
    }
}
