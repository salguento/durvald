import Foundation
import Observation

/// Store-owned history and track index. Navigation and queries reuse the same
/// snapshot; the existing playback reconciliation loop checks its core revision.
@MainActor
@Observable
final class PlaybackHistoryRepository {
    private(set) var entries: [PlaybackHistoryItem] = []
    private(set) var tracksByID: [Int64: Track] = [:]
    private(set) var revision: UInt64 = 0
    private(set) var isLoading = false
    @ObservationIgnored private(set) var hasRequestedHistory = false

    private struct Request: Equatable {
        let coreID: ObjectIdentifier
        let historyRevision: UInt64
        let catalogRevision: UInt64
        let tracksRevision: UInt64
    }
    private struct Snapshot {
        let entries: [PlaybackHistoryItem]
        let tracksByID: [Int64: Track]
        let resolvedIDs: Set<Int64>
    }
    @ObservationIgnored private var completedRequest: Request?
    @ObservationIgnored private var resolvedIDs: Set<Int64> = []
    @ObservationIgnored private var pendingRequest: Request?
    @ObservationIgnored private var pending: Task<Snapshot, Error>?
    @ObservationIgnored private var generation = UUID()

    func entries(matching query: String) -> [PlaybackHistoryItem] {
        guard !query.isEmpty else { return entries }
        return entries.filter { item in
            guard let track = tracksByID[item.trackId] else {
                return "Música #\(item.trackId)".localizedCaseInsensitiveContains(query)
            }
            return [track.title, track.artist, track.release].contains {
                $0.localizedCaseInsensitiveContains(query)
            }
        }
    }

    func invalidateTracks() {
        generation = UUID()
        pending?.cancel()
        pending = nil
        pendingRequest = nil
        isLoading = false
    }

    func reset() {
        invalidateTracks()
        completedRequest = nil
        resolvedIDs = []
        entries = []
        tracksByID = [:]
        hasRequestedHistory = false
        revision &+= 1
    }

    func seed(entries: [PlaybackHistoryItem], tracks: [Track]) {
        guard completedRequest == nil else { return }
        let ids = Set(entries.map(\.trackId))
        let index = Dictionary(tracks.filter { ids.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        if self.entries != entries || tracksByID != index {
            self.entries = entries
            tracksByID = index
            revision &+= 1
        }
    }

    func refresh(core: DurvaldCore, catalogRevision: UInt64, tracksRevision: UInt64, knownTracks: [Track]) async throws {
        try Task.checkCancellation()
        hasRequestedHistory = true
        let originalGeneration = generation
        let coreRevision = try await core.playbackHistoryRevision()
        try Task.checkCancellation()
        guard originalGeneration == generation else { throw CancellationError() }
        let request = Request(coreID: ObjectIdentifier(core), historyRevision: coreRevision,
                              catalogRevision: catalogRevision, tracksRevision: tracksRevision)
        if completedRequest == request { return }
        if let latest = pendingRequest ?? completedRequest, latest.coreID == request.coreID,
           latest.historyRevision > request.historyRevision
            || latest.catalogRevision > request.catalogRevision
            || (latest.catalogRevision == request.catalogRevision && latest.tracksRevision > request.tracksRevision) {
            // An older caller may return from its revision read after a newer
            // request has already prepared optimistic or edited metadata.
            throw CancellationError()
        }

        let worker: Task<Snapshot, Error>
        if pendingRequest == request, let pending {
            worker = pending
        } else {
            if pending != nil { invalidateTracks() }
            let cachedEntries = completedRequest?.coreID == request.coreID && completedRequest?.historyRevision == coreRevision ? entries : nil
            let reuseTracks = completedRequest?.coreID == request.coreID && completedRequest?.catalogRevision == catalogRevision
            let cachedTracks = reuseTracks ? tracksByID : [:]
            let cachedIDs = reuseTracks ? resolvedIDs : []
            worker = Task.detached(priority: .utility) {
                let entries: [PlaybackHistoryItem]
                if let cachedEntries { entries = cachedEntries }
                else { entries = try await core.playbackHistory() }
                try Task.checkCancellation()
                let ids = Set(entries.map(\.trackId))
                var index = cachedTracks.filter { ids.contains($0.key) }
                for track in knownTracks where ids.contains(track.id) { index[track.id] = track }
                let missing = ids.subtracting(index.keys).subtracting(cachedIDs).sorted()
                for start in stride(from: 0, to: missing.count, by: 200) {
                    try Task.checkCancellation()
                    let batch = Array(missing[start..<min(start + 200, missing.count)])
                    for track in try await core.tracksByIds(trackIds: batch) { index[track.id] = track }
                }
                // A completion/deletion during the reads must not mix revisions.
                guard try await core.playbackHistoryRevision() == coreRevision else { throw CancellationError() }
                try Task.checkCancellation()
                return Snapshot(entries: entries, tracksByID: index, resolvedIDs: ids)
            }
            pending = worker
            pendingRequest = request
            isLoading = true
        }
        let requestGeneration = generation
        do {
            let snapshot = try await worker.value
            guard generation == requestGeneration else { throw CancellationError() }
            if completedRequest != request {
                entries = snapshot.entries
                tracksByID = snapshot.tracksByID
                resolvedIDs = snapshot.resolvedIDs
                completedRequest = request
                revision &+= 1
            }
            pending = nil
            pendingRequest = nil
            isLoading = false
            // The shared cache remains useful if just one consumer goes away.
            try Task.checkCancellation()
        } catch {
            if generation == requestGeneration {
                pending = nil
                pendingRequest = nil
                isLoading = false
            }
            throw error
        }
    }
}
