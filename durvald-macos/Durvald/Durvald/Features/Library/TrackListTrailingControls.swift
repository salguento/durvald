import SwiftUI

struct TrackListTrailingControls: View {
    @Environment(DurvaldCoreStore.self) private var store
    @AppStorage(RatingPreferences.enabledKey) private var ratingsEnabled = true
    @State private var favoriteEdit: PersonalValueEdit<Bool>
    let track: Track
    let isRowHovered: Bool
    let onPlay: () -> Void

    init(track: Track, isRowHovered: Bool, onPlay: @escaping () -> Void) {
        self.track = track
        self.isRowHovered = isRowHovered
        self.onPlay = onPlay
        _favoriteEdit = State(initialValue: PersonalValueEdit(track.isFavorite))
    }

    private var isFavorite: Bool { favoriteEdit.value }
    private var showsFavorite: Bool { isFavorite || isRowHovered }

    var body: some View {
        HStack(spacing: 24) {
            Button { toggleFavorite() } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .foregroundStyle(isFavorite ? Color.accentColor : .secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(TrackRowModel.favoriteLabel(isFavorite))
            .accessibilityLabel(TrackRowModel.favoriteLabel(isFavorite))
            .accessibilityValue(PersonalValueLabels.favoriteValue(isFavorite))
            .accessibilityIdentifier("collection.track.\(track.id).favorite")
            .opacity(showsFavorite ? 1 : 0)
            .allowsHitTesting(showsFavorite)
            .accessibilityHidden(!showsFavorite)

            if ratingsEnabled {
                RatingControl(rating: track.ratingHalfSteps, isEditable: true, identity: .track(track.id),
                              showsUnrated: isRowHovered, onCommit: { rating in
                    await store.setTrackRating(trackID: track.id, rating: rating, fallbackTrack: track)
                })
                .accessibilityIdentifier("collection.track.\(track.id).rating")
            }

            Text(TrackRowModel(track).durationText())
                .font(.body)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
                .accessibilityIdentifier("collection.track.\(track.id).duration")

            Menu {
                Button("Reproduzir", systemImage: "play.fill", action: onPlay)
                Button("Adicionar à fila", systemImage: "text.badge.plus") {
                    Task { await store.addToQueue(trackID: track.id) }
                }
                Button(TrackRowModel.favoriteLabel(isFavorite), systemImage: isFavorite ? "star.slash" : "star") {
                    toggleFavorite()
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24, height: 24)
                    .contentShape(.rect)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Opções da faixa")
            .accessibilityLabel("Opções da faixa")
            .accessibilityIdentifier("collection.track.\(track.id).options")
            .trackOptionsMenu(track: track, onPlay: onPlay)
        }
        .onChange(of: track.id, initial: true) { _, _ in favoriteEdit.reset(track.isFavorite) }
        .onChange(of: track.isFavorite) { _, value in favoriteEdit.receive(value) }
    }

    private func toggleFavorite() {
        let value = !favoriteEdit.value
        let ticket = favoriteEdit.begin(value)
        Task { @MainActor in
            let succeeded = await store.setTrackFavorite(trackID: track.id, favorite: value, fallbackTrack: track)
            favoriteEdit.finish(ticket, succeeded: succeeded)
        }
    }
}
