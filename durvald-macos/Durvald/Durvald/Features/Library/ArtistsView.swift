//
//  ArtistsView.swift
//  Durvald
//
//  Created by Humberto Salguento on 21/08/26.
//

import SwiftUI

enum ArtistsViewLayout {
    static let portraitSize: CGFloat = 104
    static let gridMinimumCardWidth: CGFloat = 120
}

struct ArtistsView: View {
    @AppStorage("artists.listingMode") private var listingMode: CollectionListingMode = .standardGrid
    @AppStorage("artists.listingOrder") private var listingOrder: CollectionListingOrder = .alphabetical
    @AppStorage(RatingPreferences.enabledKey) private var ratingsEnabled = true
    @Environment(DurvaldCoreStore.self) private var store
    @State private var lastPlayedByRelease: [Int64: String] = [:]

    let onSelectArtist: (Artist) -> Void

    var body: some View {
        CollectionListingLayout(
            mode: listingMode,
            mainGridMinimumCardWidth: ArtistsViewLayout.gridMinimumCardWidth,
            mainListArtworkSize: ArtistsViewLayout.portraitSize
        ) { availableSize in
            let portraitSize = min(availableSize, ArtistsViewLayout.portraitSize)
            ForEach(orderedArtists, id: \.id) { artist in
                CollectionListingItem(
                    title: artist.name,
                    mode: listingMode,
                    artworkSize: portraitSize,
                    centersGridText: true,
                    action: { onSelectArtist(artist) }
                ) {
                    ArtistPortraitView(
                        artist: artist,
                        fallbackArtworkID: fallbackArtworkID(for: artist),
                        size: portraitSize
                    )
                }
                .accessibilityIdentifier("artist.\(artist.id)")
            }
        }
        .task(id: orderingTaskID) {
            guard listingOrder == .recent, let core = store.core else { return }
            lastPlayedByRelease = (try? await core.releasePlaybackRecency())?.reduce(into: [:]) {
                if let releaseID = Int64($1.key) { $0[releaseID] = $1.value }
            } ?? [:]
        }
    }

    private var orderedArtists: [Artist] {
        CollectionListingSorter.artists(
            store.artists,
            order: ratingsEnabled || listingOrder != .rating ? listingOrder : .alphabetical,
            releases: store.releases,
            lastPlayedByRelease: lastPlayedByRelease
        )
    }

    private func fallbackArtworkID(for artist: Artist) -> String? {
        store.releases.first { $0.artistId == artist.id }?.artworkId
    }

    private var orderingTaskID: String {
        "\(listingOrder.rawValue):\(store.core != nil)"
    }
}

struct ArtistPortraitView: View {
    @Environment(DurvaldCoreStore.self) private var store
    let artist: Artist
    let fallbackArtworkID: String?
    let size: CGFloat
    @State private var portraitArtworkID: String?

    var body: some View {
        Group {
            if let artworkID = portraitArtworkID ?? fallbackArtworkID {
                ArtworkView(
                    artworkID: artworkID,
                    size: size,
                    aspectRatio: 1,
                    alignment: .center,
                    showsBorder: false
                )
            } else {
                ZStack {
                    Circle().fill(.tertiary)
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.37))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle().strokeBorder(.primary.opacity(0.08), lineWidth: 1)
        }
        .task(id: artist.id) {
            portraitArtworkID = await store.artistDetails(
                artistId: artist.id,
                language: Locale.current.language.languageCode?.identifier ?? "en"
            )?.portrait?.managedPath
        }
    }
}
