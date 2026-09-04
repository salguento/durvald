enum LibraryRoute: Equatable {
    case section(LibraryDestination)
    case album(Release)
    case artist(Artist)
    case playlist(Playlist)

    var destination: LibraryDestination {
        switch self {
        case .section(let destination): destination
        case .album: .albums
        case .artist: .artists
        case .playlist: .playlists
        }
    }
}

struct LibraryNavigationHistory {
    private var entries: [LibraryRoute] = [.section(.home)]
    private var currentIndex = 0

    var current: LibraryDestination {
        currentRoute.destination
    }

    var currentRoute: LibraryRoute {
        entries[currentIndex]
    }

    var canGoBack: Bool {
        currentIndex > 0
    }

    var canGoForward: Bool {
        currentIndex + 1 < entries.count
    }

    mutating func navigate(to destination: LibraryDestination) {
        navigate(to: .section(destination))
    }

    mutating func navigate(to route: LibraryRoute) {
        guard route != currentRoute else { return }

        let firstForwardIndex = currentIndex + 1
        if firstForwardIndex < entries.count {
            entries.removeSubrange(firstForwardIndex...)
        }

        entries.append(route)
        currentIndex = entries.count - 1
    }

    mutating func goBack() {
        guard canGoBack else { return }
        currentIndex -= 1
    }

    mutating func goForward() {
        guard canGoForward else { return }
        currentIndex += 1
    }
}
