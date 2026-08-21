import SwiftUI

struct PlayerBar: View {
    @EnvironmentObject private var store: DurvaldCoreStore
    @State private var position = 0.0
    @State private var volume = 0.5
    @State private var seeking = false
    @State private var adjustingVolume = false
    @State private var changingPlaybackState = false

    var body: some View {
        let snapshot = store.playback
        let duration = max(snapshot?.durationSeconds ?? 0, 0.01)

        VStack(spacing: 8) {
            HStack {
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
}
