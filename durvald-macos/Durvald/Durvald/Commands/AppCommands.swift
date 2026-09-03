import SwiftUI

private struct OpenLibrarySearchKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var openLibrarySearch: (() -> Void)? {
        get { self[OpenLibrarySearchKey.self] }
        set { self[OpenLibrarySearchKey.self] = newValue }
    }
}

struct AppCommands: Commands {
    let store: DurvaldCoreStore
    @FocusedValue(\.openLibrarySearch) private var openSearch

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Pesquisar na biblioteca") {
                openSearch?()
            }
            .keyboardShortcut(AppKeyboardShortcuts.search)
            .disabled(openSearch == nil)
        }

        CommandMenu("Reprodução") {
            Button("Reproduzir ou pausar") {
                Task { await store.togglePause() }
            }

            Button("Próxima música") {
                Task { await store.next() }
            }

            Button("Música anterior") {
                Task { await store.previous() }
            }

            Divider()

            Button("Aumentar volume") {
                store.adjustVolume(by: 0.05)
            }
            .keyboardShortcut(AppKeyboardShortcuts.increaseVolume)

            Button("Diminuir volume") {
                store.adjustVolume(by: -0.05)
            }
            .keyboardShortcut(AppKeyboardShortcuts.decreaseVolume)

            Divider()

            Button("Ativar ou desativar aleatório") {
                Task { await store.toggleShuffle() }
            }
            .keyboardShortcut(AppKeyboardShortcuts.toggleShuffle)

            Button("Alternar repetição") {
                Task { await store.cycleRepeatMode() }
            }
            .keyboardShortcut(AppKeyboardShortcuts.cycleRepeat)
        }
    }
}
