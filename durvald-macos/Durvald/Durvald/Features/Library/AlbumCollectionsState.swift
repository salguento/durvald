import Observation
import SwiftUI

struct AlbumCollectionAddRequest: Identifiable {
    let id = UUID()
    let release: Release
}

@MainActor @Observable
final class AlbumCollectionsState {
    var collections: [AlbumCollection] = []
    var page: AlbumCollectionPage?
    var listQuery = ""
    var detailQueries: [Int64: String] = [:]
    var byCount = false
    var loading = false
    var changing = false
    var preparingPlayback = false
    var error: String?
    private var generation = 0

    var visibleCollections: [AlbumCollection] {
        collections.filter { listQuery.isEmpty || $0.name.localizedStandardContains(listQuery) || $0.description.localizedStandardContains(listQuery) }
            .sorted {
                if byCount && $0.albumCount != $1.albumCount { return $0.albumCount > $1.albumCount }
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
    }

    func load(id: Int64? = nil, using store: DurvaldCoreStore) async {
        guard let core = store.core else { return }
        generation += 1
        let request = generation
        loading = true
        if let id, page?.collection.id != id { page = nil }
        defer { if generation == request { loading = false } }
        do {
            let list = try await core.albumCollections()
            let detail: AlbumCollectionPage?
            if let id { detail = try await core.albumCollection(collectionId: id) } else { detail = nil }
            guard generation == request, store.core === core, !Task.isCancelled else { return }
            collections = list
            if let detail { page = detail }
            error = nil
        } catch {
            guard generation == request, store.core === core, !Task.isCancelled else { return }
            self.error = "Não foi possível carregar as coleções. Tente novamente."
        }
    }

    @discardableResult
    func change(id: Int64? = nil, using store: DurvaldCoreStore, operation: (DurvaldCore) async throws -> Void) async -> Bool {
        guard let core = store.core, !changing else { return false }
        changing = true; error = nil
        defer { changing = false }
        do {
            try await operation(core)
            guard store.core === core else { return false }
            await load(id: id, using: store)
            return error == nil
        } catch {
            guard store.core === core else { return false }
            await load(id: id, using: store)
            self.error = "Não foi possível atualizar a coleção. Tente novamente."
            return false
        }
    }

    func play(id: Int64, mode: AlbumCollectionPlaybackMode, startingAt releaseID: Int64? = nil, using store: DurvaldCoreStore) async {
        guard let core = store.core, !preparingPlayback, !store.isChangingTrack else { return }
        preparingPlayback = true
        defer { preparingPlayback = false }
        do {
            let source = try await core.albumCollectionTracks(collectionId: id)
            guard store.core === core, !Task.isCancelled else { return }
            let tracks = Self.playbackTracks(source, mode: mode)
            let start = releaseID.flatMap { id in tracks.first(where: { $0.releaseId == id })?.id }
            if releaseID != nil && start == nil { error = "Este álbum não tem faixas disponíveis."; return }
            if tracks.isEmpty { error = "Esta coleção não tem faixas disponíveis."; return }
            // Freeze this evaluated result for the playback session. Later
            // edits and smart-rule changes never rewrite the running queue.
            await store.playTracks(tracks, startingAt: start, shuffleEnabled: mode == .tracks,
                sourceContext: "albumCollection:\(id)")
        } catch { self.error = "Não foi possível preparar a reprodução da coleção." }
    }

    static func playbackTracks(_ tracks: [Track], mode: AlbumCollectionPlaybackMode) -> [Track] {
        guard mode == .albums else { return tracks }
        var ids: [Int64] = []
        var groups: [Int64: [Track]] = [:]
        for track in tracks {
            if groups[track.releaseId] == nil { ids.append(track.releaseId) }
            groups[track.releaseId, default: []].append(track)
        }
        return ids.shuffled().flatMap { groups[$0] ?? [] }
    }
}

enum AlbumCollectionPlaybackMode { case ordered, albums, tracks }
