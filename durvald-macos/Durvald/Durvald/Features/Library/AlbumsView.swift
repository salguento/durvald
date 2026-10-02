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

enum AlbumListingTypography {
    static let title = Font.system(
        size: NSFont.preferredFont(forTextStyle: .subheadline).pointSize + 1
    )
    static let secondary = Font.system(
        size: NSFont.preferredFont(forTextStyle: .caption1).pointSize + 1
    )
}

enum AlbumsViewLayout {
    static let gridMinimumCardWidth: CGFloat = 240
    static let listArtworkSize: CGFloat = 96
}

struct AlbumsView: View {
    @Binding var searchText: String
    @AppStorage("albums.listingMode") private var listingMode: CollectionListingMode = .standardGrid
    @AppStorage("albums.listingOrder") private var listingOrder: CollectionListingOrder = .recent
    @AppStorage("albums.minimumRating") private var minimumRating = 0
    @AppStorage(RatingPreferences.enabledKey) private var ratingsEnabled = true
    @Environment(DurvaldCoreStore.self) private var store
    @State private var lastPlayedByRelease: [Int64: String] = [:]

    @State private var completeReleases: [Release]?
    @State private var completeTracks: [Track] = []
    @State private var fileSizes: [String: Int64] = [:]
    @State private var isLoadingCatalog = true

    let onSelectAlbum: (Release) -> Void
    var onSummaryChange: (String) -> Void = { _ in }

    var body: some View {
        CollectionListingLayout(
            mode: listingMode,
            mainGridMinimumCardWidth: AlbumsViewLayout.gridMinimumCardWidth,
            mainListArtworkSize: AlbumsViewLayout.listArtworkSize
        ) { size in
            ForEach(orderedReleases, id: \.id) { release in
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
            } else if !normalizedSearchText.isEmpty && orderedReleases.isEmpty {
                ContentUnavailableView("Nenhum álbum encontrado", systemImage: "magnifyingglass")
            }
        }
        .onChange(of: searchText) { _, _ in publishSummary() }
        .task(id: "\(store.metadataRevision):\(store.core != nil):\(minimumRating):\(ratingsEnabled)") {
            await refreshSummary()
        }
        .task(id: orderingTaskID) {
            guard listingOrder == .recent, let core = store.core else { return }
            lastPlayedByRelease = (try? await core.releasePlaybackRecency())?.reduce(into: [:]) {
                if let releaseID = Int64($1.key) { $0[releaseID] = $1.value }
            } ?? [:]
        }
    }

    private func refreshSummary() async {
        isLoadingCatalog = true
        defer { if !Task.isCancelled { isLoadingCatalog = false } }
        var releases = store.releases
        var tracks = store.tracks
        if let core = store.core {
            do {
                releases = []
                var offset: UInt64 = 0
                while !Task.isCancelled {
                    let page = try await core.releasesPage(pageSize: 1_000, offset: offset)
                    releases.append(contentsOf: page.items)
                    guard let nextOffset = page.nextOffset, nextOffset > offset else { break }
                    offset = nextOffset
                }
                if !store.hasLoadedAllTracks {
                    tracks = []
                    offset = 0
                    while !Task.isCancelled {
                        let page = try await core.tracksPage(pageSize: 1_000, offset: offset)
                        tracks.append(contentsOf: page.items)
                        guard let nextOffset = page.nextOffset, nextOffset > offset else { break }
                        offset = nextOffset
                    }
                }
            } catch {
                return
            }
        }
        guard !Task.isCancelled else { return }
        let sizes = await MusicLibraryFileSizes.read(Array(Set(tracks.map(\.filePath))))
        guard !Task.isCancelled else { return }
        completeReleases = releases
        completeTracks = tracks
        fileSizes = sizes
        publishSummary()
    }

    private func publishSummary() {
        let releaseIDs = Set(filteredReleases.map(\.id))
        let tracks = completeTracks.filter { releaseIDs.contains($0.releaseId) }
        let summary = MusicLibrarySummary(tracks: tracks, kind: .all, fileSizes: fileSizes)
        let hours = summary.durationSeconds / 3600
        let minutes = (summary.durationSeconds / 60) % 60
        let duration = hours > 0
            ? "\(hours) \(hours == 1 ? "hora" : "horas"), \(minutes) \(minutes == 1 ? "minuto" : "minutos")"
            : "\(minutes) \(minutes == 1 ? "minuto" : "minutos")"
        let size = summary.totalBytes.map {
            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
        } ?? "—"
        let count = releaseIDs.count
        let prefix = normalizedSearchText.isEmpty ? "" : "Resultados para “\(normalizedSearchText)” • "
        onSummaryChange("\(prefix)\(count.formatted()) \(count == 1 ? "item" : "itens"), \(duration), \(size)")
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredReleases: [Release] {
        let updated = Dictionary(store.releases.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let query = normalizedSearchText
        return (completeReleases ?? store.releases).map { updated[$0.id] ?? $0 }.filter {
            (!ratingsEnabled || minimumRating == 0 || Int($0.rating ?? 0) >= minimumRating)
                && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
                    || $0.artist.localizedCaseInsensitiveContains(query))
        }
    }

    private var orderedReleases: [Release] {
        CollectionListingSorter.albums(
            filteredReleases,
            order: ratingsEnabled || listingOrder != .rating ? listingOrder : .recent,
            lastPlayedByRelease: lastPlayedByRelease
        )
    }

    private var orderingTaskID: String {
        "\(listingOrder.rawValue):\(store.core != nil)"
    }
}

struct AlbumCard: View {
    @Environment(DurvaldCoreStore.self) private var store

    let release: Release
    let onSelectAlbum: (Release) -> Void

    var subtitle: String? = nil
    /// Optional external fallback selected by the core. Callers must still
    /// prefer `release.artworkId`, which represents local/manual artwork.
    var fallbackArtworkID: String? = nil

    var artworkSize: CGFloat = AlbumGridLayout.cardWidth
    var titleLineLimit: Int = 1

    @State private var isHovered = false
    @FocusState private var isPlayFocused: Bool

    private var showsPlay: Bool {
        isHovered || isPlayFocused
    }

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
                            font: AlbumListingTypography.title
                        )
                            .lineLimit(titleLineLimit)

                        Text(subtitle ?? release.artist)
                            .font(AlbumListingTypography.secondary)
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

            ZStack(alignment: .bottomTrailing) {
                Color.clear
                    .allowsHitTesting(false)

                Button {
                    Task {
                        await store.playRelease(releaseID: release.id)
                    }
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
                .accessibilityLabel("Reproduzir o álbum \(release.title)")
                .accessibilityIdentifier("album.\(release.id).play")
                .help("Reproduzir álbum")
            }
            .frame(
                width: artworkSize,
                height: artworkSize
            )
            .animation(.easeInOut(duration: 0.12), value: showsPlay)
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
