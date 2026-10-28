import SwiftUI
import UniformTypeIdentifiers

struct DownloadTransfersView: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var initialJobID: String? = nil
    var isSheet = false
    @State private var presentation = DownloadTransfersPresentation()
    @State private var showSettings = false
    @State private var pickingFile = false
    @State private var fileToInspect: DownloadTransferFile?
    @State private var pollRevision: UInt64 = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Transferências").font(.title2)
                Spacer()
                Button("Configurar pastas…") { showSettings = true }
                Button("Atualizar") { pollRevision &+= 1 }
                if isSheet { Button("Fechar") { dismiss() } }
            }
            Text("Os lotes permanecem salvos após fechar o aplicativo. Apenas arquivos concluídos e revisados são importados; um lote parcial não confirma um álbum completo.").font(.caption).foregroundStyle(.secondary)
            if let error = presentation.error { Text(error).foregroundStyle(.red) }
            HSplitView {
                List(selection: $presentation.selectedID) {
                    ForEach(presentation.jobs, id: \.jobId) { job in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(job.folder).lineLimit(2)
                            Text("\(job.peer) · \(job.files.filter { $0.state == .imported }.count)/\(job.files.count) arquivos importados").font(.caption)
                        }.tag(job.jobId)
                    }
                }.frame(minWidth: 240, idealWidth: 290)
                ScrollView {
                    if let job = presentation.selected {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(job.peer).font(.headline)
                            Text("Lote: \(job.jobId)").font(.caption).textSelection(.enabled)
                            Text("Destino no slskd: \(job.remoteDownloadRoot)/\(job.relativeDestination)").font(.caption).textSelection(.enabled)
                            Text("Pasta acessível: \(job.mappedDownloadRoot)/\(job.relativeDestination)").font(.caption).textSelection(.enabled)
                            Text("Biblioteca: \(job.libraryDestination)").font(.caption).textSelection(.enabled)
                            if let message = job.message { Text(message).foregroundStyle(.secondary) }
                            ProgressView(value: job.files.reduce(0.0) { $0 + Double($1.bytesTransferred) }, total: max(1, job.files.reduce(0.0) { $0 + Double($1.sizeBytes) }))
                            Text("\(job.files.filter { [.completed, .importing, .imported].contains($0.state) }.count)/\(job.files.count) downloads concluídos · \(job.files.filter { $0.state == .imported }.count) importados").font(.caption)
                            HStack {
                                Button("Cancelar downloads pendentes") { Task { await presentation.cancel() } }.disabled(presentation.working)
                                Button("Retomar / tentar novamente") { Task { await presentation.retry(); pollRevision &+= 1 } }.disabled(presentation.working)
                                if presentation.working { ProgressView().controlSize(.small) }
                            }
                            ForEach(job.files, id: \.index) { file in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(file.filename).textSelection(.enabled)
                                    Text(file.state.label).font(.caption)
                                    ProgressView(value: Double(file.bytesTransferred), total: Double(max(file.sizeBytes, 1)))
                                    Text("\(bytes(file.bytesTransferred)) / \(bytes(file.sizeBytes))" + (file.queuePosition.map { " · Fila: \($0)" } ?? "")).font(.caption).foregroundStyle(.secondary)
                                    if let message = file.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                                    if file.state == .completed || file.state == .importing {
                                        Button("Localizar arquivo concluído e revisar…") { fileToInspect = file; pickingFile = true }.disabled(presentation.working)
                                    }
                                    if file.state == .importing {
                                        Button("Revisar importação pendente…") { Task { await presentation.inspect(file: file, path: nil) } }.disabled(presentation.working)
                                    }
                                    if let path = file.importedPath { Text(path).font(.caption).textSelection(.enabled) }
                                }
                                Divider()
                            }
                        }.padding().frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("Nenhuma transferência selecionada. Inicie um download na pesquisa Soulseek.").foregroundStyle(.secondary).padding()
                    }
                }.frame(minWidth: 430)
            }
        }.padding(20).frame(minWidth: 820, minHeight: 520)
        .task(id: store.core.map(ObjectIdentifier.init)) { if let core = store.core { await presentation.load(core: core, initialID: initialJobID) } }
        .task(id: "\(presentation.selectedID ?? ""):\(pollRevision)") {
            guard presentation.selectedID != nil else { return }
            await presentation.refresh()
            while !Task.isCancelled && presentation.shouldPoll {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard !Task.isCancelled else { return }; await presentation.refresh()
            }
        }
        .onDisappear { presentation.close() }
        .sheet(isPresented: $showSettings) { DownloadTransferSettingsView() }
        .sheet(isPresented: Binding(get: { presentation.preview != nil }, set: { if !$0 { presentation.preview = nil } })) {
            if let preview = presentation.preview { DownloadImportConfirmationView(preview: preview, onImported: presentation.didImport) }
        }
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.audio]) { result in
            guard let file = fileToInspect else { return }
            if case .success(let url) = result { Task { let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }; await presentation.inspect(file: file, path: url.path) } }
        }
    }
    private func bytes(_ value: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file) }
}
struct DownloadImportConfirmationView: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let preview: DownloadImportPreview
    let onImported: (DownloadTransferJob) -> Void
    @State private var target: Int64?
    @State private var query = ""
    @State private var matches: [Track] = []
    @State private var reviewed = false
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Revisar importação").font(.title2)
            Text(preview.title).font(.headline)
            Text("\(preview.artist) · \(preview.release) · \(Int(preview.durationSeconds)) s")
            Text(preview.destination).font(.caption).textSelection(.enabled)
            Text("Confira se este é o arquivo e a gravação desejados. A cópia será permanente; os metadados do arquivo serão preservados e a associação manterá avaliações, favoritos, tags e histórico da faixa existente.").font(.caption).foregroundStyle(.secondary)
            if preview.resuming { Text("Retomando a mesma importação e o destino já confirmado.").font(.caption) }
            Picker("Destino", selection: $target) {
                Text("Adicionar uma nova faixa").tag(Optional<Int64>.none)
                if let id = preview.targetTrackId { Text("Faixa confirmada #\(id)").tag(Optional(id)) }
                ForEach(matches.filter { $0.id != preview.targetTrackId }, id: \.id) { Text("\($0.title) — \($0.artist) — \($0.release)").tag(Optional($0.id)) }
            }.disabled(preview.resuming || busy)
            if !preview.resuming {
                HStack {
                    TextField("Buscar faixa existente para associar", text: $query)
                    Button("Buscar") { Task { matches = (try? await store.core?.search(query: query).tracks) ?? [] } }
                }.disabled(busy)
            }
            Toggle("Conferi o arquivo, a gravação e o destino", isOn: $reviewed).disabled(busy)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button(busy ? "Importando…" : "Confirmar e importar") { Task { await confirm() } }.disabled(!reviewed || busy)
                if busy { ProgressView().controlSize(.small) }
                Button("Cancelar") { dismiss() }.disabled(busy)
            }
        }.padding(24).frame(width: 650)
        .interactiveDismissDisabled(busy)
        .onAppear { target = preview.targetTrackId }
    }
    private func confirm() async {
        guard let core = store.core else { return }; busy = true; defer { busy = false }
        do {
            let job = try await core.importDownloadFile(jobId: preview.jobId, fileIndex: preview.fileIndex, reviewToken: preview.reviewToken, targetTrackId: target, confirmed: reviewed)
            await store.sourcesDidChange(); onImported(job); dismiss()
        } catch CoreError.InvalidInput(let text) { self.error = text }
        catch { self.error = "Não foi possível confirmar a importação. O registro foi preservado para tentar novamente." }
    }
}
