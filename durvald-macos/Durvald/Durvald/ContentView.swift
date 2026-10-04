import AppKit
import SwiftUI

private final class LibraryScrollOffsetStore {
    private var offsets: [Int: CGFloat] = [:]

    func offset(for entryID: Int) -> CGFloat {
        offsets[entryID] ?? 0
    }

    func setOffset(_ offset: CGFloat, for entryID: Int) {
        offsets[entryID] = offset
    }
}

struct ContentView: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(TrackInfoCoordinator.self) private var trackInfo
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.openWindow) private var openWindow

    @AppStorage("albums.listingMode") private var albumListingMode: CollectionListingMode = .standardGrid
    @AppStorage("artists.listingMode") private var artistListingMode: CollectionListingMode = .standardGrid
    @AppStorage("playlists.listingMode") private var playlistListingMode: CollectionListingMode = .standard
    @AppStorage("albums.listingOrder") private var albumListingOrder: CollectionListingOrder = .recent
    @AppStorage("artists.onlyLocal") private var artistOnlyLocal = true
    @AppStorage("artists.listingOrder") private var artistListingOrder: CollectionListingOrder = .alphabetical
    @AppStorage("playlists.listingOrder") private var playlistListingOrder: CollectionListingOrder = .recent
    @AppStorage("albums.minimumRating") private var albumMinimumRating = 0

    @State private var albumSearchText = ""
    @State private var albumsSummary = "Carregando…"
    @State private var artistSearchText = ""
    @State private var artistsSummary = "Carregando…"
    @State private var historySearchText = ""
    @State private var historySummary = "Carregando…"
    @State private var musicEntryID: Int?
    @State private var musicPresentation = MusicLibraryPresentation()
    @State private var musicSearchText = ""
    @State private var contentColumnWidth: CGFloat = 0
    @State private var fullDetailColumnWidth: CGFloat = 0
    @State private var libraryToolbarMeasurements: [String: LibraryToolbarMeasurement] = [:]
    @State private var isLibrarySearchExpanded = false
    @State private var musicLibrarySummary = MusicLibrarySummary(tracks: [], kind: .all)
    @State private var shell = ContentShellState()
    @State private var windowLayout = WindowSplitLayoutCoordinator()
    @State private var playlistCreation = PlaylistCreationCoordinator()
    // Scroll geometry can change on every rendered frame. Keeping these values
    // in a reference store avoids invalidating the entire content column while
    // still preserving an independent position for every navigation entry.
    @State private var pageScrollOffsets = LibraryScrollOffsetStore()

    private enum Layout {
        static let librarySummaryLeadingPadding: CGFloat = 8
        static let panelToggleIconWidth: CGFloat = 20
        static let panelToggleIconHeight: CGFloat = 16
        static let contentViewMinimumWidth: CGFloat = 360
        static let windowMinimumHeight: CGFloat = 360
        static let compactNavigationWidth: CGFloat = 700
        static let contentMinimumWidth = WindowSplitLayoutPolicy.contentMinimumWidth
        static let queueMinimumWidth: CGFloat = 260
        static let queueIdealWidth: CGFloat = 300
        static let queueMaximumWidth: CGFloat = 380
        static let queueToggleWidth: CGFloat = 38
        static let playerHorizontalMargin: CGFloat = 32
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
            .frame(minWidth: WindowSplitLayoutPolicy.sidebarMinimumWidth)
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
                    ToolbarSpacer(.flexible)
                    ToolbarItem(placement: .automatic) {
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
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.automatic, for: .windowToolbar)
        .overlay(alignment: .trailing) {
            if shell.isQueuePresented {
                GeometryReader { geometry in
                    QueueView(topInset: geometry.safeAreaInsets.top)
                        .background(.ultraThinMaterial)
                        .ignoresSafeArea(edges: .top)
                }
                .frame(width: Layout.queueIdealWidth)
                .frame(maxHeight: .infinity)
                .background(.ultraThinMaterial)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
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
        .environment(\.trackMenuNavigation, TrackMenuNavigation(artist: showArtist, album: showAlbum, playlist: showPlaylist,
            deletedPlaylist: { id in
                if case .playlist(let playlist) = shell.navigationHistory.currentRoute, playlist.id == id {
                    shell.navigationHistory.navigate(to: .playlists)
                }
            }))
        .onAppear {
            trackInfo.presentWindow = {
                openWindow(id: "track-info")
            }
        }
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
                if !playlistCreation.pendingTrackIDs.isEmpty {
                    await store.addSelectionToPlaylist(playlistCreation.pendingTrackIDs, playlist: playlist)
                }
                if let trackID = playlistCreation.pendingTrackID {
                    store.addTrack(trackID, to: playlist)
                }
                if let releaseID = playlistCreation.pendingReleaseID {
                    guard await store.addRelease(releaseID, to: playlist) else { return false }
                }
                if let sourceID = playlistCreation.pendingPlaylistID {
                    guard await store.addPlaylist(sourceID, to: playlist) else { return false }
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
        ZStack {
            if let entryID = musicEntryID {
                MusicLibraryView(
                    searchText: $musicSearchText, presentation: musicPresentation,
                    isPresented: shell.navigationHistory.current == .songs,
                    navigationEntryID: entryID
                ) { summary in
                    musicLibrarySummary = summary
                }
                .environment(\.libraryScrollOffset, pageScrollOffset(for: entryID))
                .opacity(shell.navigationHistory.current == .songs ? 1 : 0)
                .allowsHitTesting(shell.navigationHistory.current == .songs)
                .accessibilityHidden(shell.navigationHistory.current != .songs)
            }
            if shell.navigationHistory.current != .songs {
                detail
                    .environment(\.libraryScrollOffset, currentPageScrollOffset)
                    .id(shell.navigationHistory.currentEntryID)
            }
        }
            .onChange(of: shell.navigationHistory.currentEntryID, initial: true) { _, entryID in
                if shell.navigationHistory.current == .songs { musicEntryID = entryID }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentColumnWidth = $0 }
            .padding(.trailing, shell.isQueuePresented ? Layout.queueIdealWidth : 0)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { fullDetailColumnWidth = $0 }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                PlayerBar(onSelectAlbum: showAlbum, onSelectArtist: showArtist)
                    .padding(.horizontal, Layout.playerHorizontalMargin)
                    .padding(.trailing, shell.isQueuePresented ? Layout.queueIdealWidth : 0)
                    .padding(.top, Layout.playerTopMargin)
                    .padding(.bottom, 20)
                    .frame(maxWidth: .infinity)
            }
            // Keep the toolbar and its scroll views in the same split column.
            // macOS owns the backdrop and its transition as content scrolls
            // behind the controls, including when the side panels resize.
            .toolbar { contentToolbar }
            .onChange(of: shell.navigationHistory.currentRoute) { _, _ in
                isLibrarySearchExpanded = false
            }
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
    }

    @ToolbarContentBuilder
    private var contentToolbar: some ToolbarContent {
        navigationToolbar

        if shell.navigationHistory.current == .search {
            ToolbarItem(id: "global-search", placement: .principal) {
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
                .offset(x: shell.isQueuePresented ? -Layout.queueIdealWidth / 2 : 0)
            }
            .sharedBackgroundVisibility(.hidden)
        }

        ToolbarSpacer(.flexible)

        if !hasLibrarySearch,
           case .section(let destination) = shell.navigationHistory.currentRoute,
                  destination == .artists || destination == .playlists {
            ToolbarItem(id: "\(destination.rawValue)-view-options", placement: .automatic) {
                collectionOptions(for: destination)
            }
            .sharedBackgroundVisibility(.hidden)
            if shell.isQueuePresented {
                ToolbarItem(id: "queue-toolbar-space", placement: .automatic) {
                    Color.clear
                        .frame(width: Layout.queueIdealWidth - Layout.queueToggleWidth - 32, height: 1)
                        .accessibilityHidden(true)
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        ToolbarSpacer(.fixed)
        ToolbarItem(id: "queue-toggle", placement: .automatic) {
            queueToggleButton
        }
        .sharedBackgroundVisibility(.hidden)
        .visibilityPriority(.high)
    }

    private var hasLibrarySearch: Bool {
        guard case .section(let destination) = shell.navigationHistory.currentRoute else { return false }
        return destination == .albums || destination == .songs || destination == .artists || destination == .history
    }

    private var librarySummaryText: String {
        switch shell.navigationHistory.current {
        case .songs: musicLibrarySummary.text
        case .artists: artistsSummary
        case .history: historySummary
        default: albumsSummary
        }
    }

    private var librarySearchText: Binding<String> {
        switch shell.navigationHistory.current {
        case .songs: $musicSearchText
        case .artists: $artistSearchText
        case .history: $historySearchText
        default: $albumSearchText
        }
    }

    private var librarySearchPlaceholder: String {
        switch shell.navigationHistory.current {
        case .songs: "Pesquisar músicas"
        case .artists: "Pesquisar artistas"
        case .history: "Pesquisar no histórico"
        default: "Pesquisar álbuns"
        }
    }

    private var librarySearchIdentifier: String {
        switch shell.navigationHistory.current {
        case .songs: "library.search"
        case .artists: "artists.search"
        case .history: "history.search"
        default: "albums.search"
        }
    }

    private var libraryToolbarLayoutKey: String {
        "\(shell.columnVisibility == .detailOnly)"
    }

    private var libraryToolbarDetailWidth: CGFloat {
        fullDetailColumnWidth > 0 ? fullDetailColumnWidth
            : contentColumnWidth + (shell.isQueuePresented ? Layout.queueIdealWidth : 0)
    }

    private var libraryExpandedControlsMinimumWidth: CGFloat {
        let textWidth = min(480, (librarySummaryText as NSString).size(withAttributes: [
            .font: NSFont.preferredFont(forTextStyle: .caption1)
        ]).width)
        return textWidth + 220 + 44 + 8 + Layout.librarySummaryLeadingPadding
    }

    private var libraryContentToolbar: some View {
        let navigationWidth: CGFloat = shell.columnVisibility == .detailOnly ? 280 : 76
        let detailWidth = libraryToolbarDetailWidth
        let measuredWidth = libraryToolbarMeasurements[libraryToolbarLayoutKey].map {
            $0.availableWidth + detailWidth - $0.detailWidth
        }
        let hostWidth = max(80, measuredWidth
                            ?? (detailWidth - navigationWidth - Layout.queueToggleWidth - 48))
        let panelReservation = shell.isQueuePresented ? Layout.queueIdealWidth - Layout.queueToggleWidth - 16 : 0
        let minimumWidth = 80 + panelReservation
        // Keep the last native measurement for each sidebar configuration.
        // The right overlay only reserves space inside this same toolbar item.
        let preferredWidth = max(minimumWidth, hostWidth)

        let content = GeometryReader { geometry in
            // Decide from the space AppKit actually assigned, never from a
            // preferred width that can lag behind the current resize frame.
            let compact = geometry.size.width - panelReservation < libraryExpandedControlsMinimumWidth
            let searchWidth = min(220, max(36, geometry.size.width - panelReservation - 44))
            let controlsReservation: CGFloat = (compact ? 36 : searchWidth) + 44
            let summaryWidth = max(0, geometry.size.width - panelReservation - controlsReservation - 8
                                   - Layout.librarySummaryLeadingPadding)

            ZStack(alignment: .trailing) {
                libraryToolbarSummary
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: summaryWidth, alignment: .leading)
                    .clipped()
                    .padding(.leading, Layout.librarySummaryLeadingPadding)
                    .frame(width: geometry.size.width, alignment: .leading)
                    .opacity(compact && isLibrarySearchExpanded ? 0 : 1)
                    .accessibilityHidden(compact && isLibrarySearchExpanded)
                libraryTopbarControls(searchWidth: searchWidth, prefersCompact: compact)
                    .padding(.trailing, panelReservation)
            }
            .frame(width: geometry.size.width, height: 36)
        }
        .environment(\.appearsActive, appearsActive)
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }

        return LibraryToolbarHost(content: content, minimumWidth: minimumWidth, preferredWidth: preferredWidth)
        .frame(minWidth: minimumWidth, maxWidth: .infinity, minHeight: 36, maxHeight: 36)
        .background {
            LibraryToolbarWidthObserver(
                trailingReservation: Layout.queueToggleWidth + 24,
                detailWidth: detailWidth,
                layoutKey: libraryToolbarLayoutKey,
                measurements: $libraryToolbarMeasurements
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    @ViewBuilder
    private var libraryToolbarSummary: some View {
        if shell.navigationHistory.current == .songs {
            MusicLibrarySummaryView(summary: musicLibrarySummary)
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Text(shell.navigationHistory.current.title).font(.headline)
                Text(librarySummaryText).font(.caption)
            }
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: 480, alignment: .leading)
            .help(librarySummaryText)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("\(shell.navigationHistory.current.rawValue).summary")
        }
    }

    private func libraryTopbarControls(searchWidth: CGFloat, prefersCompact: Bool) -> some View {
        HStack(spacing: 8) {
            LibraryToolbarSearchField(
                searchText: librarySearchText,
                placeholder: librarySearchPlaceholder,
                identifier: librarySearchIdentifier,
                prefersCompact: prefersCompact,
                expandedWidth: searchWidth,
                isExpanded: $isLibrarySearchExpanded
            )
            if shell.navigationHistory.current == .songs {
                MusicLibraryViewOptionsMenu(onShowViewOptions: {
                    openWindow(id: "music-view-options")
                })
                .glassEffect(.regular, in: .circle)
            } else if shell.navigationHistory.current == .history {
                HistoryToolbarOptionsMenu()
            } else {
                collectionOptions(for: shell.navigationHistory.current == .artists ? .artists : .albums)
            }
        }
        .fixedSize()
        .id(shell.navigationHistory.current)
    }

    private func collectionOptions(for destination: LibraryDestination) -> some View {
        CollectionListingMenu(
            mode: listingModeBinding(for: destination),
            order: listingOrderBinding(for: destination),
            minimumRating: destination == .albums ? $albumMinimumRating : nil,
            onlyLocal: destination == .artists ? $artistOnlyLocal : nil,
            controlSize: 36, controlWidth: 36, usesGlassEffect: true
        )
        .accessibilityIdentifier("\(destination.rawValue).listingMode")
    }

    private func listingModeBinding(for destination: LibraryDestination) -> Binding<CollectionListingMode> {
        switch destination {
        case .albums: $albumListingMode
        case .artists: $artistListingMode
        default: $playlistListingMode
        }
    }

    private func listingOrderBinding(for destination: LibraryDestination) -> Binding<CollectionListingOrder> {
        switch destination {
        case .albums: $albumListingOrder
        case .artists: $artistListingOrder
        default: $playlistListingOrder
        }
    }

    @ToolbarContentBuilder
    private var navigationToolbar: some ToolbarContent {
        if shell.columnVisibility == .detailOnly {
            ToolbarItem(placement: .navigation) {
                sidebarToolbarButtons
            }
        }

        ToolbarSpacer(.fixed, placement: .navigation)

        ToolbarItem(placement: .navigation) {
            backForwardButtons
        }
        if hasLibrarySearch {
            // The summary adds leading padding to match the navigation-to-title gap.
            ToolbarItem(id: "library-content-controls", placement: .navigation) {
                libraryContentToolbar
            }
            .sharedBackgroundVisibility(.hidden)
        }
    }

    private var queueToggleButton: some View {
        Button {
            toggleQueue()
        } label: {
            Image(systemName: "sidebar.trailing")
                .resizable()
                .scaledToFit()
                .frame(width: Layout.panelToggleIconWidth, height: Layout.panelToggleIconHeight)
                .foregroundStyle(appearsActive ? Color.primary : Color.secondary)
                .frame(width: Layout.queueToggleWidth, height: 36)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(width: Layout.queueToggleWidth, height: 36)
        .glassEffect(.regular.interactive(), in: .capsule)
        .help(shell.isQueuePresented ? "Ocultar fila" : "Mostrar fila")
        .accessibilityHint("Mostra ou oculta a fila lateral de reprodução")
        .accessibilityLabel(shell.isQueuePresented ? "Ocultar fila" : "Mostrar fila")
        .accessibilityIdentifier("player.queue")
        .keyboardShortcut(AppKeyboardShortcuts.toggleQueue)
    }

    private var sidebarToggleButton: some View {
        Button {
            toggleSidebar()
        } label: {
            Image(systemName: "sidebar.leading")
                .resizable()
                .scaledToFit()
                .frame(width: Layout.panelToggleIconWidth, height: Layout.panelToggleIconHeight)
        }
        .help(sidebarToggleTitle)
        .accessibilityLabel(sidebarToggleTitle)
        .accessibilityIdentifier("navigation.sidebar")
    }

    private var sidebarToggleTitle: String {
        shell.columnVisibility == .detailOnly
            ? "Mostrar barra lateral"
            : "Ocultar barra lateral"
    }

    private var sidebarToolbarButtons: some View {
        ControlGroup {
            sidebarToggleButton
            addPlaylistButton
        }
        .labelStyle(.iconOnly)
        .controlGroupStyle(.navigation)
    }

    private var backForwardButtons: some View {
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

    private var currentPageScrollOffset: Binding<CGFloat> {
        pageScrollOffset(for: shell.navigationHistory.currentEntryID)
    }

    private func pageScrollOffset(for entryID: Int) -> Binding<CGFloat> {
        Binding(
            get: { pageScrollOffsets.offset(for: entryID) },
            set: {
                pageScrollOffsets.setOffset($0, for: entryID)
            }
        )
    }

    private func requestSearchFocus() {
        shell.requestSearchFocus()
    }

    private func navigateBack() {
        shell.navigationHistory.goBack()
    }

    private func toggleSidebar() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { shell.toggleSidebar() }
    }

    private func toggleQueue() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { shell.toggleQueue() }
    }

    private func showAlbum(_ album: Release) {
        shell.navigationHistory.navigate(to: .album(album))
    }

    private func showExternalAlbum(_ release: ExternalReleaseGroup, artist: Artist) {
        shell.navigationHistory.navigate(to: .externalAlbum(release, artist))
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
        case .externalAlbum(let release, let artist):
            AlbumView(externalRelease: release, artist: artist, onSelectArtist: showArtist)
                .id(release.musicbrainzId)
        case .artist(let artist):
            ArtistView(
                artist: artist,
                onSelectAlbum: showAlbum,
                onSelectExternalRelease: { release in
                    showExternalAlbum(release, artist: artist)
                },
                onSelectArtist: showArtist
            )
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
            // The music page lives in contentColumn with a stable identity.
            Color.clear
        case .albums:
            AlbumsView(searchText: $albumSearchText, onSelectAlbum: showAlbum) { summary in
                albumsSummary = summary
            }
        case .artists:
            ArtistsView(searchText: $artistSearchText, onSelectArtist: showArtist) { summary in
                artistsSummary = summary
            }
        case .playlists:
            PlaylistsView(onSelectPlaylist: showPlaylist)
        case .history:
            HistoryView(searchText: $historySearchText) { summary in
                historySummary = summary
            }
        }
    }
}

// Let SwiftUI negotiate the toolbar width through sizeThatFits alone. Native
// width constraints on the embedded view would introduce a second sizing
// authority and can scale the hosting canvas when the toolbar compresses it.
private struct LibraryToolbarHost<Content: View>: NSViewRepresentable {
    let content: Content
    let minimumWidth: CGFloat
    let preferredWidth: CGFloat

    func makeNSView(context: Context) -> LibraryToolbarHostingView<Content> {
        LibraryToolbarHostingView(rootView: content)
    }

    func updateNSView(_ view: LibraryToolbarHostingView<Content>, context: Context) {
        view.hostingView.rootView = content
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LibraryToolbarHostingView<Content>, context: Context) -> CGSize? {
        let proposedWidth = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? preferredWidth
        return CGSize(width: max(minimumWidth, proposedWidth), height: 36)
    }
}

// Keep the representable's native sizing separate from SwiftUI's hosting
// canvas. Resizing the toolbar must relayout the canvas, not scale a cached
// rendering of its metadata and controls to fit a smaller native item.
private final class LibraryToolbarHostingView<Content: View>: NSView {
    let hostingView: NSHostingView<Content>

    init(rootView: Content) {
        hostingView = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        hostingView.sizingOptions = []
        hostingView.layerContentsRedrawPolicy = .duringViewResize
        addSubview(hostingView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 36)
    }

    override var preservesContentDuringLiveResize: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutHostedContent()
    }

    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        layoutHostedContent()
    }

    override func layout() {
        super.layout()
        layoutHostedContent()
    }

    private func layoutHostedContent() {
        // Update the canvas synchronously with the native item. Waiting for
        // the next layout pass leaves its previous width visible for a frame
        // precisely when the search changes between expanded and compact.
        if hostingView.frame != bounds { hostingView.frame = bounds }
        hostingView.layoutSubtreeIfNeeded()
    }
}

private struct LibraryToolbarMeasurement {
    let availableWidth: CGFloat
    let detailWidth: CGFloat
}

private struct LibraryToolbarWidthObserver: NSViewRepresentable {
    let trailingReservation: CGFloat
    let detailWidth: CGFloat
    let layoutKey: String
    @Binding var measurements: [String: LibraryToolbarMeasurement]

    func makeNSView(context: Context) -> WidthObserverView { WidthObserverView() }

    func updateNSView(_ view: WidthObserverView, context: Context) {
        view.trailingReservation = trailingReservation
        view.publish = { width in
            if let previous = measurements[layoutKey],
               abs(previous.availableWidth - width) <= 0.5,
               abs(previous.detailWidth - detailWidth) <= 0.5 { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                measurements[layoutKey] = LibraryToolbarMeasurement(
                    availableWidth: width, detailWidth: detailWidth)
            }
        }
        view.scheduleMeasurement()
    }

    final class WidthObserverView: NSView {
        var trailingReservation: CGFloat = 0
        var publish: ((CGFloat) -> Void)?
        private var isMeasurementScheduled = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if let window {
                NotificationCenter.default.addObserver(self, selector: #selector(windowResized),
                    name: NSWindow.didResizeNotification, object: window)
                NotificationCenter.default.addObserver(self, selector: #selector(windowResized),
                    name: NSWindow.didEndLiveResizeNotification, object: window)
            }
            scheduleMeasurement()
        }

        override func layout() {
            super.layout()
            scheduleMeasurement()
        }

        @objc private func windowResized() { scheduleMeasurement() }

        func scheduleMeasurement() {
            // Coalesce updates and read geometry after AppKit's layout pass.
            // This observer never changes constraints or native item priorities.
            guard !isMeasurementScheduled else { return }
            isMeasurementScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isMeasurementScheduled = false
                // During live resize, extrapolate the last settled measurement
                // from the content column instead of feeding every toolbar
                // layout pass back into its own preferred-width constraints.
                guard let window = self.window, !window.inLiveResize, self.bounds.width > 0,
                      let toolbar = window.toolbar,
                      let item = toolbar.items.first(where: { item in
                          guard let view = item.view else { return false }
                          return self.isDescendant(of: view)
                      }),
                      toolbar.visibleItems?.contains(where: { $0 === item }) == true
                else { return }
                let contentStart = self.convert(self.bounds, to: nil).minX
                let availableWidth = max(80, window.frame.width - contentStart - self.trailingReservation)
                self.publish?(availableWidth)
            }
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}

#Preview {
    ContentView()
        .environment(DurvaldCoreStore())
        .environment(TrackInfoCoordinator())
}
