import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable {
    case navigation
    case playlists
    case albums
    case artists

    var id: Self { self }

    var title: String {
        switch self {
        case .navigation: "Navegação"
        case .playlists: "Playlists"
        case .albums: "Álbuns"
        case .artists: "Artistas"
        }
    }

    var icon: String {
        switch self {
        case .navigation: "sidebar.left"
        case .playlists: "music.note.list"
        case .albums: "square.stack"
        case .artists: "music.mic"
        }
    }
}
