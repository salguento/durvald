import SwiftUI
import UniformTypeIdentifiers

@Observable
final class PlaylistToolbarState {
    var searchText = ""
    var order: PlaylistTrackOrder = .playlist
    var isEditingSmartPlaylist = false
    var exportRelativePaths: Bool?
}

enum PlaylistTrackOrder: String, CaseIterable, Identifiable {
    case playlist
    case title
    case artist
    case duration

    var id: Self { self }

    var title: String {
        switch self {
        case .playlist: "Ordem da playlist"
        case .title: "Título"
        case .artist: "Artista"
        case .duration: "Duração"
        }
    }
}

struct PlaylistView: View {
    private struct TrackDropTarget: Equatable {
        let hoveredPosition: Int
        let insertionIndex: Int
    }

    private struct TrackDropDelegate: DropDelegate {
        let destinationPosition: Int
        let trackCount: Int
        @Binding var draggedPosition: Int?
        @Binding var dropTarget: TrackDropTarget?
        @Binding var isCompletingDrop: Bool
        let onMove: (_ sourcePosition: Int, _ insertionIndex: Int) -> Bool

        func validateDrop(info: DropInfo) -> Bool {
            draggedPosition != nil
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            guard draggedPosition != nil else {
                dropTarget = nil
                return DropProposal(operation: .cancel)
            }
            let insertionIndex = destinationPosition - 1 + (info.location.y < 29 ? 0 : 1)
            let target = TrackDropTarget(
                hoveredPosition: destinationPosition,
                insertionIndex: min(max(insertionIndex, 0), trackCount)
            )
            if dropTarget != target {
                dropTarget = target
            }
            return DropProposal(operation: .move)
        }

        func dropExited(info: DropInfo) {
            guard dropTarget?.hoveredPosition == destinationPosition else { return }
            dropTarget = nil
        }

        func performDrop(info: DropInfo) -> Bool {
            guard let sourcePosition = draggedPosition else { return false }
            let fallbackIndex = destinationPosition - 1 + (info.location.y < 29 ? 0 : 1)
            let insertionIndex: Int
            if let dropTarget, dropTarget.hoveredPosition == destinationPosition {
                insertionIndex = dropTarget.insertionIndex
            } else {
                insertionIndex = min(max(fallbackIndex, 0), trackCount)
            }

            isCompletingDrop = true
            draggedPosition = nil
            dropTarget = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                isCompletingDrop = false
            }
            return onMove(sourcePosition, insertionIndex)
        }
    }

    private struct TrackEntry: Identifiable {
        let position: Int
        let track: Track

        var id: Int { position }
    }

    @Environment(DurvaldCoreStore.self) private var store
    @Environment(PlaylistCreationCoordinator.self) private var playlistCreation

    let playlist: Playlist

    @State private var tracks: [Track] = []
    @State private var isLoading = true
    @State private var selectedTrackPosition: Int?
    @Bindable var toolbarState = PlaylistToolbarState()
    @State private var draggedTrackPosition: Int?
    @State private var trackDropTarget: TrackDropTarget?
    @State private var isCompletingTrackDrop = false
    @State private var isPersistingTrackOrder = false
    @State private var isExporting = false
    @State private var exportMessage: String?
    @AppStorage(RatingPreferences.enabledKey) private var ratingsEnabled = true

    private let artworkSize: CGFloat = 268

    private var currentPlaylist: Playlist {
        store.playlists.first(where: { $0.id == playlist.id }) ?? playlist
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                trackList
                if !currentPlaylist.isSmart {
                    VStack(alignment: .leading, spacing: 10) {
                        Divider()
                        PlaylistMusicPicker(playlist: currentPlaylist) { track in
                            tracks.append(track)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onDrop(of: [LibraryTrackDrag.type], isTargeted: nil) { providers in
            guard !currentPlaylist.isSmart else { return false }
            return LibraryTrackDrag.accept(providers) { ids in
                Task {
                    await store.addSelectionToPlaylist(ids, playlist: currentPlaylist)
                    tracks = await store.tracks(forPlaylistID: playlist.id)
                }
            }
        }
        .preservesLibraryScrollPosition(isContentReady: !isLoading)
        .task(id: playlist.id) {
            isLoading = true
            tracks = await store.tracks(forPlaylistID: playlist.id)
            isLoading = false
        }
        .accessibilityIdentifier("playlist.detail.\(playlist.id)")
        .task(id: store.metadataRevision) {
            guard store.metadataRevision > 0 else { return }
            tracks = await store.tracks(forPlaylistID: playlist.id)
        }
        .task(id: store.historyRepository.revision) {
            guard RetrospectivePlaylistConfiguration.read(currentPlaylist) != nil else { return }
            await store.refreshHistory()
            await store.refreshRetrospectivePlaylistsIfNeeded()
            tracks = await store.tracks(forPlaylistID: playlist.id)
        }
        .task(id: currentPlaylist.isSmart) {
            guard !currentPlaylist.isSmart else { return }
            tracks = await store.tracks(forPlaylistID: playlist.id)
        }
        .onChange(of: toolbarState.exportRelativePaths) { _, relativePaths in
            guard let relativePaths else { return }
            toolbarState.exportRelativePaths = nil
            export(relativePaths: relativePaths)
        }
        .sheet(isPresented: $toolbarState.isEditingSmartPlaylist) {
            if let config = RetrospectivePlaylistConfiguration.read(currentPlaylist),
               let period = RetrospectivePeriod(rawValue: config.period) {
                RetrospectivePlaylistSettingsSheet(playlist: currentPlaylist, config: config, period: period) { live, automatically in
                    let draft = RetrospectivePlaylistDraft(period: period, interval: DateInterval(
                        start: Date(timeIntervalSince1970: Double(config.startAt)), end: Date(timeIntervalSince1970: Double(config.endAt))))
                    guard await store.updateReplay(draft, live: live, closeAutomatically: automatically) else { return false }
                    tracks = await store.tracks(forPlaylistID: currentPlaylist.id)
                    return true
                }
            } else {
                SmartPlaylistSheet(playlist: currentPlaylist) { name, description, definition in
                    guard await store.updateSmartPlaylist(
                        id: currentPlaylist.id, name: name,
                        description: description, definition: definition
                    ) != nil else { return false }
                    tracks = await store.tracks(forPlaylistID: currentPlaylist.id)
                    return true
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(alignment: .top, spacing: 24) {
                PlaylistArtworkThumbnail(
                    playlistID: currentPlaylist.id,
                    artworkBase64: currentPlaylist.artworkId,
                    size: artworkSize
                )
                .playlistContextMenu(playlist: currentPlaylist)

                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        if currentPlaylist.isSmart { toolbarState.isEditingSmartPlaylist = true }
                        else { playlistCreation.requestEdit(currentPlaylist) }
                    } label: {
                        Text(currentPlaylist.name)
                            .font(.largeTitle)
                            .fontWeight(.bold)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 24)
                    .help("Editar playlist")
                    .accessibilityLabel("Editar playlist \(currentPlaylist.name)")
                    .accessibilityIdentifier("playlist.edit")

                    if !currentPlaylist.description.isEmpty {
                        Text(currentPlaylist.description)
                            .font(.title2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }

                    Text(playlistMetadataText)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)

                    if let config = RetrospectivePlaylistConfiguration.read(currentPlaylist) {
                        Label("Mantida atualizada", systemImage: "arrow.trianglehead.2.clockwise")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if config.closeAutomatically {
                            Text("A seleção será fixada ao encerrar o período.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    Spacer(minLength: 20)

                    playlistPlaybackControls
                        .padding(.bottom, 24)
                }
                .frame(maxWidth: .infinity, minHeight: artworkSize, alignment: .topLeading)
            }
        }
        .alert("Exportação de playlist", isPresented: Binding(
            get: { exportMessage != nil },
            set: { if !$0 { exportMessage = nil } }
        )) {
            Button("OK") { exportMessage = nil }
        } message: {
            Text(exportMessage ?? "")
        }
    }

    private var playlistMetadataText: String {
        let count = currentPlaylist.trackCount
        let trackLabel = count == 1 ? "1 música" : "\(count) músicas"
        guard !isLoading else { return trackLabel }
        let totalSeconds = DurationFormatter.totalSeconds(tracks.map(\.durationSeconds))
        let duration = DurationFormatter.text(seconds: UInt64(totalSeconds), context: .albumHeader)
        return [trackLabel, duration].joined(separator: " • ")
    }

    private var playlistPlaybackControls: some View {
        HStack(spacing: 16) {
            Button { playPlaylist(.play) } label: {
                CollectionHeaderPlayLabel(size: 60)
            }
            .buttonStyle(.plain)
            .disabled(isLoading || tracks.isEmpty)
            .help("Reproduzir")
            .accessibilityLabel("Reproduzir")
            .accessibilityIdentifier("collection.play")

            Button { playPlaylist(.shuffle) } label: {
                Image(systemName: "shuffle")
            }
            .buttonStyle(CollectionHeaderActionButtonStyle(size: 40))
            .disabled(isLoading || tracks.isEmpty)
            .help("Reproduzir aleatoriamente")
            .accessibilityLabel("Reproduzir aleatoriamente")
            .accessibilityIdentifier("collection.shuffle")

            Button {
                store.setPlaylistFavorite(playlistID: playlist.id, favorite: !currentPlaylist.isFavorite)
            } label: {
                Image(systemName: "star.fill")
                    .foregroundStyle(currentPlaylist.isFavorite ? Color.accentColor : .white.opacity(0.45))
            }
            .buttonStyle(CollectionHeaderActionButtonStyle(size: 40))
            .help(currentPlaylist.isFavorite ? "Desfavoritar playlist" : "Favoritar playlist")
            .accessibilityLabel(currentPlaylist.isFavorite ? "Desfavoritar playlist" : "Favoritar playlist")
            .accessibilityValue(currentPlaylist.isFavorite ? "Favorito" : "Não favorito")
            .accessibilityAddTraits(currentPlaylist.isFavorite ? .isSelected : [])
            .accessibilityIdentifier("collection.favorite")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("playlist.header.actions")
    }

    private func playPlaylist(_ action: PlaybackCollection.Action) {
        guard !isLoading, !tracks.isEmpty else { return }
        Task { await PlaybackCollection.playlist(playlist.id).perform(action, using: store) }
    }

    private func export(relativePaths: Bool) {
        guard !isExporting else { return }
        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                let url = try await store.exportM3U8(
                    playlist: currentPlaylist,
                    relativePaths: relativePaths
                )
                exportMessage = "Playlist exportada para \(url.path)."
            } catch PlaylistTransferError.exportCancelled {
                // The save panel already communicates cancellation.
            } catch {
                exportMessage = "Não foi possível exportar: \(error.localizedDescription)"
            }
        }
    }

    @ViewBuilder
    private var trackList: some View {
        if isLoading {
            ProgressView("Carregando faixas…")
                .frame(maxWidth: .infinity, alignment: .center)
        } else if tracks.isEmpty {
            ContentUnavailableView(
                "Nenhuma faixa",
                systemImage: "music.note",
                description: Text("Esta playlist ainda não possui músicas.")
            )
            .frame(maxWidth: .infinity)
        } else if visibleTracks.isEmpty {
            ContentUnavailableView.search(text: toolbarState.searchText)
                .frame(maxWidth: .infinity)
        } else {
            LazyVStack(spacing: 1) {
                ForEach(visibleTracks) { entry in
                    reorderableTrackRow(entry)
                }
            }
        }
    }

    private var isReorderMode: Bool {
        toolbarState.order == .playlist
            && toolbarState.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canReorderTracks: Bool {
        !currentPlaylist.isSmart && isReorderMode && !isPersistingTrackOrder
    }

    @ViewBuilder
    private func reorderableTrackRow(_ entry: TrackEntry) -> some View {
        let row = trackRow(entry.track, position: entry.position)

        if canReorderTracks {
            row
                .onDrag {
                    isCompletingTrackDrop = false
                    draggedTrackPosition = entry.position
                    return NSItemProvider(object: String(entry.position) as NSString)
                } preview: {
                    trackDragPreview(entry.track)
                        .opacity(isCompletingTrackDrop ? 0 : 1)
                        .animation(nil, value: isCompletingTrackDrop)
                }
                .overlay {
                    trackDropIndicator(for: entry.position)
                }
                .onDrop(
                    of: [UTType.text],
                    delegate: TrackDropDelegate(
                        destinationPosition: entry.position,
                        trackCount: tracks.count,
                        draggedPosition: $draggedTrackPosition,
                        dropTarget: $trackDropTarget,
                        isCompletingDrop: $isCompletingTrackDrop,
                        onMove: moveTrack(from:toInsertionIndex:)
                    )
                )
        } else {
            row
        }
    }

    private func trackDragPreview(_ track: Track) -> some View {
        HStack(spacing: 10) {
            ArtworkView(artworkID: track.artworkId, size: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .lineLimit(1)

                if !track.artist.isEmpty {
                    Text(track.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(width: 260, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(0.22))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.accentColor.opacity(0.55), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func trackDropIndicator(for position: Int) -> some View {
        if draggedTrackPosition != nil, let target = trackDropTarget {
            VStack(spacing: 0) {
                if target.insertionIndex == position - 1 {
                    dropIndicatorLine
                }
                Spacer(minLength: 0)
                if position == tracks.count, target.insertionIndex == tracks.count {
                    dropIndicatorLine
                }
            }
            .allowsHitTesting(false)
        }
    }

    private var dropIndicatorLine: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(height: 2)
            .padding(.horizontal, 4)
    }

    private func moveTrack(from sourcePosition: Int, toInsertionIndex insertionIndex: Int) -> Bool {
        let sourceIndex = sourcePosition - 1
        let destinationIndex = insertionIndex > sourceIndex
            ? insertionIndex - 1
            : insertionIndex
        guard tracks.indices.contains(sourceIndex),
              tracks.indices.contains(destinationIndex),
              sourceIndex != destinationIndex,
              !isPersistingTrackOrder
        else { return false }

        let movedTrack = tracks.remove(at: sourceIndex)
        tracks.insert(movedTrack, at: destinationIndex)
        let destinationPosition = destinationIndex + 1
        if let selectedTrackPosition {
            if selectedTrackPosition == sourcePosition {
                self.selectedTrackPosition = destinationPosition
            } else if sourcePosition < destinationPosition,
                      selectedTrackPosition > sourcePosition,
                      selectedTrackPosition <= destinationPosition {
                self.selectedTrackPosition = selectedTrackPosition - 1
            } else if destinationPosition < sourcePosition,
                      selectedTrackPosition >= destinationPosition,
                      selectedTrackPosition < sourcePosition {
                self.selectedTrackPosition = selectedTrackPosition + 1
            }
        }
        isPersistingTrackOrder = true

        Task {
            let saved = await store.movePlaylistTrack(
                playlistID: playlist.id,
                from: sourceIndex,
                to: destinationIndex
            )
            if !saved {
                tracks = await store.tracks(forPlaylistID: playlist.id)
            }
            isPersistingTrackOrder = false
        }
        return true
    }

    private var visibleTracks: [TrackEntry] {
        let query = toolbarState.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var entries = tracks.enumerated().map {
            TrackEntry(position: $0.offset + 1, track: $0.element)
        }

        if !query.isEmpty {
            entries = entries.filter {
                $0.track.title.localizedStandardContains(query)
                    || $0.track.artist.localizedStandardContains(query)
                    || $0.track.release.localizedStandardContains(query)
            }
        }

        switch toolbarState.order {
        case .playlist:
            break
        case .title:
            entries.sort { $0.track.title.localizedStandardCompare($1.track.title) == .orderedAscending }
        case .artist:
            entries.sort { $0.track.artist.localizedStandardCompare($1.track.artist) == .orderedAscending }
        case .duration:
            entries.sort { $0.track.durationSeconds < $1.track.durationSeconds }
        }

        return entries
    }

    private func trackRow(_ track: Track, position: Int) -> some View {
        let isActive = activeTrackPosition == position
        let model = TrackRowModel(track)

        return HStack(spacing: 12) {
            AlbumTrackPosition(
                trackID: track.id,
                number: "\(position)",
                isActiveOverride: isActive
            )
                .offset(x: -6)

            ArtworkView(artworkID: model.artworkID, size: 42)

            TrackRowText(model: model, activeOverride: isActive, inactiveColor: .primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            TrackListTrailingControls(
                track: track,
                onPlay: {
                    Task {
                        await TrackRowPlayback.playlist(playlist.id, position: position - 1).perform(using: store)
                    }
                },
                onToggleFavorite: { isFavorite in
                    await store.setTrackFavorite(trackID: track.id, favorite: isFavorite, fallbackTrack: track)
                }
            ) {
                if ratingsEnabled {
                    RatingControl(
                        rating: model.rating,
                        isEditable: true,
                        identity: .track(track.id),
                        onCommit: { rating in
                            await store.setTrackRating(trackID: track.id, rating: rating, fallbackTrack: track)
                        }
                    )
                }

                Button {
                    Task { await store.addToQueue(trackID: track.id) }
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(model.enqueueLabel)
            }
        }
        .padding(.vertical, 8)
        .padding(.trailing, 16)
        .playTrackOnDoubleClick {
            Task {
                await TrackRowPlayback.playlist(playlist.id, position: position - 1).perform(using: store)
            }
        }
        .background {
            if selectedTrackPosition == position {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.10))
            }
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                selectedTrackPosition = position
            }
        )
        .trackContextMenu(track: track) {
            Task {
                await TrackRowPlayback.playlist(playlist.id, position: position - 1).perform(using: store)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selectedTrackPosition == position ? .isSelected : [])
        .accessibilityIdentifier("playlist.track.\(track.id)")
    }

    private var activeTrackPosition: Int? {
        guard let activeTrackID = store.activeTrackID else { return nil }
        let queueTrackIDs = store.queue.map(\.trackId)

        if !queueTrackIDs.isEmpty,
           let index = tracks.indices.first(where: { index in
               tracks[index...].map(\.id) == queueTrackIDs
           }) {
            return index + 1
        }

        let matchingPositions = tracks.indices.filter { tracks[$0].id == activeTrackID }
        guard matchingPositions.count == 1, let index = matchingPositions.first else { return nil }
        return index + 1
    }
}

struct PlaylistDetailToolbarControls: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(PlaylistCreationCoordinator.self) private var playlistCreation
    let playlist: Playlist
    @Bindable var state: PlaylistToolbarState
    let searchWidth: CGFloat
    let prefersCompact: Bool
    @Binding var isSearchExpanded: Bool

    var body: some View {
        HStack(spacing: ToolbarControlMetrics.spacing) {
            LibraryToolbarSearchField(
                searchText: $state.searchText,
                placeholder: "Pesquisar faixas",
                identifier: "playlist.tracks.search",
                prefersCompact: prefersCompact,
                expandedWidth: searchWidth,
                isExpanded: $isSearchExpanded
            )

            ToolbarOptionsButton(title: "Opções", systemImage: "ellipsis") {
                Button(playlist.isSmart ? "Editar regras" : "Editar playlist", systemImage: "pencil") {
                    if playlist.isSmart { state.isEditingSmartPlaylist = true }
                    else { playlistCreation.requestEdit(playlist) }
                }
                Button(playlist.isFavorite ? "Desfavoritar playlist" : "Favoritar playlist",
                       systemImage: playlist.isFavorite ? "star.slash" : "star") {
                    store.setPlaylistFavorite(playlistID: playlist.id, favorite: !playlist.isFavorite)
                }
                Divider()
                Button("Exportar M3U8 — caminhos relativos", systemImage: "square.and.arrow.up") {
                    state.exportRelativePaths = true
                }
                Button("Exportar M3U8 — caminhos absolutos", systemImage: "square.and.arrow.up") {
                    state.exportRelativePaths = false
                }
            }
            .accessibilityIdentifier("playlist.options")
            .playlistOptionsMenu(playlist: playlist)

            ToolbarOptionsButton(title: "Organizar ou filtrar faixas") {
                Picker("Organizar", selection: $state.order) {
                    ForEach(PlaylistTrackOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }
            }
            .accessibilityIdentifier("playlist.tracks.organize")
        }
    }
}
