import SwiftUI

struct SettingsView: View {
    @Environment(DurvaldCoreStore.self) private var store
    @State private var draft = EditingState(GeneralSettingsValues())
    @State private var selectedTab = SettingsTab.general

    private enum SettingsTab: Hashable {
        case general, audio, equalizer, library, enrichment, lastFM, soulseek, services
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Form {
                Toggle("Crossfade", isOn: $draft.value.crossFade)
                Stepper(
                    "Duração: \(draft.value.crossFadeDuration) segundos",
                    value: $draft.value.crossFadeDuration,
                    in: 1...60
                )
                .disabled(!draft.value.crossFade)
                Toggle("Normalizar volume", isOn: $draft.value.normalizeVolume)
                Toggle("Permitir conteúdo explícito", isOn: $draft.value.explicitContent)
                RatingScaleSettingsView()

                HStack {
                    Spacer()
                    if let error = draft.errorMessage { Text(error).foregroundStyle(.red) }
                    Button("Salvar") { Task { await save() } }
                        .disabled(!draft.isDirty || draft.isSaving || store.core == nil)

                }
            }
            .padding()
            .tabItem { Label("Geral", systemImage: "gearshape") }
            .tag(SettingsTab.general)
            AudioOutputSettingsView()
                .padding()
                .tabItem { Label("Áudio", systemImage: "hifispeaker") }
                .tag(SettingsTab.audio)
            EqualizerSettingsView(isActive: selectedTab == .equalizer)
                .tabItem { Label("Equalizador", systemImage: "slider.vertical.3") }
                .tag(SettingsTab.equalizer)
            LibrarySettingsView()
                .padding()
                .tabItem {
                    Label("Biblioteca", systemImage: "books.vertical")
                }
                .tag(SettingsTab.library)
            EnrichmentSettingsView()
                .padding()
                .tabItem {
                    Label("Metadados", systemImage: "person.text.rectangle")
                }
                .tag(SettingsTab.enrichment)
            ServiceImportSettingsView().tabItem { Label("Serviços", systemImage: "link") }.tag(SettingsTab.services)
            SoulseekSettingsView().padding()
                .tabItem { Label("Soulseek", systemImage: "magnifyingglass") }.tag(SettingsTab.soulseek)
            LastFmSettingsView()
                .padding()
                .tabItem { Label("Last.fm", systemImage: "dot.radiowaves.left.and.right") }
                .tag(SettingsTab.lastFM)
        }
        .frame(width: 600, height: 420)
        .background(WindowTrafficLightsHider(closesOnEscape: true))
        .task(id: store.core.map(ObjectIdentifier.init)) {
            draft.refresh(store.appSettings.map(GeneralSettingsValues.init) ?? GeneralSettingsValues(),
                          sourceID: store.core.map(ObjectIdentifier.init))
        }
        .onChange(of: store.appSettings.map(GeneralSettingsValues.init)) { _, values in
            if let values { draft.receive(values) }
        }
    }

    private func save() async {
        guard let ticket = draft.beginSaving() else { return }
        let submitted = ticket.value
        let succeeded = await store.updateSettings(crossFade: submitted.crossFade,
            crossFadeDuration: UInt32(submitted.crossFadeDuration), normalizeVolume: submitted.normalizeVolume,
            explicitContent: submitted.explicitContent)
        if succeeded { draft.finish(ticket, confirmed: submitted) }
        else { draft.fail(ticket, message: store.errorMessage ?? "Não foi possível salvar as configurações.") }
    }
}
