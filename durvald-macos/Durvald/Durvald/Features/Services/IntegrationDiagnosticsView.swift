import SwiftUI

extension IntegrationOutcome {
    var recoveryMessage: String {
        switch self {
        case .succeeded: "Operação concluída."
        case .cancelled: "Operação cancelada. Inicie novamente quando quiser."
        case .timedOut: "A fonte demorou para responder. Confira a rede ou tente novamente mais tarde."
        case .rateLimited: "Aguarde o limite informado pela fonte antes de tentar novamente."
        case .authentication: "Revise a credencial nos ajustes deste serviço."
        case .disabled: "Integração desativada. Ative nos ajustes se quiser usá-la."
        case .busy: "Há operações em andamento. Aguarde ou cancele uma busca."
        case .unavailable: "Fonte indisponível. Confira a configuração e tente novamente. A biblioteca local continua disponível."
        }
    }
}
extension IntegrationOperation {
    var diagnosticLabel: String {
        switch self {
        case .catalogSearch: "Pesquisa de catálogo"
        case .metadata: "Detalhes"
        case .sourceSearch: "Busca de fontes"
        case .playbackResolution: "Preparação da fonte"
        case .downloadSearch: "Pesquisa de arquivos"
        case .downloadTransfer: "Transferências"
        case .collectionRead: "Leitura de coleções"
        case .other: "Outras operações"
        }
    }
}

struct IntegrationDiagnosticsView: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: IntegrationDiagnostics?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Diagnóstico dos serviços").font(.title2)
                Spacer()
                Button("Atualizar") { Task { await refresh() } }.disabled(store.core == nil)
                    .accessibilityIdentifier("integrations.diagnostics.refresh")
            }
            Text("Dados desta execução. Atualizar lê os contadores locais, sem consultar serviços. Não inclui consultas, links ou credenciais.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Os tempos incluem a espera pela integração; preparação da fonte não mede o buffering do player oficial.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                if let snapshot {
                    if !snapshot.preferencesAvailable {
                        Text("As configurações das integrações estão indisponíveis. A biblioteca local continua disponível. Preserve o arquivo music-plugins.json e revise sua versão antes de restaurar um backup.")
                    }
                    ForEach(snapshot.providers, id: \.provider) { provider in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(provider.provider) · \(provider.enabled ? "Ativo" : "Desativado")").font(.headline)
                            Text("Adaptador \(provider.adapterVersion)").font(.caption).foregroundStyle(.secondary)
                            if provider.measurements.isEmpty { Text("Sem operações nesta execução.").font(.callout) }
                            ForEach(provider.measurements, id: \.operation) { m in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(m.operation.diagnosticLabel).font(.subheadline)
                                    Text("\(m.active) em andamento · \(m.succeeded) concluídas · \(m.failed) falhas · \(m.cancelled) canceladas").font(.caption)
                                    Text("p95: \(m.p95ElapsedMs) ms · espera: \(m.p95QueueMs) ms · últimas \(m.sampleCount) operações").font(.caption).foregroundStyle(.secondary)
                                    if let outcome = m.lastOutcome { Text(outcome.recoveryMessage).font(.callout) }
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                    }
                } else { Text("Carregando diagnóstico…") }
            }
            HStack { Spacer(); Button("Concluído") { dismiss() }.keyboardShortcut(.defaultAction) }
            Text("Áudio local independe destes serviços. Soulseek usa o slskd configurado por você; SoundCloud e YouTube usam players oficiais visíveis. Bandcamp permite consulta e importação de metadados.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding().frame(width: 560, height: 480)
            .task(id: store.core.map(ObjectIdentifier.init)) { await refresh() }
    }
    private func refresh() async { snapshot = await store.core?.integrationDiagnostics() }
}
