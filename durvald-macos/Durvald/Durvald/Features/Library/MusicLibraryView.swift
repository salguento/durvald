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
    private struct LibrarySummaryRequest: Equatable {
        let tracks: [Track]
        let metadataRevision: Int
        let hasLoadedAllTracks: Bool
    }
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(TrackInfoCoordinator.self) private var trackInfo
    @Environment(PlaylistCreationCoordinator.self) private var playlistCreation
    @Environment(\.trackMenuNavigation) private var navigation
    @Environment(\.libraryScrollOffset) private var savedScrollOffset
    @State private var selectedTrackIDs = Set<Int64>()
    @Binding var searchText: String
    let onSummaryChange: (MusicLibrarySummary) -> Void
    @State private var searchResults: [Track]?
    @State private var committedSearchQuery = ""
    @State private var isSearching = false
    @State private var searchRequestID = UUID()
    @State private var fileSizes: [String: Int64] = [:]
    @State private var librarySummary: MusicLibrarySummary?
    @State private var completeLibraryTracks: [Track]?
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
        let displayedTracks = visibleTracks
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
                onLayoutChange: { layout in
                    columnLayout = layout
                },
                onPlay: { track in
                    Task { await store.play(trackID: track.id) }
                },
                onLoadMore: { trackID in
                    guard normalizedSearchText.isEmpty, completeLibraryTracks == nil else { return }
                    Task { await store.loadMoreTracks(ifNeededAfter: trackID) }
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
        .onChange(of: summary, initial: true) { _, value in onSummaryChange(value) }
        .onAppear {
            if !trackNumberColumnIntroduced {
                let initialLayout = columnLayout
                columnLayout = initialLayout
                trackNumberColumnIntroduced = true
            }
        }
        .task(id: SearchRequest(query: normalizedSearchText, metadataRevision: store.metadataRevision, usesLocalSearch: usesLocalSearch)) {
            await refreshSearch()
        }
        .task(id: LibrarySummaryRequest(tracks: store.tracks, metadataRevision: store.metadataRevision, hasLoadedAllTracks: store.hasLoadedAllTracks)) {
            await refreshLibrarySummary()
        }
        .task(id: displayedTracks.map(\.filePath)) {
            guard !normalizedSearchText.isEmpty else { return }
            let missingPaths = Set(displayedTracks.map(\.filePath)).filter { fileSizes[$0] == nil }
            guard !missingPaths.isEmpty else { return }
            let sizes = await MusicLibraryFileSizes.read(Array(missingPaths))
            guard !Task.isCancelled else { return }
            fileSizes.merge(sizes, uniquingKeysWith: { _, latest in latest })
        }
    }

    private var summary: MusicLibrarySummary {
        if !normalizedSearchText.isEmpty {
            return MusicLibrarySummary(
                tracks: visibleTracks, kind: .search, query: normalizedSearchText,
                fileSizes: fileSizes,
                isPending: !usesLocalSearch && committedSearchQuery != normalizedSearchText,
                onlyFavorites: onlyFavorites
            )
        }
        let tracks = onlyFavorites ? visibleTracks : store.tracks
        let selectedTracks = tracks.filter { selectedTrackIDs.contains($0.id) }
        if !selectedTracks.isEmpty {
            return MusicLibrarySummary(tracks: selectedTracks, kind: .selected, fileSizes: fileSizes, onlyFavorites: onlyFavorites)
        }
        if onlyFavorites { return MusicLibrarySummary(tracks: visibleTracks, kind: .all, fileSizes: fileSizes, onlyFavorites: true) }
        return librarySummary ?? MusicLibrarySummary(tracks: tracks, kind: .all, fileSizes: fileSizes)
    }

    private func refreshLibrarySummary() async {
        var tracks = store.tracks
        if !store.hasLoadedAllTracks, let core = store.core {
            var offset = UInt64(tracks.count)
            do {
                while !Task.isCancelled {
                    let page = try await core.tracksPage(pageSize: 1_000, offset: offset)
                    guard !Task.isCancelled else { return }
                    tracks.append(contentsOf: page.items)
                    guard let nextOffset = page.nextOffset, nextOffset > offset else { break }
                    offset = nextOffset
                }
            } catch {
                // Keep the previous complete summary if a catalog refresh fails.
                return
            }
        }
        guard !Task.isCancelled else { return }
        let sizes = await MusicLibraryFileSizes.read(Array(Set(tracks.map(\.filePath))))
        guard !Task.isCancelled else { return }
        fileSizes.merge(sizes, uniquingKeysWith: { _, latest in latest })
        completeLibraryTracks = tracks
        librarySummary = MusicLibrarySummary(tracks: tracks, kind: .all, fileSizes: sizes)
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var usesLocalSearch: Bool {
        store.hasLoadedAllTracks && store.tracks.count <= 1_000
    }

    private var visibleTracks: [Track] {
        let updatedTracks = Dictionary(store.tracks.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        var tracks: [Track]
        if normalizedSearchText.isEmpty {
            tracks = (completeLibraryTracks ?? store.tracks).map { updatedTracks[$0.id] ?? $0 }
        } else if usesLocalSearch {
            let query = normalizedSearchText
            tracks = store.tracks.filter {
                $0.title.localizedCaseInsensitiveContains(query)
                    || $0.artist.localizedCaseInsensitiveContains(query)
                    || $0.release.localizedCaseInsensitiveContains(query)
            }
        } else {
            tracks = (searchResults ?? []).map { updatedTracks[$0.id] ?? $0 }
        }
        if onlyFavorites { tracks = tracks.filter(\.isFavorite) }
        let effectiveSort = !ratingsEnabled && sort == .rating ? .title : sort
        return tracks.sorted { lhs, rhs in
            let order = effectiveSort.compare(lhs, rhs)
            if order != .orderedSame {
                return sortAscending ? order == .orderedAscending : order == .orderedDescending
            }
            if lhs.discNumber != rhs.discNumber { return lhs.discNumber < rhs.discNumber }
            if lhs.trackNumber != rhs.trackNumber { return lhs.trackNumber < rhs.trackNumber }
            let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return lhs.id < rhs.id
        }
    }

    private func refreshSearch() async {
        let requestID = UUID()
        searchRequestID = requestID
        isSearching = false
        let query = normalizedSearchText
        guard !query.isEmpty, !usesLocalSearch else {
            searchResults = nil
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
            trackInfo.open(trackID: track.id)
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

    private func accentForeground(for track: Track) -> Color {
        selectedTrackIDs.contains(track.id)
            ? Color(nsColor: MusicLibrarySelectionStyle.accentForeground) : .accentColor
    }

    @ViewBuilder
    private func cell(for track: Track, column: MusicLibraryColumn) -> some View {
        switch column {
        case .artwork:
            ArtworkView(artworkID: track.artworkId, size: CGFloat(artworkSize))
        case .favorite:
            Button {
                Task { await store.setTrackFavorite(trackID: track.id, favorite: !track.isFavorite) }
            } label: {
                Image(systemName: track.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(track.isFavorite ? accentForeground(for: track) : .secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(track.isFavorite ? "Desfavoritar faixa" : "Favoritar faixa")
        case .size:
            Text(fileSizes[track.filePath].flatMap { $0 >= 0 ? ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) : nil } ?? "—")
                .foregroundStyle(.secondary)
        case .rating:
            RatingControl(rating: track.rating, isEditable: true, accentForeground: accentForeground(for: track)) { rating in
                Task { await store.setTrackRating(trackID: track.id, rating: rating) }
            }
        default:
            EmptyView()
        }
    }

}
