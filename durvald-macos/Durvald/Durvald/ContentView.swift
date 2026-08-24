import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: DurvaldCoreStore

    @State private var navigationHistory = LibraryNavigationHistory()
    @State private var sidebarSection: SidebarSection = .navigation
    @State private var searchText = ""
    @State private var isQueuePresented = false

    var body: some View {
        NavigationSplitView {
            LibrarySidebarView(
                section: $sidebarSection,
                searchText: $searchText,
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
                Text(navigationHistory.current.title)
                    .font(.headline)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .scrollEdgeEffectStyle(.soft, for: .top)
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
                navigationHistory.navigate(to: destination)
            }
        )
    }

    @ViewBuilder
    private var detail: some View {
        switch navigationHistory.current {
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
