//
//  AlbumsView.swift
//  Durvald
//
//  Created by Humberto Salguento on 21/08/26.
//

import SwiftUI

struct AlbumsView: View {
    @EnvironmentObject private var store: DurvaldCoreStore

    let onSelectAlbum: (Release) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 180), spacing: 20)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: columns,
                alignment: .leading,
                spacing: 24
            ) {
                ForEach(store.releases, id: \.id) { release in
                    AlbumCard(
                        release: release,
                        onSelectAlbum: onSelectAlbum
                    )
                }
            }
            .padding(20)
        }
    }
}

private struct AlbumCard: View {
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
                        size: 160
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
                    .frame(width: 160, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Abrir \(release.title), de \(release.artist)")
            .accessibilityIdentifier("album.\(release.id)")

            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.black.opacity(showsPlay ? 0.28 : 0))
                    .allowsHitTesting(false)

                Button {
                    Task {
                        await store.playRelease(releaseID: release.id)
                    }
                } label: {
                    Image(systemName: "play.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.65), in: Circle())
                }
                .buttonStyle(.plain)
                .focused($isPlayFocused)
                .opacity(showsPlay ? 1 : 0)
                .allowsHitTesting(showsPlay)
                .accessibilityLabel("Reproduzir o álbum \(release.title)")
                .accessibilityIdentifier("album.\(release.id).play")
                .help("Reproduzir álbum")
            }
            .frame(width: 160, height: 160)
        }
        .frame(width: 160, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}
