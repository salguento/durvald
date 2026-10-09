import SwiftUI

struct TrackListTrailingControls<AdditionalControls: View>: View {
    @Environment(DurvaldCoreStore.self) private var store
    @State private var favoriteEdit = PersonalValueEdit(false)

    let track: Track
    let onPlay: () -> Void
    let onToggleFavorite: (Bool) async -> Bool
    @ViewBuilder let additionalControls: () -> AdditionalControls

    init(track: Track, onPlay: @escaping () -> Void,
         onToggleFavorite: @escaping (Bool) async -> Bool,
         @ViewBuilder additionalControls: @escaping () -> AdditionalControls) {
        self.track = track
        self.onPlay = onPlay
        self.onToggleFavorite = onToggleFavorite
        self.additionalControls = additionalControls
        _favoriteEdit = State(initialValue: PersonalValueEdit(track.isFavorite))
    }

    private var isFavorite: Bool {
        favoriteEdit.value
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                toggleFavorite()
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .foregroundStyle(isFavorite ? Color.accentColor : .secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(TrackRowModel.favoriteLabel(isFavorite))
            .accessibilityLabel(TrackRowModel.favoriteLabel(isFavorite))

            Text(durationText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)

            additionalControls()

            Menu {
                Button("Reproduzir", systemImage: "play.fill", action: onPlay)
                Button("Adicionar à fila", systemImage: "text.badge.plus") {
                    Task { await store.addToQueue(trackID: track.id) }
                }
                Button(
                    TrackRowModel.favoriteLabel(isFavorite),
                    systemImage: isFavorite ? "star.slash" : "star"
                ) {
                    toggleFavorite()
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(.rect)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Opções da faixa")
            .accessibilityLabel("Opções da faixa")
            .trackOptionsMenu(track: track, onPlay: onPlay)
        }
        .onChange(of: track.id, initial: true) { _, _ in favoriteEdit.reset(track.isFavorite) }
        .onChange(of: track.isFavorite) { _, value in favoriteEdit.receive(value) }
    }

    private func toggleFavorite() {
        let value = !favoriteEdit.value
        let ticket = favoriteEdit.begin(value)
        Task { @MainActor in
            let succeeded = await onToggleFavorite(value)
            favoriteEdit.finish(ticket, succeeded: succeeded)
        }
    }

    private var durationText: String {
        TrackRowModel(track).durationText()
    }
}

