import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SourceManagementView: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let entry: CatalogEntry
    @State private var presentation = SourceManagementPresentation()
    @State private var link = ""
    @State private var matchQuery = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading) { Text("Origens da música").font(.title2.bold()); Text(entry.title); if let artist = entry.artistCredit { Text(artist).foregroundStyle(.secondary) } }
                Spacer(); Button("Concluído") { dismiss() }.keyboardShortcut(.cancelAction).disabled(presentation.busy)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let message = presentation.message { Text(message).foregroundStyle(.secondary).textSelection(.enabled) }
                    if let error = presentation.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    savedSources
                    GroupBox("Buscar fontes para este item") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(presentation.providers, id: \.id) { provider in
                                Toggle(provider.name, isOn: Binding(get: { provider.enabled }, set: { value in Task { await presentation.setProvider(provider, enabled: value) } }))
                            }
                            HStack {
                                TextField("Link SoundCloud, YouTube ou Bandcamp (opcional)", text: $link)
                                    .accessibilityIdentifier("sources.link")
                                Button("Buscar fontes") { Task { await presentation.search(link: link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : link) } }
                                    .disabled(presentation.busy || !presentation.loading.isEmpty || !presentation.providers.contains(where: \.enabled))
                                    .accessibilityIdentifier("sources.search")
                            }
                            Text("A consulta usa apenas o item selecionado. Um link não comprova áudio completo ou reprodução interna.").font(.caption).foregroundStyle(.secondary)
                            ForEach(presentation.providers.filter(\.enabled), id: \.id) { provider in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack { Text(provider.name).font(.headline); if presentation.loading.contains(provider.id) { ProgressView().controlSize(.small) } }
                                    if let error = presentation.providerErrors[provider.id] { Text(error).foregroundStyle(.secondary) }
                                    if let page = presentation.pages[provider.id] {
                                        if let failure = page.failure { Text(failure.sourceMessage).foregroundStyle(.secondary) }
                                        else if page.candidates.isEmpty { Text("Nenhuma fonte encontrada por este serviço.").foregroundStyle(.secondary) }
                                        ForEach(page.candidates, id: \.candidateId) { candidate in candidateRow(candidate) }
                                    }
                                }
                            }
                        }.padding(8)
                    }
                    if let candidate = presentation.reviewing { review(candidate) }
                }
            }
        }.padding(24).frame(minWidth: 640, idealWidth: 760, minHeight: 500, idealHeight: 720)
        .accessibilityIdentifier("sources.management")
        .task(id: entry.entryKey) {
            guard let core = store.core else { return }
            await presentation.load(entry: entry, loader: NativeSourceManager(core: core,
                changed: { if store.core === core { await store.sourcesDidChange() } },
                playbackChanged: { if store.core === core { await store.refreshPlayback() } }))
        }
        .onDisappear { presentation.cancel() }
    }
    @ViewBuilder private var savedSources: some View {
        if let track = presentation.currentTrack {
            GroupBox("Origens salvas — \(track.title)") {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Escolher para tocar agora não altera a preferência salva.").font(.caption).foregroundStyle(.secondary)
                    ForEach(presentation.sources, id: \.sourceId) { source in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(source.provider == "local" ? "Arquivo local" : source.provider).font(.headline)
                                if source.preferred { Label("Preferida", systemImage: "star.fill").font(.caption) }
                                Spacer()
                                Toggle("Ativa", isOn: Binding(get: { source.enabled }, set: { value in Task { await presentation.enabled(source, value: value) } })).toggleStyle(.checkbox)
                            }
                            Text(source.title ?? source.localPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Origem externa")
                            metadata(uploader: source.uploader, version: source.versionLabel, duration: source.durationSeconds, capability: source.capability)
                            if let path = source.localPath { Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                            if let url = source.canonicalUrl { Text(url).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                            if let checked = source.lastCheckedAt { Text("Última verificação: \(checked)").font(.caption).foregroundStyle(.secondary) }
                            HStack {
                                Button("Verificar") { Task { await presentation.test(source) } }
                                Button(source.preferred ? "Limpar preferência" : "Tornar preferida") { Task { await presentation.prefer(source) } }
                                if source.localPath != nil {
                                    Button("Tocar agora com esta origem") { Task { await presentation.play(source) } }.disabled(!source.enabled || source.capability != .fullAudio)
                                } else {
                                    Button("Abrir no serviço") { Task { if let url = await presentation.openURL(source) { NSWorkspace.shared.open(url) } } }.disabled(source.capability != .externalOpen && source.capability != .preview)
                                }
                                Button("Remover origem", role: .destructive) { Task { await presentation.remove(source) } }
                            }.controlSize(.small)
                        }.disabled(presentation.busy)
                        Divider()
                    }
                    if presentation.sources.isEmpty { Text("Nenhuma origem associada. Os dados da faixa foram preservados.").foregroundStyle(.secondary) }
                    Button("Anexar arquivo local…") { chooseLocalFile() }.disabled(presentation.busy)
                }.padding(8)
            }
        }
    }
    private func candidateRow(_ candidate: SourceCandidate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(candidate.title).font(.headline)
            Text(candidate.provider).font(.caption).foregroundStyle(.secondary)
            metadata(uploader: candidate.uploader, version: candidate.versionLabel, duration: candidate.durationSeconds, capability: candidate.capability)
            if let url = URL(string: candidate.canonicalUrl) { Link("Abrir no serviço", destination: url) }
            Button("Revisar associação…") { presentation.review(candidate); matchQuery = "" }.disabled(presentation.busy)
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
    private func metadata(uploader: String?, version: String?, duration: UInt64?, capability: SourceCapability) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Uploader: \(uploader ?? "não informado") · Versão: \(version ?? "não informada")")
            Text("Duração: \(duration.map { "\($0 / 60):\(String(format: "%02d", $0 % 60))" } ?? "não informada") · \(capability.sourceLabel)")
        }.font(.caption).foregroundStyle(.secondary)
    }
    private func review(_ candidate: SourceCandidate) -> some View {
        GroupBox("Revisar antes de associar") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Confira artista, versão e duração. A semelhança de nomes não confirma a mesma gravação ou edição.")
                Text(candidate.canonicalUrl).font(.caption).textSelection(.enabled)
                Picker("Destino", selection: $presentation.associationTrackID) {
                    if entry.reference.provider != "library" { Text("Adicionar uma faixa à biblioteca").tag(Optional<Int64>.none) }
                    if let track = presentation.currentTrack { Text("\(track.title) — \(track.artist)").tag(Optional(track.id)) }
                    ForEach(presentation.matches.filter { $0.id != presentation.currentTrack?.id }, id: \.id) { track in
                        Text("\(track.title) — \(track.artist) — \(track.release)").tag(Optional(track.id))
                    }
                }
                HStack {
                    TextField("Encontrar outra faixa na biblioteca", text: $matchQuery)
                    Button("Encontrar") { Task { await presentation.findMatches(matchQuery) } }
                }
                HStack {
                    Button(presentation.associationTrackID == nil ? "Confirmar e adicionar faixa" : "Confirmar e anexar origem") { Task { await presentation.confirm() } }
                        .accessibilityIdentifier("sources.confirm")
                    Button("Cancelar revisão") { presentation.reviewing = nil }
                }.disabled(presentation.busy)
            }.padding(8)
        }
    }
    private func chooseLocalFile() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.allowedContentTypes = [.audio]
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            Task { @MainActor in await presentation.attachLocal(url.path) }
        }
    }
}
private extension CatalogFailure {
    var sourceMessage: String {
        switch self {
        case .disabled: "Serviço desativado."
        case .unavailable: "Este serviço está indisponível. Os outros resultados continuam disponíveis."
        case .invalidQuery: "Este item ou link não é compatível com o serviço."
        case .rateLimited: "O serviço pediu para aguardar antes de consultar novamente."
        case .timedOut: "O serviço demorou para responder."
        case .cancelled: "Consulta cancelada."
        }
    }
}
