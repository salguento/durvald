import SwiftUI

struct PlayerBar: View {
    @EnvironmentObject private var store: DurvaldCoreStore
    @State private var position = 0.0
    @State private var volume = 0.5
    @State private var seeking = false
    @State private var adjustingVolume = false
    @State private var changingPlaybackState = false

    let isQueuePresented: Bool
    let onToggleQueue: () -> Void

    var body: some View {
        let snapshot = store.playback
        let duration = max(snapshot?.durationSeconds ?? 0, 0.01)

        VStack(spacing: 8) {
            HStack {
                ArtworkView(
                    artworkID: snapshot?.currentTrack?.artworkId,
                    size: 44
                )

                VStack(alignment: .leading) {
                    Text(snapshot?.currentTrack?.title ?? "Nada tocando")
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(snapshot?.currentTrack?.artist ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
                Button {
                    changingPlaybackState = true

                    Task {
                        await store.togglePause()
                        changingPlaybackState = false
                    }
                } label: {
                    Image(
                        systemName: store.playback?.isPaused == true
                            ? "play.fill"
                            : "pause.fill"
                    )
                }
                .buttonStyle(.plain)
                .disabled(store.playback?.currentTrack == nil || changingPlaybackState)
                .accessibilityHint("Alterna entre reproduzir e pausar a faixa atual")
                .accessibilityLabel(
                    store.playback?.isPaused == true ? "Reproduzir" : "Pausar"
                )
                .accessibilityIdentifier("player.playPause")
                .keyboardShortcut(.space, modifiers: [])
                Button(action: onToggleQueue) {
                    Image(systemName: "list.bullet")
                        .foregroundStyle(
                            isQueuePresented ? Color.accentColor : Color.primary
                        )
                }
                .accessibilityHint("Mostra ou oculta a fila lateral de reprodução")
                .accessibilityLabel(isQueuePresented ? "Ocultar fila" : "Mostrar fila")
                .accessibilityIdentifier("player.queue")
                .keyboardShortcut("l", modifiers: [.command, .option])
                Button {
                    Task { await store.toggleShuffle() }
                } label: {
                    Image(systemName: "shuffle")
                        .symbolVariant(
                            store.playback?.shuffleEnabled == true ? .fill : .none
                        )
                }
                .accessibilityHint("Alterna a reprodução aleatória da fila")
                .accessibilityLabel(
                    store.playback?.shuffleEnabled == true
                        ? "Desativar reprodução aleatória"
                        : "Ativar reprodução aleatória"
                )
                .accessibilityIdentifier("player.shuffle")

                Button {
                    Task { await store.cycleRepeatMode() }
                } label: {
                    Image(systemName: repeatIcon)
                }
                .accessibilityHint("Alterna entre repetição desativada, da fila e de uma faixa")
                .accessibilityLabel(repeatLabel)
                .accessibilityIdentifier("player.repeat")
            }
            Slider(value: $position, in: 0...duration, onEditingChanged: { editing in
                seeking = editing
                if !editing {
                    Task { await store.seek(to: position) }
                }
            })
            .tint(.accentColor)
            .disabled(snapshot?.currentTrack == nil)
            .accessibilityLabel("Posição da reprodução")
            .accessibilityValue(
                "\(time(seeking ? position : (snapshot?.positionSeconds ?? 0))) " +
                "de \(time(duration))"
            )
            .accessibilityIdentifier("player.progress")
            HStack {
                Text(time(seeking ? position : (snapshot?.positionSeconds ?? 0)))
                    .foregroundStyle(.secondary)

                Spacer()

                Text(time(duration))
                    .foregroundStyle(.secondary)

                Image(systemName: "speaker.fill")
                    .foregroundStyle(.secondary)

                Slider(value: $volume, in: 0...1) { editing in
                    adjustingVolume = editing

                    if !editing {
                        store.scheduleVolume(volume, immediately: true)
                    }
                }
                .tint(.accentColor)
                .frame(width: 120)
                .onChange(of: volume) { _, newValue in
                    guard adjustingVolume else { return }
                    store.scheduleVolume(newValue)
                }
                .accessibilityLabel("Volume")
                .accessibilityIdentifier("player.volume")
            }
            .font(.caption)
        }
        .padding().background(.bar)
        .onChange(of: store.playback) { _, snapshot in
            guard let snapshot else { return }
            if !seeking { position = snapshot.positionSeconds }
            if !adjustingVolume { volume = Double(snapshot.volume) }
        }
    }

    private func time(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        return String(format: "%d:%02d", value / 60, value % 60)
    }

    private var repeatIcon: String {
        switch store.playback?.repeatMode ?? .none {
        case .none: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    private var repeatLabel: String {
        switch store.playback?.repeatMode ?? .none {
        case .none: return "Repetição desativada"
        case .all: return "Repetir fila"
        case .one: return "Repetir uma música"
        }
    }
}
