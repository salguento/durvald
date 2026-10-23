import SwiftUI

enum LibraryDestination: String, CaseIterable, Identifiable {
    case home
    case genres
    case listenList
    case songs
    case albums
    case artists
    case playlists
    case retrospective
    case search

    var id: Self { self }

    static let navigationItems: [LibraryDestination] = [
        .listenList,
        .genres,
        .songs,
        .albums,
        .artists,
        .playlists,
        .retrospective,
    ]

    var title: String {
        switch self {
        case .genres: "Gêneros"
        case .home: "Início"
        case .listenList: "Para ouvir"
        case .songs: "Músicas"
        case .albums: "Álbuns"
        case .artists: "Artistas"
        case .playlists: "Playlists"
        case .retrospective: "Retrospectiva"
        case .search: "Resultados da pesquisa"
        }
    }

    var icon: String {
        switch self {
        case .genres: "square.grid.2x2"
        case .home: "house"
        case .listenList: "bookmark"
        case .songs: "music.note"
        case .albums: "square.stack"
        case .artists: "music.mic"
        case .playlists: "music.note.list"
        case .retrospective: "clock.arrow.circlepath"
        case .search: "magnifyingglass"
        }
    }
}
