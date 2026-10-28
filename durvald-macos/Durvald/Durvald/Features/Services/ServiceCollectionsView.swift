import SwiftUI

struct ServiceCollectionsView: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var initialURL: String? = nil
    var isSheet = false
    @State private var url = ""
    @State private var presentation = ServiceCollectionsPresentation()
    @State private var showSettings = false
    @State private var actionError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Serviços e coleções").font(.title2)
                Spacer()
                Button("Configurar serviços…") { showSettings = true }
                if isSheet { Button("Fechar") { dismiss() } }
            }
            HStack {
                TextField("Link de faixa, vídeo, álbum Bandcamp ou playlist", text: $url).onSubmit { begin() }
                Button("Consultar link") { begin() }.disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || presentation.busy)
                Button("Cancelar") { Task { await presentation.cancel() } }.disabled(!presentation.busy)
            }
            Text("A consulta não salva itens nem inicia áudio. A importação salva links e metadados, por confirmação. Arquivos de compra, coleções autenticadas Bandcamp, mixes, lives e estreias ficam fora deste fluxo.").font(.caption).foregroundStyle(.secondary)
            if let error = presentation.error ?? actionError { Text(error).foregroundStyle(.red) }
            HSplitView {
                List(selection: Binding(get: { presentation.selectedID }, set: { presentation.select($0) })) {
                    ForEach(presentation.jobs, id: \.jobId) { job in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(job.title).lineLimit(2)
                            Text("\(job.provider.label) · \(job.items.filter { $0.savedTrackId != nil }.count)/\(job.items.count) salvos").font(.caption).foregroundStyle(.secondary)
                        }.tag(job.jobId)
                    }
                }.frame(minWidth: 220, idealWidth: 270)
                ScrollView { if let job = presentation.selected { details(job) } else { Text("Cole um link para iniciar uma captura revisável.").foregroundStyle(.secondary).padding() } }.frame(minWidth: 430)
            }
        }.padding(20).frame(minWidth: 820, minHeight: 540)
        .task(id: store.core.map(ObjectIdentifier.init)) {
            url = initialURL ?? ""
            if let core = store.core { await presentation.prepare(ServiceCollectionsLoader(core: core)) }
        }
        .task(id: presentation.busy) {
            while presentation.busy && !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                await presentation.refreshProgress()
            }
        }
        .sheet(isPresented: $showSettings) {
            VStack(spacing: 0) {
                HStack { Spacer(); Button("Fechar") { showSettings = false }.keyboardShortcut(.cancelAction) }.padding()
                ServiceImportSettingsView()
            }.frame(width: 660, height: 600)
        }
        .onDisappear { Task { await presentation.close() } }
    }
    private func begin() { Task { await presentation.begin(url) } }
    private func details(_ job: ServiceCollectionJob) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(job.title).font(.headline)
            if let link = URL(string: job.canonicalUrl) { Link("Abrir coleção / item no serviço", destination: link) }
            Text("\(job.items.count) ocorrências recebidas em \(job.loadedPages) páginas · \(job.items.filter { $0.savedTrackId != nil }.count) salvas" + (job.fromCache ? " · Em cache" : "")).font(.caption)
            if job.truncated { Text("Captura parcial: o serviço não expôs todos os itens ou o limite foi atingido.").foregroundStyle(.secondary) }
            if let failure = job.failure { Text(failure.message).foregroundStyle(.secondary) }
            HStack {
                Button(job.cancelled ? "Retomar captura" : "Carregar próxima página") { Task { await presentation.loadNext() } }
                    .disabled(presentation.busy || (!job.cancelled && (job.complete || job.items.count >= 1000 || job.loadedPages >= 40 || (job.loadedPages > 0 && job.nextCursor == nil))))
                Button("Rever páginas recebidas") { Task { await presentation.retryPages() } }.disabled(presentation.busy || job.loadedPages == 0)
                if presentation.busy { ProgressView().controlSize(.small) }
            }
            Text("Confira a gravação, edição, cover/remix e possíveis introduções de vídeo. Canal e uploader não são identidade verificada de artista. Ocorrências repetidas serão mantidas na playlist.").font(.caption).foregroundStyle(.secondary)
            ForEach(job.items, id: \.occurrenceId) { item in
                HStack(alignment: .top) {
                    Toggle(isOn: Binding(get: { presentation.selectedItems.contains(item.occurrenceId) }, set: { if $0 { presentation.selectedItems.insert(item.occurrenceId) } else { presentation.selectedItems.remove(item.occurrenceId) }; presentation.reviewed = false })) { EmptyView() }
                        .labelsHidden().disabled(presentation.busy || !ServiceCollectionsPresentation.eligible(item))
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(item.position + 1). \(item.entry?.title ?? "Item indisponível")")
                        if let credit = item.entry?.artistCredit { Text("Canal / uploader: \(credit)").font(.caption) }
                        Text(item.access.label).font(.caption).foregroundStyle(.secondary)
                        if let failure = item.failure { Text(failure.message).font(.caption).foregroundStyle(.secondary) }
                        HStack {
                            if let url = item.entry?.canonicalUrl, let link = URL(string: url) { Link("Abrir no serviço", destination: link) }
                            if item.savedTrackId != nil {
                                Text("Salvo").font(.caption)
                                if job.provider != .bandcamp { Button("Reproduzir no player") { Task { await play(item) } } }
                            }
                        }
                    }
                }
                Divider()
            }
            Toggle("Revisei os itens selecionados e suas versões", isOn: $presentation.reviewed).disabled(presentation.busy)
            Button("Salvar \(presentation.selectedItems.count) itens selecionados") { Task { await presentation.apply(); await store.sourcesDidChange() } }
                .disabled(!presentation.reviewed || presentation.selectedItems.isEmpty || presentation.busy || job.cancelled)
            if job.isCollection { Text("Os itens elegíveis selecionados são reunidos em uma playlist. Indisponíveis permanecem na captura para revisão; não viram faixas fictícias.").font(.caption).foregroundStyle(.secondary) }
        }.padding().frame(maxWidth: .infinity, alignment: .leading)
    }
    private func play(_ item: ServiceCollectionItem) async {
        guard let core = store.core, let track = item.savedTrackId, let entry = item.entry else { return }
        do {
            let sources = try await core.trackSources(trackId: track)
            guard let source = sources.first(where: { $0.provider == entry.reference.provider && $0.externalId == entry.reference.id }) else { return }
            _ = try await core.playEmbeddedTrackSource(trackId: track, sourceId: source.sourceId)
            await store.refreshPlayback(); await store.embeddedPlayer.refresh(); actionError = nil
        } catch { actionError = "Não foi possível reproduzir. Confira o player habilitado e, para YouTube, reveja os metadados do vídeo." }
    }
}
