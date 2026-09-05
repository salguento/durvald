import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(\.appearsActive) private var appearsActive

    @State private var navigationHistory = LibraryNavigationHistory()
    @State private var sidebarSection: SidebarSection = .navigation
    @State private var searchText = ""
    @State private var searchFocusRequest = 0
    @State private var isSearchFocused = false
    @State private var isQueuePresented = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var sidebarLayout = SidebarLayoutController()
    @State private var inspectorLayout = InspectorLayoutController()
    @State private var playlistCreation = PlaylistCreationCoordinator()

    private enum Layout {
        static let contentViewMinimumWidth: CGFloat = 360
        static let windowMinimumHeight: CGFloat = 360
        static let compactNavigationWidth: CGFloat = 700
        static let sidebarMinimumWidth: CGFloat = 180
        static let contentMinimumWidth: CGFloat = 360
        static let queueMinimumWidth: CGFloat = 260
        static let queueIdealWidth: CGFloat = 300
        static let queueMaximumWidth: CGFloat = 380
        static let playerMaximumWidth: CGFloat = 760
        static let playerHorizontalMargin: CGFloat = 16
        static let playerTopMargin: CGFloat = 12
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            LibrarySidebarView(
                section: $sidebarSection,
                destination: destinationBinding,
                selectedPlaylistID: selectedPlaylistID,
                onSelectAlbum: showAlbum,
                onSelectArtist: showArtist,
                onSelectPlaylist: showPlaylist
            )
            .navigationSplitViewColumnWidth(
                min: Layout.sidebarMinimumWidth,
                ideal: 240,
                max: 280
            )
            .background {
                SidebarSplitLayout(controller: sidebarLayout)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .toolbar(removing: .sidebarToggle)
            .toolbar {
                if columnVisibility != .detailOnly {
                    ToolbarItem(placement: .primaryAction) {
                        ControlGroup {
                            sidebarToggleButton
                            addPlaylistButton
                        }
                        .controlGroupStyle(.navigation)
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
            InspectorSplitLayout(controller: inspectorLayout)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .inspector(isPresented: $isQueuePresented) {
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
            guard width < Layout.compactNavigationWidth else { return }
            columnVisibility = .detailOnly
            isQueuePresented = false
        }
        .environment(playlistCreation)
        .focusedSceneValue(\.openLibrarySearch) {
            destinationBinding.wrappedValue = .search
        }
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
        .sheet(isPresented: Binding(
            get: { playlistCreation.isPresented },
            set: { playlistCreation.isPresented = $0 }
        )) {
            let editingPlaylist = playlistCreation.editingPlaylist.map { playlist in
                store.playlists.first(where: { $0.id == playlist.id }) ?? playlist
            }
            CreatePlaylistSheet(playlist: editingPlaylist) { title, description, artworkBase64 in
                if let editingPlaylist {
                    guard let updatedPlaylist = store.updatePlaylist(
                        id: editingPlaylist.id,
                        name: title,
                        description: description,
                        artworkBase64: artworkBase64
                    ) else { return false }
                    if case .playlist(let currentPlaylist) = navigationHistory.currentRoute,
                       currentPlaylist.id == updatedPlaylist.id {
                        navigationHistory.replaceCurrent(with: .playlist(updatedPlaylist))
                    }
                    return true
                }

                guard let playlist = store.createPlaylist(
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
        if columnVisibility == .detailOnly {
            ToolbarItem(placement: .navigation) {
                ControlGroup {
                    sidebarToggleButton
                    addPlaylistButton
                }
                .controlGroupStyle(.navigation)
            }
        }

        ToolbarItem(placement: .navigation) {
            ControlGroup {
                Button {
                    navigateBack()
                } label: {
                    Label("Voltar", systemImage: "chevron.left")
                }
                .disabled(
                    !navigationHistory.canGoBack
                )
                .keyboardShortcut(AppKeyboardShortcuts.goBack)
                .accessibilityIdentifier("navigation.back")

                Button {
                    navigationHistory.goForward()
                } label: {
                    Label("Avançar", systemImage: "chevron.right")
                }
                .disabled(
                    !navigationHistory.canGoForward
                )
                .keyboardShortcut(AppKeyboardShortcuts.goForward)
                .accessibilityIdentifier("navigation.forward")
            }
            .labelStyle(.iconOnly)
            .controlGroupStyle(.navigation)
        }

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
            .keyboardShortcut(AppKeyboardShortcuts.toggleQueue)
        }
    }

    private var sidebarToggleButton: some View {
        Button {
            columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
        } label: {
            Label(
                columnVisibility == .detailOnly
                    ? "Mostrar barra lateral"
                    : "Ocultar barra lateral",
                systemImage: "sidebar.leading"
            )
        }
        .labelStyle(.iconOnly)
        .help(
            columnVisibility == .detailOnly
                ? "Mostrar barra lateral"
                : "Ocultar barra lateral"
        )
        .accessibilityIdentifier("navigation.sidebar")
    }

    private var addPlaylistButton: some View {
        Button {
            playlistCreation.request(for: nil)
        } label: {
            Label("Adicionar", systemImage: "plus")
        }
        .labelStyle(.iconOnly)
        .help("Adicionar")
        .accessibilityIdentifier("library.addMenu")
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

    private var selectedPlaylistID: Int64? {
        guard case .playlist(let playlist) = navigationHistory.currentRoute else { return nil }
        return playlist.id
    }

    private func requestSearchFocus() {
        searchFocusRequest &+= 1
    }

    private func navigateBack() {
        navigationHistory.goBack()
    }

    private func toggleQueue() {
        // Configure the collapsed inspector before its first layout can grow
        // the window. A helper inside QueueView would only run after opening.
        inspectorLayout.configure()
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            isQueuePresented.toggle()
        }
    }

    private func showAlbum(_ album: Release) {
        navigationHistory.navigate(to: .album(album))
    }

    private func showArtist(_ artist: Artist) {
        navigationHistory.navigate(to: .artist(artist))
    }

    private func showPlaylist(_ playlist: Playlist) {
        navigationHistory.navigate(to: .playlist(playlist))
    }

    @ViewBuilder
    private var detail: some View {
        switch navigationHistory.currentRoute {
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
            LibrarySearchView(searchText: $searchText)
        case .home:
            HomeView { destination in
                navigationHistory.navigate(to: destination)
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

@MainActor
private final class SidebarLayoutController {
    weak var anchor: NSView?

    func configure() {
        guard let anchor else { return }
        var ancestor = anchor.superview

        while let view = ancestor {
            if let splitView = view as? NSSplitView,
               let controller = splitView.delegate as? NSSplitViewController,
               let sidebar = controller.splitViewItems.first(where: {
                   anchor.isDescendant(of: $0.viewController.view)
               }),
               sidebar.behavior != .inspector {
                sidebar.minimumThickness = 230
                return
            }
            ancestor = view.superview
        }
    }
}

private struct SidebarSplitLayout: NSViewRepresentable {
    let controller: SidebarLayoutController

    func makeNSView(context: Context) -> ConfigurationView {
        ConfigurationView(controller: controller)
    }

    func updateNSView(_ view: ConfigurationView, context: Context) {
        view.scheduleConfiguration()
    }

    final class ConfigurationView: NSView {
        private let controller: SidebarLayoutController
        private var configurationScheduled = false

        init(controller: SidebarLayoutController) {
            self.controller = controller
            super.init(frame: .zero)
            controller.anchor = self
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is unavailable")
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            scheduleConfiguration()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleConfiguration()
        }

        override func layout() {
            super.layout()
            scheduleConfiguration()
        }

        func scheduleConfiguration() {
            guard !configurationScheduled else { return }
            configurationScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.configurationScheduled = false
                self.controller.anchor = self
                self.controller.configure()
            }
        }
    }
}

/// Configure the outer split from its always-present content, even while the
/// inspector is collapsed. Keep the nested navigation sidebar's glass unchanged.
@MainActor
private final class InspectorLayoutController {
    weak var anchor: NSView?

    func configure() {
        guard let anchor else { return }
        anchor.window?.titlebarSeparatorStyle = .none
        var ancestor = anchor.superview

        while let view = ancestor {
            if let splitView = view as? NSSplitView,
               let controller = splitView.delegate as? NSSplitViewController,
               let inspector = controller.splitViewItems.first(where: { $0.behavior == .inspector }),
               let content = controller.splitViewItems.first(where: {
                   $0 !== inspector && anchor.isDescendant(of: $0.viewController.view)
               }) {
                // Avoid counting the queue's safe area twice through nested splits.
                if content.automaticallyAdjustsSafeAreaInsets {
                    content.automaticallyAdjustsSafeAreaInsets = false
                }
                if inspector.collapseBehavior != .preferResizingSiblingsWithFixedSplitView {
                    inspector.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
                }
                return
            }
            ancestor = view.superview
        }
    }
}

private struct InspectorSplitLayout: NSViewRepresentable {
    let controller: InspectorLayoutController

    func makeNSView(context: Context) -> ConfigurationView {
        ConfigurationView(controller: controller)
    }

    func updateNSView(_ view: ConfigurationView, context: Context) {
        view.scheduleConfiguration()
    }

    final class ConfigurationView: NSView {
        private let controller: InspectorLayoutController
        private var configurationScheduled = false

        init(controller: InspectorLayoutController) {
            self.controller = controller
            super.init(frame: .zero)
            controller.anchor = self
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is unavailable")
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            scheduleConfiguration()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleConfiguration()
        }

        override func layout() {
            super.layout()
            scheduleConfiguration()
        }

        func scheduleConfiguration() {
            guard !configurationScheduled else { return }
            configurationScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.configurationScheduled = false
                self.controller.anchor = self
                self.controller.configure()
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(DurvaldCoreStore())
}
