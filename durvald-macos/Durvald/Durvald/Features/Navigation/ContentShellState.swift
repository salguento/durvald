import SwiftUI

struct ContentShellState {
    var navigationHistory = LibraryNavigationHistory()
    var sidebarSection: SidebarSection = .navigation
    var searchText = ""
    var searchFocusRequest = 0
    var isSearchFocused = false
    var isQueuePresented = false
    var columnVisibility: NavigationSplitViewVisibility = .all

    mutating func adaptToWidth(_ width: CGFloat, compactThreshold: CGFloat) {
        guard width < compactThreshold else { return }
        columnVisibility = .detailOnly
        isQueuePresented = false
    }

    mutating func toggleSidebar() {
        columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
    }

    mutating func toggleQueue() {
        isQueuePresented.toggle()
    }

    mutating func requestSearchFocus() {
        searchFocusRequest &+= 1
    }

    mutating func handleDestinationChange(_ destination: LibraryDestination) {
        if destination == .search {
            requestSearchFocus()
        } else {
            isSearchFocused = false
        }
    }
}
