import Foundation
import Observation

/// Payload arrays never participate in SwiftUI task identity.
struct QueueMenuTrackRequest: Equatable {
    var coreID: ObjectIdentifier?
    var queueRevision: UInt64
    var catalogRevision: UInt64
    var tracksRevision: UInt64

    @MainActor
    init(store: DurvaldCoreStore) {
        self.init(coreID: store.core.map(ObjectIdentifier.init), queueRevision: store.queueRevision,
                  catalogRevision: store.libraryCatalogRevision, tracksRevision: store.tracksRevision)
    }

    init(coreID: ObjectIdentifier? = nil, queueRevision: UInt64 = 0,
         catalogRevision: UInt64 = 0, tracksRevision: UInt64 = 0) {
        self.coreID = coreID
        self.queueRevision = queueRevision
        self.catalogRevision = catalogRevision
        self.tracksRevision = tracksRevision
    }
}

@MainActor
@Observable
final class QueueMenuTrackPresentation {
    private(set) var tracksByID: [Int64: Track] = [:]
    @ObservationIgnored private var completedRequest: QueueMenuTrackRequest?
    @ObservationIgnored private var cachedCoreID: ObjectIdentifier?
    @ObservationIgnored private var cachedCatalogRevision: UInt64?
    @ObservationIgnored private var generation = UUID()

    func refresh(store: DurvaldCoreStore) async {
        let request = QueueMenuTrackRequest(store: store)
        let queue = store.queue
        let knownTracks = queue.compactMap { store.loadedTrack(id: $0.trackId) }
        let core = store.core
        await refresh(request: request, queue: queue, knownTracks: knownTracks) { id in
            try await core?.track(trackId: id)
        }
    }

    func refresh(request: QueueMenuTrackRequest, queue: [QueueItem], knownTracks: [Track],
                 load: (Int64) async throws -> Track?) async {
        let currentGeneration = UUID()
        generation = currentGeneration
        guard !Task.isCancelled, completedRequest != request else { return }
        let canReuse = cachedCoreID == request.coreID && cachedCatalogRevision == request.catalogRevision
        if !canReuse {
            // A different database or metadata revision must not serve old menus.
            tracksByID = [:]
            completedRequest = nil
        }
        let ids = Set(queue.map(\.trackId))
        var resolved = canReuse ? tracksByID.filter { ids.contains($0.key) } : [:]
        let known = firstRecordIndex(knownTracks, key: { $0.id })
        for item in queue {
            guard !Task.isCancelled, generation == currentGeneration else { return }
            if let track = known[item.trackId] {
                resolved[item.trackId] = track
            } else if resolved[item.trackId] == nil {
                let track = try? await load(item.trackId)
                guard !Task.isCancelled, generation == currentGeneration else { return }
                resolved[item.trackId] = track
            }
        }
        guard !Task.isCancelled, generation == currentGeneration else { return }
        tracksByID = resolved
        cachedCoreID = request.coreID
        cachedCatalogRevision = request.catalogRevision
        completedRequest = request
    }
}
