import SwiftUI

struct RatingScaleSettingsView: View {
    @Environment(DurvaldCoreStore.self) private var store
    @AppStorage(RatingPreferences.enabledKey) private var ratingsEnabled = true
    @State private var selection: RatingGranularity = .halfStars
    @State private var isLoading = true
    @State private var confirmsRounding = false
    @State private var affectedCount: UInt64 = 0
    @State private var error: String?

    var body: some View {
        Section {
            Toggle("Exibir avaliações", isOn: $ratingsEnabled)
                .accessibilityIdentifier("settings.ratings.enabled")
            Picker("Escala de avaliação", selection: Binding(get: { selection }, set: choose)) {
                Text("De meia em meia estrela").tag(RatingGranularity.halfStars)
                Text("Apenas estrelas inteiras").tag(RatingGranularity.wholeStars)
            }
            .accessibilityIdentifier("settings.ratings.scale")
            .disabled(isLoading || store.isChangingRatingScale || store.core == nil)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .task(id: store.core.map(ObjectIdentifier.init)) {
            isLoading = true
            await store.refreshRatingPreferences()
            selection = store.ratingGranularity
            isLoading = false
        }
        .onChange(of: store.ratingGranularity) { _, value in selection = value }
        .confirmationDialog("Converter avaliações para estrelas inteiras?", isPresented: $confirmsRounding,
                            titleVisibility: .visible) {
            Button("Arredondar para cima") { apply(.wholeStars, rounding: .up) }
            Button("Arredondar para baixo") { apply(.wholeStars, rounding: .down) }
            Button("Cancelar", role: .cancel) { selection = store.ratingGranularity }
        } message: {
            Text("\(affectedCount) avaliações usam meia estrela. Arredondar para cima converte 3,5 em 4; para baixo, em 3. Essa conversão é permanente: voltar à escala de meia estrela não recupera as frações.")
        }
    }

    private func choose(_ value: RatingGranularity) {
        guard value != store.ratingGranularity else { return }
        error = nil
        selection = value
        if value == .halfStars { apply(value, rounding: nil); return }
        isLoading = true
        Task {
            do {
                let counts = try await store.previewRatingConversion()
                affectedCount = counts.tracks + counts.releases + counts.missingTracks + counts.archivedReleases
                if affectedCount > 0 {
                    // Keep the persisted choice visible until the user confirms.
                    selection = store.ratingGranularity
                    confirmsRounding = true
                } else { apply(value, rounding: nil) }
            } catch {
                self.error = "Não foi possível verificar as avaliações: \(error)"
                selection = store.ratingGranularity
            }
            isLoading = false
        }
    }

    private func apply(_ value: RatingGranularity, rounding: RatingRounding?) {
        isLoading = true
        Task {
            let succeeded = await store.changeRatingGranularity(value, rounding: rounding)
            selection = store.ratingGranularity
            if !succeeded { error = store.errorMessage ?? "Não foi possível alterar a escala." }
            isLoading = false
        }
    }
}
