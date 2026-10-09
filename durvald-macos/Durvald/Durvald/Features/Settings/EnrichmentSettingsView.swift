import SwiftUI

struct EnrichmentSettingsView: View {
    @Environment(DurvaldCoreStore.self) private var store
    @State private var draft = EditingState(EnrichmentSettings(enabled: false, offline: false, preferredLanguage: "pt"))

    var body: some View {
        Form {
            Section("Metadados de artistas") {
                Toggle("Buscar biografias, discografias e imagens", isOn: $draft.value.enabled)

                Text(
                    "Quando ativado, o nome e os identificadores do artista podem ser enviados ao MusicBrainz, aos serviços Wikimedia e ao Cover Art Archive. A biblioteca e a reprodução continuam funcionando sem esse recurso."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Toggle("Modo offline", isOn: $draft.value.offline)
                    .disabled(!draft.value.enabled)

                Picker("Idioma preferido", selection: $draft.value.preferredLanguage) {
                    Text("Português").tag("pt")
                    Text("English").tag("en")
                    Text("Español").tag("es")
                    Text("Français").tag("fr")
                    Text("Deutsch").tag("de")
                    Text("Italiano").tag("it")
                }
                .disabled(!draft.value.enabled)
            }

            Section("Biblioteca") {
                Button {
                    Task { await store.updateLibraryMetadata(refreshRemote: true) }
                } label: {
                    if store.isUpdatingLibraryMetadata {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Atualizando \(store.metadataUpdateCompleted) de \(store.metadataUpdateTotal)…")
                        }
                    } else {
                        Label("Atualizar metadados da biblioteca", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(store.isUpdatingLibraryMetadata || store.core == nil)
                .accessibilityIdentifier("settings.enrichment.updateLibrary")

                Text("Metadados já armazenados são aplicados depois de uma varredura. Consultas remotas para toda a biblioteca só acontecem ao solicitar esta atualização. Artistas sem identidade confirmada precisam ser vinculados antes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Spacer()
                    if let error = draft.errorMessage { Text(error).foregroundStyle(.red) }
                    Button("Salvar") { Task { await save() } }
                        .disabled(!draft.isDirty || draft.isSaving || store.core == nil)

                }
            }
        }
        .task(id: store.core.map(ObjectIdentifier.init)) {
            draft.refresh(store.enrichmentSettings ?? EnrichmentSettings(enabled: false, offline: false, preferredLanguage: "pt"),
                          sourceID: store.core.map(ObjectIdentifier.init))
        }
        .onChange(of: store.enrichmentSettings) { _, settings in
            apply(settings)
        }
    }

    private func apply(_ settings: EnrichmentSettings?) {
        if let settings { draft.receive(settings) }
    }

    private func save() async {
        guard let ticket = draft.beginSaving() else { return }
        var submitted = ticket.value
        submitted.offline = submitted.enabled && submitted.offline
        let succeeded = await store.configureEnrichment(submitted)
        if succeeded { draft.finish(ticket, confirmed: submitted) }
        else { draft.fail(ticket, message: store.errorMessage ?? "Não foi possível salvar os metadados de artistas.") }
    }
}
