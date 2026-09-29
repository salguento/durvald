import SwiftUI
import UniformTypeIdentifiers

struct PlaylistsView: View {
    @Environment(DurvaldCoreStore.self) private var store
    @AppStorage("playlists.listingMode") private var listingMode: CollectionListingMode = .standard
    @AppStorage("playlists.listingOrder") private var listingOrder: CollectionListingOrder = .recent
    @AppStorage(RatingPreferences.enabledKey) private var ratingsEnabled = true
    @State private var tracksByPlaylist: [Int64: [Track]] = [:]
    @State private var isChoosingImport = false
    @State private var isImporting = false
    @State private var importReport: PlaylistImportReport?
    @State private var importError: String?
    let onSelectPlaylist: (Playlist) -> Void

    var body: some View {
        CollectionListingLayout(mode: listingMode) { size in
            ForEach(orderedPlaylists, id: \.id) { playlist in
                CollectionListingItem(title: playlist.name, mode: listingMode, artworkSize: size, action: { onSelectPlaylist(playlist) }) {
                    PlaylistArtworkThumbnail(playlistID: playlist.id, artworkBase64: playlist.artworkId, size: size)
                }
                .playlistContextMenu(playlist: playlist)
                .accessibilityIdentifier("playlist.\(playlist.id)")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Button("Importar M3U8…", systemImage: "square.and.arrow.down") {
                    isChoosingImport = true
                }
                .disabled(isImporting)
                if isImporting { ProgressView().controlSize(.small) }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .fileImporter(
            isPresented: $isChoosingImport,
            allowedContentTypes: [PlaylistTransferService.m3u8Type],
            allowsMultipleSelection: false,
            onCompletion: importPlaylist
        )
        .sheet(item: $importReport) { PlaylistImportReportSheet(report: $0) }
        .alert("Não foi possível importar", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .task(id: orderingTaskID) {
            await loadOrderingTracksIfNeeded()
        }
    }

    private func importPlaylist(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else {
            if case .failure(let error) = result { importError = error.localizedDescription }
            return
        }
        isImporting = true
        Task {
            defer { isImporting = false }
            do { importReport = try await store.importM3U8(from: url) }
            catch { importError = error.localizedDescription }
        }
    }

    private var orderedPlaylists: [Playlist] {
        CollectionListingSorter.playlists(
            store.playlists,
            order: ratingsEnabled || listingOrder != .rating ? listingOrder : .recent,
            tracksByPlaylist: tracksByPlaylist,
            releases: store.releases
        )
    }

    private var orderingTaskID: String {
        "\(listingOrder.rawValue):\(store.playlists.map(\.id))"
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
        tracksByPlaylist = loaded
    }
}
