import Foundation
import Observation

/// Lives with the window, so navigation does not discard catalog and sort caches.
@MainActor
@Observable
final class MusicLibraryPresentation {
    struct CatalogRequest: Equatable {
        let storeID: ObjectIdentifier
        let tracksRevision: UInt64
        let metadataRevision: Int
        let hasLoadedAllTracks: Bool
        let coreID: ObjectIdentifier?
    }

    struct DisplayKey: Equatable {
        var storeID: ObjectIdentifier? = nil
        var coreID: ObjectIdentifier? = nil
        var tracksRevision: UInt64 = 0
        var metadataRevision: Int = 0
        var catalogRevision: UInt64 = 0
        var searchRevision: UInt64 = 0
        var query = ""
        var usesLocalSearch = false
        var onlyFavorites = false
        var sort: MusicLibrarySort = .title
        var ascending = true
    }

    /// Arrays are payload, never part of SwiftUI's task identity.
    struct DisplayRequest {
        let tracks: [Track]
        let query: String
        let onlyFavorites: Bool
        let sort: MusicLibrarySort
        let ascending: Bool
        var updatedTracks: [Track] = []
    }

    private(set) var catalog: [Track]?
    private(set) var catalogVersion: UInt64 = 0
    private(set) var displayRevision: UInt64 = 0
    private(set) var displayedTracks: [Track] = []
    private(set) var librarySummary: MusicLibrarySummary?
    var fileSizes: [String: Int64] = [:]
    private var catalogRevision: Int?
    private var catalogStoreID: ObjectIdentifier?
    private var catalogCoreID: ObjectIdentifier?
    @ObservationIgnored private var completedCatalogRequest: CatalogRequest?
    @ObservationIgnored private var completedDisplayKey: DisplayKey?
    @ObservationIgnored private var catalogGeneration = UUID()
    @ObservationIgnored private var displayGeneration = UUID()

    func sourceTracks(store: DurvaldCoreStore, searchResults: [Track]?, query: String, usesLocalSearch: Bool) -> [Track] {
        if !query.isEmpty {
            return usesLocalSearch ? store.tracks : (searchResults ?? [])
        }
        if catalogStoreID == ObjectIdentifier(store), catalogRevision == store.metadataRevision, catalogCoreID == store.core.map(ObjectIdentifier.init), let catalog {
            return catalog
        }
        return store.tracks
    }

    func prepare(_ request: DisplayRequest, key: DisplayKey) async {
        let generation = UUID()
        displayGeneration = generation
        guard key != completedDisplayKey else { return }
        let task = Task.detached(priority: .userInitiated) {
            Self.sortedTracks(request)
        }
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: { task.cancel() }
        guard !Task.isCancelled, generation == displayGeneration else { return }
        displayedTracks = result
        displayRevision &+= 1
        completedDisplayKey = key
    }

    nonisolated static func sortedTracks(_ request: DisplayRequest) -> [Track] {
        let query = request.query
        let updates = Dictionary(request.updatedTracks.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let source = updates.isEmpty ? request.tracks : request.tracks.map { updates[$0.id] ?? $0 }
        let tracks = source.filter {
            (!request.onlyFavorites || $0.isFavorite) &&
            (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
                || $0.artist.localizedCaseInsensitiveContains(query)
                || $0.release.localizedCaseInsensitiveContains(query))
        }
        return tracks.sorted { lhs, rhs in
            let order = request.sort.compare(lhs, rhs)
            if order != .orderedSame {
                return request.ascending ? order == .orderedAscending : order == .orderedDescending
            }
            if lhs.discNumber != rhs.discNumber { return lhs.discNumber < rhs.discNumber }
            if lhs.trackNumber != rhs.trackNumber { return lhs.trackNumber < rhs.trackNumber }
            let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return lhs.id < rhs.id
        }
    }

    func catalogRequest(for store: DurvaldCoreStore) -> CatalogRequest {
        CatalogRequest(storeID: ObjectIdentifier(store), tracksRevision: store.tracksRevision,
                       metadataRevision: store.metadataRevision,
                       hasLoadedAllTracks: store.hasLoadedAllTracks,
                       coreID: store.core.map(ObjectIdentifier.init))
    }

    func refreshCatalog(store: DurvaldCoreStore) async {
        let request = catalogRequest(for: store)
        guard request != completedCatalogRequest else { return }
        let generation = UUID()
        catalogGeneration = generation
        // Catalog fetching and FFI conversion are independent of table creation.
        let core = store.core
        let loadedTracks = store.tracks
        let task = Task.detached(priority: .utility) { () throws -> [Track] in
            var tracks = loadedTracks
            if !request.hasLoadedAllTracks, let core {
                var offset = UInt64(tracks.count)
                while true {
                    try Task.checkCancellation()
                    let page = try await core.tracksPage(pageSize: 1_000, offset: offset)
                    tracks.append(contentsOf: page.items)
                    guard let next = page.nextOffset, next > offset else { break }
                    offset = next
                }
            }
            return tracks
        }
        do {
            let tracks = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            guard !Task.isCancelled, generation == catalogGeneration, catalogRequest(for: store) == request else { return }
            // Publish catalog before file metadata finishes. The summary never
            // gates the first table frame or sorting the complete collection.
            catalogStoreID = request.storeID
            catalogRevision = request.metadataRevision
            catalogCoreID = request.coreID
            catalog = tracks
            catalogVersion &+= 1
            let paths = Array(Set(tracks.map(\.filePath)))
            let sizes = await MusicLibraryFileSizes.read(paths)
            guard !Task.isCancelled, generation == catalogGeneration, catalogRequest(for: store) == request else { return }
            fileSizes = sizes
            librarySummary = MusicLibrarySummary(tracks: tracks, kind: .all, fileSizes: sizes)
            completedCatalogRequest = request
        } catch {
            // Leave the last successful cache intact; retry on the next visit.
        }
    }
}
