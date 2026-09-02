import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: DurvaldCoreStore
    @Environment(\.appearsActive) private var appearsActive

    @State private var navigationHistory = LibraryNavigationHistory()
    @State private var sidebarSection: SidebarSection = .navigation
    @State private var searchText = ""
    @State private var searchFocusRequest = 0
    @State private var isSearchFocused = false
    @State private var isQueuePresented = false
    @State private var selectedAlbum: Release?

    private enum Layout {
        static let contentMinimumWidth: CGFloat = 360
        static let queueMinimumWidth: CGFloat = 260
        static let queueIdealWidth: CGFloat = 300
        static let queueMaximumWidth: CGFloat = 380
    }

    var body: some View {
        NavigationSplitView {
            LibrarySidebarView(
                section: $sidebarSection,
                destination: destinationBinding,
                onSelectAlbum: showAlbum
            )
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            contentColumn
                .frame(
                    minWidth: Layout.contentMinimumWidth,
                    maxWidth: .infinity,
                    maxHeight: .infinity
                )
        }
        .inspector(isPresented: $isQueuePresented) {
            QueueView()
                .background {
                    InspectorSplitLayout()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .inspectorColumnWidth(
                    min: Layout.queueMinimumWidth,
                    ideal: Layout.queueIdealWidth,
                    max: Layout.queueMaximumWidth
                )
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ControlGroup {
                    Button {
                        navigateBack()
                    } label: {
                        Label("Voltar", systemImage: "chevron.left")
                    }
                    .disabled(
                        selectedAlbum == nil && !navigationHistory.canGoBack
                    )
                    .keyboardShortcut("[", modifiers: .command)
                    .accessibilityIdentifier("navigation.back")

                    Button {
                        navigationHistory.goForward()
                    } label: {
                        Label("Avançar", systemImage: "chevron.right")
                    }
                    .disabled(
                        selectedAlbum != nil || !navigationHistory.canGoForward
                    )
                    .keyboardShortcut("]", modifiers: .command)
                    .accessibilityIdentifier("navigation.forward")
                }
                .labelStyle(.iconOnly)
                .controlGroupStyle(.navigation)
            }

            ToolbarItem(placement: .navigation) {
                Text(toolbarTitle)
                    .font(.headline)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarItem(placement: .principal) {
                if navigationHistory.current == .search {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)

                        ToolbarSearchTextField(
                            text: $searchText,
                            isFocused: $isSearchFocused,
                            isPresented: true,
                            focusRequest: searchFocusRequest
                        )
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Pesquisar na biblioteca")
                        .accessibilityIdentifier("search.field")

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
                    .frame(
                        minWidth: 180,
                        idealWidth: 260,
                        maxWidth: 300,
                        minHeight: 36,
                        maxHeight: 36
                    )
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("search.container")
                    .glassEffect(
                        .regular
                            .interactive(),
                        in: .capsule
                    )
                    .overlay {
                        Capsule()
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .opacity(isSearchFocused && appearsActive ? 1 : 0)
                            .animation(.easeOut(duration: 0.15), value: appearsActive)
                    }
                    .animation(.easeOut(duration: 0.15), value: appearsActive)
                } else {
                    Color.clear
                        .frame(width: 1, height: 36)
                        .accessibilityHidden(true)
                }
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarSpacer(.flexible)

            ToolbarItem(placement: .automatic) {
                Button {
                    toggleQueue()
                } label: {
                    Image(systemName: "sidebar.trailing")
                        .foregroundStyle(
                            isQueuePresented && appearsActive
                                ? Color.accentColor
                                : Color.secondary
                        )
                }
                .help(isQueuePresented ? "Ocultar fila" : "Mostrar fila")
                .accessibilityHint("Mostra ou oculta a fila lateral de reprodução")
                .accessibilityLabel(isQueuePresented ? "Ocultar fila" : "Mostrar fila")
                .accessibilityIdentifier("player.queue")
                .keyboardShortcut("l", modifiers: [.command, .option])
            }
        }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .onChange(of: navigationHistory.current, initial: true) { _, destination in
            if destination != .albums {
                selectedAlbum = nil
            }

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

    private var contentColumn: some View {
        VStack(spacing: 0) {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            PlayerBar()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var destinationBinding: Binding<LibraryDestination?> {
        Binding(
            get: { navigationHistory.current },
            set: { destination in
                guard let destination else { return }
                selectedAlbum = nil
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

    private func navigateBack() {
        if selectedAlbum != nil {
            selectedAlbum = nil
        } else {
            navigationHistory.goBack()
        }
    }

    private func toggleQueue() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            isQueuePresented.toggle()
        }
    }

    private var toolbarTitle: String {
        if let selectedAlbum {
            return selectedAlbum.title
        }

        return navigationHistory.current == .search
            ? ""
            : navigationHistory.current.title
    }

    private func showAlbum(_ album: Release) {
        navigationHistory.navigate(to: .albums)
        selectedAlbum = album
    }

    @ViewBuilder
    private var detail: some View {
        switch navigationHistory.current {
        case .search:
            LibrarySearchView(searchText: $searchText)
        case .home:
            HomeView { destination in
                navigationHistory.navigate(to: destination)
            }
        case .songs:
            MusicLibraryView()
        case .albums:
            if let selectedAlbum {
                AlbumView(album: selectedAlbum)
            } else {
                AlbumsView(onSelectAlbum: showAlbum)
            }
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
