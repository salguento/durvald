import SwiftUI
import UniformTypeIdentifiers

struct DownloadTransferSettingsView: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var value = DownloadTransferSettings(enabled: false, remoteDownloadRoot: "", mappedDownloadRoot: "", libraryDestination: "", mappingConfirmed: false)
    @State private var choosingFolder = false
    @State private var choosingLibrary = false
    @State private var busy = false
    @State private var message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Transferências Soulseek").font(.title2)
            Form {
                Toggle("Permitir downloads por confirmação explícita", isOn: $value.enabled)
                TextField("Diretório de downloads configurado no slskd", text: $value.remoteDownloadRoot)
                Text("É o caminho no computador do slskd. Cada lote usa uma subpasta durvald própria. Esse caminho não é tratado como arquivo local.").font(.caption).foregroundStyle(.secondary)
                HStack { TextField("A mesma pasta acessível neste Mac", text: $value.mappedDownloadRoot); Button("Escolher…") { choosingLibrary = false; choosingFolder = true } }
                HStack { TextField("Destino permanente na biblioteca", text: $value.libraryDestination); Button("Escolher…") { choosingLibrary = true; choosingFolder = true } }
                Toggle("Confirmei que a pasta acessível corresponde à pasta do slskd", isOn: $value.mappingConfirmed)
                Text("Para slskd remoto, monte a pasta compartilhada neste Mac antes de importar. Após a conclusão, você localizará o arquivo dentro da subpasta do lote. O áudio será validado e copiado para o destino permanente; os originais serão preservados.").font(.caption).foregroundStyle(.secondary)
                Text("Formatos importáveis: MP3, WAV, FLAC e Ogg Vorbis. A busca permanece independente; nenhum download começa ao abrir esta tela.").font(.caption).foregroundStyle(.secondary)
            }.disabled(busy)
            if let message { Text(message).foregroundStyle(.red) }
            HStack {
                Button("Salvar") { Task { await save() } }.disabled(busy || store.core == nil)
                if busy { ProgressView().controlSize(.small) }
                Button("Fechar") { dismiss() }.disabled(busy)
            }
        }.padding(24).frame(width: 660, height: 520)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                if choosingLibrary { value.libraryDestination = url.path } else { value.mappedDownloadRoot = url.path }
            }
        }
        .task { if let core = store.core { do { value = try await core.downloadTransferSettings() } catch { message = "Não foi possível ler a configuração de transferências." } } }
    }
    private func save() async {
        guard let core = store.core else { return }; busy = true; defer { busy = false }
        do { value = try await core.configureDownloadTransfers(settings: value); dismiss() }
        catch CoreError.InvalidInput(let text) { message = text }
        catch { message = "Não foi possível salvar a configuração." }
    }
}
