import AppKit
import SwiftUI

struct PlayerBar: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position = 0.0
    @State private var volume = 0.5
    @State private var volumeBeforeMute = 0.5
    @State private var isVolumeMuted = false
    @State private var seeking = false
    @State private var scrubbingTrackID: Int64?
    @State private var adjustingVolume = false
    @State private var changingPlaybackState = false
    @State private var isProgressHovered = false
    @State private var availableWidth: CGFloat = 360

    private var isNarrow: Bool { availableWidth < 600 }

    let onSelectAlbum: (Release) -> Void
    let onSelectArtist: (Artist) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 4) {
                trackInformation
                    .frame(
                        minWidth: 112,
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                    .frame(height: 44, alignment: .center)
                    .contentShape(Rectangle())

                playbackControls
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: isNarrow ? 80 : 184)
                    .frame(height: 44, alignment: .center)

                if !isNarrow {
                    trailingControls
                        .frame(minWidth: 120, maxWidth: .infinity)
                        .frame(height: 44, alignment: .center)
                }
            }
        }
        .padding(14)
        .glassEffect(
            .regular.interactive(),
            in: .rect(cornerRadius: 20)
        )
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.width
        } action: { availableWidth = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.bar")
        .onChange(of: store.playback, initial: true) { previous, _ in
            // Read the latest publication, not an older value captured by a
            // view update while the user was releasing the slider.
            guard let snapshot = store.playback else {
                seeking = false
                scrubbingTrackID = nil
                position = 0
                return
            }
            let changedTrack = previous?.currentTrack?.id != snapshot.currentTrack?.id
            if changedTrack {
                seeking = false
                scrubbingTrackID = nil
            }
            if !adjustingVolume {
                volume = Double(snapshot.volume)
                if volume > 0 {
                    volumeBeforeMute = volume
                    isVolumeMuted = false
                }
            }
        }
    }

    private var trackInformation: some View {
        let track = store.playback?.currentTrack
        let album = store.releases.first { $0.id == track?.releaseId }
        let artist = store.artists.first { $0.id == track?.artistId }

        return HStack(alignment: .top, spacing: 8) {
            Button {
                if let album { onSelectAlbum(album) }
            } label: {
                ArtworkView(artworkID: track?.artworkId, size: 44)
            }
            .buttonStyle(.plain)
            .disabled(album == nil)
            .accessibilityLabel(album.map { "Abrir álbum \($0.title)" } ?? "Capa da faixa")
            .accessibilityIdentifier("player.artwork")
            .contextMenu {
                if let album {
                    Button("Abrir álbum", systemImage: "square.stack") {
                        onSelectAlbum(album)
                    }
                    Button("Reproduzir álbum", systemImage: "play") {
                        Task { await store.playRelease(releaseID: album.id) }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                trackMetadata(track, album: album, artist: artist)

                Spacer(minLength: 0)

                playbackProgress
            }
            .frame(height: 44, alignment: .top)
        }
    }

    private func trackMetadata(_ track: Track?, album: Release?, artist: Artist?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let track {
                PlayerMetadataLink(
                    title: track.title,
                    destinationLabel: album.map { "Abrir álbum \($0.title)" },
                    action: { if let album { onSelectAlbum(album) } }
                )
                .font(.caption.weight(.medium))
                .accessibilityIdentifier("player.trackTitle")
                .trackContextMenu(
                    track: track,
                    onPlay: { Task { await store.play(trackID: track.id) } },
                    additionalActions: [
                        TrackMenuAction(
                        track.isFavorite ? "Desfavoritar faixa" : "Favoritar faixa",
                        systemImage: track.isFavorite ? "star.slash" : "star"
                        ) {
                        store.setTrackFavorite(trackID: track.id, favorite: !track.isFavorite)
                        },
                        TrackMenuAction("Abrir álbum", systemImage: "square.stack",
                                        isEnabled: album != nil) {
                            if let album { onSelectAlbum(album) }
                        },
                        TrackMenuAction("Abrir artista", systemImage: "music.mic",
                                        isEnabled: artist != nil) {
                            if let artist { onSelectArtist(artist) }
                        }
                    ]
                )
            } else {
                PlayerMetadataLink(
                    title: "Nada tocando",
                    destinationLabel: nil,
                    action: {}
                )
                .font(.caption.weight(.medium))
                .accessibilityIdentifier("player.trackTitle")
            }

            PlayerMetadataLink(
                title: track?.artist ?? "",
                destinationLabel: artist.map { "Abrir artista \($0.name)" },
                action: { if let artist { onSelectArtist(artist) } }
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("player.artist")
            .contextMenu {
                if let artist {
                    Button("Abrir artista", systemImage: "music.mic") {
                        onSelectArtist(artist)
                    }
                    Button("Copiar nome do artista", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(artist.name, forType: .string)
                    }
                }
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func trackActions(_ track: Track?, album: Release?, artist: Artist?) -> some View {
        let isFavorite = track?.isFavorite == true
        let favoriteLabel = isFavorite ? "Desfavoritar faixa" : "Favoritar faixa"

        return HStack(spacing: 8) {
            Button {
                if let track {
                    store.setTrackFavorite(trackID: track.id, favorite: !isFavorite)
                }
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .foregroundStyle(isFavorite ? Color.accentColor : .secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(favoriteLabel)
            .accessibilityLabel(favoriteLabel)
            .accessibilityValue(isFavorite ? "Favorita" : "Não favorita")
            .accessibilityIdentifier("player.favorite")

            if !isNarrow {
                Menu {
                    if let track {
                        Button(
                            track.isFavorite ? "Desfavoritar faixa" : "Favoritar faixa",
                            systemImage: track.isFavorite ? "star.slash" : "star"
                        ) {
                            store.setTrackFavorite(trackID: track.id, favorite: !track.isFavorite)
                        }
                        Button("Adicionar à fila", systemImage: "text.badge.plus") {
                            Task { await store.addToQueue(trackID: track.id) }
                        }
                        Divider()
                        Button("Abrir álbum", systemImage: "square.stack") {
                            if let album { onSelectAlbum(album) }
                        }
                        .disabled(album == nil)
                        Button("Abrir artista", systemImage: "music.mic") {
                            if let artist { onSelectArtist(artist) }
                        }
                        .disabled(artist == nil)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Opções da faixa")
                .accessibilityLabel("Opções da faixa")
                .accessibilityIdentifier("player.options")
            }
        }
        .font(.system(size: 15))
        .fixedSize()
        .disabled(track == nil)
    }

    private var trailingControls: some View {
        let track = store.playback?.currentTrack
        let album = store.releases.first { $0.id == track?.releaseId }
        let artist = store.artists.first { $0.id == track?.artistId }

        return HStack(spacing: 8) {
            trackActions(track, album: album, artist: artist)
                .frame(maxWidth: .infinity, alignment: .center)

            if !isNarrow {
                volumeControl
                    .frame(minWidth: 64, maxWidth: 120)
            }
        }
    }

    private var playbackControls: some View {
        HStack(spacing: isNarrow ? 12 : 14) {
            if !isNarrow {
                Button {
                    Task { await store.toggleShuffle() }
                } label: {
                    Image(systemName: "shuffle")
                        .foregroundStyle(
                            store.playback?.shuffleEnabled == true
                                ? Color.accentColor : Color.secondary
                        )
                        .symbolVariant(
                            store.playback?.shuffleEnabled == true ? .fill : .none
                        )
                        .frame(height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityHint("Alterna a reprodução aleatória da fila")
                .accessibilityLabel(
                    store.playback?.shuffleEnabled == true
                        ? "Desativar reprodução aleatória"
                        : "Ativar reprodução aleatória"
                )
                .accessibilityIdentifier("player.shuffle")
            }

            if !isNarrow {
                Button {
                    Task { await store.previous() }
                } label: {
                    Image(systemName: "backward.fill")
                        .frame(height: 44)
                        .contentShape(Rectangle())
                }
                .disabled(store.playback?.currentTrack == nil)
                .help("Faixa anterior")
                .accessibilityLabel("Faixa anterior")
                .accessibilityHint("Volta para a faixa anterior")
                .accessibilityIdentifier("player.previous")
            }

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
                .font(.system(size: 28))
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .disabled(store.playback?.currentTrack == nil || changingPlaybackState)
            .accessibilityHint("Alterna entre reproduzir e pausar a faixa atual")
            .accessibilityLabel(
                store.playback?.isPaused == true ? "Reproduzir" : "Pausar"
            )
            .accessibilityIdentifier("player.playPause")
            .keyboardShortcut(AppKeyboardShortcuts.playPause)

            Button {
                Task { await store.next() }
            } label: {
                Image(systemName: "forward.fill")
                    .frame(height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(store.playback?.currentTrack == nil)
            .help("Próxima faixa")
            .accessibilityLabel("Próxima faixa")
            .accessibilityHint("Avança para a próxima faixa")
            .accessibilityIdentifier("player.next")

            if !isNarrow {
                Button {
                    Task { await store.cycleRepeatMode() }
                } label: {
                    Image(systemName: repeatIcon)
                        .foregroundStyle(
                            (store.playback?.repeatMode ?? RepeatMode.none) == RepeatMode.none
                                ? Color.secondary : Color.accentColor
                        )
                        .frame(height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityHint("Alterna entre repetição desativada, da fila e de uma faixa")
                .accessibilityLabel(repeatLabel)
                .accessibilityIdentifier("player.repeat")
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 14))
    }

    private var playbackProgress: some View {
        let snapshot = store.playback
        let duration = max(snapshot?.durationSeconds ?? 0, 0.01)
        let expanded = isProgressHovered || seeking
        let displayedPosition = seeking ? position : (snapshot?.positionSeconds ?? 0)
        let elapsed = time(displayedPosition)

        return HStack(spacing: 4) {
            Text(elapsed)
                .fixedSize()
                .accessibilityIdentifier("player.elapsed")

            PlayerBarSlider(
                value: displayedPosition,
                onValueChange: { position = $0 },
                upperBound: duration,
                expanded: expanded,
                controlHeight: 12,
                onEditingChanged: updateSeeking
            )
            .transaction { transaction in
                if seeking || store.isSeeking {
                    transaction.animation = nil
                }
            }
            .disabled(snapshot?.currentTrack == nil)
            .focusable(snapshot?.currentTrack != nil)
            .focusEffectDisabled()
            .onHover { isProgressHovered = $0 }
            .onKeyPress(AppKeyboardShortcuts.Slider.decrease) {
                adjustProgress(by: -5, duration: duration)
                return .handled
            }
            .onKeyPress(AppKeyboardShortcuts.Slider.increase) {
                adjustProgress(by: 5, duration: duration)
                return .handled
            }
            .accessibilityRepresentation {
                Slider(
                    value: Binding(
                        get: { displayedPosition },
                        set: { newValue in
                            updateSeeking(true)
                            position = newValue
                            updateSeeking(false)
                        }
                    ),
                    in: 0...duration
                )
                .disabled(snapshot?.currentTrack == nil)
                .accessibilityLabel("Posição da reprodução")
                .accessibilityValue("\(elapsed) de \(time(duration))")
                .accessibilityIdentifier("player.progress")
            }

        }
        .font(.system(size: 9).monospacedDigit())
        .foregroundStyle(.tertiary)
        .frame(height: 12)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: expanded)
    }

    private func updateSeeking(_ editing: Bool) {
        if editing {
            position = store.playback?.positionSeconds ?? 0
            scrubbingTrackID = store.playback?.currentTrack?.id
            seeking = true
        } else {
            if scrubbingTrackID == store.playback?.currentTrack?.id {
                store.seek(to: position)
            }
            position = store.playback?.positionSeconds ?? 0
            scrubbingTrackID = nil
            seeking = false
        }
    }

    private func adjustProgress(by seconds: Double, duration: Double) {
        guard store.playback?.currentTrack != nil, !seeking else { return }
        updateSeeking(true)
        position = min(max(position + seconds, 0), duration)
        updateSeeking(false)
    }

    private var volumeControl: some View {
        HStack(spacing: 6) {
            muteButton

            PlayerBarSlider(
                value: volume,
                onValueChange: { updateVolume($0, immediately: !adjustingVolume) },
                upperBound: 1,
                expanded: true,
                fillColor: .white,
                trackStyle: .secondary,
                showsGlow: false
            ) { editing in
                adjustingVolume = editing
                if !editing {
                    store.scheduleVolume(volume, immediately: true)
                }
            }
            .frame(minWidth: 34, maxWidth: .infinity)
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(AppKeyboardShortcuts.Slider.decrease) {
                updateVolume(volume - 0.05)
                return .handled
            }
            .onKeyPress(AppKeyboardShortcuts.Slider.increase) {
                updateVolume(volume + 0.05)
                return .handled
            }
            .accessibilityRepresentation {
                Slider(
                    value: Binding(
                        get: { volume },
                        set: { updateVolume($0) }
                    ),
                    in: 0...1
                )
                .accessibilityLabel("Volume")
                .accessibilityValue("\(Int((volume * 100).rounded()))%")
                .accessibilityIdentifier("player.volume")
            }
        }
        .font(.caption)
    }

    private func updateVolume(_ newValue: Double, immediately: Bool = true) {
        volume = min(max(newValue, 0), 1)
        isVolumeMuted = false
        if volume > 0 { volumeBeforeMute = volume }
        store.scheduleVolume(volume, immediately: immediately)
    }

    private func toggleMute() {
        if isVolumeMuted || volume == 0 {
            updateVolume(volumeBeforeMute)
        } else {
            volumeBeforeMute = volume
            volume = 0
            isVolumeMuted = true
            store.scheduleVolume(0, immediately: true)
        }
    }

    private var muteButton: some View {
        Button(action: toggleMute) {
            Image(systemName: volumeIcon)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isVolumeMuted || volume == 0 ? "Desmutar volume" : "Mutar volume")
        .accessibilityLabel(isVolumeMuted || volume == 0 ? "Desmutar volume" : "Mutar volume")
        .accessibilityValue(volumeDescription)
        .accessibilityIdentifier("player.mute")
    }

    private var volumeIcon: String {
        if isVolumeMuted { return "speaker.slash.fill" }
        if volume == 0 { return "speaker.fill" }
        if volume <= 1.0 / 3 { return "speaker.wave.1.fill" }
        if volume <= 2.0 / 3 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    private var volumeDescription: String {
        if isVolumeMuted { return "Mudo" }
        if volume == 0 { return "Sem volume" }
        let level = volume <= 1.0 / 3 ? "baixo" : (volume <= 2.0 / 3 ? "médio" : "alto")
        return "Volume \(level), \(Int((volume * 100).rounded()))%"
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

/// Shared track and interaction geometry for playback progress and volume.
private struct PlayerBarSlider: View {
    let value: Double
    let onValueChange: (Double) -> Void
    let upperBound: Double
    let expanded: Bool
    var fillColor: Color = .secondary
    var activeFillColor: Color = .accentColor
    var trackStyle: HierarchicalShapeStyle = .quaternary
    var showsGlow = true
    var controlHeight: CGFloat = 24
    let onEditingChanged: (Bool) -> Void

    @Environment(\.isEnabled) private var isEnabled
    @GestureState private var isDragging = false
    @State private var isEditing = false
    @State private var isHovered = false

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let fraction = min(max(value / max(upperBound, 0.01), 0), 1)
            let trackHeight: CGFloat = expanded ? 4 : 1.5
            let progressColor = (isHovered || isDragging) && isEnabled
                ? activeFillColor : fillColor

            ZStack(alignment: .leading) {
                if showsGlow {
                    // Keep the hover glow inside the seek control's own bounds.
                    Capsule()
                        .fill(progressColor.opacity(0.25))
                        .frame(width: width * fraction, height: trackHeight)
                        .blur(radius: 3)
                        .opacity(expanded && isEnabled ? 1 : 0)
                        .allowsHitTesting(false)
                }

                Capsule()
                    .fill(trackStyle)
                    .frame(height: trackHeight)

                Capsule()
                    .fill(progressColor)
                    .frame(width: width * fraction, height: trackHeight)

                Circle()
                    .fill(progressColor)
                    .frame(width: 12, height: 12)
                    .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                    .offset(x: min(max(width * fraction - 6, 0), max(width - 12, 0)))
                    .opacity((isHovered || isDragging) && isEnabled ? 1 : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isDragging) { _, dragging, _ in dragging = true }
                    .onChanged { gesture in
                        guard isEnabled else { return }
                        if !isEditing {
                            isEditing = true
                            onEditingChanged(true)
                        }
                        onValueChange(min(max(gesture.location.x / width, 0), 1) * upperBound)
                    }
                    .onEnded { gesture in
                        guard isEditing else { return }
                        onValueChange(min(max(gesture.location.x / width, 0), 1) * upperBound)
                        finishEditing()
                    }
            )
        }
        .frame(height: controlHeight)
        .clipped()
        .onHover { isHovered = $0 }
        .onChange(of: isDragging) { _, dragging in
            if !dragging { finishEditing() }
        }
        .onDisappear { finishEditing() }
    }

    private func finishEditing() {
        guard isEditing else { return }
        isEditing = false
        onEditingChanged(false)
    }
}

private struct PlayerMetadataLink: View {
    let title: String
    let destinationLabel: String?
    let action: () -> Void

    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        if let destinationLabel {
            Button(action: action) {
                PlayerMarqueeText(text: title, underlined: isHovered || isFocused)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($isFocused)
            .onHover { isHovered = $0 }
            .help(destinationLabel)
            .accessibilityLabel(title)
            .accessibilityHint(destinationLabel)
            .accessibilityAddTraits(.isLink)
        } else {
            PlayerMarqueeText(text: title)
        }
    }
}
