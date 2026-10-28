import Foundation
import Observation

struct SoulseekSearchLoader {
    var search: (DownloadSearchRequest, UInt64) async throws -> DownloadSearchPage
    var poll: (UInt64) async throws -> DownloadSearchPage
    var cancel: () async -> DownloadSearchPage
    var enqueue: ((String, [String], Bool) async throws -> DownloadTransferJob)?
    var close: () async -> Void
    init(session: DownloadSearchSession) {
        search = { try await session.search(request: $0, generation: $1) }
        poll = { try await session.poll(generation: $0) }
        cancel = { await session.cancel() }
        close = { await session.close() }
        enqueue = { try await session.enqueueDownload(offerId: $0, filenames: $1, confirmed: $2) }
    }
    init(search: @escaping (DownloadSearchRequest, UInt64) async throws -> DownloadSearchPage, poll: @escaping (UInt64) async throws -> DownloadSearchPage, cancel: @escaping () async -> DownloadSearchPage, close: @escaping () async -> Void) {
        self.search = search; self.poll = poll; self.cancel = cancel; self.close = close
    }
}
@MainActor @Observable
final class SoulseekSearchPresentation {
    private(set) var page: DownloadSearchPage?
    private(set) var busy = false
    private(set) var error: String?
    var textFilter = ""
    var formatFilter = ""
    var freeSlotsOnly = false
    var minimumBitrate = 0
    var selectedID: String?
    private var generation: UInt64 = 0
    private var loader: SoulseekSearchLoader?
    private var task: Task<Void, Never>?
    var groups: [DownloadOfferGroup] {
        (page?.groups ?? []).filter { group in
            (!freeSlotsOnly || group.freeUploadSlot == true) &&
            (textFilter.isEmpty || (group.peer + " " + group.folder).localizedCaseInsensitiveContains(textFilter) || group.files.contains { $0.filename.localizedCaseInsensitiveContains(textFilter) }) &&
            group.files.contains { file in
                (formatFilter.isEmpty || file.format == formatFilter) &&
                (minimumBitrate == 0 || (file.bitrateKbps ?? 0) >= UInt32(minimumBitrate))
            }
        }
    }
    var selected: DownloadOfferGroup? { groups.first { $0.offerId == selectedID } }
    var status: String {
        guard let page else { return "A busca só começa quando você confirmar a consulta." }
        if let failure = page.failure { return Self.message(failure) }
        switch page.state {
        case .searching: return "Buscando… \(page.groups.count) pastas encontradas."
        case .completed: return page.groups.isEmpty ? "Busca concluída sem ofertas. Isso não confirma ausência de arquivos na rede." : "Busca concluída: \(page.groups.count) pastas."
        case .timedOut: return "O prazo da busca terminou. A rede pode limitar as conexões; você pode tentar novamente. \(page.groups.count) pastas recebidas."
        case .cancelled: return "Busca cancelada."
        case .failed: return "Não foi possível concluir a busca."
        }
    }
    static func message(_ failure: DownloadSearchFailure) -> String {
        switch failure {
        case .disabled: return "A pesquisa Soulseek está desativada. Configure-a nos Ajustes."
        case .configuration: return "Confira o endereço e a configuração slskd nos Ajustes."
        case .authentication: return "A chave da API foi recusada ou não está disponível. Confira-a nos Ajustes."
        case .timedOut: return "A conexão excedeu o tempo de espera. A rede pode bloquear ou limitar o Soulseek. Tente novamente em uma rede permitida."
        case .unavailable: return "A pesquisa no slskd está indisponível. Confira o serviço, a consulta e as restrições da rede."
        case .rateLimited: return "O slskd pediu para aguardar. Tente novamente mais tarde."
        case .invalidResponse: return "O slskd retornou uma resposta incompatível ou grande demais."
        case .cancelled: return "A pesquisa foi cancelada ou a configuração mudou. Inicie outra busca."
        }
    }
    func enqueue(offerID: String, filenames: [String]) async throws -> DownloadTransferJob {
        guard let enqueue = loader?.enqueue else { throw CoreError.InvalidInput(message: "A busca não está disponível para download.") }
        return try await enqueue(offerID, filenames, true)
    }
    func prepare(_ loader: SoulseekSearchLoader) async {
        if self.loader != nil { await close() }
        self.loader = loader; page = nil; error = nil
    }
    func start(query: String, expected: [DownloadExpectedTrack]) {
        guard let loader else { return }
        task?.cancel(); generation &+= 1
        let current = generation
        busy = true; error = nil; page = nil; selectedID = nil
        task = Task { @MainActor in
            defer { if generation == current { busy = false } }
            do {
                var result = try await loader.search(DownloadSearchRequest(query: query, expectedTracks: expected), current)
                while !Task.isCancelled && generation == current {
                    guard result.generation == current else { return }
                    page = result
                    guard result.state == .searching else { return }
                    try await Task.sleep(for: .seconds(1))
                    result = try await loader.poll(current)
                }
            } catch {
                guard !Task.isCancelled, generation == current else { return }
                if case CoreError.InvalidInput(let text) = error { self.error = text }
                else { self.error = "Não foi possível realizar a pesquisa. Confira o slskd e a conexão." }
            }
        }
    }
    func cancel() async {
        task?.cancel(); generation &+= 1; let current = generation; busy = false
        let result = await loader?.cancel()
        guard generation == current else { return }
        page = result; selectedID = nil
    }
    func close() async { task?.cancel(); generation &+= 1; busy = false; await loader?.close() }
}
