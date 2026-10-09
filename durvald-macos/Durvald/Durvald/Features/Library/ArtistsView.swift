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
    @AppStorage("artists.onlyLocal") private var onlyLocal = true
    @AppStorage("artists.listingOrder") private var listingOrder: CollectionListingOrder = .alphabetical
    @AppStorage(RatingPreferences.enabledKey) private var ratingsEnabled = true
    @Environment(DurvaldCoreStore.self) private var store
    @State private var lastPlayedByRelease: [Int64: String] = [:]
    @State private var localArtistIDs: Set<Int64>?
    @State private var completeReleases: [Release]?
    @State private var payloadRevision: UInt64 = 0
    @State private var orderingRevision: UInt64 = 0
    @State private var presentation = PreparedLibraryListing(ArtistListingSnapshot())

    let onSelectArtist: (Artist) -> Void
    var onSummaryChange: (String) -> Void = { _ in }

    var body: some View {
        CollectionListingLayout(
            mode: listingMode,
            mainGridMinimumCardWidth: ArtistsViewLayout.gridMinimumCardWidth,
            mainListArtworkSize: ArtistsViewLayout.portraitSize
        ) { availableSize in
            let portraitSize = min(availableSize, ArtistsViewLayout.portraitSize)
            ForEach(presentation.value.items, id: \.id) { artist in
                CollectionListingItem(
                    title: artist.name,
                    mode: listingMode,
                    artworkSize: portraitSize,
                    centersGridText: true,
                    action: { onSelectArtist(artist) }
                ) {
                    ArtistPortraitView(
                        artist: artist,
                        fallbackArtworkID: presentation.value.fallbackArtwork[artist.id],
                        size: portraitSize
                    )
                }
                .accessibilityIdentifier("artist.\(artist.id)")
            }
        }
        .overlay {
            if !normalizedSearchText.isEmpty && presentation.value.items.isEmpty && !presentation.isPreparing {
                ContentUnavailableView("Nenhum artista encontrado", systemImage: "magnifyingglass")
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
        .task(id: preparationKey) { await prepareListing() }
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func refreshSummary() async {
        let revision = store.libraryCatalogRevision
        let artistIDs: Set<Int64>
        let releases: [Release]
        do {
            async let tracks = store.completeCatalogTracks()
            async let loadedReleases = store.completeCatalogReleases()
            let catalog = try await (tracks, loadedReleases)
            artistIDs = Set(catalog.0.map(\.artistId) + catalog.1.map(\.artistId))
            releases = catalog.1
        } catch { return }
        guard !Task.isCancelled, revision == store.libraryCatalogRevision else { return }
        localArtistIDs = artistIDs
        completeReleases = releases
        payloadRevision &+= 1
    }

    private func prepareListing() async {
        let key = preparationKey
        let artists = store.artists
        let releases = completeReleases ?? store.releases
        let updates = store.releases
        let localIDs = localArtistIDs
        let loadedTracks = store.tracks
        let recency = lastPlayedByRelease
        await presentation.prepare(key: key, payload: (artists: artists, releases: releases, updates: updates, localIDs: localIDs, tracks: loadedTracks, recency: recency)) { payload in
            let updated = Dictionary(payload.updates.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            let current = payload.releases.map { updated[$0.id] ?? $0 }
            return ArtistListingSnapshot.build(artists: payload.artists, releases: current, localIDs: payload.localIDs ?? Set(payload.tracks.map(\.artistId) + current.map(\.artistId)), key: key, recency: payload.recency)
        }
        guard !Task.isCancelled else { return }
        onSummaryChange(presentation.value.summary)
    }

    private var preparationKey: LibraryListingKey {
        LibraryListingKey(storeID: ObjectIdentifier(store), catalogRevision: store.libraryCatalogRevision,
                          tracksRevision: store.tracksRevision, releasesRevision: store.releasesRevision,
                          artistsRevision: store.artistsRevision, payloadRevision: payloadRevision,
                          orderingRevision: orderingRevision, query: normalizedSearchText,
                          order: ratingsEnabled || listingOrder != .rating ? listingOrder : .alphabetical,
                          ratingsEnabled: ratingsEnabled, onlyLocal: onlyLocal)
    }

    private var orderingTaskID: String {
        "\(listingOrder.rawValue):\(store.libraryCatalogRevision):\(store.historyRepository.revision):\(store.core != nil)"
    }
}

struct ArtistPortraitView: View {
    @Environment(DurvaldCoreStore.self) private var store
    let artist: Artist
    let fallbackArtworkID: String?
    let size: CGFloat
    @State private var portraitArtworkID: String?
    @State private var loadedRequest: Request?

    private struct Request: Equatable {
        let artistID: Int64
        let coreID: ObjectIdentifier?
    }

    var body: some View {
        let request = Request(artistID: artist.id, coreID: store.core.map(ObjectIdentifier.init))
        let currentPortrait = loadedRequest == request ? portraitArtworkID : nil
        Group {
            if let artworkID = currentPortrait ?? fallbackArtworkID {
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
        .task(id: request) {
            let portrait = await store.artistDetails(
                artistId: artist.id,
                language: Locale.current.language.languageCode?.identifier ?? "en"
            )?.portrait?.managedPath
            guard !Task.isCancelled else { return }
            portraitArtworkID = portrait
            loadedRequest = request
        }
    }
}
