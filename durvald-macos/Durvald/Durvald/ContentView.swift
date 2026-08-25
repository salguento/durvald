import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: DurvaldCoreStore
    @Environment(\.controlActiveState) private var controlActiveState

    @State private var navigationHistory = LibraryNavigationHistory()
    @State private var sidebarSection: SidebarSection = .navigation
    @State private var searchText = ""
    @State private var searchFocusRequest = 0
    @State private var isSearchFocused = false
    @State private var isQueuePresented = false

    var body: some View {
        NavigationSplitView {
            LibrarySidebarView(
                section: $sidebarSection,
                destination: destinationBinding
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            VStack(spacing: 0) {
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                PlayerBar(
                    isQueuePresented: isQueuePresented,
                    onToggleQueue: { isQueuePresented.toggle() }
                )
            }
        }
        .inspector(isPresented: $isQueuePresented) {
            QueueView()
                .inspectorColumnWidth(min: 320, ideal: 360, max: 480)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ControlGroup {
                    Button {
                        navigationHistory.goBack()
                    } label: {
                        Label("Voltar", systemImage: "chevron.left")
                    }
                    .disabled(!navigationHistory.canGoBack)
                    .keyboardShortcut("[", modifiers: .command)
                    .accessibilityIdentifier("navigation.back")

                    Button {
                        navigationHistory.goForward()
                    } label: {
                        Label("Avançar", systemImage: "chevron.right")
                    }
                    .disabled(!navigationHistory.canGoForward)
                    .keyboardShortcut("]", modifiers: .command)
                    .accessibilityIdentifier("navigation.forward")
                }
                .labelStyle(.iconOnly)
                .controlGroupStyle(.navigation)
            }

            ToolbarItem(placement: .navigation) {
                Text(navigationHistory.current == .search ? "" : navigationHistory.current.title)
                    .font(.headline)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)

                    ToolbarSearchTextField(
                        text: $searchText,
                        isFocused: $isSearchFocused,
                        isPresented: navigationHistory.current == .search,
                        focusRequest: searchFocusRequest
                    )
                    .frame(maxWidth: .infinity)

                    Button {
                        searchText = ""
                        requestSearchFocus()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .opacity(searchText.isEmpty ? 0 : 1)
                    .allowsHitTesting(!searchText.isEmpty)
                    .accessibilityHidden(searchText.isEmpty)
                    .accessibilityLabel("Limpar pesquisa")
                    .accessibilityIdentifier("search.clear")
                }
                .padding(.horizontal, 12)
                .frame(width: 300, height: 36)
                .accessibilityIdentifier("search.container")
                .glassEffect(
                    .regular
                        .interactive(),
                    in: .capsule
                )
                .overlay {
                    Capsule()
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .opacity(
                            isSearchFocused && controlActiveState != .inactive
                                ? 1
                                : 0
                        )
                }
                .animation(.easeOut(duration: 0.15), value: isSearchFocused)
                .animation(.easeOut(duration: 0.15), value: controlActiveState)
                .opacity(navigationHistory.current == .search ? 1 : 0)
                .allowsHitTesting(navigationHistory.current == .search)
                .accessibilityHidden(navigationHistory.current != .search)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .onChange(of: navigationHistory.current, initial: true) { _, destination in
            if destination == .search {
                requestSearchFocus()
            } else {
                isSearchFocused = false
            }
        }
        .alert(
            "Erro",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )
        ) {
            Button("OK") {
                store.errorMessage = nil
            }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private var destinationBinding: Binding<LibraryDestination?> {
        Binding(
            get: { navigationHistory.current },
            set: { destination in
                guard let destination else { return }
                if destination == .search && navigationHistory.current == .search {
                    requestSearchFocus()
                }
                navigationHistory.navigate(to: destination)
            }
        )
    }

    private func requestSearchFocus() {
        searchFocusRequest &+= 1
    }

    @ViewBuilder
    private var detail: some View {
        switch navigationHistory.current {
        case .search:
            LibrarySearchView(searchText: $searchText)
        case .songs:
            MusicLibraryView()
        case .albums:
            AlbumsView()
        case .artists:
            ArtistsView()
        case .playlists:
            PlaylistsView()
        case .history:
            HistoryView()
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(DurvaldCoreStore())
}
