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

struct AlbumsView: View {
    @AppStorage("albums.listingMode") private var listingMode: CollectionListingMode = .standardGrid
    @AppStorage("albums.listingOrder") private var listingOrder: CollectionListingOrder = .recent
    @Environment(DurvaldCoreStore.self) private var store
    @State private var orderingTracks: [Track] = []

    let onSelectAlbum: (Release) -> Void

    var body: some View {
        CollectionListingLayout(mode: listingMode) { size in
            ForEach(orderedReleases, id: \.id) { release in
                CollectionListingItem(title: release.title, subtitle: release.artist, isFavorite: release.isFavorite, mode: listingMode, artworkSize: size, action: { onSelectAlbum(release) }) {
                    ArtworkView(artworkID: release.artworkId, size: size)
                }
                .albumContextMenu(album: release)
                .accessibilityIdentifier("album.\(release.id)")
                .task { await store.loadMoreReleases(ifNeededAfter: release.id) }
            }
        }
        .task(id: orderingTaskID) {
            guard listingOrder == .recent else { return }
            orderingTracks = (try? await store.core?.tracks()) ?? store.tracks
        }
    }

    private var orderedReleases: [Release] {
        CollectionListingSorter.albums(
            store.releases,
            order: listingOrder,
            tracks: orderingTracks.isEmpty ? store.tracks : orderingTracks
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
