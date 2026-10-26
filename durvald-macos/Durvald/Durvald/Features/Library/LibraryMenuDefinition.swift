import Foundation

/// Commands are independent of AppKit selectors and of the capture surface.
enum LibraryMenuCommand {
    case playPlaylist, shufflePlaylist, editPlaylist, deletePlaylist
    case playAlbum, shuffleAlbum, playNext, addToQueue, toggleFavorite, setRating
    case goToArtist, goToAlbum, navigateSelection, showInfo, copyName, additional, personalTags, listenList, albumCollection
}

struct LibraryMenuAction {
    let title: String
    let command: LibraryMenuCommand
    var tag = 0
    var isSelected = false
    var isEnabled = true
    var systemImage: String? = nil
    var track: Track? = nil
}

indirect enum LibraryMenuItem {
    case action(LibraryMenuAction)
    case separator
    case submenu(String, [LibraryMenuItem])
    case playlistPicker
    case containingPlaylists

    static func action(_ title: String, _ command: LibraryMenuCommand) -> Self {
        .action(LibraryMenuAction(title: title, command: command))
    }
}

enum LibraryMenuDefinition {
    static func build(track: Track?, selectedTracks: [Track], album: Release?, playlist: Playlist?,
                      ratingsEnabled: Bool, ratingGranularity: RatingGranularity = .halfStars, ratingEditingEnabled: Bool = true, additionalActions: [TrackMenuAction]) -> [LibraryMenuItem] {
        if playlist != nil {
            return [.action("Tocar", .playPlaylist), .action("Aleatório", .shufflePlaylist), .separator,
                    .playlistPicker, .action("Tocar de próxima", .playNext), .action("Adicionar à fila", .addToQueue),
                    .separator, .action("Editar detalhes", .editPlaylist), .separator, .action("Deletar", .deletePlaylist)]
        }
        if let album {
            var items: [LibraryMenuItem] = [.action("Tocar", .playAlbum), .action("Aleatório", .shuffleAlbum), .separator,
                .playlistPicker, .action("Tocar de próxima", .playNext), .action("Adicionar à fila", .addToQueue),
                .separator, .action(album.isFavorite ? "Desfavoritar" : "Favoritar", .toggleFavorite)]
            if ratingsEnabled { items.append(rating(current: album.ratingHalfSteps, granularity: ratingGranularity, enabled: ratingEditingEnabled)) }
            items += [.separator, .action("Info", .showInfo), .action("Adicionar a Ouvir depois", .listenList), .action("Adicionar à coleção de álbuns…", .albumCollection), .action("Tags pessoais…", .personalTags), .submenu("Compartilhar", [.action("Copiar título", .copyName)])]
            return items
        }
        let favorite = !selectedTracks.isEmpty && selectedTracks.allSatisfy(\.isFavorite)
        var items: [LibraryMenuItem] = [.playlistPicker, .action("Tocar de próxima", .playNext),
            .action("Adicionar à fila", .addToQueue), .separator,
            .action(favorite ? "Desfavoritar" : "Favoritar", .toggleFavorite)]
        if ratingsEnabled { items.append(rating(current: track?.ratingHalfSteps, granularity: ratingGranularity, enabled: ratingEditingEnabled)) }
        items += [.separator, navigation(tracks: selectedTracks, artist: true), navigation(tracks: selectedTracks, artist: false),
                  .containingPlaylists, .separator, .action("Info", .showInfo), .action("Tags pessoais…", .personalTags),
                  .submenu("Compartilhar", [.action("Copiar nome", .copyName)])]
        if !additionalActions.isEmpty {
            items.append(.separator)
            items += additionalActions.enumerated().map { index, action in
                .action(LibraryMenuAction(title: action.title, command: .additional, tag: index,
                                          isEnabled: action.isEnabled, systemImage: action.systemImage))
            }
        }
        return items
    }

    private static func rating(current: UInt8?, granularity: RatingGranularity, enabled: Bool) -> LibraryMenuItem {
        var items: [LibraryMenuItem] = [.action(LibraryMenuAction(title: "Sem avaliação", command: .setRating, tag: -1,
                                                                 isSelected: current == nil, isEnabled: enabled)), .separator]
        items += RatingValues.options(granularity).map { value in
            .action(LibraryMenuAction(title: PersonalValueLabels.rating(UInt8(value)), command: .setRating, tag: value,
                                      isSelected: current == UInt8(value), isEnabled: enabled))
        }
        return .submenu("Avaliação", items)
    }

    private static func navigation(tracks: [Track], artist: Bool) -> LibraryMenuItem {
        let title = artist ? "Ir ao artista" : "Ir ao álbum"
        var seen = Set<Int64>()
        let choices = tracks.filter { seen.insert(artist ? $0.artistId : $0.releaseId).inserted }
        guard choices.count > 1 else { return .action(title, artist ? .goToArtist : .goToAlbum) }
        return .submenu(title, choices.map { track in
            .action(LibraryMenuAction(title: artist ? track.artist : track.release, command: .navigateSelection,
                                      tag: artist ? 1 : 0, track: track))
        })
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

