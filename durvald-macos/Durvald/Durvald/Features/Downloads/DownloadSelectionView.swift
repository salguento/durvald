import SwiftUI

struct DownloadSelectionView: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let group: DownloadOfferGroup
    let enqueue: ([String]) async throws -> Void
    @State private var selected = Set<String>()
    @State private var settings: DownloadTransferSettings?
    @State private var showSettings = false
    @State private var confirmed = false
    @State private var busy = false
    @State private var error: String?
    private func supported(_ file: DownloadOfferFile) -> Bool { ["mp3", "wav", "flac", "ogg", "oga"].contains(file.format) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Confirmar download").font(.title2)
            Text("\(group.peer) · \(group.folder)").textSelection(.enabled)
            Text("Selecione os arquivos. O download usa a pasta do slskd indicada abaixo; a importação na biblioteca será revisada separadamente. Selecionar uma pasta de resultados não inicia transferências.").font(.caption).foregroundStyle(.secondary)
            List(group.files, id: \.filename) { file in
                Toggle(isOn: Binding(get: { selected.contains(file.filename) }, set: { if $0 { selected.insert(file.filename) } else { selected.remove(file.filename) } })) {
                    Text(file.filename).font(.caption)
                }.disabled(!supported(file) || busy)
            }.frame(height: 220)
            if let settings {
                Text("slskd: \(settings.remoteDownloadRoot)/durvald/<lote>").font(.caption).textSelection(.enabled)
                Text("Pasta acessível: \(settings.mappedDownloadRoot)").font(.caption).textSelection(.enabled)
                Text("Biblioteca: \(settings.libraryDestination)").font(.caption).textSelection(.enabled)
                if !settings.enabled { Text("Habilite as transferências e configure as pastas antes de baixar.").foregroundStyle(.secondary) }
            }
            Button("Configurar pastas…") { showSettings = true }.disabled(busy)
            Toggle("Revisei os arquivos selecionados e os destinos", isOn: $confirmed).disabled(busy)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button(busy ? "Enviando…" : "Baixar \(selected.count) arquivos") { Task { await submit() } }.disabled(busy || !confirmed || selected.isEmpty || settings?.enabled != true)
                if busy { ProgressView().controlSize(.small) }
                Button("Cancelar") { dismiss() }.disabled(busy)
            }
        }.padding(24).frame(width: 700)
        .interactiveDismissDisabled(busy)
        .task { selected = Set(group.files.filter(supported).map(\.filename)); await loadSettings() }
        .sheet(isPresented: $showSettings, onDismiss: { Task { await loadSettings() } }) { DownloadTransferSettingsView() }
    }
    private func loadSettings() async { settings = try? await store.core?.downloadTransferSettings() }
    private func submit() async {
        busy = true; self.error = nil; defer { busy = false }
        do { try await enqueue(selected.sorted()); dismiss() }
        catch CoreError.InvalidInput(let message) { self.error = message }
        catch { self.error = "Não foi possível confirmar o envio. Confira a fila de transferências antes de tentar novamente." }
    }
}
