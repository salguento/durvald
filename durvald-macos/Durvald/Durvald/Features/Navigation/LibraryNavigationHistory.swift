struct LibraryNavigationHistory {
    private var entries: [LibraryDestination] = [.home]
    private var currentIndex = 0

    var current: LibraryDestination {
        entries[currentIndex]
    }

    var canGoBack: Bool {
        currentIndex > 0
    }

    var canGoForward: Bool {
        currentIndex + 1 < entries.count
    }

    mutating func navigate(to destination: LibraryDestination) {
        guard destination != current else { return }

        let firstForwardIndex = currentIndex + 1
        if firstForwardIndex < entries.count {
            entries.removeSubrange(firstForwardIndex...)
        }

        entries.append(destination)
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
