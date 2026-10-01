import SwiftUI

struct QueueView: View {
    private enum Panel: String, CaseIterable, Identifiable {
        case details = "Detalhes"
        case queue = "Fila"
        case lyrics = "Letra"

        var id: Self { self }
    }

    private static let pickerHeight: CGFloat = 52
    private static let headerHeight: CGFloat = 50
    private static let listTopInset: CGFloat = pickerHeight + headerHeight + 8

    @Environment(DurvaldCoreStore.self) private var store
    @Environment(TrackInfoCoordinator.self) private var trackInfo
    @Environment(PlaylistCreationCoordinator.self) private var playlistCreation
    @Environment(\.trackMenuNavigation) private var navigation
    @State private var menuTracks: [Int64: Track] = [:]
    @State private var selectedPanel: Panel = .queue
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                switch selectedPanel {
                case .details:
                    detailsPanel
                case .queue:
                    queuePanel
                case .lyrics:
                    lyricsPanel
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 0) {
                panelPicker

                if selectedPanel == .queue {
                    queueHeader
                }
            }
            .background(.ultraThinMaterial)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("queue.sidebar")
        .task(id: store.queue.map(\.trackId)) {
            for item in store.queue where menuTracks[item.trackId] == nil {
                guard !Task.isCancelled else { return }
                menuTracks[item.trackId] = try? await store.core?.track(trackId: item.trackId)
            }
        }
    }

    private var queuePanel: some View {
        // Size the AppKit viewport from the available space, not its document's
        // fitting size. The queue scrolls instead of raising the window minimum
        // during SwiftUI's size negotiation or a live resize.
        GeometryReader { geometry in
            QueueTableView(
                    rows: tableRows,
                    core: store.core,
                    isWindowActive: appearsActive,
                    topContentInset: Self.listTopInset,
                    onMove: { from, to in
                        store.moveQueueItem(from: from, to: to)
                    },
                    onPlay: { position in
                        Task {
                            await store.playQueueItem(at: position)
                        }
                    },
                    onTogglePlayback: {
                        Task {
                            await store.togglePause()
                        }
                    },
                    onRemove: { position in
                        Task {
                            await store.removeQueueItem(at: position)
                        }
                    },
                    onInfo: { trackInfo.open(trackID: $0) },
                    configureMenu: { controller, trackID in
                        guard let track = store.tracks.first(where: { $0.id == trackID })
                            ?? store.playback?.currentTrack.flatMap({ $0.id == trackID ? $0 : nil })
                            ?? menuTracks[trackID] else { return false }
                        controller.configure(track: track, store: store,
                            playlistCreation: playlistCreation, trackInfo: trackInfo,
                            navigation: navigation)
                        return true
                    }
            )
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }

    private var panelPicker: some View {
        HStack(spacing: 0) {
            ForEach(Panel.allCases) { panel in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selectedPanel = panel
                    }
                } label: {
                    Text(panel.rawValue)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background {
                            if selectedPanel == panel {
                                Capsule()
                                    .fill(.white.opacity(0.08))
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedPanel == panel ? .isSelected : [])
            }
        }
        .padding(3)
        .frame(maxWidth: .infinity)
        .glassEffect(.clear.interactive(), in: .capsule)
        .padding(.horizontal, 8)
        .frame(height: Self.pickerHeight)
    }

    private var queueHeader: some View {
        HStack {
            Text("Fila")
                .font(.headline)

            Spacer()

            Button("Limpar") {
                Task {
                    await store.clearQueue()
                }
            }
            .disabled(store.queue.count <= 1)
            .accessibilityIdentifier("queue.clear")
        }
        .padding(.horizontal, 8)
        .frame(height: Self.headerHeight)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    @ViewBuilder
    private var detailsPanel: some View {
        if let track = store.playback?.currentTrack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ArtworkView(artworkID: track.artworkId, size: 220)
                        .frame(maxWidth: .infinity)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title)
                            .font(.title2.weight(.semibold))
                        Text(track.artist)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text(track.release)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    LabeledContent("Duração", value: durationText(track.durationSeconds))
                    LabeledContent("Faixa", value: String(track.trackNumber))
                    LabeledContent("Reproduções", value: String(track.playCount))
                }
                .padding(16)
                .padding(.top, Self.pickerHeight)
            }
        } else {
            ContentUnavailableView(
                "Nenhuma faixa em reprodução",
                systemImage: "music.note"
            )
        }
    }

    @ViewBuilder
    private var lyricsPanel: some View {
        if let track = store.playback?.currentTrack {
            LyricsView(track: track, usesFixedPopoverSize: false)
                .padding(.top, Self.pickerHeight)
        } else {
            ContentUnavailableView(
                "Nenhuma faixa em reprodução",
                systemImage: "quote.bubble"
            )
        }
    }

    private func durationText(_ duration: Double) -> String {
        let seconds = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var tableRows: [QueueTableRow] {
        let tracksByID = Dictionary(store.tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let isPaused = store.isPlaybackPaused
        return store.queue.map { item in
            let track = tracksByID[item.trackId]
            let isCurrent = item.position == 0

            return QueueTableRow(
                trackID: item.trackId,
                position: item.position,
                title: track?.title ?? "Música #\(item.trackId)",
                artist: track?.artist ?? "",
                artworkID: track?.artworkId,
                isCurrent: isCurrent,
                isPaused: isCurrent && isPaused
            )
        }
    }
}
