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
    @AppStorage("albums.minimumRating.halfSteps") private var albumMinimumRating = 0

    @AppStorage(RecentSearchHistory.storageKey) private var recentSearchesJSON = "[]"
    @State private var playlistsSearchText = ""
    @State private var playlistsSummary = "Carregando…"
    @State private var playlistsToolbarState = PlaylistsToolbarState()
    @State private var albumSearchText = ""
    @State private var albumsSummary = "Carregando…"
    @State private var artistSearchText = ""
    @State private var artistsSummary = "Carregando…"
    @State private var retrospectiveSearchText = ""
    @State private var retrospectiveSummary = "Carregando…"
    @State private var artistToolbarBackground: Visibility = .hidden
    @State private var isContentScrolled = false
    @State private var isContentTopbarHovered = false
    @State private var artistToolbarState = ArtistToolbarState()
    @State private var playlistToolbarState = PlaylistToolbarState()
    @State private var albumToolbarState = AlbumToolbarState()
    @State private var musicEntryID: Int?
    @State private var musicPresentation = MusicLibraryPresentation()
    @State private var musicSearchText = ""
    @State private var contentColumnWidth: CGFloat = 0
    @State private var fullDetailColumnWidth: CGFloat = 0
    @State private var toolbarAvailableWidth: CGFloat?
    @State private var isLibrarySearchExpanded = false
    @State private var musicLibrarySummary = MusicLibrarySummary(tracks: [], kind: .all)
    @State private var shell = ContentShellState()
    @State private var commandKeyboard = CommandKeyboardState()
    @State private var isShortcutHelpPresented = false
    @State private var isCommandClearQueuePresented = false
    @State private var shortcutHelpAvailability = Set<AppCommandID>()
    @State private var pageFilterFocusRequest = 0
    @FocusedValue(\.protectsBareCommandKeys) private var protectsBareCommandKeys
    @FocusedValue(\.selectionCommands) private var commandSelection
    @FocusedValue(\.pageCommands) private var commandPage
    @State private var globalSearch = SearchPresentation<SearchResults>()
    @State private var searchPreview = SearchPresentation<SearchResults>()
    @State private var windowLayout = WindowSplitLayoutCoordinator()
    @State private var playlistCreation = PlaylistCreationCoordinator()
    // Scroll geometry can change on every rendered frame. Keeping these values
    // in a reference store avoids invalidating the entire content column while
    // still preserving an independent position for every navigation entry.
    @State private var pageScrollOffsets = LibraryScrollOffsetStore()

    private enum Layout {
        static let librarySummaryLeadingPadding: CGFloat = 4
        static let panelToggleIconWidth: CGFloat = 20
        static let panelToggleIconHeight: CGFloat = 16
        static let contentViewMinimumWidth: CGFloat = 360
        static let windowMinimumHeight: CGFloat = 360
        static let compactNavigationWidth: CGFloat = 700
        static let contentMinimumWidth = WindowSplitLayoutPolicy.contentMinimumWidth
        static let queueMinimumWidth: CGFloat = 260
        static let queueIdealWidth = PageChromePolicy.queueWidth
        static let queueMaximumWidth: CGFloat = 380
        static let queueToggleWidth = PageChromePolicy.queueToggleWidth
        static let playerHorizontalMargin: CGFloat = 32
        static let playerTopMargin: CGFloat = 12
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $shell.columnVisibility) {
            LibrarySidebarView(
                section: $shell.sidebarSection,
                destination: destinationBinding,
                playlistsToolbarState: playlistsToolbarState,
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
                        sidebarToggleButton
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
        .toolbarBackgroundVisibility(
            contentToolbarBackgroundVisibility,
            for: .windowToolbar
        )
        .onPreferenceChange(PageToolbarBackgroundPreferenceKey.self) { visibility in
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { artistToolbarBackground = visibility ?? .hidden }
        }
        .overlay(alignment: .trailing) {
            if shell.isQueuePresented {
                GeometryReader { geometry in
                    NativeSidebarPane {
                        QueueView(topInset: geometry.safeAreaInsets.top)
                    }
                    .ignoresSafeArea(edges: .top)
                }
                .frame(width: Layout.queueIdealWidth)
                .frame(maxHeight: .infinity)
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
        .modifier(PlaylistsCreationPresentation(state: playlistsToolbarState))
        .environment(playlistCreation)
        .environment(\.trackMenuNavigation, trackMenuNavigation)
        .onAppear {
            trackInfo.presentWindow = {
                openWindow(id: "track-info")
            }
        }
        .focusedSceneValue(\.windowCommands, windowCommandTarget)
        .focusedSceneValue(\.commandKeyboardState, commandKeyboard)
        .environment(\.pageFilterFocusRequest, pageFilterFocusRequest)
        .background { CommandKeyboardBridge(state: commandKeyboard, perform: performKeyboardCommand).frame(width: 0, height: 0) }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(keys: [.space, .return, .delete], phases: .down) { press in
            guard press.modifiers.isEmpty else { return .ignored }
            let id: AppCommandID = press.key == .space ? .playPause : press.key == .return ? .playSelection : .removeQueueItem
            return performKeyboardCommand(id) ? .handled : .ignored
        }
        .alert("Limpar a fila?", isPresented: $isCommandClearQueuePresented) {
            Button("Cancelar", role: .cancel) {}
            Button("Limpar fila", role: .destructive) { Task { await store.clearQueue() } }
        }
        .sheet(isPresented: $isShortcutHelpPresented) { KeyboardShortcutsHelp(available: shortcutHelpAvailability) }
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
                isContentScrolled = PageChromePolicy.isScrolled(offset: pageScrollOffsets.offset(for: entryID))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if pageChrome.kind == .standard && pageChrome.observesHover {
                    TopbarHoverObserver(isHovered: $isContentTopbarHovered)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                if pageChrome.usesPageBackdrop && !pageChrome.hasSupplementaryHeader {
                    PageTopbarBackground(isVisible: pageChrome.backdropVisible)
                        .ignoresSafeArea(.container, edges: .top)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentColumnWidth = $0 }
            .safeAreaInset(edge: .trailing, spacing: 0) {
                if shell.isQueuePresented {
                    Color.clear
                        .frame(width: Layout.queueIdealWidth)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { fullDetailColumnWidth = $0 }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                PlayerBar(onSelectAlbum: showAlbum, onSelectArtist: showArtist)
                    .padding(.horizontal, Layout.playerHorizontalMargin)
                    .padding(.trailing, pageChrome.queueReservation)
                    .padding(.top, Layout.playerTopMargin)
                    .padding(.bottom, 20)
                    .frame(maxWidth: .infinity)
            }
            // Keep the toolbar and its scroll views in the same split column.
            // macOS owns the backdrop and its transition as content scrolls
            // behind the controls, including when the side panels resize.
            .toolbar { contentToolbar }
            .onChange(of: shell.columnVisibility) { _, _ in
                toolbarAvailableWidth = nil
            }
            .onChange(of: fullDetailColumnWidth) { _, _ in
                toolbarAvailableWidth = nil
            }
            .onChange(of: shell.navigationHistory.currentRoute) { _, _ in
                isLibrarySearchExpanded = false
                if isAlbumDetail {
                    albumToolbarState.searchText = ""
                    albumToolbarState.order = .album
                    albumToolbarState.minimumTrackRating = 0
                }
                if isPlaylistDetail {
                    playlistToolbarState.searchText = ""
                    playlistToolbarState.order = .playlist
                    playlistToolbarState.isEditingSmartPlaylist = false
                    playlistToolbarState.exportRelativePaths = nil
                }
                if isArtistDetail {
                    artistToolbarState.searchText = ""
                    artistToolbarState.order = .album
                }
            }
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
    }

    @ToolbarContentBuilder
    private var contentToolbar: some ToolbarContent {
        navigationToolbar
        // Keep one native item across navigation. Page-specific controls and the
        // queue toggle share a canvas, so their spacing cannot drift independently.
        // Native navigation spacing (8 pt) plus the summary's inset (4 pt)
        // keeps both text lines exactly 12 pt after the back/forward group.
        ToolbarItem(id: "page-content-controls", placement: .navigation) {
            pageContentToolbar
        }
        .sharedBackgroundVisibility(.hidden)
    }

    private var isPlaylistsListing: Bool {
        shell.navigationHistory.currentRoute == .section(.playlists)
    }

    private var hasLibrarySearch: Bool {
        if isArtistDetail || isPlaylistDetail || isAlbumDetail { return true }
        guard case .section(let destination) = shell.navigationHistory.currentRoute else { return false }
        return destination == .albums || destination == .songs || destination == .artists || destination == .retrospective || destination == .playlists
    }

    private var trackMenuNavigation: TrackMenuNavigation {
        TrackMenuNavigation(artist: showArtist, album: showAlbum, playlist: showPlaylist,
            deletedPlaylist: { id in
                if case .playlist(let playlist) = shell.navigationHistory.currentRoute, playlist.id == id {
                    shell.navigationHistory.navigate(to: .playlists)
                }
            })
    }

    private var isAlbumDetail: Bool {
        if case .album = shell.navigationHistory.currentRoute { return true }
        return false
    }

    private var toolbarAlbum: Release? {
        guard case .album(let album) = shell.navigationHistory.currentRoute else { return nil }
        return store.loadedRelease(id: album.id) ?? album
    }

    private var isPlaylistDetail: Bool {
        if case .playlist = shell.navigationHistory.currentRoute { return true }
        return false
    }

    private var toolbarPlaylist: Playlist? {
        guard case .playlist(let playlist) = shell.navigationHistory.currentRoute else { return nil }
        return store.playlists.first(where: { $0.id == playlist.id }) ?? playlist
    }

    private var isArtistDetail: Bool {
        if case .artist = shell.navigationHistory.currentRoute { return true }
        return false
    }

    private var librarySummaryText: String {
        switch shell.navigationHistory.current {
        case .search:
            SummaryPresentation.search(results: globalSearch.value, query: shell.submittedSearchText,
                isPending: globalSearch.isPending || globalSearch.committedQuery != shell.submittedSearchText)
        case .songs: musicLibrarySummary.text
        case .artists: artistsSummary
        case .playlists: playlistsSummary
        case .retrospective: retrospectiveSummary
        default: albumsSummary
        }
    }

    private var librarySearchText: Binding<String> {
        switch shell.navigationHistory.current {
        case .songs: $musicSearchText
        case .artists: $artistSearchText
        case .playlists: $playlistsSearchText
        case .retrospective: $retrospectiveSearchText
        default: $albumSearchText
        }
    }

    private var librarySearchPlaceholder: String {
        switch shell.navigationHistory.current {
        case .songs: "Pesquisar músicas"
        case .artists: "Pesquisar artistas"
        case .playlists: "Pesquisar playlists"
        case .retrospective: "Pesquisar na retrospectiva"
        default: "Pesquisar álbuns"
        }
    }

    private var librarySearchIdentifier: String {
        switch shell.navigationHistory.current {
        case .songs: "library.search"
        case .artists: "artists.search"
        case .playlists: "playlists.search"
        case .retrospective: "retrospective.search"
        default: "albums.search"
        }
    }

    private var libraryToolbarDetailWidth: CGFloat {
        PageViewport.column(visibleWidth: contentColumnWidth,
            measuredFullWidth: fullDetailColumnWidth,
            trailingReservation: pageChrome.queueReservation).fullWidth
    }

    private var libraryExpandedControlsMinimumWidth: CGFloat {
        if isArtistDetail || isPlaylistDetail || isAlbumDetail { return 308 }
        // Result counts change while typing; they must not switch the search
        // between compact and expanded presentation.
        return 120 + 220 + 44 + (isPlaylistsListing ? 44 : 0) + 8 + Layout.librarySummaryLeadingPadding
    }

    private var pageContentToolbar: some View {
        let detailWidth = libraryToolbarDetailWidth
        let layout = PageToolbarLayout(kind: pageChrome.kind,
                                       additionalMenuCount: isPlaylistDetail || isAlbumDetail || isPlaylistsListing ? 1 : 0,
                                       queuePresented: shell.isQueuePresented,
                                       expandedMinimumWidth: libraryExpandedControlsMinimumWidth,
                                       summaryLeadingPadding: Layout.librarySummaryLeadingPadding)
        let toggleReservation = Layout.queueToggleWidth + ToolbarControlMetrics.spacing
        let panelReservation = layout.panelReservation
        let hasSearch = shell.navigationHistory.current == .home || shell.navigationHistory.current == .search
        // The panel reservation is drawing space, not a native minimum width.
        // Counting it as a minimum can push navigation into toolbar overflow,
        // which inserts an extra trailing button and moves the queue toggle.
        let controlsMinimum: CGFloat = hasLibrarySearch ? layout.minimumWidth - panelReservation
            : (hasSearch ? 36 : 0)
        let minimumWidth = controlsMinimum + toggleReservation
        let preferredWidth = max(minimumWidth, toolbarAvailableWidth
            ?? (layout.preferredWidth(detailWidth: detailWidth,
                sidebarVisible: shell.columnVisibility != .detailOnly) + toggleReservation))

        let content = GeometryReader { toolbarGeometry in
            HStack(spacing: ToolbarControlMetrics.spacing) {
                GeometryReader { geometry in
                    let controls = layout.controls(assignedWidth: geometry.size.width,
                                                   searchExpanded: isLibrarySearchExpanded)
                    ZStack(alignment: .trailing) {
                        if hasLibrarySearch {
                            if !isArtistDetail && !isPlaylistDetail && !isAlbumDetail {
                                libraryToolbarSummary
                                    .fixedSize(horizontal: false, vertical: true)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(width: controls.summaryWidth, alignment: .leading)
                                    .clipped()
                                    .padding(.leading, Layout.librarySummaryLeadingPadding)
                                    .frame(width: geometry.size.width, alignment: .leading)
                            }
                            libraryTopbarControls(searchWidth: controls.searchWidth,
                                                  prefersCompact: controls.compact)
                                .padding(.trailing, panelReservation)
                        } else if hasSearch {
                            let showsSummary = shell.navigationHistory.current == .search
                            let availableWidth = max(0, geometry.size.width - panelReservation)
                            let summaryReservation: CGFloat = showsSummary
                                ? 120 + ToolbarControlMetrics.spacing + Layout.librarySummaryLeadingPadding : 0
                            let searchWidth = min(ToolbarControlMetrics.searchWidth, max(36, availableWidth - summaryReservation))
                            if showsSummary {
                                libraryToolbarSummary
                                    .fixedSize(horizontal: false, vertical: true)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(width: max(0, availableWidth - searchWidth - 8 - Layout.librarySummaryLeadingPadding),
                                           alignment: .leading)
                                    .clipped()
                                    .padding(.leading, Layout.librarySummaryLeadingPadding)
                                    .frame(width: geometry.size.width, alignment: .leading)
                            }
                            GlobalSearchField(
                                text: $shell.searchText, isFocused: $shell.isSearchFocused,
                                focusRequest: $shell.searchFocusRequest, search: searchPreview,
                                isExecutingSearch: globalSearch.isPending,
                                recentQueries: RecentSearchHistory.terms(in: recentSearchesJSON),
                                onSubmit: submitGlobalSearch,
                                navigation: TrackMenuNavigation(artist: showArtist, album: showAlbum,
                                                               playlist: showPlaylist)
                            )
                            .frame(width: searchWidth, height: ToolbarControlMetrics.size)
                            .padding(.trailing, panelReservation)
                        }
                    }
                    .frame(width: geometry.size.width, height: ToolbarControlMetrics.size,
                           alignment: .trailing)
                }
                queueToggleButton
            }
            .frame(width: toolbarGeometry.size.width, height: ToolbarControlMetrics.size)
        }
        .environment(\.appearsActive, appearsActive)
        .environment(store)
        .environment(playlistCreation)
        .environment(\.trackMenuNavigation, trackMenuNavigation)
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }

        return LibraryToolbarHost(content: content, minimumWidth: minimumWidth,
                                  preferredWidth: preferredWidth)
        .frame(minWidth: minimumWidth, maxWidth: preferredWidth,
               minHeight: ToolbarControlMetrics.size, maxHeight: ToolbarControlMetrics.size)
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
            LibrarySummaryView(
                title: shell.navigationHistory.current.title,
                text: librarySummaryText,
                identifier: "\(shell.navigationHistory.current.rawValue).summary"
            )
        }
    }

    @ViewBuilder
    private func libraryTopbarControls(searchWidth: CGFloat, prefersCompact: Bool) -> some View {
        if isArtistDetail {
            ArtistDetailToolbarControls(
                state: artistToolbarState,
                searchWidth: searchWidth,
                prefersCompact: prefersCompact,
                isSearchExpanded: $isLibrarySearchExpanded
            )
            .fixedSize()
        } else if let album = toolbarAlbum {
            AlbumDetailToolbarControls(
                album: album, state: albumToolbarState,
                searchWidth: searchWidth, prefersCompact: prefersCompact,
                isSearchExpanded: $isLibrarySearchExpanded
            )
            .fixedSize()
        } else if let playlist = toolbarPlaylist {
            PlaylistDetailToolbarControls(
                playlist: playlist, state: playlistToolbarState,
                searchWidth: searchWidth, prefersCompact: prefersCompact,
                isSearchExpanded: $isLibrarySearchExpanded
            )
            .fixedSize()
        } else {
            HStack(spacing: ToolbarControlMetrics.spacing) {
                if isPlaylistsListing {
                    PlaylistsCreationMenu(state: playlistsToolbarState)
                }
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
                } else if shell.navigationHistory.current == .retrospective {
                    RetrospectiveToolbarOptionsMenu()
                } else if isPlaylistsListing {
                    collectionOptions(for: .playlists)
                } else {
                    collectionOptions(for: shell.navigationHistory.current == .artists ? .artists : .albums)
                }
            }
            .fixedSize()
            .id(shell.navigationHistory.current)
        }
    }

    private func collectionOptions(for destination: LibraryDestination) -> some View {
        CollectionListingMenu(
            mode: listingModeBinding(for: destination),
            order: listingOrderBinding(for: destination),
            minimumRating: destination == .albums ? $albumMinimumRating : nil,
            onlyLocal: destination == .artists ? $artistOnlyLocal : nil,
            controlSize: ToolbarControlMetrics.size, controlWidth: ToolbarControlMetrics.size, usesGlassEffect: true
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
                sidebarToggleButton
            }
            .visibilityPriority(.high)
            ToolbarSpacer(.fixed, placement: .navigation)

            ToolbarItem(id: "navigation-home", placement: .navigation) {
                homeToolbarButton
            }
            .sharedBackgroundVisibility(.hidden)
            .visibilityPriority(.high)
        }

        ToolbarSpacer(.fixed, placement: .navigation)

        // Keep navigation ahead of the flexible page canvas when AppKit
        // resolves toolbar widths, including before its first measurement.
        ToolbarItem(id: "navigation-history", placement: .navigation) {
            backForwardButtons
        }
        .visibilityPriority(.high)

    }

    private var queueToggleButton: some View {
        Button {
            toggleQueue()
        } label: {
            Label {
                Text(queueToggleTitle)
            } icon: {
                Image(systemName: "sidebar.trailing")
                    .resizable()
                    .scaledToFit()
                    .frame(width: Layout.panelToggleIconWidth, height: Layout.panelToggleIconHeight)
            }
            .labelStyle(.iconOnly)
            .foregroundStyle(appearsActive ? Color.primary : Color.secondary)
            .frame(width: Layout.queueToggleWidth, height: 36)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(width: Layout.queueToggleWidth, height: 36)
        .glassEffect(.regular.interactive(), in: .capsule)
        .help(queueToggleTitle)
        .accessibilityHint("Mostra ou oculta a fila lateral de reprodução")
        .accessibilityLabel(queueToggleTitle)
        .accessibilityIdentifier("player.queue")
    }

    private var queueToggleTitle: String {
        shell.isQueuePresented ? "Ocultar fila" : "Mostrar fila"
    }

    private var sidebarToggleButton: some View {
        Button {
            toggleSidebar()
        } label: {
            Label {
                Text(sidebarToggleTitle)
            } icon: {
                Image(systemName: "sidebar.leading")
                    .resizable()
                    .scaledToFit()
                    .frame(width: Layout.panelToggleIconWidth, height: Layout.panelToggleIconHeight)
            }
            .labelStyle(.iconOnly)
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

    private var backForwardButtons: some View {
        ControlGroup {
            Button {
                navigateBack()
            } label: {
                Label("Voltar", systemImage: "chevron.left")
            }
            .disabled(!shell.navigationHistory.canGoBack)
            .accessibilityIdentifier("navigation.back")

            Button {
                shell.navigationHistory.goForward()
            } label: {
                Label("Avançar", systemImage: "chevron.right")
            }
            .disabled(!shell.navigationHistory.canGoForward)
            .accessibilityIdentifier("navigation.forward")
        }
        .labelStyle(.iconOnly)
        .controlGroupStyle(.navigation)
        .accessibilityIdentifier("navigation.history")
        .background {
            ToolbarNavigationWidthObserver { width in
                guard abs((toolbarAvailableWidth ?? 0) - width) > 0.5 else { return }
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { toolbarAvailableWidth = width }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private var homeToolbarButton: some View {
        Button {
            shell.navigationHistory.navigate(to: .home)
        } label: {
            Label("Início", systemImage: "house")
                .labelStyle(.iconOnly)
                .frame(width: ToolbarControlMetrics.size, height: ToolbarControlMetrics.size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .help("Ir para o início")
        .accessibilityLabel("Início")
        .accessibilityIdentifier("navigation.home")
    }

    private var destinationBinding: Binding<LibraryDestination?> {
        Binding(
            get: { shell.navigationHistory.current },
            set: { destination in
                guard let destination else { return }
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

    private var pageChrome: PageChromePolicy {
        PageChromePolicy(kind: isArtistDetail ? .artist : .standard,
                         queuePresented: shell.isQueuePresented,
                         scrolled: isContentScrolled, hovered: isContentTopbarHovered,
                         hasSupplementaryHeader: shell.navigationHistory.current == .retrospective)
    }

    private var contentToolbarBackgroundVisibility: Visibility {
        return isArtistDetail ? artistToolbarBackground : pageChrome.toolbarVisibility
    }

    private func pageScrollOffset(for entryID: Int) -> Binding<CGFloat> {
        Binding(
            get: { pageScrollOffsets.offset(for: entryID) },
            set: {
                pageScrollOffsets.setOffset($0, for: entryID)
                guard entryID == shell.navigationHistory.currentEntryID else { return }
                let scrolled = PageChromePolicy.isScrolled(offset: $0)
                if isContentScrolled != scrolled { isContentScrolled = scrolled }
            }
        )
    }

    private func submitGlobalSearch() {
        guard !shell.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        recentSearchesJSON = RecentSearchHistory.record(shell.searchText, in: recentSearchesJSON)
        shell.submitSearch()
    }

    private func performKeyboardCommand(_ id: AppCommandID) -> Bool {
        commandKeyboard.update()
        if id.isBareKey && (protectsBareCommandKeys == true || commandKeyboard.window?.firstResponder is NSControl && !(commandKeyboard.window?.firstResponder is NSTableView)) { return false }
        guard let action = AppCommandDispatch.action(id, window: windowCommandTarget, page: commandPage,
            selection: commandSelection, isMain: commandKeyboard.isMainContext, editing: commandKeyboard.isEditing) else { return false }
        action()
        return true
    }

    private var windowCommandTarget: AppCommandTarget {
        var actions: [AppCommandID: () -> Void] = [
            .search: requestSearchFocus, .sidebar: toggleSidebar, .queue: toggleQueue,
            .home: { shell.navigationHistory.navigate(to: .home) },
            .songs: { shell.navigationHistory.navigate(to: .songs) },
            .albums: { shell.navigationHistory.navigate(to: .albums) },
            .artists: { shell.navigationHistory.navigate(to: .artists) },
            .playlists: { shell.navigationHistory.navigate(to: .playlists) },
            .retrospective: { shell.navigationHistory.navigate(to: .retrospective) },
            .newPlaylist: { playlistCreation.request(for: nil) },
            .newSmartPlaylist: { playlistsToolbarState.isShowingSmartPlaylist = true },
            .help: {
                shortcutHelpAvailability = Set(AppCommandID.allCases.filter {
                    AppCommandDispatch.action($0, window: self.windowCommandTarget, page: commandPage,
                        selection: commandSelection, isMain: commandKeyboard.isMainContext, editing: commandKeyboard.isEditing) != nil
                })
                isShortcutHelpPresented = true
            }
        ]
        if shell.navigationHistory.canGoBack { actions[.back] = navigateBack }
        if shell.navigationHistory.canGoForward { actions[.forward] = { shell.navigationHistory.goForward() } }
        if hasLibrarySearch { actions[.filter] = { pageFilterFocusRequest += 1 } }
        if !playlistsToolbarState.isImporting { actions[.importPlaylist] = { playlistsToolbarState.isChoosingImport = true } }
        if shell.navigationHistory.current == .songs { actions[.viewOptions] = { openWindow(id: "music-view-options") } }
        if !store.queue.isEmpty { actions[.clearQueue] = { isCommandClearQueuePresented = true } }
        if store.core != nil {
            actions[.volumeUp] = { store.adjustVolume(by: 0.05) }
            actions[.volumeDown] = { store.adjustVolume(by: -0.05) }
            actions[.mute] = { store.toggleMute() }
            if !store.isScanningLibrary {
                actions[.addFolder] = {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
                    guard let window = commandKeyboard.window else { return }
                    panel.beginSheetModal(for: window) { result in
                        if result == .OK, let url = panel.url { store.addAndScanLibraryFolder(url) }
                    }
                }
                if !store.libraryPaths.isEmpty { actions[.updateLibrary] = { store.updateLibrary() } }
            } else { actions[.cancelScan] = { store.cancelScan() } }
        }
        if store.activeTrackID != nil, !store.isChangingTrack {
            actions[.playPause] = { Task { await store.togglePause() } }
            actions[.next] = { Task { await store.next() } }
            actions[.previous] = { Task { await store.previous() } }
            actions[.shuffle] = { Task { await store.toggleShuffle() } }
            actions[.repeatMode] = { Task { await store.cycleRepeatMode() } }
            actions[.seekBack] = { store.seek(to: max(0, (store.playback?.positionSeconds ?? 0) - 5)) }
            actions[.seekForward] = { store.seek(to: min(store.playback?.durationSeconds ?? .infinity, (store.playback?.positionSeconds ?? 0) + 5)) }
            actions[.playingAlbum] = {
                guard let track = store.playback?.currentTrack else { return }
                Task { if let album = try? await store.core?.release(releaseId: track.releaseId) { showAlbum(album) } }
            }
            actions[.playingArtist] = {
                guard let track = store.playback?.currentTrack else { return }
                Task { if let artist = try? await store.core?.artist(artistId: track.artistId) { showArtist(artist) } }
            }
        }
        return AppCommandTarget(actions: actions)
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
            AlbumView(album: album, toolbarState: albumToolbarState, onSelectArtist: showArtist)
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
                onSelectArtist: showArtist,
                toolbarState: artistToolbarState
            )
                .id(artist.id)
        case .playlist(let playlist):
            PlaylistView(playlist: playlist, toolbarState: playlistToolbarState)
                .id(playlist.id)
        case .retrospectivePlaylist(let draft):
            if let saved = store.savedRetrospectivePlaylist(for: draft) {
                PlaylistView(playlist: saved, toolbarState: playlistToolbarState)
                    .id(saved.id)
            } else {
                RetrospectivePlaylistView(draft: draft) { playlist in
                    shell.navigationHistory.replace(.retrospectivePlaylist(draft), with: .playlist(playlist))
                }
                .id(draft.identity)
            }
        case .section(let destination):
            sectionContent(destination)
        }
    }

    @ViewBuilder
    private func sectionContent(_ destination: LibraryDestination) -> some View {
        switch destination {
        case .search:
            LibrarySearchView(searchText: $shell.submittedSearchText, search: globalSearch,
                              submissionRevision: shell.searchSubmissionRevision)
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
            PlaylistsView(searchText: $playlistsSearchText,
                          onSelectPlaylist: showPlaylist) { summary in
                playlistsSummary = summary
            }
        case .retrospective:
            RetrospectiveView(searchText: $retrospectiveSearchText, onOpenPlaylist: { draft in
                if let saved = store.savedRetrospectivePlaylist(for: draft) {
                    shell.navigationHistory.navigate(to: .playlist(saved))
                } else {
                    shell.navigationHistory.navigate(to: .retrospectivePlaylist(draft))
                }
            }) { summary in
                retrospectiveSummary = summary
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
        CGSize(width: PageToolbarLayout.fittingWidth(proposal.width, minimum: minimumWidth,
                                                    preferred: preferredWidth), height: 36)
    }
}

// Keep the representable's native sizing separate from SwiftUI's hosting
// canvas. Resizing the toolbar must relayout the canvas, not scale a cached
// rendering of its metadata and controls to fit a smaller native item.
final class LibraryToolbarHostingView<Content: View>: NSView {
    let hostingView: NSHostingView<Content>

    convenience init(rootView: Content) {
        self.init(hostingView: NSHostingView(rootView: rootView))
    }

    init(hostingView: NSHostingView<Content>) {
        self.hostingView = hostingView
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
        // Frame/bounds setters and layout can describe the same geometry.
        // Only force an extra subtree pass when the hosting canvas changes;
        // AppKit still lays out dirty content normally at an unchanged size.
        guard hostingView.frame != bounds else { return }
        // Update the canvas synchronously with the native item. Waiting for
        // the next layout pass leaves its previous width visible for a frame
        // precisely when the search changes between expanded and compact.
        hostingView.frame = bounds
        hostingView.layoutSubtreeIfNeeded()
    }
}


// Measure from the independent navigation group, never from the flexible
// toolbar canvas itself. Its leading gap and the trailing window inset are 8 pt.
private struct ToolbarNavigationWidthObserver: NSViewRepresentable {
    let publish: (CGFloat) -> Void

    func makeNSView(context: Context) -> ObserverView { ObserverView() }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.publish = publish
        view.scheduleMeasurement()
    }

    final class ObserverView: NSView {
        var publish: ((CGFloat) -> Void)?
        private var scheduled = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if let window {
                NotificationCenter.default.addObserver(self, selector: #selector(windowUpdated),
                    name: NSWindow.didUpdateNotification, object: window)
            }
            scheduleMeasurement()
        }

        override func layout() {
            super.layout()
            scheduleMeasurement()
        }

        @objc private func windowUpdated() { scheduleMeasurement() }

        func scheduleMeasurement() {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                guard let window = self.window, !self.isHiddenOrHasHiddenAncestor,
                      self.bounds.width > 0 else { return }
                let navigationEnd = self.convert(self.bounds, to: nil).maxX
                self.publish?(max(0, window.frame.width - navigationEnd - 16))
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
