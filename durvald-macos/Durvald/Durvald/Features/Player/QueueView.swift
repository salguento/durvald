import AppKit
import SwiftUI

private struct QueueArtistCard: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(\.trackMenuNavigation) private var navigation
    let artistID: Int64
    let artistName: String
    let width: CGFloat
    @State private var artist: Artist?
    @State private var portraitArtworkID: String?
    @State private var isInformationPresented = false
    @State private var isHovered = false
    @State private var informationSheetHeight: CGFloat = 500

    var body: some View {
        Button {
            let window = NSApp.keyWindow ?? NSApp.mainWindow
            let windowHeight = window?.contentView?.bounds.height ?? 628
            informationSheetHeight = max(1, windowHeight - 64 - 64)
            isInformationPresented = true
        } label: {
            ZStack(alignment: .bottomLeading) {
                ArtworkView(
                    artworkID: portraitArtworkID,
                    size: width,
                    aspectRatio: 1.4,
                    alignment: .top,
                    showsBorder: false
                )
                LinearGradient(
                    colors: [.clear, .black.opacity(0.65)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                Text(artistName)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .underline(isHovered)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: width, height: width / 1.4)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .disabled(artist == nil)
        .accessibilityLabel("Ver informações de \(artistName)")
        .task(id: artistID) {
            artist = nil
            portraitArtworkID = nil
            let loadedArtist = try? await store.core?.artist(artistId: artistID)
            let details = await store.artistDetails(
                artistId: artistID,
                language: Locale.current.language.languageCode?.identifier ?? "en"
            )
            guard !Task.isCancelled else { return }
            artist = loadedArtist
            portraitArtworkID = details?.portrait?.managedPath
        }
        .sheet(isPresented: $isInformationPresented) {
            if let artist {
                ArtistView(
                    artist: artist,
                    onSelectAlbum: navigation.album,
                    onSelectExternalRelease: { _ in },
                    onSelectArtist: navigation.artist,
                    informationOnly: true
                )
                .frame(width: 500, height: informationSheetHeight)
            }
        }
    }
}

struct QueueView: View {
    let topInset: CGFloat

    private enum Panel: String, CaseIterable, Identifiable {
        case details = "Detalhes"
        case queue = "Fila"
        case lyrics = "Letra"

        var id: Self { self }
    }

    private static let pickerHeight: CGFloat = 34
    private static let pickerFadeHeight: CGFloat = 24
    private static let contentTopSpacing: CGFloat = 18
    // Account for the first section label's 4 pt inset inside its row.
    private static let listTopInset: CGFloat = pickerHeight + contentTopSpacing - 4

    @Environment(DurvaldCoreStore.self) private var store
    @Environment(TrackInfoCoordinator.self) private var trackInfo
    @Environment(PlaylistCreationCoordinator.self) private var playlistCreation
    @Environment(\.trackMenuNavigation) private var navigation
    @State private var menuTracks: [Int64: Track] = [:]
    @State private var selectedPanel: Panel = .details
    @State private var isClearQueueConfirmationPresented = false
    @State private var isTrackLinkHovered = false
    @State private var isArtistLinkHovered = false
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

            Rectangle()
                .fill(.ultraThinMaterial)
                .frame(height: topInset + Self.pickerHeight + Self.pickerFadeHeight)
                .mask {
                    VStack(spacing: 0) {
                        Rectangle()
                            .frame(height: topInset + Self.pickerHeight)
                        LinearGradient(
                            colors: [.black, .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: Self.pickerFadeHeight)
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            panelPicker
                .padding(.top, topInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("queue.sidebar")
        .alert("Limpar a fila?", isPresented: $isClearQueueConfirmationPresented) {
            Button("Cancelar", role: .cancel) {}
            Button("Limpar fila", role: .destructive) {
                Task {
                    await store.clearQueue()
                }
            }
        } message: {
            Text("Tem certeza de que deseja limpar a fila? Essa ação não pode ser desfeita.")
        }
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
                    topContentInset: topInset + Self.listTopInset,
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
                    onClear: {
                        isClearQueueConfirmationPresented = true
                    },
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
            .frame(width: max(0, geometry.size.width - 12), height: geometry.size.height)
            .padding(.horizontal, 6)
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
                        .contentShape(Rectangle())
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
        .frame(height: Self.pickerHeight, alignment: .bottom)
    }

    @ViewBuilder
    private var detailsPanel: some View {
        if let track = store.playback?.currentTrack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 8) {
                            ArtworkView(
                                artworkID: track.artworkId,
                                size: max(0, geometry.size.width - 28)
                            )
                            .trackContextMenu(track: track, onPlay: {
                                Task { await store.play(trackID: track.id) }
                            })

                            HStack(alignment: .center, spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Button {
                                        Task {
                                            if let album = try? await store.core?.release(releaseId: track.releaseId) {
                                                navigation.album(album)
                                            }
                                        }
                                    } label: {
                                        Text(track.title)
                                            .font(.title2.weight(.semibold))
                                            .underline(isTrackLinkHovered)
                                    }
                                    .buttonStyle(.plain)
                                    .onHover { isTrackLinkHovered = $0 }
                                    .trackContextMenu(track: track, onPlay: {
                                        Task { await store.play(trackID: track.id) }
                                    })
                                    .accessibilityHint("Abrir página do álbum")

                                    Button {
                                        Task {
                                            if let artist = try? await store.core?.artist(artistId: track.artistId) {
                                                navigation.artist(artist)
                                            }
                                        }
                                    } label: {
                                        Text(track.artist)
                                            .font(.headline)
                                            .underline(isArtistLinkHovered)
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .onHover { isArtistLinkHovered = $0 }
                                    .accessibilityHint("Abrir página do artista")
                                    .contextMenu {
                                        Button("Abrir artista", systemImage: "music.mic") {
                                            Task {
                                                if let artist = try? await store.core?.artist(artistId: track.artistId) {
                                                    navigation.artist(artist)
                                                }
                                            }
                                        }
                                        Button("Copiar nome do artista", systemImage: "doc.on.doc") {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(track.artist, forType: .string)
                                        }
                                    }
                                }
                                .padding(.leading, 2)
                                Spacer(minLength: 8)

                                Button {
                                    Task {
                                        await store.setTrackFavorite(trackID: track.id, favorite: !track.isFavorite)
                                    }
                                } label: {
                                    Image(systemName: track.isFavorite ? "star.fill" : "star")
                                        .foregroundStyle(track.isFavorite ? Color.accentColor : .secondary)
                                        .frame(width: 28, height: 28)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(track.isFavorite ? "Desfavoritar faixa" : "Favoritar faixa")
                                .accessibilityLabel(track.isFavorite ? "Desfavoritar faixa" : "Favoritar faixa")
                                .accessibilityIdentifier("queue.details.favorite")
                            }
                        }

                        QueueArtistCard(
                            artistID: track.artistId,
                            artistName: track.artist,
                            width: max(0, geometry.size.width - 28)
                        )
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .padding(.top, topInset + Self.pickerHeight + Self.contentTopSpacing - 10)
                }
            }
        } else {
            ContentUnavailableView(
                "Nenhuma faixa em reprodução",
                systemImage: "music.note"
            )
            .padding(.top, topInset + Self.pickerHeight + Self.contentTopSpacing)
        }
    }

    @ViewBuilder
    private var lyricsPanel: some View {
        if let track = store.playback?.currentTrack {
            LyricsView(track: track, usesFixedPopoverSize: false, horizontalPadding: 14)
                // LyricsView already includes 18 pt of internal padding.
                .padding(.top, topInset + Self.pickerHeight + Self.contentTopSpacing - 18)
        } else {
            ContentUnavailableView(
                "Nenhuma faixa em reprodução",
                systemImage: "quote.bubble"
            )
            .padding(.top, topInset + Self.pickerHeight + Self.contentTopSpacing)
        }
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
