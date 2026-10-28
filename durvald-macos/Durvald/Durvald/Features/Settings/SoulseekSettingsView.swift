import SwiftUI

struct SoulseekSettingsView: View {
    @Environment(DurvaldCoreStore.self) private var store
    @State private var endpoint = "http://127.0.0.1:5030"
    @State private var key = ""
    @State private var enabled = false
    @State private var acknowledged = false
    @State private var hasKey = false
    @State private var busy = false
    @State private var message: String?
    @State private var showTransfers = false
    var body: some View {
        Form {
            Toggle("Habilitar pesquisa Soulseek", isOn: $enabled)
            TextField("Endereço slskd", text: $endpoint)
            SecureField(hasKey ? "Nova chave da API (vazio mantém a atual)" : "Chave da API slskd", text: $key)
            Text("Conecte uma instância slskd instalada e configurada por você. Use HTTPS para endereços remotos. A conta Soulseek e os compartilhamentos são gerenciados no slskd.").font(.caption).foregroundStyle(.secondary)
            Toggle("Revisei os compartilhamentos da minha instância slskd", isOn: $acknowledged)
            Text("Habilitar a pesquisa não compartilha sua biblioteca. A chave fica no armazenamento protegido do sistema. Downloads e importações exigem confirmação e destinos configurados separadamente.").font(.caption).foregroundStyle(.secondary)
            Button("Configurar transferências e pastas…") { showTransfers = true }
            if let message { Text(message).foregroundStyle(.secondary) }
            HStack {
                Button("Salvar") { Task { await save(removeKey: false) } }
                Button("Remover chave e desativar") { Task { await save(removeKey: true) } }.disabled(!hasKey)
                if busy { ProgressView().controlSize(.small) }
            }
        }
        .sheet(isPresented: $showTransfers) { DownloadTransferSettingsView() }
        .disabled(busy || store.core == nil)
        .task(id: store.core.map(ObjectIdentifier.init)) {
            guard let core = store.core else { return }
            do { apply(try await core.downloadSearchSettings()) }
            catch { message = "Não foi possível ler a configuração Soulseek." }
        }
    }
    private func apply(_ settings: DownloadSearchSettings) {
        endpoint = settings.endpoint; enabled = settings.enabled; acknowledged = settings.sharingAcknowledged; hasKey = settings.hasApiKey
    }
    private func save(removeKey: Bool) async {
        guard let core = store.core, !busy else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            let value = try await core.configureDownloadSearch(endpoint: endpoint, apiKey: removeKey ? "" : (key.isEmpty ? nil : key), enabled: removeKey ? false : enabled, sharingAcknowledged: acknowledged)
            apply(value); key = ""; message = "Configuração salva. A conexão será usada ao iniciar uma busca."
        } catch CoreError.InvalidInput(let text) { message = text }
        catch { message = "Não foi possível salvar. Confira o armazenamento protegido e a configuração antes de tentar novamente." }
    }
}
