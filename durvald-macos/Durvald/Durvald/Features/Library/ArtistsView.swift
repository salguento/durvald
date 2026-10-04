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
    @Binding var searchText: String
    @AppStorage("artists.listingMode") private var listingMode: CollectionListingMode = .standardGrid
    @AppStorage("artists.listingOrder") private var listingOrder: CollectionListingOrder = .alphabetical
    @AppStorage(RatingPreferences.enabledKey) private var ratingsEnabled = true
    @Environment(DurvaldCoreStore.self) private var store
    @State private var lastPlayedByRelease: [Int64: String] = [:]
    @State private var localArtistIDs: Set<Int64>?

    let onSelectArtist: (Artist) -> Void
    var onSummaryChange: (String) -> Void = { _ in }

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
        .overlay {
            if !normalizedSearchText.isEmpty && filteredArtists.isEmpty {
                ContentUnavailableView("Nenhum artista encontrado", systemImage: "magnifyingglass")
            }
        }
        .onChange(of: searchText) { _, _ in publishSummary() }
        .onChange(of: store.artists) { _, _ in publishSummary() }
        .task(id: "\(store.metadataRevision):\(store.core != nil)") {
            await refreshSummary()
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
            filteredArtists,
            order: ratingsEnabled || listingOrder != .rating ? listingOrder : .alphabetical,
            releases: store.releases,
            lastPlayedByRelease: lastPlayedByRelease
        )
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredArtists: [Artist] {
        let query = normalizedSearchText
        return store.artists.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }

    private func refreshSummary() async {
        var artistIDs = Set(store.tracks.map(\.artistId))
        artistIDs.formUnion(store.releases.map(\.artistId))
        if let core = store.core {
            do {
                if !store.hasLoadedAllTracks {
                    var offset: UInt64 = 0
                    while !Task.isCancelled {
                        let page = try await core.tracksPage(pageSize: 1_000, offset: offset)
                        artistIDs.formUnion(page.items.map(\.artistId))
                        guard let nextOffset = page.nextOffset, nextOffset > offset else { break }
                        offset = nextOffset
                    }
                }
                var offset: UInt64 = 0
                while !Task.isCancelled {
                    let page = try await core.releasesPage(pageSize: 1_000, offset: offset)
                    artistIDs.formUnion(page.items.map(\.artistId))
                    guard let nextOffset = page.nextOffset, nextOffset > offset else { break }
                    offset = nextOffset
                }
            } catch {
                return
            }
        }
        guard !Task.isCancelled else { return }
        localArtistIDs = artistIDs
        publishSummary()
    }

    private func publishSummary() {
        guard let localArtistIDs else {
            onSummaryChange("Carregando…")
            return
        }
        let artists = filteredArtists
        let localCount = artists.filter { localArtistIDs.contains($0.id) }.count
        let indexedCount = artists.count - localCount
        let localText = "\(localCount.formatted()) \(localCount == 1 ? "artista local" : "artistas locais")"
        let indexedText = "\(indexedCount.formatted()) \(indexedCount == 1 ? "artista indexado" : "artistas indexados")"
        let prefix = normalizedSearchText.isEmpty ? "" : "Resultados para “\(normalizedSearchText)” • "
        onSummaryChange("\(prefix)\(localText), \(indexedText)")
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
