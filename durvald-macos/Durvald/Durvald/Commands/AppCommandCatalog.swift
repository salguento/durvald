import SwiftUI

/// A command has one identity and presentation across menus, help and keyboard routing.
enum AppCommandID: String, CaseIterable, Identifiable {
    case search, filter, back, forward, sidebar, queue
    case home, songs, albums, artists, playlists, retrospective
    case playPause, next, previous, volumeUp, volumeDown, mute, shuffle, repeatMode, seekBack, seekForward
    case playSelection, playCollection, shuffleCollection, playNext, enqueue, addToPlaylist, info, copyName, favorite
    case clearRating, rate0, rate1, rate2, rate3, rate4, rate5, rate6, rate7, rate8, rate9, rate10
    case openReplay, saveReplay
    case goToAlbum, goToArtist, playingAlbum, playingArtist
    case removeQueueItem, clearQueue, moveUp, moveDown
    case newPlaylist, newSmartPlaylist, importPlaylist, editPlaylist, deletePlaylist, exportRelative, exportAbsolute
    case updateLibrary, addFolder, cancelScan, viewOptions, help
    var id: String { rawValue }
    var group: String {
        switch self {
        case .search, .filter, .back, .forward, .sidebar, .queue, .home, .songs, .albums, .artists, .playlists, .retrospective: "Navegação"
        case .playPause, .next, .previous, .volumeUp, .volumeDown, .mute, .shuffle, .repeatMode, .seekBack, .seekForward, .playCollection, .shuffleCollection, .playingAlbum, .playingArtist: "Reprodução"
        case .newPlaylist, .newSmartPlaylist, .importPlaylist, .editPlaylist, .deletePlaylist, .exportRelative, .exportAbsolute: "Playlists"
        case .updateLibrary, .addFolder, .cancelScan, .viewOptions: "Biblioteca"
        case .help: "Ajuda"
        case .openReplay, .saveReplay: "Playlists"
        default: "Seleção e fila"
        }
    }
    var title: String {
        switch self {
        case .search: "Pesquisar na biblioteca"
        case .filter: "Filtrar a página"
        case .back: "Voltar"
        case .forward: "Avançar"
        case .sidebar: "Mostrar ou ocultar barra lateral"
        case .queue: "Mostrar ou ocultar fila"
        case .home: "Ir ao Início"
        case .songs: "Ir a Músicas"
        case .albums: "Ir a Álbuns"
        case .artists: "Ir a Artistas"
        case .playlists: "Ir a Playlists"
        case .retrospective: "Ir à Retrospectiva"
        case .playPause: "Reproduzir ou pausar"
        case .next: "Próxima música"
        case .previous: "Música anterior"
        case .volumeUp: "Aumentar volume"
        case .volumeDown: "Diminuir volume"
        case .mute: "Mutar ou restaurar volume"
        case .shuffle: "Ativar ou desativar aleatório"
        case .repeatMode: "Alternar repetição"
        case .seekBack: "Recuar cinco segundos"
        case .seekForward: "Avançar cinco segundos"
        case .playSelection: "Reproduzir seleção"
        case .playCollection: "Reproduzir coleção aberta"
        case .shuffleCollection: "Embaralhar coleção aberta"
        case .playNext: "Tocar seleção de próxima"
        case .enqueue: "Adicionar seleção à fila"
        case .addToPlaylist: "Adicionar seleção à playlist…"
        case .info: "Informações da seleção"
        case .copyName: "Copiar nome da seleção"
        case .favorite: "Favoritar ou desfavoritar seleção"
        case .openReplay: "Abrir Replay do período"
        case .saveReplay: "Salvar Replay…"
        case .clearRating: "Sem avaliação"
        case .rate0, .rate1, .rate2, .rate3, .rate4, .rate5, .rate6, .rate7, .rate8, .rate9, .rate10:
            "Avaliar: \(Double(ratingHalfSteps ?? 0) / 2) estrelas"
        case .goToAlbum: "Ir ao álbum da seleção"
        case .goToArtist: "Ir ao artista da seleção"
        case .playingAlbum: "Ir ao álbum em reprodução"
        case .playingArtist: "Ir ao artista em reprodução"
        case .removeQueueItem: "Remover item da fila"
        case .clearQueue: "Limpar fila…"
        case .moveUp: "Mover item para cima"
        case .moveDown: "Mover item para baixo"
        case .newPlaylist: "Nova playlist…"
        case .newSmartPlaylist: "Nova playlist inteligente…"
        case .importPlaylist: "Importar playlist…"
        case .editPlaylist: "Editar playlist…"
        case .deletePlaylist: "Excluir playlist…"
        case .exportRelative: "Exportar M3U8 com caminhos relativos…"
        case .exportAbsolute: "Exportar M3U8 com caminhos absolutos…"
        case .updateLibrary: "Atualizar biblioteca"
        case .addFolder: "Adicionar pasta…"
        case .cancelScan: "Cancelar scan"
        case .viewOptions: "Opções da listagem…"
        case .help: "Atalhos de teclado…"
        }
    }
    var shortcut: KeyboardShortcut? {
        switch self {
        case .search: .init("k", modifiers: .command)
        case .filter: .init("f", modifiers: .command)
        case .back: .init("[", modifiers: .command)
        case .forward: .init("]", modifiers: .command)
        case .sidebar: .init("s", modifiers: [.command, .control])
        case .queue: .init("l", modifiers: [.command, .option])
        case .home: .init("1", modifiers: .command)
        case .songs: .init("2", modifiers: .command)
        case .albums: .init("3", modifiers: .command)
        case .artists: .init("4", modifiers: .command)
        case .playlists: .init("5", modifiers: .command)
        case .retrospective: .init("6", modifiers: .command)
        case .playPause: .init(.space, modifiers: [])
        case .next: .init(.rightArrow, modifiers: [.command, .control])
        case .previous: .init(.leftArrow, modifiers: [.command, .control])
        case .volumeUp: .init(.upArrow, modifiers: .command)
        case .volumeDown: .init(.downArrow, modifiers: .command)
        case .mute: .init("m", modifiers: [.command, .shift])
        case .shuffle: .init("s", modifiers: [.command, .shift])
        case .repeatMode: .init("r", modifiers: [.command, .shift])
        case .seekBack: .init(.leftArrow, modifiers: [.command, .option])
        case .seekForward: .init(.rightArrow, modifiers: [.command, .option])
        case .playSelection: .init(.return, modifiers: [])
        case .playCollection: .init(.return, modifiers: .command)
        case .shuffleCollection: .init(.return, modifiers: [.command, .shift])
        case .playNext: .init("n", modifiers: [.command, .option])
        case .enqueue: .init("e", modifiers: [.command, .option])
        case .addToPlaylist: .init("p", modifiers: [.command, .shift])
        case .info: .init("i", modifiers: .command)
        case .copyName: .init("c", modifiers: [.command, .shift])
        case .favorite: .init("l", modifiers: [.command, .shift])
        case .removeQueueItem: .init(.delete, modifiers: [])
        case .moveUp: .init(.upArrow, modifiers: [.command, .control])
        case .moveDown: .init(.downArrow, modifiers: [.command, .control])
        case .newPlaylist: .init("n", modifiers: .command)
        case .newSmartPlaylist: .init("n", modifiers: [.command, .shift])
        case .updateLibrary: .init("r", modifiers: .command)
        case .viewOptions: .init("j", modifiers: .command)
        case .help: .init("/", modifiers: [.command, .shift])
        default: nil
        }
    }
    var shortcutLabel: String {
        guard let shortcut else { return "—" }
        let key: String
        switch shortcut.key {
        case .space: key = "Espaço"
        case .return: key = "Return"
        case .delete: key = "⌫"
        case .leftArrow: key = "←"
        case .rightArrow: key = "→"
        case .upArrow: key = "↑"
        case .downArrow: key = "↓"
        default: key = String(shortcut.key.character).uppercased()
        }
        return (shortcut.modifiers.contains(.control) ? "⌃" : "")
            + (shortcut.modifiers.contains(.option) ? "⌥" : "")
            + (shortcut.modifiers.contains(.shift) ? "⇧" : "")
            + (shortcut.modifiers.contains(.command) ? "⌘" : "") + key
    }
    var scope: String {
        if usesSelection { return "Seleção focada" }
        if [.editPlaylist, .deletePlaylist].contains(self) { return "Playlist focada ou aberta" }
        if [.playCollection, .shuffleCollection, .editPlaylist, .deletePlaylist, .exportRelative, .exportAbsolute, .openReplay, .saveReplay].contains(self) { return "Página aberta" }
        return "Janela da biblioteca"
    }
    var ratingHalfSteps: UInt8? {
        let ratings: [Self] = [.rate0, .rate1, .rate2, .rate3, .rate4, .rate5, .rate6, .rate7, .rate8, .rate9, .rate10]
        return ratings.firstIndex(of: self).map(UInt8.init)
    }
    var isRating: Bool { self == .clearRating || ratingHalfSteps != nil }
    var isBareKey: Bool { shortcut?.modifiers.isEmpty == true }
    var usesSelection: Bool {
        if isRating { return true }
        return switch self {
        case .playSelection, .playNext, .enqueue, .addToPlaylist, .info, .copyName, .favorite, .goToAlbum, .goToArtist, .removeQueueItem, .moveUp, .moveDown: true
        default: false
        }
    }
}

struct KeyboardShortcutsHelp: View {
    let available: Set<AppCommandID>
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Atalhos de teclado").font(.title.bold())
            Text("Disponibilidade no contexto em que esta ajuda foi aberta. Foque uma faixa para usar os comandos de seleção. Espaço, Return, Delete e setas preservam a edição de texto e os controles focados.")
                .font(.callout).foregroundStyle(.secondary)
            List {
                ForEach(["Navegação", "Reprodução", "Seleção e fila", "Playlists", "Biblioteca", "Ajuda"], id: \.self) { group in
                    Section(group) {
                        ForEach(AppCommandID.allCases.filter { $0.group == group }) { command in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(command.title)
                                    Text(command.scope).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(command.shortcutLabel).monospaced()
                                Image(systemName: available.contains(command) ? "checkmark.circle" : "minus.circle")
                                    .foregroundStyle(available.contains(command) ? .green : .secondary)
                                    .accessibilityLabel(available.contains(command) ? "Disponível" : "Indisponível neste contexto")
                            }
                        }
                    }
                }
            }
            HStack { Spacer(); Button("Fechar") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(24).frame(width: 720, height: 640)
        .accessibilityIdentifier("keyboardShortcuts.help")
    }
}
