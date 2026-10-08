import SwiftUI

struct SettingsView: View {
    @Environment(DurvaldCoreStore.self) private var store
    @State private var draft = SettingsDraft(GeneralSettingsValues())
    @State private var selectedTab = SettingsTab.general

    private enum SettingsTab: Hashable {
        case general, audio, equalizer, library, enrichment, lastFM
    }
    @AppStorage(RatingPreferences.enabledKey) private var ratingsEnabled = true

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
                Toggle("Exibir avaliações", isOn: $ratingsEnabled)
                    .accessibilityIdentifier("settings.ratings.enabled")

                HStack {
                    Spacer()
                    Button("Salvar") {
                        store.updateSettings(
                            crossFade: draft.value.crossFade,
                            crossFadeDuration: UInt32(draft.value.crossFadeDuration),
                            normalizeVolume: draft.value.normalizeVolume,
                            explicitContent: draft.value.explicitContent
                        )
                    }
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
            LastFmSettingsView()
                .padding()
                .tabItem { Label("Last.fm", systemImage: "dot.radiowaves.left.and.right") }
                .tag(SettingsTab.lastFM)
        }
        .frame(width: 600, height: 420)
        .background(WindowTrafficLightsHider(closesOnEscape: true))
        .task { apply(store.appSettings) }
        .onChange(of: store.appSettings.map(GeneralSettingsValues.init)) { _, values in
            if let values { draft.receive(values) }
        }
    }

    private func apply(_ settings: Settings?) {
        guard let settings else { return }
        draft.receive(GeneralSettingsValues(settings))
    }
}
