enum LibraryRoute: Equatable {
    case section(LibraryDestination)
    case album(Release)
    case externalAlbum(ExternalReleaseGroup, Artist)
    case artist(Artist)
    case playlist(Playlist)

    var destination: LibraryDestination {
        switch self {
        case .section(let destination): destination
        case .album, .externalAlbum: .albums
        case .artist: .artists
        case .playlist: .playlists
        }
    }
}

struct LibraryNavigationHistory {
    private struct Entry {
        let id: Int
        var route: LibraryRoute
    }

    private var entries: [Entry] = [Entry(id: 0, route: .section(.home))]
    private var currentIndex = 0
    private var nextEntryID = 1

    var current: LibraryDestination {
        currentRoute.destination
    }

    var currentRoute: LibraryRoute {
        entries[currentIndex].route
    }

    var currentEntryID: Int {
        entries[currentIndex].id
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

        entries.append(Entry(id: nextEntryID, route: route))
        nextEntryID += 1
        currentIndex = entries.count - 1
    }

    mutating func replaceCurrent(with route: LibraryRoute) {
        entries[currentIndex].route = route
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
