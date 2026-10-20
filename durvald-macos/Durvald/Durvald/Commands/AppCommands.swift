import SwiftUI

private struct CommandKeyboardKey: FocusedValueKey { typealias Value = CommandKeyboardState }
extension FocusedValues {
    var commandKeyboardState: CommandKeyboardState? {
        get { self[CommandKeyboardKey.self] }
        set { self[CommandKeyboardKey.self] = newValue }
    }
}

@MainActor
enum AppCommandDispatch {
    static func action(_ id: AppCommandID, window: AppCommandTarget?, page: AppCommandTarget?,
                       selection: AppCommandTarget?, isMain: Bool, editing: Bool) -> (() -> Void)? {
        guard isMain else { return nil }
        if editing && (id.usesSelection || [.playPause, .playCollection, .shuffleCollection, .volumeUp, .volumeDown, .seekBack, .seekForward].contains(id)) { return nil }
        if id.usesSelection { return selection?.actions[id] }
        if [.editPlaylist, .deletePlaylist].contains(id), let selectedAction = selection?.actions[id] { return selectedAction }
        return page?.actions[id] ?? window?.actions[id]
    }
}

struct AppCommands: Commands {
    @FocusedValue(\.windowCommands) private var window
    @FocusedValue(\.pageCommands) private var page
    @FocusedValue(\.selectionCommands) private var selection
    @FocusedValue(\.commandKeyboardState) private var keyboard

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            command(.newPlaylist)
            command(.newSmartPlaylist)
            command(.importPlaylist)
        }
        CommandGroup(after: .textEditing) {
            command(.search)
            command(.filter)
            Divider()
            command(.info)
            command(.copyName)
        }
        CommandMenu("Navegação") {
            command(.back); command(.forward)
            Divider()
            command(.sidebar); command(.queue)
            Divider()
            ForEach([AppCommandID.home, .songs, .albums, .artists, .playlists, .retrospective]) { command($0) }
            Divider()
            command(.playingAlbum); command(.playingArtist)
        }
        CommandMenu("Reprodução") {
            command(.playPause); command(.next); command(.previous)
            Divider()
            command(.volumeUp); command(.volumeDown); command(.mute)
            Divider()
            command(.shuffle); command(.repeatMode)
            command(.seekBack); command(.seekForward)
            Divider()
            command(.playCollection); command(.shuffleCollection)
        }
        CommandMenu("Seleção") {
            ForEach(AppCommandID.allCases.filter { $0.usesSelection && !$0.isRating }) { command($0) }
            Menu("Avaliação") { ForEach(AppCommandID.allCases.filter(\.isRating)) { command($0) } }
            Divider()
            command(.clearQueue)
        }
        CommandMenu("Biblioteca") {
            command(.updateLibrary); command(.addFolder); command(.cancelScan); command(.viewOptions)
            Divider()
            command(.editPlaylist); command(.deletePlaylist)
            command(.exportRelative); command(.exportAbsolute)
            command(.openReplay); command(.saveReplay)
        }
        CommandGroup(replacing: .help) { command(.help) }
    }

    private func command(_ id: AppCommandID) -> some View {
        let action = AppCommandDispatch.action(id, window: window, page: page, selection: keyboard?.nativeSelection ?? selection,
                                               isMain: keyboard?.isMainContext == true, editing: keyboard?.isEditing == true)
        // Bare keys route after the focused control, not through menu equivalents
        // (which would otherwise steal spaces/Return/Delete from native editors).
        return Button(id.title + (id.isBareKey ? " (\(id.shortcutLabel))" : "")) {
            keyboard?.update()
            AppCommandDispatch.action(id, window: window, page: page, selection: keyboard?.nativeSelection ?? selection,
                isMain: keyboard?.isMainContext == true, editing: keyboard?.isEditing == true)?()
        }
            .keyboardShortcut(id.isBareKey ? nil : id.shortcut)
            .disabled(action == nil)
    }
}
