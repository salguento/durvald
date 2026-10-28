import Foundation
import Observation

@MainActor
protocol SourceManaging: AnyObject {
    func providers() async throws -> [SourceProvider]
    func setProvider(_ id: String, enabled: Bool) async throws
    func search(provider: String, entry: CatalogEntry, link: String?, generation: UInt64) async throws -> SourceSearchPage
    func sources(_ track: Int64) async throws -> [TrackSource]
    func matches(_ query: String) async throws -> [Track]
    func track(_ id: Int64) async throws -> Track
    func attach(_ candidate: String, track: Int64?) async throws -> TrackSource
    func attachLocal(_ path: String, track: Int64) async throws -> TrackSource
    func enabled(_ source: TrackSource, value: Bool) async throws
    func remove(_ source: TrackSource) async throws
    func prefer(_ source: TrackSource, value: Bool) async throws
    func test(_ source: TrackSource) async throws -> SourceTestResult
    func openURL(_ source: TrackSource) async throws -> String
    func play(_ source: TrackSource) async throws
    func close() async
}

@MainActor
final class NativeSourceManager: SourceManaging {
    private let core: DurvaldCore
    private let session: SourceSearchSession
    private let changed: () async -> Void
    private let playbackChanged: () async -> Void
    init(core: DurvaldCore, changed: @escaping () async -> Void, playbackChanged: @escaping () async -> Void) {
        self.core = core; session = core.sourceSearchSession(); self.changed = changed; self.playbackChanged = playbackChanged
    }
    func providers() async throws -> [SourceProvider] { try await core.sourceProviders() }
    func setProvider(_ id: String, enabled: Bool) async throws { try await core.setSourceProviderEnabled(provider: id, enabled: enabled) }
    func search(provider: String, entry: CatalogEntry, link: String?, generation: UInt64) async throws -> SourceSearchPage {
        try await session.search(provider: provider, entry: entry, link: link, generation: generation)
    }
    func sources(_ track: Int64) async throws -> [TrackSource] { try await core.trackSources(trackId: track) }
    func matches(_ query: String) async throws -> [Track] {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return try await core.tracksPage(pageSize: 50, offset: 0).items }
        return try await core.search(query: query).tracks
    }
    func track(_ id: Int64) async throws -> Track { try await core.track(trackId: id) }
    func attach(_ candidate: String, track: Int64?) async throws -> TrackSource {
        let source = try await session.attachCandidate(candidateId: candidate, trackId: track, confirmed: true)
        await changed(); return source
    }
    func attachLocal(_ path: String, track: Int64) async throws -> TrackSource {
        let source = try await core.attachLocalTrackSource(trackId: track, path: path)
        await changed(); return source
    }
    func enabled(_ source: TrackSource, value: Bool) async throws { _ = try await core.setTrackSourceEnabled(trackId: source.trackId, sourceId: source.sourceId, enabled: value); await changed() }
    func remove(_ source: TrackSource) async throws { try await core.removeTrackSource(trackId: source.trackId, sourceId: source.sourceId); await changed() }
    func prefer(_ source: TrackSource, value: Bool) async throws { try await core.preferTrackSource(trackId: source.trackId, sourceId: value ? source.sourceId : nil) }
    func test(_ source: TrackSource) async throws -> SourceTestResult { try await core.testTrackSource(trackId: source.trackId, sourceId: source.sourceId) }
    func openURL(_ source: TrackSource) async throws -> String { try await core.trackSourceOpenUrl(trackId: source.trackId, sourceId: source.sourceId) }
    func play(_ source: TrackSource) async throws { _ = try await core.playTrackSource(trackId: source.trackId, sourceId: source.sourceId); await playbackChanged() }
    func close() async { await session.close() }
}

@MainActor @Observable
final class SourceManagementPresentation {
    private(set) var providers: [SourceProvider] = []
    private(set) var pages: [String: SourceSearchPage] = [:]
    private(set) var loading: Set<String> = []
    private(set) var providerErrors: [String: String] = [:]
    private(set) var sources: [TrackSource] = []
    private(set) var currentTrack: Track?
    private(set) var matches: [Track] = []
    private(set) var busy = false
    private(set) var error: String?
    private(set) var message: String?
    var reviewing: SourceCandidate?
    var associationTrackID: Int64?
    @ObservationIgnored private var loader: (any SourceManaging)?
    @ObservationIgnored private var entry: CatalogEntry?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var jobs: [Task<Void, Never>] = []
    @ObservationIgnored private var matchRevision: UInt64 = 0

    func load(entry: CatalogEntry, loader: any SourceManaging) async {
        cancel(); self.loader = loader; self.entry = entry; error = nil; message = nil
        providers = []; pages = [:]; providerErrors = [:]; sources = []; currentTrack = nil; matches = []; reviewing = nil; associationTrackID = nil; busy = false
        let current = generation
        if entry.reference.provider == "library", let id = Int64(entry.reference.id) {
            do {
                let track = try await loader.track(id)
                let sources = try await loader.sources(id)
                guard generation == current, !Task.isCancelled else { return }
                currentTrack = track; self.sources = sources; associationTrackID = id
            } catch { guard generation == current else { return }; self.error = "Não foi possível carregar as origens da faixa." }
        }
        do {
            let values = try await loader.providers()
            guard generation == current, !Task.isCancelled else { return }; providers = values
        } catch { guard generation == current else { return }; self.error = "Não foi possível carregar os serviços. As origens salvas continuam disponíveis." }
        // Source search starts only when the user presses Buscar for this item.
    }
    func search(link: String?) async {
        guard let loader, let entry else { return }
        jobs.forEach { $0.cancel() }; jobs = []; generation &+= 1
        let current = generation; pages = [:]; loading = []; providerErrors = [:]; reviewing = nil
        for provider in providers where provider.enabled {
            loading.insert(provider.id)
            jobs.append(Task { @MainActor in
                do {
                    let page = try await loader.search(provider: provider.id, entry: entry, link: link, generation: current)
                    guard self.generation == current, !Task.isCancelled else { return }
                    self.pages[provider.id] = page
                } catch {
                    guard self.generation == current, !Task.isCancelled else { return }
                    self.providerErrors[provider.id] = "Não foi possível consultar este serviço."
                }
                self.loading.remove(provider.id)
            })
        }
        for job in jobs { await job.value }
    }
    func setProvider(_ provider: SourceProvider, enabled: Bool) async {
        guard let loader else { return }
        do {
            try await loader.setProvider(provider.id, enabled: enabled)
            if let index = providers.firstIndex(where: { $0.id == provider.id }) { providers[index].enabled = enabled }
            if !enabled { pages[provider.id] = nil; reviewing = nil }
        } catch { self.error = "Não foi possível alterar o serviço." }
    }
    func findMatches(_ query: String) async {
        guard let loader else { return }; matchRevision &+= 1; let revision = matchRevision
        do { let matches = try await loader.matches(query); guard revision == matchRevision else { return }; self.matches = matches }
        catch { guard revision == matchRevision else { return }; self.error = "Não foi possível buscar faixas na biblioteca." }
    }
    func review(_ candidate: SourceCandidate) { reviewing = candidate; associationTrackID = currentTrack?.id; matches = [] }
    func confirm() async {
        guard let candidate = reviewing, let loader else { return }
        let target = associationTrackID
        await mutate {
            let current = self.generation
            let source = try await loader.attach(candidate.candidateId, track: target)
            let track = try await loader.track(source.trackId)
            guard self.generation == current else { return }
            self.currentTrack = track
            self.reviewing = nil
        }
    }
    func attachLocal(_ path: String) async {
        guard let track = currentTrack, let loader else { return }
        await mutate { _ = try await loader.attachLocal(path, track: track.id) }
    }
    func enabled(_ source: TrackSource, value: Bool) async { guard let loader else { return }; await mutate { try await loader.enabled(source, value: value) } }
    func remove(_ source: TrackSource) async { guard let loader else { return }; await mutate { try await loader.remove(source) } }
    func prefer(_ source: TrackSource) async { guard let loader else { return }; await mutate { try await loader.prefer(source, value: !source.preferred) } }
    func test(_ source: TrackSource) async { guard let loader else { return }; await mutate { self.message = try await loader.test(source).message } }
    func play(_ source: TrackSource) async { guard let loader else { return }; await mutate { try await loader.play(source) } }
    func openURL(_ source: TrackSource) async -> URL? {
        guard let loader else { return nil }
        do { return URL(string: try await loader.openURL(source)) } catch { self.error = "Esta origem não possui um link de serviço compatível."; return nil }
    }
    private func mutate(_ operation: () async throws -> Void) async {
        guard !busy else { return }; busy = true; error = nil; let current = generation
        defer { if generation == current { busy = false } }
        do {
            try await operation()
            guard generation == current else { return }
            if let track = currentTrack, let loader {
                let refreshed = try await loader.sources(track.id)
                guard generation == current else { return }; sources = refreshed
            }
        } catch { guard generation == current else { return }; self.error = "Não foi possível concluir a ação. \(error.localizedDescription)" }
    }
    func cancel() {
        generation &+= 1; matchRevision &+= 1; jobs.forEach { $0.cancel() }; jobs = []; loading = []
        let previous = loader; loader = nil
        Task { await previous?.close() }
    }
}

extension SourceCapability {
    var sourceLabel: String {
        switch self {
        case .unknown: "Capacidade desconhecida"
        case .fullAudio: "Áudio completo (arquivo local)"
        case .preview: "Prévia"
        case .embeddedPlayer: "Player integrado"
        case .externalOpen: "Abrir no serviço"
        case .unavailable: "Indisponível"
        }
    }
}
extension CatalogEntry {
    var supportsSources: Bool { [.track, .recording, .releaseTrack, .audioTrack, .video].contains(reference.kind) }
    static func sourceEntry(_ track: Track) -> CatalogEntry {
        CatalogEntry(reference: CatalogReference(provider: "library", kind: .track, id: String(track.id)), title: track.title, artistCredit: track.artist, versionLabel: track.release, durationSeconds: UInt64(max(0, track.durationSeconds)), canonicalUrl: nil)
    }
}
