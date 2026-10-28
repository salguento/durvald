import Foundation
import Observation

struct ServiceCollectionsLoader {
    var list: () async throws -> [ServiceCollectionJob]
    var progress: ((String) async throws -> ServiceCollectionJob)? = nil
    var begin: (String) async throws -> ServiceCollectionJob
    var page: (String, Bool) async throws -> ServiceCollectionJob
    var retry: (String, UInt32) async throws -> ServiceCollectionJob
    var apply: (String, [String], Bool) async throws -> ServiceCollectionJob
    var cancel: (String) async throws -> ServiceCollectionJob
    var resume: (String) async throws -> ServiceCollectionJob
}
extension ServiceCollectionsLoader {
    init(core: DurvaldCore) {
        progress = { try await core.serviceCollectionImport(jobId: $0) }
        list = { try await core.serviceCollectionImports() }; begin = { try await core.beginServiceCollectionImport(url: $0) }
        page = { try await core.loadServiceCollectionPage(jobId: $0, refresh: $1) }; retry = { try await core.retryServiceCollectionPage(jobId: $0, pageIndex: $1) }
        apply = { try await core.importServiceCollectionItems(jobId: $0, occurrenceIds: $1, confirmed: $2) }
        cancel = { try await core.cancelServiceCollectionImport(jobId: $0) }; resume = { try await core.resumeServiceCollectionImport(jobId: $0) }
    }
}
@MainActor @Observable
final class ServiceCollectionsPresentation {
    private(set) var jobs: [ServiceCollectionJob] = []
    private(set) var busy = false
    private(set) var error: String?
    var selectedID: String?
    var selectedItems = Set<String>()
    var reviewed = false
    private var loader: ServiceCollectionsLoader?
    private var revision: UInt64 = 0
    var selected: ServiceCollectionJob? { jobs.first { $0.jobId == selectedID } }
    static func eligible(_ item: ServiceCollectionItem) -> Bool { item.entry != nil && item.savedTrackId == nil && ![ServiceMediaAccess.restricted, .unavailable, .unsupportedLive].contains(item.access) }
    func prepare(_ loader: ServiceCollectionsLoader) async {
        revision &+= 1; let current = revision; self.loader = loader
        do { let list = try await loader.list(); guard revision == current else { return }; jobs = list; if selectedID == nil { selectedID = list.first?.jobId } }
        catch { self.error = "Não foi possível carregar as capturas salvas." }
    }
    func select(_ id: String?) {
        if busy, let old = selectedID, old != id, let loader { Task { _ = try? await loader.cancel(old) } }
        revision &+= 1; selectedID = id; selectedItems = Set(selected?.items.filter(Self.eligible).map(\.occurrenceId) ?? []); reviewed = false; busy = false }
    private func publish(_ job: ServiceCollectionJob) {
        let priorEligible = Set(selected?.items.filter(Self.eligible).map(\.occurrenceId) ?? [])
        if let i = jobs.firstIndex(where: { $0.jobId == job.jobId }) { jobs[i] = job } else { jobs.insert(job, at: 0) }
        if selectedID == job.jobId {
            let eligible = Set(job.items.filter(Self.eligible).map(\.occurrenceId))
            selectedItems = selectedItems.intersection(eligible).union(eligible.subtracting(priorEligible)); reviewed = false
        }
    }
    func begin(_ url: String) async {
        guard let loader, !busy else { return }; revision &+= 1; let current = revision; busy = true; error = nil
        defer { if revision == current { busy = false } }
        do {
            var job = try await loader.begin(url); guard revision == current else { return }
            selectedID = job.jobId; publish(job)
            if job.loadedPages == 0 { job = try await loader.page(job.jobId, false); guard revision == current else { return }; publish(job) }
        } catch { if revision == current { show(error) } }
    }
    func loadNext(refresh: Bool = false) async {
        guard let loader, let id = selectedID, !busy else { return }; revision &+= 1; let current = revision; busy = true; error = nil
        defer { if revision == current { busy = false } }
        do {
            if selected?.cancelled == true { publish(try await loader.resume(id)) }
            let result = try await loader.page(id, refresh); guard revision == current, selectedID == id else { return }; publish(result)
        } catch { if revision == current { show(error) } }
    }
    func retryPages() async {
        guard let loader, let job = selected, !busy else { return }; revision &+= 1; let current = revision; busy = true; error = nil
        defer { if revision == current { busy = false } }
        do {
            if job.cancelled { publish(try await loader.resume(job.jobId)) }
            for index in 0..<job.loadedPages { let result = try await loader.retry(job.jobId, index); guard revision == current, selectedID == job.jobId else { return }; publish(result); if result.failure != nil { return } }
        } catch { if revision == current { show(error) } }
    }
    func apply() async {
        guard let loader, let id = selectedID, reviewed, !busy else { return }; revision &+= 1; let current = revision; busy = true; error = nil
        defer { if revision == current { busy = false } }
        do { let result = try await loader.apply(id, selectedItems.sorted(), true); guard revision == current, selectedID == id else { return }; publish(result) }
        catch { if revision == current { show(error) } }
    }
    func cancel() async {
        guard let loader, let id = selectedID else { return }; revision &+= 1; let current = revision
        busy = false; reviewed = false
        do { let result = try await loader.cancel(id); guard revision == current else { return }; publish(result) }
        catch { if revision == current { show(error) } }
    }
    func refreshProgress() async {
        guard busy, let id = selectedID, let progress = loader?.progress else { return }; let current = revision
        guard let job = try? await progress(id), busy, current == revision, selectedID == id else { return }
        if let i = jobs.firstIndex(where: { $0.jobId == id }) { jobs[i] = job }
    }
    func close() async { if busy { await cancel() }; revision &+= 1 }
    private func show(_ error: Error) { if case CoreError.InvalidInput(let text) = error { self.error = text } else { self.error = "Não foi possível concluir a ação. Os itens já salvos foram preservados." } }
}
extension ServiceImportFailure {
    var message: String { switch self {
    case .disabled: "Esta integração está desativada. Habilite-a nos Ajustes de serviços."
    case .authentication: "Credencial ausente ou expirada. Confira o token ou a chave da API nos Ajustes."
    case .restricted: "O serviço restringiu o acesso. Este fluxo aceita somente recursos públicos autorizados."
    case .notFound: "O item não foi encontrado no serviço."
    case .timedOut: "A consulta excedeu o tempo de espera. Tente novamente quando a conexão estiver disponível."
    case .rateLimited: "O serviço pediu para aguardar. Tente mais tarde."
    case .unavailable: "O serviço está indisponível. Os itens recebidos foram preservados."
    case .invalidResponse: "Não foi possível importar este item ou a resposta não é compatível. Confira também se a playlist foi editada."
    case .changedCollection: "A coleção mudou ou a ordem da página é incompatível com a captura. Os itens salvos foram preservados."
    case .cancelled: "Captura cancelada. Você pode retomá-la."
    case .limitReached: "Limite de 1.000 itens ou 40 páginas atingido. A captura está parcial."
    } }
}
extension ServiceMediaAccess {
    var label: String { switch self {
    case .unknown: "Acesso ao áudio não verificado"
    case .streamObserved: "Stream observado; arquivo original ou de compra não incluído"
    case .preview: "Prévia; não conta como faixa completa"
    case .restricted: "Acesso restrito"
    case .unavailable: "Item indisponível"
    case .unsupportedLive: "Live ou estreia fora deste fluxo"
    } }
}
