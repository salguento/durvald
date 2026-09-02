//
//  AlbumsView.swift
//  Durvald
//
//  Created by Humberto Salguento on 21/08/26.
//

import SwiftUI

enum AlbumGridLayout {
    static let cardWidth: CGFloat = 160
    static let spacing: CGFloat = 12
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

struct AlbumsView: View {
    @EnvironmentObject private var store: DurvaldCoreStore

    let onSelectAlbum: (Release) -> Void

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                LazyVGrid(
                    columns: AlbumGridLayout.columns(
                        for: proxy.size.width
                    ),
                    alignment: .leading,
                    spacing: AlbumGridLayout.spacing
                ) {
                    ForEach(store.releases, id: \.id) { release in
                        AlbumCard(
                            release: release,
                            onSelectAlbum: onSelectAlbum
                        )
                    }
                }
                .padding(.horizontal, AlbumGridLayout.horizontalPadding)
                .padding(.vertical, 24)
            }
        }
    }
}

struct AlbumCard: View {
    @EnvironmentObject private var store: DurvaldCoreStore

    let release: Release
    let onSelectAlbum: (Release) -> Void

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
                VStack(alignment: .leading, spacing: 8) {
                    ArtworkView(
                        artworkID: release.artworkId,
                        size: AlbumGridLayout.cardWidth
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(release.title)
                            .font(.headline)
                            .lineLimit(1)

                        Text(release.artist)
                            .font(.caption)
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
