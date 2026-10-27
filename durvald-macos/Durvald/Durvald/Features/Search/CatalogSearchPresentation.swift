import Foundation
import Observation

@MainActor
protocol CatalogSearchLoading: AnyObject {
    func page(provider: CatalogProvider, query: CatalogQuery) async throws -> CatalogPage
    func cancel(generation: UInt64) async
    func close() async
}

@MainActor
final class NativeCatalogSearch: CatalogSearchLoading {
    private let session: CatalogSearchSession
    init(core: DurvaldCore) { session = core.catalogSearchSession() }
    init(session: CatalogSearchSession) { self.session = session }
    func page(provider: CatalogProvider, query: CatalogQuery) async throws -> CatalogPage {
        try await session.searchPage(provider: provider, query: query)
    }
    func cancel(generation: UInt64) async { await session.cancel(generation: generation) }
    func close() async { await session.close() }
}

extension DurvaldCoreStore {
    func makeCatalogSearchLoader() -> (any CatalogSearchLoading)? {
        #if DEBUG
        if let fixture = catalogSearchFixture { return fixture() }
        #endif
        guard let core else { return nil }
        return NativeCatalogSearch(core: core)
    }
}

struct CatalogProviderPage {
    var items: [CatalogItem] = []
    var nextCursor: String?
    var lastCursor: String?
    var failure: CatalogFailure?
    var retryAfterSeconds: UInt64?
    var isLoading = false
    var fromCache = false
    var errorMessage: String?
}

@MainActor
@Observable
final class CatalogSearchPresentation {
    private(set) var library = CatalogProviderPage()
    private(set) var musicBrainz = CatalogProviderPage()
    private(set) var generation: UInt64 = 0
    @ObservationIgnored private var loader: (any CatalogSearchLoading)?
    @ObservationIgnored private var workers: [Task<Void, Never>] = []
    @ObservationIgnored private var submittedQuery = ""
    @ObservationIgnored private var filter = CatalogFilter.all
    @ObservationIgnored private var language = "und"

    func run(query: String, filter: CatalogFilter, language: String,
             loader: any CatalogSearchLoading) async {
        cancel()
        self.loader = loader
        submittedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.filter = filter
        self.language = language
        library = CatalogProviderPage()
        musicBrainz = CatalogProviderPage()
        guard !submittedQuery.isEmpty, !Task.isCancelled else { return }
        let current = generation
        let local = Task { @MainActor in
            await self.load(.library, cursor: nil, generation: current, loader: loader)
        }
        let remote = Task { @MainActor in
            await self.load(.musicBrainz, cursor: nil, generation: current, loader: loader)
        }
        workers = [local, remote]
        await withTaskCancellationHandler {
            await local.value
            await remote.value
        } onCancel: {
            local.cancel()
            remote.cancel()
            Task { @MainActor in await loader.cancel(generation: current) }
        }
    }

    func cancel() {
        let previous = loader
        generation &+= 1
        workers.forEach { $0.cancel() }
        workers = []
        loader = nil
        library.isLoading = false
        musicBrainz.isLoading = false
        if let previous { Task { @MainActor in await previous.close() } }
    }

    func page(for provider: CatalogProvider) -> CatalogProviderPage {
        provider == .library ? library : musicBrainz
    }

    func retry(_ provider: CatalogProvider) async {
        guard let loader, !page(for: provider).isLoading else { return }
        await load(provider, cursor: page(for: provider).lastCursor, generation: generation, loader: loader)
    }

    func loadMore(_ provider: CatalogProvider) async {
        guard let loader, !page(for: provider).isLoading, let cursor = page(for: provider).nextCursor else { return }
        await load(provider, cursor: cursor, generation: generation, loader: loader)
    }

    private func load(_ provider: CatalogProvider, cursor: String?, generation current: UInt64,
                      loader: any CatalogSearchLoading) async {
        guard generation == current, !Task.isCancelled else { return }
        update(provider) { $0.isLoading = true; $0.lastCursor = cursor; $0.errorMessage = nil; $0.failure = nil }
        defer { if generation == current { update(provider) { $0.isLoading = false } } }
        do {
            var query = CatalogQuery(query: submittedQuery, scope: .explore, filter: filter,
                                     language: language, pageSize: 20, cursor: cursor,
                                     generation: current, cacheOnly: provider == .musicBrainz && cursor == nil)
            if query.cacheOnly {
                let cached = try await loader.page(provider: provider, query: query)
                guard generation == current, !Task.isCancelled else { return }
                if cached.fromCache || cached.failure != nil {
                    publish(cached, cursor: cursor, generation: current)
                    return
                }
                query.cacheOnly = false
            }
            let page = try await loader.page(provider: provider, query: query)
            guard generation == current, !Task.isCancelled else { return }
            publish(page, cursor: cursor, generation: current)
        } catch {
            guard generation == current, !Task.isCancelled, !(error is CancellationError) else { return }
            update(provider) { $0.errorMessage = "Não foi possível carregar estes resultados. Tente novamente." }
        }
    }

    private func publish(_ page: CatalogPage, cursor: String?, generation current: UInt64) {
        guard page.generation == current, generation == current, page.failure != .cancelled else { return }
        update(page.provider) { state in
            state.failure = page.failure
            state.retryAfterSeconds = page.retryAfterSeconds
            state.fromCache = page.fromCache
            guard page.failure == nil else { return }
            var seen = Set(cursor == nil ? [] : state.items.map(\.catalogKey))
            let additions = page.items.filter { seen.insert($0.catalogKey).inserted }
            state.items = cursor == nil ? additions : state.items + additions
            state.nextCursor = page.nextCursor
        }
    }

    private func update(_ provider: CatalogProvider, _ change: (inout CatalogProviderPage) -> Void) {
        if provider == .library { change(&library) } else { change(&musicBrainz) }
    }
}

extension CatalogItem {
    var catalogKey: String { "\(provider):\(kind):\(id)" }
    var kindLabel: String {
        switch kind {
        case .artist: "Artista"
        case .releaseGroup: "Lançamento"
        case .releaseEdition: "Edição"
        case .recording, .track: "Faixa"
        case .playlist: "Playlist"
        case .releaseTrack: "Faixa da edição"
        case .serviceProfile: "Perfil"
        case .audioTrack: "Faixa"
        case .video: "Vídeo"
        case .albumVideo: "Vídeo de álbum"
        }
    }
}
