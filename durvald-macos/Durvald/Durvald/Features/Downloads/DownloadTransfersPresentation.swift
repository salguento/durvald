import Foundation
import Observation

struct DownloadTransfersLoader {
    var list: () async throws -> [DownloadTransferJob]
    var refresh: (String) async throws -> DownloadTransferJob
    var cancel: (String) async throws -> DownloadTransferJob
    var retry: (String) async throws -> DownloadTransferJob
    var inspect: (String, UInt32, String) async throws -> DownloadImportPreview
    var pending: (String, UInt32) async throws -> DownloadImportPreview
}
extension DownloadTransfersLoader {
    init(core: DurvaldCore) {
        list = { try await core.downloadTransfers() }
        refresh = { try await core.refreshDownloadTransfer(jobId: $0) }
        cancel = { try await core.cancelDownloadTransfer(jobId: $0) }
        retry = { try await core.retryDownloadTransfer(jobId: $0) }
        inspect = { try await core.inspectDownloadFile(jobId: $0, fileIndex: $1, path: $2) }
        pending = { try await core.pendingDownloadImport(jobId: $0, fileIndex: $1) }
    }
}

@MainActor @Observable
final class DownloadTransfersPresentation {
    private(set) var jobs: [DownloadTransferJob] = []
    private(set) var error: String?
    private(set) var working = false
    var selectedID: String?
    var preview: DownloadImportPreview?
    private var loader: DownloadTransfersLoader?
    private var generation: UInt64 = 0
    var selected: DownloadTransferJob? { jobs.first { $0.jobId == selectedID } }
    var shouldPoll: Bool {
        guard let job = selected, job.message == nil else { return false }
        return job.files.contains { [.prepared, .submissionUnknown, .queued, .downloading].contains($0.state) }
    }
    func load(core: DurvaldCore, initialID: String?) async {
        await load(loader: DownloadTransfersLoader(core: core), initialID: initialID)
    }
    func load(loader: DownloadTransfersLoader, initialID: String?) async {
        generation &+= 1; let ticket = generation; self.loader = loader
        do {
            let restored = try await loader.list()
            guard generation == ticket, !Task.isCancelled else { return }
            jobs = restored
            if let initialID { selectedID = initialID }
            if selectedID == nil { selectedID = jobs.first?.jobId }
        } catch { self.error = "Não foi possível carregar as transferências salvas." }
    }
    private func publish(_ job: DownloadTransferJob) {
        if let i = jobs.firstIndex(where: { $0.jobId == job.jobId }) { jobs[i] = job } else { jobs.insert(job, at: 0) }
    }
    func refresh() async {
        guard let loader, let id = selectedID else { return }
        generation &+= 1; let ticket = generation
        do {
            let result = try await loader.refresh(id)
            guard generation == ticket, selectedID == id, !Task.isCancelled else { return }
            publish(result); self.error = nil
        } catch { guard generation == ticket else { return }; self.error = "Não foi possível atualizar o lote. O registro local foi preservado." }
    }
    func cancel() async {
        guard let loader, let id = selectedID else { return }; working = true; generation &+= 1
        defer { working = false }
        do { publish(try await loader.cancel(id)); self.error = nil }
        catch { self.error = "O cancelamento não pôde ser confirmado. Atualize o lote quando a conexão voltar." }
    }
    func retry() async {
        guard let loader, let id = selectedID, !working else { return }; working = true; defer { working = false }
        do { publish(try await loader.retry(id)); self.error = nil }
        catch CoreError.InvalidInput(let text) { self.error = text }
        catch { self.error = "Não foi possível retomar este lote." }
    }
    func inspect(file: DownloadTransferFile, path: String?) async {
        guard let loader, let id = selectedID, !working else { return }; working = true; defer { working = false }
        do {
            let result: DownloadImportPreview
            if let path { result = try await loader.inspect(id, file.index, path) }
            else { result = try await loader.pending(id, file.index) }
            guard selectedID == id else { return }; preview = result; self.error = nil
        } catch CoreError.InvalidInput(let text) { self.error = text }
        catch { self.error = "Não foi possível validar o arquivo para importação." }
    }
    func didImport(_ job: DownloadTransferJob) { publish(job); preview = nil; self.error = nil }
    func close() { generation &+= 1 }
}
extension DownloadFileState {
    var label: String { switch self {
    case .prepared: "Preparado"
    case .submissionUnknown: "Envio ainda não confirmado"
    case .queued: "Na fila do slskd"
    case .downloading: "Baixando"
    case .completed: "Concluído; aguardando revisão"
    case .failed: "Falhou"
    case .cancelled: "Cancelado"
    case .importing: "Importação pendente de confirmação"
    case .imported: "Importado"
    } }
}
