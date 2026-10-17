import SwiftUI
import UniformTypeIdentifiers

@Observable
final class PlaylistsToolbarState {
    var isChoosingImport = false
    var isImporting = false
    var isShowingSmartPlaylist = false
}

struct PlaylistsView: View {
    @Binding var searchText: String
    @Environment(PlaylistCreationCoordinator.self) private var playlistCreation
    @Environment(DurvaldCoreStore.self) private var store
    @AppStorage("playlists.listingMode") private var listingMode: CollectionListingMode = .standard
    @AppStorage("playlists.listingOrder") private var listingOrder: CollectionListingOrder = .recent
    @AppStorage(RatingPreferences.enabledKey) private var ratingsEnabled = true
    @State private var tracksByPlaylist: [Int64: [Track]] = [:]
    @State private var orderingRevision: UInt64 = 0
    @State private var presentation = PreparedLibraryListing(PlaylistListingSnapshot())
    let onSelectPlaylist: (Playlist) -> Void
    var onSummaryChange: (String) -> Void = { _ in }

    var body: some View {
        CollectionListingLayout(mode: listingMode) { size in
            ForEach(presentation.value.items, id: \.id) { playlist in
                CollectionListingItem(title: playlist.name, mode: listingMode, artworkSize: size, action: { onSelectPlaylist(playlist) }) {
                    PlaylistArtworkThumbnail(playlistID: playlist.id, artworkBase64: playlist.artworkId, size: size)
                }
                .playlistContextMenu(playlist: playlist)
                .playlistTrackDropTarget(playlist)
                .accessibilityIdentifier("playlist.\(playlist.id)")
            }
        }
        .contentShape(Rectangle())
        .onDrop(of: [LibraryTrackDrag.type], isTargeted: nil) { providers in
            LibraryTrackDrag.accept(providers) { playlistCreation.requestTracks($0) }
        }
        .overlay {
            if !normalizedSearchText.isEmpty && presentation.value.items.isEmpty && !presentation.isPreparing {
                ContentUnavailableView("Nenhuma playlist encontrada", systemImage: "magnifyingglass")
            }
        }
        .task(id: orderingTaskID) {
            await loadOrderingTracksIfNeeded()
        }
        .task(id: preparationKey) {
            let key = preparationKey
            let playlists = store.playlists
            let tracks = tracksByPlaylist
            let releases = store.releases
            await presentation.prepare(key: key, payload: (playlists, tracks, releases)) { payload in
                PlaylistListingSnapshot.build(playlists: payload.0, tracksByPlaylist: payload.1,
                                              releases: payload.2, key: key)
            }
            guard !Task.isCancelled else { return }
            onSummaryChange(presentation.value.summary)
        }
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var preparationKey: LibraryListingKey {
        LibraryListingKey(storeID: ObjectIdentifier(store), catalogRevision: store.libraryCatalogRevision,
                          releasesRevision: store.releasesRevision, playlistsRevision: store.playlistsRevision,
                          orderingRevision: orderingRevision, query: normalizedSearchText,
                          order: ratingsEnabled || listingOrder != .rating ? listingOrder : .recent,
                          ratingsEnabled: ratingsEnabled)
    }

    private var orderingTaskID: LibraryListingKey {
        LibraryListingKey(storeID: ObjectIdentifier(store), catalogRevision: store.libraryCatalogRevision,
                          playlistsRevision: store.playlistsRevision, order: listingOrder, ratingsEnabled: ratingsEnabled)
    }

    private func loadOrderingTracksIfNeeded() async {
        guard listingOrder == .recent || listingOrder == .artist || listingOrder == .releaseDate
                || (ratingsEnabled && listingOrder == .rating),
              let core = store.core else { return }
        var loaded: [Int64: [Track]] = [:]
        for playlist in store.playlists {
            guard !Task.isCancelled else { return }
            loaded[playlist.id] = try? await core.playlistTracks(playlistId: playlist.id)
        }
        guard !Task.isCancelled else { return }
        tracksByPlaylist = loaded
        orderingRevision &+= 1
    }
}

struct PlaylistsCreationMenu: View {
    @Bindable var state: PlaylistsToolbarState

    var body: some View {
        ToolbarOptionsButton(title: "Adicionar playlist", systemImage: "plus") {
            PlaylistsCreationActions(state: state)
        }
        .overlay(alignment: .bottomTrailing) {
            if state.isImporting {
                ProgressView().controlSize(.mini)
                    .allowsHitTesting(false)
                    .accessibilityLabel("Importando playlist")
            }
        }
        .accessibilityIdentifier("playlists.add")
    }
}

/// The toolbar and sidebar share the same commands and import availability.
struct PlaylistsCreationActions: View {
    @Environment(PlaylistCreationCoordinator.self) private var playlistCreation
    @Bindable var state: PlaylistsToolbarState

    var body: some View {
        Button("Nova playlist", systemImage: "plus") {
            playlistCreation.request(for: nil)
        }
        Button("Nova playlist inteligente", systemImage: "wand.and.stars") {
            state.isShowingSmartPlaylist = true
        }
        Button("Importar playlist", systemImage: "square.and.arrow.down") {
            state.isChoosingImport = true
        }
        .disabled(state.isImporting)
    }
}

/// Keep presentation attached to the window, so sidebar commands work from any page.
struct PlaylistsCreationPresentation: ViewModifier {
    @Environment(DurvaldCoreStore.self) private var store
    @Bindable var state: PlaylistsToolbarState
    @State private var importReport: PlaylistImportReport?
    @State private var importError: String?

    func body(content: Content) -> some View {
        content
        .fileImporter(
            isPresented: $state.isChoosingImport,
            allowedContentTypes: [PlaylistTransferService.m3u8Type],
            allowsMultipleSelection: false,
            onCompletion: importPlaylist
        )
        .sheet(item: $importReport) { PlaylistImportReportSheet(report: $0) }
        .sheet(isPresented: $state.isShowingSmartPlaylist) {
            SmartPlaylistSheet { name, description, definition in
                await store.createSmartPlaylist(
                    named: name, description: description, definition: definition
                ) != nil
            }
        }
        .alert("Não foi possível importar", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    private func importPlaylist(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else {
            if case .failure(let error) = result { importError = error.localizedDescription }
            return
        }
        state.isImporting = true
        Task {
            defer { state.isImporting = false }
            do { importReport = try await store.importM3U8(from: url) }
            catch { importError = error.localizedDescription }
        }
    }

}
