import Foundation
import Observation

@MainActor
protocol CatalogDetailLoading: AnyObject {
    func page(_ request: CatalogDetailRequest) async throws -> CatalogDetailPage
    func selection(_ reference: CatalogReference) async throws -> CatalogSelection?
    func save(_ entry: CatalogEntry) async throws -> CatalogSelection
    func followed(_ artistID: Int64) async throws -> Bool
    func follow(_ entry: CatalogEntry, followed: Bool) async throws -> CatalogSelection
    func hasListenIntent(_ entry: CatalogEntry) async throws -> Bool
    func listen(_ entry: CatalogEntry, artist: CatalogEntry) async throws
    func close() async
}

@MainActor
final class NativeCatalogDetails: CatalogDetailLoading {
    private let core: DurvaldCore
    private let session: CatalogSearchSession
    private let onLibraryChange: @MainActor () async -> Void
    init(core: DurvaldCore, onLibraryChange: @escaping @MainActor () async -> Void) {
        self.core = core
        self.onLibraryChange = onLibraryChange
        session = core.catalogSearchSession()
    }
    func page(_ request: CatalogDetailRequest) async throws -> CatalogDetailPage { try await session.detailSection(request: request) }
    func selection(_ reference: CatalogReference) async throws -> CatalogSelection? { try await core.catalogSelection(reference: reference) }
    func save(_ entry: CatalogEntry) async throws -> CatalogSelection {
        let saved = try await core.saveCatalogSelection(entry: entry)
        await onLibraryChange()
        return saved
    }
    func followed(_ artistID: Int64) async throws -> Bool { try await core.followedArtists().contains { $0.artist.id == artistID } }
    func follow(_ entry: CatalogEntry, followed: Bool) async throws -> CatalogSelection {
        let saved = try await core.followCatalogArtist(entry: entry, followed: followed)
        await onLibraryChange()
        return saved
    }
    func hasListenIntent(_ entry: CatalogEntry) async throws -> Bool {
        guard entry.reference.provider == "musicbrainz", entry.reference.kind == .releaseGroup else { return false }
        return try await core.listenList().contains { $0.externalRelease?.musicbrainzId == entry.reference.id }
    }
    func listen(_ entry: CatalogEntry, artist: CatalogEntry) async throws {
        _ = try await core.addCatalogToListenList(entry: entry, artist: artist)
        await onLibraryChange()
    }
    func close() async { await session.close() }
}

struct CatalogDetailBlock {
    var page: CatalogDetailPage?
    var loading = false
    var error: String?
    var lastCursor: String?
}

@MainActor
@Observable
final class CatalogDetailPresentation {
    private(set) var blocks: [CatalogDetailSection: CatalogDetailBlock] = [:]
    private(set) var selection: CatalogSelection?
    private(set) var followed = false
    private(set) var inListenList = false
    private(set) var saving = false
    private(set) var actionError: String?
    private(set) var generation: UInt64 = 0
    @ObservationIgnored private var loader: (any CatalogDetailLoading)?
    @ObservationIgnored private var workers: [Task<Void, Never>] = []
    @ObservationIgnored private var seed: CatalogEntry?
    @ObservationIgnored private var language = "und"
    @ObservationIgnored private var actionRevision: UInt64 = 0

    var entry: CatalogEntry? { blocks[.basic]?.page?.items.first ?? seed }
    var primaryArtist: CatalogEntry? { blocks[.basic]?.page?.items.dropFirst().first { $0.reference.kind == .artist } }
    func run(entry: CatalogEntry, language: String, loader: any CatalogDetailLoading) async {
        cancel()
        self.seed = entry; self.language = language; self.loader = loader
        blocks = [:]; saving = false; actionRevision &+= 1; selection = nil; followed = false; inListenList = false; actionError = nil
        let current = generation
        let revision = actionRevision
        var tasks = entry.detailSections.map { section in Task { @MainActor in await self.load(section, cursor: nil, generation: current, loader: loader) } }
        tasks.append(Task { @MainActor in
            do {
                let saved = try await loader.selection(entry.reference)
                let followed = if let id = saved?.localArtistId { try await loader.followed(id) } else { false }
                let listening = try await loader.hasListenIntent(entry)
                guard self.generation == current, !Task.isCancelled, revision == self.actionRevision else { return }
                self.selection = saved; self.followed = followed; self.inListenList = listening
            } catch {
                guard self.generation == current, !Task.isCancelled, revision == self.actionRevision else { return }
                self.actionError = "Não foi possível verificar os itens salvos."
            }
        })
        workers = tasks
        await withTaskCancellationHandler {
            for task in tasks { await task.value }
        } onCancel: {
            tasks.forEach { $0.cancel() }
            Task { @MainActor in await loader.close() }
        }
    }
    func cancel() {
        let previous = loader
        generation &+= 1; workers.forEach { $0.cancel() }; workers = []; loader = nil
        if let previous { Task { @MainActor in await previous.close() } }
    }
    func retry(_ section: CatalogDetailSection) async {
        guard let loader, blocks[section]?.loading != true else { return }
        await load(section, cursor: blocks[section]?.lastCursor, generation: generation, loader: loader)
    }
    func more(_ section: CatalogDetailSection) async {
        guard let loader, blocks[section]?.loading != true, let cursor = blocks[section]?.page?.nextCursor else { return }
        await load(section, cursor: cursor, generation: generation, loader: loader)
    }
    private func load(_ section: CatalogDetailSection, cursor: String?, generation current: UInt64, loader: any CatalogDetailLoading) async {
        guard let seed, generation == current, !Task.isCancelled else { return }
        blocks[section, default: .init()].loading = true
        blocks[section, default: .init()].error = nil
        blocks[section, default: .init()].lastCursor = cursor
        defer { if generation == current { blocks[section, default: .init()].loading = false } }
        do {
            var page = try await loader.page(CatalogDetailRequest(reference: seed.reference, section: section, language: language, cursor: cursor, generation: current))
            guard generation == current, !Task.isCancelled, page.generation == current, page.reference == seed.reference, page.section == section else { return }
            if let failure = page.failure {
                guard failure != .cancelled else { return }
                blocks[section, default: .init()].error = failure == .rateLimited
                    ? page.retryAfterSeconds.map { "Serviço ocupado. Tente novamente em \($0) segundos." } ?? "Serviço ocupado. Tente novamente mais tarde."
                    : "Não foi possível carregar esta parte. Os demais detalhes continuam disponíveis."
                return
            }
            if cursor != nil, let previous = blocks[section]?.page {
                var seen = Set(previous.items.map(\.entryKey))
                page.items = previous.items + page.items.filter { seen.insert($0.entryKey).inserted }
            }
            blocks[section, default: .init()].page = page
        } catch {
            guard generation == current, !Task.isCancelled else { return }
            blocks[section, default: .init()].error = "Não foi possível carregar esta parte. Tente novamente."
        }
    }
    func save() async {
        let current = generation
        await action { loader, entry in
            let saved = try await loader.save(entry)
            guard self.generation == current else { return }
            self.selection = saved
        }
    }
    func toggleFollow() async {
        let current = generation
        let next = !followed
        await action { loader, entry in
            let saved = try await loader.follow(entry, followed: next)
            guard self.generation == current else { return }
            self.selection = saved; self.followed = next
        }
    }
    func listen() async {
        guard let artist = primaryArtist else { return }
        let current = generation
        await action { loader, entry in
            try await loader.listen(entry, artist: artist)
            guard self.generation == current else { return }
            self.inListenList = true
        }
    }
    private func action(_ operation: (any CatalogDetailLoading, CatalogEntry) async throws -> Void) async {
        guard !saving, let loader, let entry else { return }
        let current = generation
        saving = true; actionError = nil; actionRevision &+= 1
        defer { if generation == current { saving = false } }
        do { try await operation(loader, entry) } catch {
            if generation == current { actionError = "Não foi possível salvar esta alteração. Tente novamente." }
        }
    }

}

extension CatalogEntry {
    var entryKey: String { "\(reference.provider):\(reference.kind):\(reference.id)" }
    var detailSections: [CatalogDetailSection] {
        guard reference.provider == "musicbrainz" else { return [] }
        switch reference.kind {
        case .artist: return [.basic, .cover, .profile, .discography, .similar]
        case .releaseGroup: return [.basic, .cover, .editions]
        case .releaseEdition: return [.basic, .cover, .tracklist]
        case .recording: return [.basic]
        default: return []
        }
    }
}
extension CatalogItem {
    var detailEntry: CatalogEntry {
        CatalogEntry(reference: CatalogReference(provider: provider == .musicBrainz ? "musicbrainz" : "library", kind: kind, id: id), title: title, artistCredit: artistCredit, versionLabel: versionLabel, durationSeconds: durationSeconds, canonicalUrl: canonicalUrl)
    }
}

extension DurvaldCoreStore {
    func makeCatalogDetailLoader() -> (any CatalogDetailLoading)? {
        #if DEBUG
        if let fixture = catalogDetailFixture { return fixture() }
        #endif
        guard let core else { return nil }
        return NativeCatalogDetails(core: core, onLibraryChange: { [weak self] in
            guard let self, self.core === core else { return }
            await self.refreshLibraryCatalog()
        })
    }
}
