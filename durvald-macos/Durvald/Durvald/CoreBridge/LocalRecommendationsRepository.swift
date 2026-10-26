import Foundation
import Observation

@MainActor @Observable
final class LocalRecommendationsRepository {
    private(set) var snapshot = LocalRecommendations(items: [], exploration: true)
    private(set) var loading = false
    private(set) var changing = false
    private(set) var error: String?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var completed: Request?
    @ObservationIgnored private var coreID: ObjectIdentifier?
    @ObservationIgnored private var pending = false
    @ObservationIgnored private var activeSignals: String?
    private struct Request: Equatable {
        let core: ObjectIdentifier
        let signals: String
        let history: UInt64
        let day: Int64
    }

    func refresh(core: DurvaldCore, signals: String, force: Bool = false) async {
        let id = ObjectIdentifier(core)
        guard force || (!changing && !(pending && coreID == id && activeSignals == signals)) else { return }
        let token = UUID(); generation = token
        pending = true; activeSignals = signals
        defer { if generation == token { pending = false } }
        if coreID != id {
            coreID = id; completed = nil
            snapshot = LocalRecommendations(items: [], exploration: true)
        }
        do {
            let history = try await core.playbackHistoryRevision()
            try Task.checkCancellation()
            guard generation == token else { return }
            let request = Request(core: id, signals: signals, history: history,
                day: Int64(Date().timeIntervalSince1970) / 86_400)
            guard force || completed != request else { return }
            loading = true
            snapshot = LocalRecommendations(items: [], exploration: snapshot.exploration)
            let result = try await core.localRecommendations(limit: 12)
            try Task.checkCancellation()
            guard generation == token else { return }
            guard try await core.playbackHistoryRevision() == history else { loading = false; return }
            try Task.checkCancellation()
            guard generation == token else { return }
            snapshot = result; completed = request; error = nil; loading = false
        } catch {
            guard generation == token else { return }
            loading = false
            if !Task.isCancelled { self.error = "Não foi possível atualizar as sugestões. Tente novamente." }
        }
    }

    func record(_ event: RecommendationEvent, releaseID: Int64, core: DurvaldCore) async {
        // Local measurement is best effort; a failed metric must never prevent
        // opening an album or interfere with playback.
        try? await core.recordRecommendationEvent(releaseId: releaseID, event: event)
    }

    func dismiss(releaseID: Int64, core: DurvaldCore, signals: String) async {
        guard !changing else { return }
        changing = true; generation = UUID()
        defer { changing = false }
        do {
            try await core.dismissLocalRecommendation(releaseId: releaseID)
            guard coreID == ObjectIdentifier(core) else { return }
            completed = nil
            await refresh(core: core, signals: signals, force: true)
        } catch { self.error = "Não foi possível dispensar esta sugestão. Tente novamente." }
    }

    func restore(core: DurvaldCore, signals: String) async {
        guard !changing else { return }
        changing = true; generation = UUID()
        defer { changing = false }
        do {
            try await core.restoreLocalRecommendations()
            guard coreID == ObjectIdentifier(core) else { return }
            completed = nil
            await refresh(core: core, signals: signals, force: true)
        } catch { self.error = "Não foi possível restaurar as sugestões. Tente novamente." }
    }
}
