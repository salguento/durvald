import SwiftUI

struct EnrichmentSettingsView: View {
    @Environment(DurvaldCoreStore.self) private var store
    @State private var enabled = false
    @State private var offline = false
    @State private var preferredLanguage = "pt"

    var body: some View {
        Form {
            Section("Metadados de artistas") {
                Toggle("Buscar biografias, discografias e imagens", isOn: $enabled)

                Text(
                    "Quando ativado, o nome e os identificadores do artista podem ser enviados ao MusicBrainz, aos serviços Wikimedia e ao Cover Art Archive. A biblioteca e a reprodução continuam funcionando sem esse recurso."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Toggle("Modo offline", isOn: $offline)
                    .disabled(!enabled)

                Picker("Idioma preferido", selection: $preferredLanguage) {
                    Text("Português").tag("pt")
                    Text("English").tag("en")
                    Text("Español").tag("es")
                    Text("Français").tag("fr")
                    Text("Deutsch").tag("de")
                    Text("Italiano").tag("it")
                }
                .disabled(!enabled)
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

                Text("A atualização também acontece automaticamente ao abrir o Durvald e depois de uma varredura. Artistas sem identidade confirmada precisam ser vinculados antes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Salvar") {
                        store.configureEnrichment(
                            EnrichmentSettings(
                                enabled: enabled,
                                offline: enabled && offline,
                                preferredLanguage: preferredLanguage
                            )
                        )
                    }
                }
            }
        }
        .task { apply(store.enrichmentSettings) }
        .onChange(of: store.enrichmentSettings) { _, settings in
            apply(settings)
        }
    }

    private func apply(_ settings: EnrichmentSettings?) {
        guard let settings else { return }
        enabled = settings.enabled
        offline = settings.offline
        preferredLanguage = settings.preferredLanguage
    }
}
