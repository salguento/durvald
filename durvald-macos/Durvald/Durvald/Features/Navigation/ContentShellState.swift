import SwiftUI

private struct LibraryScrollOffsetKey: EnvironmentKey {
    static let defaultValue = Binding.constant(CGFloat.zero)
}

extension EnvironmentValues {
    var libraryScrollOffset: Binding<CGFloat> {
        get { self[LibraryScrollOffsetKey.self] }
        set { self[LibraryScrollOffsetKey.self] = newValue }
    }
}

private struct LibraryScrollPositionModifier: ViewModifier {
    @Environment(\.libraryScrollOffset) private var savedOffset

    let isContentReady: Bool

    @State private var position = ScrollPosition()
    @State private var isRestoring = true

    private struct GeometrySnapshot: Equatable {
        let offset: CGFloat
    }

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onScrollGeometryChange(for: GeometrySnapshot.self) { geometry in
                GeometrySnapshot(
                    offset: max(0, geometry.visibleRect.minY)
                )
            } action: { _, geometry in
                // ScrollPosition clamps requested offsets to the current
                // content bounds. Never hide the page or retry until an exact
                // offset matches, especially with lazily measured collections.
                guard isContentReady, !isRestoring else { return }
                savedOffset.wrappedValue = geometry.offset
            }
            .onScrollPhaseChange { oldPhase, newPhase, context in
                guard !isRestoring,
                      newPhase == .idle,
                      isUserDriven(oldPhase) else { return }
                savedOffset.wrappedValue = max(0, context.geometry.visibleRect.minY)
            }
            .task(id: isContentReady) {
                guard isContentReady else {
                    isRestoring = true
                    return
                }

                isRestoring = true
                let offsetToRestore = savedOffset.wrappedValue
                await Task.yield()
                guard !Task.isCancelled else { return }
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    position.scrollTo(y: offsetToRestore)
                    isRestoring = false
                }
            }
    }

    private func isUserDriven(_ phase: ScrollPhase) -> Bool {
        switch phase {
        case .tracking, .interacting, .decelerating, .animating:
            true
        case .idle:
            false
        }
    }
}

extension View {
    func preservesLibraryScrollPosition(isContentReady: Bool = true) -> some View {
        modifier(LibraryScrollPositionModifier(isContentReady: isContentReady))
    }
}

struct ContentShellState {
    var navigationHistory = LibraryNavigationHistory()
    var sidebarSection: SidebarSection = .navigation
    var searchText = ""
    var submittedSearchText = ""
    var searchSubmissionRevision: UInt64 = 0
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

    mutating func submitSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        submittedSearchText = query
        searchSubmissionRevision &+= 1
        navigationHistory.navigate(to: .search)
    }

    mutating func requestSearchFocus() {
        navigationHistory.navigate(to: .home)
        searchFocusRequest &+= 1
    }

    mutating func handleDestinationChange(_ destination: LibraryDestination) {
        if destination != .home && destination != .search {
            isSearchFocused = false
        }
    }
}
