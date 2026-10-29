import SwiftUI

extension ServiceProvider {
    var label: String { switch self { case .bandcamp: "Bandcamp"; case .soundCloud: "SoundCloud"; case .youTube: "YouTube" } }
}
struct ServiceImportSettingsView: View {
    @Environment(DurvaldCoreStore.self) private var store
    @State private var settings: [ServiceImportSettings] = []
    @State private var drafts: [String: String] = [:]
    @State private var enabled: [String: Bool] = [:]
    @State private var youtube = false
    @State private var busy = false
    @State private var error: String?
    @State private var diagnostics = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Serviços e coleções").font(.title2)
                Button("Diagnóstico dos serviços…") { diagnostics = true }
                    .accessibilityIdentifier("integrations.diagnostics.open")
                Text("Cada integração é opcional. Importar salva metadados e links, após revisão; não baixa áudio nem acessa arquivos comprados.").font(.caption).foregroundStyle(.secondary)
                ForEach(settings, id: \.provider) { setting in
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Importar de \(setting.provider.label)", isOn: Binding(get: { enabled[setting.provider.label] ?? setting.enabled }, set: { enabled[setting.provider.label] = $0 }))
                        if setting.provider != .bandcamp {
                            SecureField(setting.hasCredential ? "Nova credencial (vazio mantém a salva)" : (setting.provider == .soundCloud ? "Token OAuth SoundCloud" : "Chave da API de dados YouTube"), text: Binding(get: { drafts[setting.provider.label] ?? "" }, set: { drafts[setting.provider.label] = $0 }))
                            Text(setting.provider == .soundCloud ? "Use um token OAuth válido do seu aplicativo autorizado. Se expirar, informe um token atualizado. O widget de reprodução continua independente." : "A chave consulta vídeos e playlists públicas pela API oficial. Lives, estreias e vídeos sem verificação de duração finita ficam fora deste fluxo.").font(.caption).foregroundStyle(.secondary)
                        } else { Text("Leitura pública de faixas e álbuns. Stream observado não comprova áudio sem perdas. Coleções autenticadas e arquivos de compra não estão habilitados.").font(.caption).foregroundStyle(.secondary) }
                        HStack {
                            Button("Salvar \(setting.provider.label)") { Task { await save(setting, remove: false) } }
                            if setting.provider != .bandcamp { Button("Remover credencial e desativar") { Task { await save(setting, remove: true) } }.disabled(!setting.hasCredential) }
                        }
                    }.padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                }
                Toggle("Reproduzir YouTube como vídeo visível no player", isOn: Binding(get: { youtube }, set: { value in Task { do { try await store.core?.setYoutubePlaybackEnabled(enabled: value); youtube = value } catch { self.error = "Não foi possível alterar o player YouTube." } } }))
                Text("O player usa o IFrame oficial com vídeo e controles visíveis. Não oferece áudio isolado, download, equalização nem reprodução sem intervalo. A verificação dos metadados de vídeo deve ter menos de 24 horas.").font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
            }.padding()
        }.sheet(isPresented: $diagnostics) { IntegrationDiagnosticsView() }
        .disabled(busy || store.core == nil)
        .task(id: store.core.map(ObjectIdentifier.init)) {
            guard let core = store.core else { return }
            do { settings = try await core.serviceImportSettings(); youtube = await core.youtubePlaybackEnabled() }
            catch { self.error = "Não foi possível ler as configurações de serviços." }
        }
    }
    private func save(_ setting: ServiceImportSettings, remove: Bool) async {
        guard let core = store.core else { return }; busy = true; error = nil; defer { busy = false }
        let draft = drafts[setting.provider.label] ?? ""
        do {
            settings = try await core.configureServiceImport(provider: setting.provider, enabled: remove ? false : (enabled[setting.provider.label] ?? setting.enabled), credential: setting.provider == .bandcamp ? nil : (remove ? "" : (draft.isEmpty ? nil : draft)))
            drafts[setting.provider.label] = ""; enabled[setting.provider.label] = nil
        } catch CoreError.InvalidInput(let text) { self.error = text }
        catch { self.error = "Não foi possível salvar a integração ou a credencial protegida." }
    }
}
