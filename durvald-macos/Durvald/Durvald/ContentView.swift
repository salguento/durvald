import SwiftUI

struct ContentView: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(\.appearsActive) private var appearsActive

    @State private var shell = ContentShellState()
    @State private var windowLayout = WindowSplitLayoutCoordinator()
    @State private var playlistCreation = PlaylistCreationCoordinator()

    private enum Layout {
        static let contentViewMinimumWidth: CGFloat = 360
        static let windowMinimumHeight: CGFloat = 360
        static let compactNavigationWidth: CGFloat = 700
        static let contentMinimumWidth: CGFloat = 360
        static let queueMinimumWidth: CGFloat = 260
        static let queueIdealWidth: CGFloat = 300
        static let queueMaximumWidth: CGFloat = 380
        static let playerMaximumWidth: CGFloat = 760
        static let playerHorizontalMargin: CGFloat = 16
        static let playerTopMargin: CGFloat = 12
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $shell.columnVisibility) {
            LibrarySidebarView(
                section: $shell.sidebarSection,
                destination: destinationBinding,
                selectedPlaylistID: selectedPlaylistID,
                onSelectAlbum: showAlbum,
                onSelectArtist: showArtist,
                onSelectPlaylist: showPlaylist
            )
            .navigationSplitViewColumnWidth(
                min: WindowSplitLayoutPolicy.sidebarMinimumWidth,
                ideal: WindowSplitLayoutPolicy.sidebarIdealWidth,
                max: WindowSplitLayoutPolicy.sidebarMaximumWidth
            )
            .background {
                SidebarSplitLayout(coordinator: windowLayout)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .toolbar(removing: .sidebarToggle)
            .toolbar {
                if shell.columnVisibility != .detailOnly {
                    ToolbarItem(placement: .primaryAction) {
                        sidebarToolbarButtons
                    }
                }
            }
        } detail: {
            contentColumn
                .frame(
                    minWidth: Layout.contentMinimumWidth,
                    maxWidth: .infinity,
                    maxHeight: .infinity
                )
        }
        .background {
            InspectorSplitLayout(coordinator: windowLayout)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .inspector(isPresented: $shell.isQueuePresented) {
            QueueView()
                .inspectorColumnWidth(
                    min: Layout.queueMinimumWidth,
                    ideal: Layout.queueIdealWidth,
                    max: Layout.queueMaximumWidth
                )
        }
        .toolbar(removing: .title)
        .frame(
            minWidth: Layout.contentViewMinimumWidth,
            minHeight: Layout.windowMinimumHeight
        )
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.width
        } action: { width in
            shell.adaptToWidth(width, compactThreshold: Layout.compactNavigationWidth)
        }
        .environment(playlistCreation)
        .focusedSceneValue(\.openLibrarySearch) {
            destinationBinding.wrappedValue = .search
        }
        .onChange(of: shell.navigationHistory.current, initial: true) { _, destination in
            shell.handleDestinationChange(destination)
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
        .sheet(isPresented: Binding(
            get: { playlistCreation.isPresented },
            set: { playlistCreation.isPresented = $0 }
        )) {
            let editingPlaylist = playlistCreation.editingPlaylist.map { playlist in
                store.playlists.first(where: { $0.id == playlist.id }) ?? playlist
            }
            CreatePlaylistSheet(playlist: editingPlaylist) { title, description, artworkBase64 in
                if let editingPlaylist {
                    guard let updatedPlaylist = await store.updatePlaylist(
                        id: editingPlaylist.id,
                        name: title,
                        description: description,
                        artworkBase64: artworkBase64
                    ) else { return false }
                    if case .playlist(let currentPlaylist) = shell.navigationHistory.currentRoute,
                       currentPlaylist.id == updatedPlaylist.id {
                        shell.navigationHistory.replaceCurrent(with: .playlist(updatedPlaylist))
                    }
                    return true
                }

                guard let playlist = await store.createPlaylist(
                    named: title,
                    description: description,
                    artworkBase64: artworkBase64
                ) else { return false }
                if let trackID = playlistCreation.pendingTrackID {
                    store.addTrack(trackID, to: playlist)
                }
                let updatedPlaylist = store.playlists.first { $0.id == playlist.id } ?? playlist
                showPlaylist(updatedPlaylist)
                return true
            }
        }
        .onChange(of: playlistCreation.isPresented) { _, isPresented in
            if !isPresented { playlistCreation.reset() }
        }
    }

    private var contentColumn: some View {
        detail
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                PlayerBar(onSelectAlbum: showAlbum, onSelectArtist: showArtist)
                    .frame(maxWidth: Layout.playerMaximumWidth)
                    .padding(.horizontal, Layout.playerHorizontalMargin)
                    .padding(.top, Layout.playerTopMargin)
                    .padding(.bottom, Layout.playerHorizontalMargin)
                    .frame(maxWidth: .infinity)
            }
            // Keep the toolbar and its scroll views in the same split column.
            // macOS owns the backdrop and its transition as content scrolls
            // behind the controls, including when the side panels resize.
            .toolbar { contentToolbar }
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
    }

    @ToolbarContentBuilder
    private var contentToolbar: some ToolbarContent {
        if shell.columnVisibility == .detailOnly {
            ToolbarItem(placement: .navigation) {
                sidebarToolbarButtons
            }
        }

        ToolbarItem(placement: .navigation) {
            ControlGroup {
                Button {
                    navigateBack()
                } label: {
                    Label("Voltar", systemImage: "chevron.left")
                }
                .disabled(!shell.navigationHistory.canGoBack)
                .keyboardShortcut(AppKeyboardShortcuts.goBack)
                .accessibilityIdentifier("navigation.back")

                Button {
                    shell.navigationHistory.goForward()
                } label: {
                    Label("Avançar", systemImage: "chevron.right")
                }
                .disabled(!shell.navigationHistory.canGoForward)
                .keyboardShortcut(AppKeyboardShortcuts.goForward)
                .accessibilityIdentifier("navigation.forward")
            }
            .labelStyle(.iconOnly)
            .controlGroupStyle(.navigation)
        }

        ToolbarItem(placement: .principal) {
            if shell.navigationHistory.current == .search {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)

                    ToolbarSearchTextField(
                        text: $shell.searchText,
                        isFocused: $shell.isSearchFocused,
                        isPresented: true,
                        focusRequest: shell.searchFocusRequest
                    )
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Pesquisar na biblioteca")
                    .accessibilityIdentifier("search.field")

                    Button {
                        shell.searchText = ""
                        requestSearchFocus()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .opacity(shell.searchText.isEmpty ? 0 : 1)
                    .allowsHitTesting(!shell.searchText.isEmpty)
                    .accessibilityHidden(shell.searchText.isEmpty)
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
                .glassEffect(.regular.interactive(), in: .capsule)
                .overlay {
                    Capsule()
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .opacity(shell.isSearchFocused && appearsActive ? 1 : 0)
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
                        shell.isQueuePresented && appearsActive
                            ? Color.accentColor
                            : Color.secondary
                    )
            }
            .help(shell.isQueuePresented ? "Ocultar fila" : "Mostrar fila")
            .accessibilityHint("Mostra ou oculta a fila lateral de reprodução")
            .accessibilityLabel(shell.isQueuePresented ? "Ocultar fila" : "Mostrar fila")
            .accessibilityIdentifier("player.queue")
            .keyboardShortcut(AppKeyboardShortcuts.toggleQueue)
        }
    }

    private var sidebarToggleButton: some View {
        Button {
            shell.toggleSidebar()
        } label: {
            Label(
                shell.columnVisibility == .detailOnly
                    ? "Mostrar barra lateral"
                    : "Ocultar barra lateral",
                systemImage: "sidebar.leading"
            )
        }
        .labelStyle(.iconOnly)
        .help(
            shell.columnVisibility == .detailOnly
                ? "Mostrar barra lateral"
                : "Ocultar barra lateral"
        )
        .accessibilityIdentifier("navigation.sidebar")
    }

    private var sidebarToolbarButtons: some View {
        HStack(spacing: shell.columnVisibility == .detailOnly ? 4 : 6) {
            sidebarToggleButton
            addPlaylistButton
        }
    }

    private var addPlaylistButton: some View {
        Button {
            playlistCreation.request(for: nil)
        } label: {
            Label("Adicionar", systemImage: "plus")
        }
        .labelStyle(.iconOnly)
        .help("Adicionar")
        .accessibilityLabel("Adicionar playlist")
        .accessibilityIdentifier("library.addMenu")
    }

    private var destinationBinding: Binding<LibraryDestination?> {
        Binding(
            get: { shell.navigationHistory.current },
            set: { destination in
                guard let destination else { return }
                if destination == .search && shell.navigationHistory.current == .search {
                    requestSearchFocus()
                }
                shell.navigationHistory.navigate(to: destination)
            }
        )
    }

    private var selectedPlaylistID: Int64? {
        guard case .playlist(let playlist) = shell.navigationHistory.currentRoute else { return nil }
        return playlist.id
    }

    private func requestSearchFocus() {
        shell.requestSearchFocus()
    }

    private func navigateBack() {
        shell.navigationHistory.goBack()
    }

    private func toggleQueue() {
        // Configure the collapsed inspector before its first layout can grow
        // the window. A helper inside QueueView would only run after opening.
        windowLayout.prepareInspectorPresentation()
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            shell.toggleQueue()
        }
    }

    private func showAlbum(_ album: Release) {
        shell.navigationHistory.navigate(to: .album(album))
    }

    private func showArtist(_ artist: Artist) {
        shell.navigationHistory.navigate(to: .artist(artist))
    }

    private func showPlaylist(_ playlist: Playlist) {
        shell.navigationHistory.navigate(to: .playlist(playlist))
    }

    @ViewBuilder
    private var detail: some View {
        switch shell.navigationHistory.currentRoute {
        case .album(let album):
            AlbumView(album: album, onSelectArtist: showArtist)
                .id(album.id)
        case .artist(let artist):
            ArtistView(artist: artist, onSelectAlbum: showAlbum)
                .id(artist.id)
        case .playlist(let playlist):
            PlaylistView(playlist: playlist)
                .id(playlist.id)
        case .section(let destination):
            sectionContent(destination)
        }
    }

    @ViewBuilder
    private func sectionContent(_ destination: LibraryDestination) -> some View {
        switch destination {
        case .search:
            LibrarySearchView(searchText: $shell.searchText)
        case .home:
            HomeView { destination in
                shell.navigationHistory.navigate(to: destination)
            }
        case .songs:
            MusicLibraryView()
        case .albums:
            AlbumsView(onSelectAlbum: showAlbum)
        case .artists:
            ArtistsView(onSelectArtist: showArtist)
        case .playlists:
            PlaylistsView()
        case .history:
            HistoryView()
        }
    }
}

#Preview {
    ContentView()
        .environment(DurvaldCoreStore())
}
