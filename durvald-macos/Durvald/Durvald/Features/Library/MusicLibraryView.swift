//
//  MusicLibraryView.swift
//  Durvald
//
//  Created by Humberto Salguento on 21/08/26.
//

import AppKit
import SwiftUI

struct MusicLibraryView: View {
    private struct SearchRequest: Equatable {
        let query: String
        let metadataRevision: Int
        let usesLocalSearch: Bool
    }
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(TrackInfoCoordinator.self) private var trackInfo
    @Environment(PlaylistCreationCoordinator.self) private var playlistCreation
    @Environment(\.trackMenuNavigation) private var navigation
    @Environment(\.libraryScrollOffset) private var savedScrollOffset
    @State private var selectedTrackIDs = Set<Int64>()
    @Binding var searchText: String
    @State private var searchRevision: UInt64 = 0
    @State private var searchResults: [Track]?
    @State private var committedSearchQuery = ""
    @State private var isSearching = false
    @State private var searchRequestID = UUID()
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
        return VStack(spacing: 0) {
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
                    Task { await store.setTrackFavorite(trackID: track.id, favorite: favorite) }
                },
                onRatingChange: { track, rating in
                    Task { await store.setTrackRating(trackID: track.id, rating: rating) }
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
            .ignoresSafeArea(.container, edges: .bottom)
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
        .task(id: isPresented ? SearchRequest(query: normalizedSearchText, metadataRevision: store.metadataRevision, usesLocalSearch: usesLocalSearch) : nil) {
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
            let missingPaths = Set(displayedTracks.map(\.filePath)).filter { fileSizes[$0] == nil }
            guard !missingPaths.isEmpty else { return }
            let sizes = await MusicLibraryFileSizes.read(Array(missingPaths))
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
        let requestID = UUID()
        searchRequestID = requestID
        isSearching = false
        let query = normalizedSearchText
        guard !query.isEmpty, !usesLocalSearch else {
            searchResults = nil
            searchRevision &+= 1
            committedSearchQuery = ""
            return
        }
        let loadingIndicator = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(250)) }
            catch { return }
            guard !Task.isCancelled, searchRequestID == requestID else { return }
            isSearching = true
        }
        defer {
            loadingIndicator.cancel()
            if searchRequestID == requestID { isSearching = false }
        }
        do { try await Task.sleep(for: .milliseconds(80)) }
        catch { return }
        let results = await store.searchLibrary(query: query)
        guard !Task.isCancelled, searchRequestID == requestID, normalizedSearchText == query else { return }
        searchResults = results.tracks
        searchRevision &+= 1
        committedSearchQuery = query
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
