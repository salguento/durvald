import SwiftUI
import UniformTypeIdentifiers

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

    private enum TrackOrder: String, CaseIterable, Identifiable {
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
    @State private var trackSearchText = ""
    @State private var trackOrder: TrackOrder = .playlist
    @State private var draggedTrackPosition: Int?
    @State private var trackDropTarget: TrackDropTarget?
    @State private var isCompletingTrackDrop = false
    @State private var isPersistingTrackOrder = false
    @FocusState private var isTrackSearchFocused: Bool

    private let artworkSize: CGFloat = 268

    private var currentPlaylist: Playlist {
        store.playlists.first(where: { $0.id == playlist.id }) ?? playlist
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                trackList
                VStack(alignment: .leading, spacing: 10) {
                    Divider()
                    PlaylistMusicPicker(playlist: currentPlaylist) { track in
                        tracks.append(track)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                        playlistCreation.requestEdit(currentPlaylist)
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

                    Text("\(currentPlaylist.trackCount) músicas")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, minHeight: artworkSize, alignment: .topLeading)
            }

            HStack(spacing: 10) {
                CollectionPlaybackControls(
                    isEnabled: !isLoading && !tracks.isEmpty,
                    presentation: .groupedCompactShuffle,
                    controlHeight: 36,
                    isFavorite: currentPlaylist.isFavorite,
                    onToggleFavorite: {
                        store.setPlaylistFavorite(
                            playlistID: playlist.id,
                            favorite: !currentPlaylist.isFavorite
                        )
                    },
                    onPlay: {
                        guard !tracks.isEmpty else { return }
                        Task {
                            await store.playPlaylist(
                                playlistID: playlist.id,
                                startingAtPosition: 0,
                                shuffleEnabled: false
                            )
                        }
                    },
                    onShuffle: {
                        guard !tracks.isEmpty else { return }
                        Task {
                            await store.playPlaylist(
                                playlistID: playlist.id,
                                startingAtPosition: 0,
                                shuffleEnabled: true
                            )
                        }
                    }
                )

                Spacer(minLength: 24)

                Menu {
                    Button("Editar playlist", systemImage: "pencil") {
                        playlistCreation.requestEdit(currentPlaylist)
                    }
                    Button(currentPlaylist.isFavorite ? "Desfavoritar playlist" : "Favoritar playlist",
                           systemImage: currentPlaylist.isFavorite ? "star.slash" : "star") {
                        store.setPlaylistFavorite(
                            playlistID: playlist.id,
                            favorite: !currentPlaylist.isFavorite
                        )
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 36, height: 36)
                }
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .background(Color.primary.opacity(0.08), in: .circle)
                .help("Opções")
                .accessibilityLabel("Opções")
                .accessibilityIdentifier("playlist.options")

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)

                    TextField("Pesquisar", text: $trackSearchText)
                        .textFieldStyle(.plain)
                        .focused($isTrackSearchFocused)
                        .onExitCommand {
                            trackSearchText = ""
                            isTrackSearchFocused = false
                        }
                }
                .padding(.horizontal, 12)
                .frame(width: 147, height: 36)
                .background(Color.primary.opacity(0.08), in: .capsule)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("playlist.tracks.search")

                Menu {
                    Picker("Organizar", selection: $trackOrder) {
                        ForEach(TrackOrder.allCases) { order in
                            Text(order.title).tag(order)
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .frame(width: 36, height: 36)
                }
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .background(Color.primary.opacity(0.08), in: .capsule)
                .help("Organizar ou filtrar faixas")
                .accessibilityLabel("Organizar ou filtrar faixas")
                .accessibilityIdentifier("playlist.tracks.organize")
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
            ContentUnavailableView.search(text: trackSearchText)
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
        trackOrder == .playlist
            && trackSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canReorderTracks: Bool { isReorderMode && !isPersistingTrackOrder }

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
        let query = trackSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
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

        switch trackOrder {
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

        return HStack(spacing: 12) {
            AlbumTrackPosition(
                trackID: track.id,
                number: "\(position)",
                isActiveOverride: isActive
            )
                .offset(x: -6)

            ArtworkView(artworkID: track.artworkId, size: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .foregroundStyle(isActive ? Color.accentColor : Color.primary)
                    .lineLimit(1)

                if !track.artist.isEmpty {
                    Text(track.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(durationText(track.durationSeconds))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Button {
                Task { await store.addToQueue(trackID: track.id) }
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Adicionar \(track.title) à fila")
        }
        .padding(.vertical, 8)
        .padding(.trailing, 16)
        .playTrackOnDoubleClick {
            Task {
                await store.playPlaylist(
                    playlistID: playlist.id,
                    startingAtPosition: position - 1
                )
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
                await store.playPlaylist(
                    playlistID: playlist.id,
                    startingAtPosition: position - 1
                )
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

    private func durationText(_ duration: Double) -> String {
        let totalSeconds = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}
