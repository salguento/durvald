import SwiftUI

struct PlayerBar: View {
    @EnvironmentObject private var store: DurvaldCoreStore
    @State private var position = 0.0
    @State private var volume = 0.5
    @State private var seeking = false
    @State private var adjustingVolume = false
    @State private var changingPlaybackState = false
    @State private var showingQueue = false

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
                    Text(snapshot?.currentTrack?.artist ?? "")
                        .font(.caption).foregroundStyle(.secondary)
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
                .accessibilityLabel(
                    store.playback?.isPaused == true ? "Reproduzir" : "Pausar"
                )
                .accessibilityIdentifier("player.playPause")
                .keyboardShortcut(.space, modifiers: [])
                Button {
                    showingQueue.toggle()
                } label: {
                    Image(systemName: "list.bullet")
                }
                .accessibilityLabel("Mostrar fila")
                .accessibilityIdentifier("player.queue")
                .keyboardShortcut("l", modifiers: [.command, .option])
                .popover(isPresented: $showingQueue) {
                    QueueView()
                        .frame(width: 380, height: 460)
                }
                Button {
                    Task { await store.toggleShuffle() }
                } label: {
                    Image(systemName: "shuffle")
                        .symbolVariant(
                            store.playback?.shuffleEnabled == true ? .fill : .none
                        )
                }
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
                .accessibilityLabel(repeatLabel)
                .accessibilityIdentifier("player.repeat")
            }
            Slider(value: $position, in: 0...duration, onEditingChanged: { editing in
                seeking = editing
                if !editing { Task { await store.seek(to: position) } }
            })
            .disabled(snapshot?.currentTrack == nil)
            HStack {
                Text(time(seeking ? position : (snapshot?.positionSeconds ?? 0)))
                Spacer()
                Text(time(duration))
                Image(systemName: "speaker.fill")
                Slider(value: $volume, in: 0...1) { editing in
                    adjustingVolume = editing

                    if !editing {
                        store.scheduleVolume(volume, immediately: true)
                    }
                }
                .frame(width: 120)
                .onChange(of: volume) { _, newValue in
                    guard adjustingVolume else { return }
                    store.scheduleVolume(newValue)
                }
                .accessibilityLabel("Volume")
                .accessibilityIdentifier("player.volume")
            }.font(.caption).foregroundStyle(.secondary)
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
