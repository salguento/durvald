//
//  AlbumsView.swift
//  Durvald
//
//  Created by Humberto Salguento on 21/08/26.
//

import SwiftUI

enum AlbumGridLayout {
    static let cardWidth: CGFloat = 192
    static let spacing: CGFloat = 16
    static let horizontalPadding: CGFloat = 24

    static func columnCount(
        for availableWidth: CGFloat,
        minimumCardWidth: CGFloat = cardWidth,
        padding: CGFloat = horizontalPadding,
        gap: CGFloat = spacing
    ) -> Int {
        let usableWidth = max(1, availableWidth - padding * 2)
        return max(1, Int((usableWidth + gap) / (minimumCardWidth + gap)))
    }

    static func cardSize(
        for availableWidth: CGFloat,
        minimumCardWidth: CGFloat = cardWidth,
        padding: CGFloat = horizontalPadding,
        gap: CGFloat = spacing
    ) -> CGFloat {
        let usableWidth = max(1, availableWidth - padding * 2)
        let count = columnCount(for: availableWidth, minimumCardWidth: minimumCardWidth, padding: padding, gap: gap)
        return max(1, (usableWidth - CGFloat(count - 1) * gap) / CGFloat(count))
    }

    static func columns(
        for availableWidth: CGFloat,
        minimumCardWidth: CGFloat = cardWidth,
        padding: CGFloat = horizontalPadding,
        gap: CGFloat = spacing
    ) -> [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 0), spacing: gap, alignment: .top),
            count: columnCount(for: availableWidth, minimumCardWidth: minimumCardWidth, padding: padding, gap: gap)
        )
    }
}

enum AlbumsViewLayout {
    static let gridMinimumCardWidth: CGFloat = 240
    static let listArtworkSize: CGFloat = 96
}

struct AlbumsView: View {
    @Binding var searchText: String
    @AppStorage("albums.listingMode") private var listingMode: CollectionListingMode = .standardGrid
    @AppStorage("albums.listingOrder") private var listingOrder: CollectionListingOrder = .recent
    @AppStorage("albums.minimumRating.halfSteps") private var minimumRating = 0
    @AppStorage(RatingPreferences.enabledKey) private var ratingsEnabled = true
    @Environment(DurvaldCoreStore.self) private var store
    @State private var lastPlayedByRelease: [Int64: String] = [:]

    @State private var completeReleases: [Release]?
    @State private var completeTracks: [Track] = []
    @State private var fileSizes: [String: Int64] = [:]
    @State private var isLoadingCatalog = true
    @State private var payloadRevision: UInt64 = 0
    @State private var orderingRevision: UInt64 = 0
    @State private var presentation = PreparedLibraryListing(AlbumListingSnapshot())

    let onSelectAlbum: (Release) -> Void
    var onSummaryChange: (String) -> Void = { _ in }

    var body: some View {
        CollectionListingLayout(
            mode: listingMode,
            mainGridMinimumCardWidth: AlbumsViewLayout.gridMinimumCardWidth,
            mainListArtworkSize: AlbumsViewLayout.listArtworkSize
        ) { size in
            ForEach(presentation.value.items, id: \.id) { release in
                CollectionListingItem(title: release.title, subtitle: release.artist, isFavorite: release.isFavorite, mode: listingMode, artworkSize: size, action: { onSelectAlbum(release) }) {
                    ArtworkView(artworkID: release.artworkId, size: size)
                }
                .albumContextMenu(album: release)
                .accessibilityIdentifier("album.\(release.id)")
                .task { await store.loadMoreReleases(ifNeededAfter: release.id) }
            }
        }
        .overlay {
            if !normalizedSearchText.isEmpty && isLoadingCatalog {
                ProgressView("Pesquisando…")
            } else if !normalizedSearchText.isEmpty && presentation.value.items.isEmpty && !presentation.isPreparing {
                ContentUnavailableView("Nenhum álbum encontrado", systemImage: "magnifyingglass")
            }
        }
        .task(id: "\(store.libraryCatalogRevision):\(store.core != nil)") {
            await refreshSummary()
        }
        .task(id: orderingTaskID) {
            guard listingOrder == .recent, let core = store.core else { return }
            let recency: [Int64: String] = (try? await core.releasePlaybackRecency())?.reduce(into: [:]) {
                if let releaseID = Int64($1.key) { $0[releaseID] = $1.value }
            } ?? [:]
            guard !Task.isCancelled else { return }
            lastPlayedByRelease = recency
            orderingRevision &+= 1
        }
        .task(id: preparationKey) {
            await prepareListing()
        }
    }

    private func refreshSummary() async {
        isLoadingCatalog = true
        defer { if !Task.isCancelled { isLoadingCatalog = false } }
        let revision = store.libraryCatalogRevision
        let releases: [Release]
        let tracks: [Track]
        do {
            async let loadedReleases = store.completeCatalogReleases()
            async let loadedTracks = store.completeCatalogTracks()
            (releases, tracks) = try await (loadedReleases, loadedTracks)
        } catch { return }
        guard !Task.isCancelled, revision == store.libraryCatalogRevision else { return }
        guard let sizes = try? await store.fileSizes(for: Array(Set(tracks.map(\.filePath)))) else { return }
        guard !Task.isCancelled, revision == store.libraryCatalogRevision else { return }
        completeReleases = releases
        completeTracks = tracks
        fileSizes = sizes
        payloadRevision &+= 1
    }

    private func prepareListing() async {
        let key = preparationKey
        let releases = completeReleases ?? store.releases
        let updates = store.releases
        let tracks = completeTracks
        let sizes = fileSizes
        let recency = lastPlayedByRelease
        await presentation.prepare(key: key, payload: (releases, updates, tracks, sizes, recency)) { payload in
            AlbumListingSnapshot.build(releases: payload.0, updates: payload.1, tracks: payload.2, sizes: payload.3, key: key, recency: payload.4)
        }
        guard !Task.isCancelled else { return }
        onSummaryChange(presentation.value.summary)
    }

    private var preparationKey: LibraryListingKey {
        LibraryListingKey(storeID: ObjectIdentifier(store), catalogRevision: store.libraryCatalogRevision,
                          releasesRevision: store.releasesRevision, payloadRevision: payloadRevision,
                          orderingRevision: orderingRevision, query: normalizedSearchText,
                          order: ratingsEnabled || listingOrder != .rating ? listingOrder : .recent,
                          minimumRating: minimumRating, ratingsEnabled: ratingsEnabled)
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var orderingTaskID: String {
        "\(listingOrder.rawValue):\(store.libraryCatalogRevision):\(store.historyRepository.revision):\(store.core != nil)"
    }
}

struct AlbumCard: View {
    let release: Release
    let onSelectAlbum: (Release) -> Void

    var subtitle: String? = nil
    /// Optional external fallback selected by the core. Callers must still
    /// prefer `release.artworkId`, which represents local/manual artwork.
    var fallbackArtworkID: String? = nil

    var artworkSize: CGFloat = AlbumGridLayout.cardWidth
    var titleLineLimit: Int = 1

    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Button {
                onSelectAlbum(release)
            } label: {
                VStack(alignment: .leading, spacing: 7) {
                    ArtworkView(
                        artworkID: release.artworkId ?? fallbackArtworkID,
                        size: artworkSize
                    )

                    VStack(alignment: .leading, spacing: 0) {
                        AlbumTitleLabel(
                            title: release.title,
                            isFavorite: release.isFavorite,
                            font: LibraryTypography.listingTitle
                        )
                            .lineLimit(titleLineLimit)

                        Text(subtitle ?? release.artist)
                            .font(LibraryTypography.listingSecondary)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(
                        width: artworkSize,
                        alignment: .leading
                    )
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Abrir \(release.title), de \(release.artist)")
            .accessibilityIdentifier("album.\(release.id)")

            AlbumArtworkPlayOverlay(releaseID: release.id, title: release.title,
                                    artworkSize: artworkSize, isHovered: isHovered)
        }
        .frame(width: artworkSize, alignment: .leading)
        .contentShape(Rectangle())
        .albumContextMenu(album: release)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}

/// Shared hover and keyboard-focus playback control for album artwork.
struct AlbumArtworkPlayOverlay: View {
    @Environment(DurvaldCoreStore.self) private var store
    let releaseID: Int64
    let title: String
    let artworkSize: CGFloat
    let isHovered: Bool
    @FocusState private var isPlayFocused: Bool
    private var showsPlay: Bool { isHovered || isPlayFocused }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.clear.allowsHitTesting(false)
            Button {
                Task { await store.playRelease(releaseID: releaseID) }
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(AlbumPlayButtonStyle())
            .focused($isPlayFocused)
            .opacity(showsPlay ? 1 : 0)
            .allowsHitTesting(showsPlay)
            .padding(8)
            .accessibilityLabel("Reproduzir o álbum \(title)")
            .accessibilityIdentifier("album.\(releaseID).play")
            .help("Reproduzir álbum")
        }
        .frame(width: artworkSize, height: artworkSize)
        .animation(.easeInOut(duration: 0.12), value: showsPlay)
    }
}

private struct AlbumPlayButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background {
                Circle()
                    .fill(Color(white: configuration.isPressed ? 0.22 : (isHovered ? 0.30 : 0.42)))
            }
            .contentShape(Circle())
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
