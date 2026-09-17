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

    static func columnCount(for availableWidth: CGFloat) -> Int {
        let usableWidth = max(
            availableWidth - (horizontalPadding * 2),
            cardWidth
        )

        return max(
            Int((usableWidth + spacing) / (cardWidth + spacing)),
            1
        )
    }

    static func columns(for availableWidth: CGFloat) -> [GridItem] {
        Array(
            repeating: GridItem(
                .fixed(cardWidth),
                spacing: spacing,
                alignment: .top
            ),
            count: columnCount(for: availableWidth)
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
    @Environment(DurvaldCoreStore.self) private var store

    let onSelectAlbum: (Release) -> Void

    var body: some View {
        CollectionListingLayout(mode: listingMode) { size in
            ForEach(store.releases, id: \.id) { release in
                Group {
                    if listingMode == .standardGrid && size == AlbumGridLayout.cardWidth {
                        AlbumCard(release: release, onSelectAlbum: onSelectAlbum)
                    } else {
                        CollectionListingItem(title: release.title, subtitle: release.artist, mode: listingMode, artworkSize: size, action: { onSelectAlbum(release) }) {
                            ArtworkView(artworkID: release.artworkId, size: size)
                        }
                        .albumContextMenu(album: release)
                    }
                }
                .accessibilityIdentifier("album.\(release.id)")
                .task { await store.loadMoreReleases(ifNeededAfter: release.id) }
            }
        }
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
                        size: AlbumGridLayout.cardWidth
                    )

                    VStack(alignment: .leading, spacing: 0) {
                        Text(release.title)
                            .font(AlbumListingTypography.title)
                            .lineLimit(1)

                        Text(subtitle ?? release.artist)
                            .font(AlbumListingTypography.secondary)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(
                        width: AlbumGridLayout.cardWidth,
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
                width: AlbumGridLayout.cardWidth,
                height: AlbumGridLayout.cardWidth
            )
            .animation(.easeInOut(duration: 0.12), value: showsPlay)
        }
        .frame(width: AlbumGridLayout.cardWidth, alignment: .leading)
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
