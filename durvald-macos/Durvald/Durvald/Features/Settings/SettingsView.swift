import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: DurvaldCoreStore
    @State private var crossFade = false
    @State private var crossFadeDuration = 5
    @State private var normalizeVolume = false
    @State private var explicitContent = true

    var body: some View {
        TabView {
            Form {
                Toggle("Crossfade", isOn: $crossFade)
                Stepper(
                    "Duração: \(crossFadeDuration) segundos",
                    value: $crossFadeDuration,
                    in: 1...60
                )
                .disabled(!crossFade)
                Toggle("Normalizar volume", isOn: $normalizeVolume)
                Toggle("Permitir conteúdo explícito", isOn: $explicitContent)

                HStack {
                    Spacer()
                    Button("Salvar") {
                        store.updateSettings(
                            crossFade: crossFade,
                            crossFadeDuration: UInt32(crossFadeDuration),
                            normalizeVolume: normalizeVolume,
                            explicitContent: explicitContent
                        )
                    }
                }
            }
            .padding()
            .tabItem { Label("Geral", systemImage: "gearshape") }
            LibrarySettingsView()
                .padding()
                .tabItem {
                    Label("Biblioteca", systemImage: "books.vertical")
                }
            LastFmSettingsView()
                .padding()
                .tabItem { Label("Last.fm", systemImage: "dot.radiowaves.left.and.right") }
        }
        .frame(width: 600, height: 420)
        .task { apply(store.appSettings) }
        .onChange(of: store.appSettings) { _, settings in
            apply(settings)
        }
    }

    private func apply(_ settings: Settings?) {
        guard let settings else { return }
        crossFade = settings.crossFade
        crossFadeDuration = Int(settings.crossFadeDuration)
        normalizeVolume = settings.normalizeVolume
        explicitContent = settings.explicitContent
    }
}
