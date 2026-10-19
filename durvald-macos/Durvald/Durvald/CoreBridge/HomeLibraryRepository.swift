import Foundation
import Observation

/// Bounded local shelves. History polling reads only a scalar until it changes.
@MainActor
@Observable
final class HomeLibraryRepository {
    private(set) var snapshot = HomeLibrary(recentlyPlayed: [], recentlyAdded: [])
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var hasLoaded = false

    private struct Request: Equatable {
        let coreID: ObjectIdentifier
        let catalogRevision: UInt64
        let historyRevision: UInt64
    }
    @ObservationIgnored private var completed: Request?
    @ObservationIgnored private var generation = UUID()

    func refresh(core: DurvaldCore, catalogRevision: UInt64) async {
        let token = UUID()
        generation = token
        do {
            let revision = try await core.playbackHistoryRevision()
            try Task.checkCancellation()
            guard generation == token else { return }
            let request = Request(coreID: ObjectIdentifier(core), catalogRevision: catalogRevision,
                                  historyRevision: revision)
            guard completed != request else {
                isLoading = false
                errorMessage = nil
                return
            }
            isLoading = true
            let result = try await core.homeLibrary(limit: 24)
            try Task.checkCancellation()
            guard generation == token else { return }
            // A listen can complete while the shelves are read. Retry next tick.
            guard try await core.playbackHistoryRevision() == revision else {
                if generation == token { isLoading = false }
                return
            }
            try Task.checkCancellation()
            guard generation == token else { return }
            snapshot = result
            completed = request
            hasLoaded = true
            errorMessage = nil
            isLoading = false
        } catch {
            guard generation == token else { return }
            isLoading = false
            if !Task.isCancelled { errorMessage = "Não foi possível atualizar a Home. Tentando novamente…" }
        }
    }
}
