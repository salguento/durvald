//
//  MusicLibraryView.swift
//  Durvald
//
//  Created by Humberto Salguento on 21/08/26.
//

import AppKit
import SwiftUI

struct MusicLibraryView: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(TrackInfoCoordinator.self) private var trackInfo
    @Environment(PlaylistCreationCoordinator.self) private var playlistCreation
    @Environment(\.trackMenuNavigation) private var navigation
    @Environment(\.libraryScrollOffset) private var savedScrollOffset
    @State private var selectedTrackIDs = Set<Int64>()
    @Binding var searchText: String
    @State private var search = SearchPresentation<[Track]>()
    private var searchRevision: UInt64 { search.revision }
    private var searchResults: [Track]? { search.value }
    private var committedSearchQuery: String { search.committedQuery }
    private var isSearching: Bool { search.isSearching }
    private var searchRequest: SearchRequest {
        .init(query: normalizedSearchText, storeID: ObjectIdentifier(store), coreID: store.core.map(ObjectIdentifier.init),
              metadataRevision: store.metadataRevision, scope: usesLocalSearch ? "music.local" : "music.remote")
    }
    let presentation: MusicLibraryPresentation
    var isPresented = true
    var navigationEntryID = 0
    let onSummaryChange: (MusicLibrarySummary) -> Void

    private var fileSizes: [String: Int64] { presentation.fileSizes }
    @AppStorage("library.music.skipBatchInfoConfirmation") private var skipBatchInfoConfirmation = false
    @AppStorage("library.music.onlyFavorites") private var onlyFavorites = false
    @AppStorage("library.music.sort") private var sort: MusicLibrarySort = .title
    @AppStorage("library.music.sortAscending") private var sortAscending = true
    @AppStorage(RatingPreferences.enabledKey) private var ratingsEnabled = true

    @AppStorage("library.music.columnLayout") private var savedColumnLayout = ""
    @AppStorage("library.music.groupArtwork") private var groupArtwork = false
    @AppStorage("library.music.artworkSizePosition") private var artworkSizePosition = 0.0
    @AppStorage("library.music.trackNumberColumnIntroduced") private var trackNumberColumnIntroduced = false
    private var columnLayout: MusicLibraryColumnLayout {
        get {
            var layout = savedColumnLayout.data(using: .utf8)
                .flatMap { try? JSONDecoder().decode(MusicLibraryColumnLayout.self, from: $0) }
                ?? MusicLibraryColumnLayout()
            var seen = Set<MusicLibraryColumn>()
            layout.order = layout.order.filter { seen.insert($0).inserted }
            let missing = MusicLibraryColumn.allCases.filter { !seen.contains($0) }
            layout.order += missing
            layout.hidden.formUnion(missing)
            layout.hidden.remove(.title)
            layout.hidden.remove(.actions)
            if !trackNumberColumnIntroduced {
                layout.hidden.remove(.trackNumber)
                layout.order.removeAll { $0 == .trackNumber }
                let index = layout.order.firstIndex(of: .artwork) ?? 0
                layout.order.insert(.trackNumber, at: index + 1)
            }
            return layout
        }
        nonmutating set {
            guard let data = try? JSONEncoder().encode(newValue),
                  let value = String(data: data, encoding: .utf8) else { return }
            savedColumnLayout = value
        }
    }

    private var artworkSize: Double {
        let position = min(2, max(0, artworkSizePosition.rounded()))
        return (32 + position * 8) * (groupArtwork ? 3 : 1)
    }

    var body: some View {
        let displayedTracks = presentation.displayedTracks
        return GeometryReader { geometry in
            VStack(spacing: 0) {
            libraryControls
            MusicLibraryTableView(
                tracks: displayedTracks,
                selection: $selectedTrackIDs,
                savedScrollOffset: savedScrollOffset,
                layout: columnLayout,
                ratingsEnabled: ratingsEnabled,
                artworkSize: artworkSize,
                groupArtwork: groupArtwork,
                activeTrackID: store.activeTrackID,
                bottomContentInset: geometry.safeAreaInsets.bottom,
                isPresented: isPresented,
                scrollRestorationID: navigationEntryID,
                tracksRevision: presentation.displayRevision,
                onLayoutChange: { layout in
                    columnLayout = layout
                },
                onPlay: { track in
                    Task { await store.play(trackID: track.id) }
                },
                onLoadMore: { trackID in
                    guard normalizedSearchText.isEmpty, presentation.catalog == nil else { return }
                    Task { await store.loadMoreTracks(ifNeededAfter: trackID) }
                },
                onFavoriteChange: { track, favorite in
                    await store.setTrackFavorite(trackID: track.id, favorite: favorite, fallbackTrack: track)
                },
                onRatingChange: { track, rating in
                    await store.setTrackRating(trackID: track.id, rating: rating, fallbackTrack: track)
                },
                configureMenu: { controller, track in
                    controller.configure(
                        track: track, store: store,
                        playlistCreation: playlistCreation,
                        trackInfo: trackInfo, navigation: navigation,
                        infoAction: { showInfo(for: track) },
                        selectedTracks: selectedTrackIDs.contains(track.id)
                            ? displayedTracks.filter { selectedTrackIDs.contains($0.id) } : [track]
                    )
                },
                cellContent: { track, column in
                    AnyView(
                        cell(for: track, column: column)
                            .id(track.id)
                            .environment(store)
                            .environment(trackInfo)
                            .environment(playlistCreation)
                            .environment(\.trackMenuNavigation, navigation)
                    )
                }
            )
            // Let AppKit inset the header and first row while the document
            // continues underneath the toolbar during scrolling.
            .ignoresSafeArea(.container, edges: [.top, .bottom])
            }
        }
        .overlay {
            if isSearching {
                ProgressView("Pesquisando…")
            } else if !normalizedSearchText.isEmpty && displayedTracks.isEmpty
                        && (usesLocalSearch || committedSearchQuery == normalizedSearchText) {
                ContentUnavailableView("Nenhuma música encontrada", systemImage: "magnifyingglass")
            }
        }
        .onChange(of: summary, initial: true) { _, value in
            if isPresented { onSummaryChange(value) }
        }
        .onChange(of: isPresented) { _, visible in
            if visible { onSummaryChange(summary) }
        }
        .onAppear {
            if !trackNumberColumnIntroduced {
                let initialLayout = columnLayout
                columnLayout = initialLayout
                trackNumberColumnIntroduced = true
            }
        }
        .onChange(of: isPresented) { _, presented in if !presented { search.cancel() } }
        .onDisappear { search.cancel() }
        .task(id: isPresented ? searchRequest : nil) {
            guard isPresented else { return }
            await refreshSearch()
        }
        .task(id: isPresented ? presentation.catalogRequest(for: store) : nil) {
            guard isPresented else { return }
            await presentation.refreshCatalog(store: store)
        }
        .task(id: isPresented ? displayKey : nil) {
            guard isPresented else { return }
            await presentation.prepare(displayRequest, key: displayKey)
        }
        .task(id: !isPresented || normalizedSearchText.isEmpty ? nil : presentation.displayRevision) {
            guard isPresented, !normalizedSearchText.isEmpty else { return }
            let paths = Array(Set(displayedTracks.map(\.filePath)))
            guard !paths.isEmpty, let sizes = try? await store.fileSizes(for: paths) else { return }
            guard !Task.isCancelled else { return }
            presentation.fileSizes.merge(sizes, uniquingKeysWith: { _, latest in latest })
        }
    }

    private var summary: MusicLibrarySummary {
        if !normalizedSearchText.isEmpty {
            return MusicLibrarySummary(
                tracks: presentation.displayedTracks, kind: .search, query: normalizedSearchText,
                fileSizes: fileSizes,
                isPending: !usesLocalSearch && committedSearchQuery != normalizedSearchText,
                onlyFavorites: onlyFavorites
            )
        }
        let tracks = presentation.displayedTracks
        let selectedTracks = selectedTrackIDs.isEmpty ? [] : tracks.filter { selectedTrackIDs.contains($0.id) }
        if !selectedTracks.isEmpty {
            return MusicLibrarySummary(tracks: selectedTracks, kind: .selected, fileSizes: fileSizes, onlyFavorites: onlyFavorites)
        }
        if onlyFavorites { return MusicLibrarySummary(tracks: presentation.displayedTracks, kind: .all, fileSizes: fileSizes, onlyFavorites: true) }
        return presentation.librarySummary ?? MusicLibrarySummary(tracks: tracks, kind: .all, fileSizes: fileSizes)
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var usesLocalSearch: Bool {
        store.hasLoadedAllTracks && store.tracks.count <= 1_000
    }

    private var displayKey: MusicLibraryPresentation.DisplayKey {
        .init(storeID: ObjectIdentifier(store), coreID: store.core.map(ObjectIdentifier.init),
              tracksRevision: store.tracksRevision, metadataRevision: store.metadataRevision,
              catalogRevision: normalizedSearchText.isEmpty ? presentation.catalogVersion : 0,
              searchRevision: searchRevision, query: normalizedSearchText, usesLocalSearch: usesLocalSearch,
              onlyFavorites: onlyFavorites,
              sort: !ratingsEnabled && sort == .rating ? .title : sort, ascending: sortAscending)
    }

    private var displayRequest: MusicLibraryPresentation.DisplayRequest {
        MusicLibraryPresentation.DisplayRequest(
            tracks: presentation.sourceTracks(store: store, searchResults: searchResults, query: normalizedSearchText, usesLocalSearch: usesLocalSearch),
            query: usesLocalSearch ? normalizedSearchText : "",
            onlyFavorites: onlyFavorites,
            sort: !ratingsEnabled && sort == .rating ? .title : sort,
            ascending: sortAscending,
            updatedTracks: !usesLocalSearch ? store.tracks : []
        )
    }

    private func refreshSearch() async {
        guard !usesLocalSearch else { search.reset(); return }
        let current = searchRequest
        await search.run(current, timing: .music, isCurrent: { isPresented && searchRequest == current }) {
            await store.searchLibrary(query: $0).tracks
        }
    }

    @ViewBuilder
    private var libraryControls: some View {
        if store.scanProgress != nil {
            VStack(spacing: 8) {
                if let progress = store.scanProgress {
                    HStack {
                        Text(verbatim: "\(progress.phase): \(progress.processedFiles)/\(progress.totalFiles)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancelar scan") { store.cancelScan() }
                    }
                }
            }
            .padding(12)
        }
    }

    private func showInfo(for track: Track) {
        let ids = selectedTrackIDs.contains(track.id) ? selectedTrackIDs : [track.id]
        guard ids.count > 1 else {
            trackInfo.open(trackID: track.id, navigationTrackIDs: presentation.displayedTracks.map(\.id))
            return
        }
        guard !skipBatchInfoConfirmation else {
            trackInfo.openBatch(trackIDs: ids)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Deseja editar as informações de várias faixas?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Editar faixas")
        alert.addButton(withTitle: "Cancelar")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Não perguntar novamente"
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            skipBatchInfoConfirmation = alert.suppressionButton?.state == .on
            trackInfo.openBatch(trackIDs: ids)
        }
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    @ViewBuilder
    private func cell(for track: Track, column: MusicLibraryColumn) -> some View {
        switch column {
        case .artwork:
            ArtworkView(artworkID: track.artworkId, size: CGFloat(artworkSize))
        case .size:
            Text(fileSizes[track.filePath].flatMap { $0 >= 0 ? ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) : nil } ?? "—")
                .foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

}
