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
    @State private var scrollPhase: ScrollPhase = .idle

    private struct GeometrySnapshot: Equatable {
        let offset: CGFloat
    }

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .opacity(isRestoring && savedOffset.wrappedValue > 0 ? 0 : 1)
            .onScrollGeometryChange(for: GeometrySnapshot.self) { geometry in
                GeometrySnapshot(
                    offset: max(0, geometry.visibleRect.minY)
                )
            } action: { _, geometry in
                if isRestoring {
                    guard isContentReady else { return }
                    guard abs(geometry.offset - savedOffset.wrappedValue) <= 0.5 else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        isRestoring = false
                    }
                } else if isUserDriven(scrollPhase) {
                    savedOffset.wrappedValue = geometry.offset
                }
            }
            .onScrollPhaseChange { oldPhase, newPhase, context in
                scrollPhase = newPhase
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
                await Task.yield()
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    position.scrollTo(y: savedOffset.wrappedValue)
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
