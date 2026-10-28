import SwiftUI

struct ListeningSourceSaveView: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let generation: String
    @State private var query = ""
    @State private var matches: [Track] = []
    @State private var target: Int64?
    @State private var reviewed = false
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Salvar ou associar a origem").font(.title2)
            if let current = store.embeddedPlayer.status, current.generation == generation {
                Text(current.title).font(.headline)
                Text(current.canonicalUrl).textSelection(.enabled)
                Text("Confira no widget artista, versão e duração. A semelhança de nomes não confirma que seja a mesma gravação.")
                Picker("Destino", selection: $target) {
                    Text("Adicionar uma faixa à biblioteca").tag(Optional<Int64>.none)
                    ForEach(matches, id: \.id) { track in Text("\(track.title) — \(track.artist) — \(track.release)").tag(Optional(track.id)) }
                }
                HStack {
                    TextField("Encontrar faixa existente", text: $query)
                    Button("Buscar") { Task { do { matches = try await store.core?.search(query: query).tracks ?? [] } catch { self.error = "Não foi possível buscar na biblioteca." } } }
                }
                Toggle("Conferi a faixa e a versão antes de associar", isOn: $reviewed)
                if let error { Text(error).foregroundStyle(.red) }
                HStack {
                    Button("Confirmar e salvar") { Task { await save() } }.disabled(!reviewed || busy)
                        .accessibilityIdentifier("listening.confirmSave")
                    Button("Cancelar") { dismiss() }.disabled(busy)
                }
            } else {
                Text("A audição mudou. Feche e revise a origem atual.")
                Button("Fechar") { dismiss() }
            }
        }.padding(24).frame(width: 560)
    }
    private func save() async {
        guard let core = store.core, !busy else { return }; busy = true
        defer { busy = false }
        do {
            _ = try await core.saveListeningSource(generation: generation, trackId: target, confirmed: reviewed)
            await store.sourcesDidChange(); await store.embeddedPlayer.refresh()
            dismiss()
        } catch { self.error = String(describing: error) }
    }
}
struct SoundCloudLinkView: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var title = ""
    @State private var artist = ""
    @State private var selected: CatalogEntry?
    @State private var busy = false
    @State private var resolvingTask: Task<Void, Never>?
    @State private var error: String?
    var body: some View {
        Group {
            if let selected { SourceManagementView(entry: selected) }
            else {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Ouvir uma faixa SoundCloud").font(.title2)
                    TextField("Link SoundCloud completo ou de compartilhamento", text: $link).disabled(busy)
                    TextField("Nome para identificar a faixa", text: $title).disabled(busy)
                    TextField("Artista (opcional)", text: $artist).disabled(busy)
                    Text("Esses nomes são informados por você. Confira a gravação no widget antes de salvar. Abrir esta tela não adiciona itens à biblioteca.").font(.caption).foregroundStyle(.secondary)
                    if let error { Text(error).foregroundStyle(.red) }
                    HStack {
                        Button(busy ? "Resolvendo link…" : "Buscar fonte") { resolveLink() }
                            .disabled(busy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .keyboardShortcut(.defaultAction)
                        if busy { ProgressView().controlSize(.small) }
                        Button("Cancelar") { resolvingTask?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                    }
                }.padding(24).frame(width: 560)
            }
        }
        .onDisappear { resolvingTask?.cancel() }
    }
    private func resolveLink() {
        guard !busy else { return }
        guard let core = store.core else { error = "A biblioteca ainda está abrindo. Tente novamente em instantes."; return }
        busy = true; error = nil
        resolvingTask = Task { @MainActor in
            defer { busy = false }
            do {
                let entry = try await core.resolveSoundcloudLinkEntry(url: link, title: title, artist: artist.isEmpty ? nil : artist)
                guard !Task.isCancelled else { return }; selected = entry
            } catch {
                guard !Task.isCancelled else { return }
                switch error {
                case CoreError.InvalidInput(let message), CoreError.Network(let message): self.error = message
                default: self.error = "Não foi possível abrir o link SoundCloud. Tente novamente."
                }
            }
        }
    }
}
