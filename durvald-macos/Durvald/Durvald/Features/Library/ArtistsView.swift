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
        .onChange(of: onlyLocal) { _, _ in publishSummary() }
        .onChange(of: searchText) { _, _ in publishSummary() }
        .onChange(of: store.artists) { _, _ in publishSummary() }
        .task(id: "\(store.libraryCatalogRevision):\(store.core != nil)") {
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
        let localIDs = localArtistIDs ?? Set(store.tracks.map(\.artistId) + store.releases.map(\.artistId))
        return store.artists.filter {
            (!onlyLocal || localIDs.contains($0.id))
                && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))
        }
    }

    private func refreshSummary() async {
        let revision = store.libraryCatalogRevision
        let artistIDs: Set<Int64>
        do {
            async let tracks = store.completeCatalogTracks()
            async let releases = store.completeCatalogReleases()
            let catalog = try await (tracks, releases)
            artistIDs = Set(catalog.0.map(\.artistId) + catalog.1.map(\.artistId))
        } catch { return }
        guard !Task.isCancelled, revision == store.libraryCatalogRevision else { return }
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
