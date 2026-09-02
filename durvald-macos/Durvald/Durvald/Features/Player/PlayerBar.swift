import AppKit
import SwiftUI

struct PlayerBar: View {
    @EnvironmentObject private var store: DurvaldCoreStore
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
    @State private var isTrackInformationHovered = false
    @State private var availableWidth: CGFloat = 760
    @State private var isTrackTooltipPresented = false

    private var isCompact: Bool { availableWidth < 500 }

    private var trackTooltip: String {
        guard let track = store.playback?.currentTrack else { return "Nada tocando" }
        return [track.title, track.artist].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    let onSelectAlbum: (Release) -> Void
    let onSelectArtist: (Artist) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                trackInformation
                    .frame(minWidth: isCompact ? 76 : 112, maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onHover {
                        isTrackInformationHovered = $0
                        if !$0 { isTrackTooltipPresented = false }
                    }

                playbackControls
                    .frame(minWidth: 184, maxWidth: .infinity)

                volumeControl
                    .frame(maxWidth: 120)
                    .frame(minWidth: 64, maxWidth: .infinity, alignment: .trailing)
            }

            playbackProgress
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .glassEffect(
            .regular.interactive(),
            in: .rect(cornerRadius: 20)
        )
        .overlay(alignment: .topLeading) {
            if isCompact && isTrackTooltipPresented {
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.playback?.currentTrack?.title ?? "Nada tocando")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)

                    if let artist = store.playback?.currentTrack?.artist, !artist.isEmpty {
                        Text(artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(.regularMaterial, in: .rect(cornerRadius: 8))
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                    .padding(.leading, 16)
                    .visualEffect { content, geometry in
                        content.offset(y: -geometry.size.height - 8)
                    }
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(trackTooltip)
                    .accessibilityIdentifier("player.trackTooltip")
            }
        }
        .task(id: isCompact && isTrackInformationHovered) {
            isTrackTooltipPresented = false
            guard isCompact && isTrackInformationHovered else { return }
            do {
                try await Task.sleep(for: .milliseconds(450))
                try Task.checkCancellation()
                isTrackTooltipPresented = true
            } catch { }
        }
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
            if !seeking {
                let delta = snapshot.positionSeconds - position
                let animateProgress = !changedTrack && !store.isSeeking
                    && snapshot.isPlaying && delta > 0 && delta <= 1
                withAnimation(animateProgress ? .linear(duration: 0.25) : nil) {
                    position = snapshot.positionSeconds
                }
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

        return HStack(spacing: 8) {
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

            if isCompact {
                trackActions(track, album: album, artist: artist)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        trackMetadata(track, album: album, artist: artist)
                            .fixedSize(horizontal: true, vertical: false)
                        trackActions(track, album: album, artist: artist)
                    }

                    HStack(spacing: 6) {
                        trackMetadata(track, album: album, artist: artist)
                        trackActions(track, album: album, artist: artist)
                    }
                }
            }
        }
    }

    private func trackMetadata(_ track: Track?, album: Release?, artist: Artist?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            PlayerMetadataLink(
                title: track?.title ?? "Nada tocando",
                destinationLabel: album.map { "Abrir álbum \($0.title)" },
                action: { if let album { onSelectAlbum(album) } }
            )
            .font(.subheadline.weight(.medium))
            .accessibilityIdentifier("player.trackTitle")
            .contextMenu {
                trackContextMenu(track, album: album, artist: artist)
            }

            PlayerMetadataLink(
                title: track?.artist ?? "",
                destinationLabel: artist.map { "Abrir artista \($0.name)" },
                action: { if let artist { onSelectArtist(artist) } }
            )
            .font(.caption)
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

        return VStack(spacing: 2) {
            Button {
                if let track {
                    store.setTrackFavorite(trackID: track.id, favorite: !isFavorite)
                }
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .foregroundStyle(isFavorite ? Color.accentColor : .secondary)
                    .opacity(isFavorite || isTrackInformationHovered ? 1 : 0)
                    .frame(width: 24, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(favoriteLabel)
            .accessibilityLabel(favoriteLabel)
            .accessibilityValue(isFavorite ? "Favorita" : "Não favorita")
            .accessibilityIdentifier("player.favorite")

            Menu {
                trackContextMenu(track, album: album, artist: artist)
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Opções da faixa")
            .accessibilityLabel("Opções da faixa")
            .accessibilityIdentifier("player.options")
        }
        .font(.system(size: 12))
        .frame(width: 24)
        .fixedSize()
        .disabled(track == nil)
    }

    @ViewBuilder
    private func trackContextMenu(_ track: Track?, album: Release?, artist: Artist?) -> some View {
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
    }

    private var playbackControls: some View {
        HStack(spacing: 14) {
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
            .keyboardShortcut(.space, modifiers: [])

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
        .buttonStyle(.plain)
        .font(.system(size: 14))
    }

    private var playbackProgress: some View {
        let snapshot = store.playback
        let duration = max(snapshot?.durationSeconds ?? 0, 0.01)
        let expanded = isProgressHovered || seeking
        let elapsed = time(seeking ? position : (snapshot?.positionSeconds ?? 0))

        return HStack(spacing: 10) {
            Text(elapsed)
                .fixedSize()
                .accessibilityIdentifier("player.elapsed")

            PlayerBarSlider(
                value: $position,
                upperBound: duration,
                expanded: expanded,
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
            .onKeyPress(.leftArrow) {
                adjustProgress(by: -5, duration: duration)
                return .handled
            }
            .onKeyPress(.rightArrow) {
                adjustProgress(by: 5, duration: duration)
                return .handled
            }
            .accessibilityRepresentation {
                Slider(
                    value: Binding(
                        get: { position },
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

            Text(time(duration))
                .fixedSize()
                .accessibilityIdentifier("player.duration")
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.tertiary)
        .frame(height: 24)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: expanded)
    }

    private func updateSeeking(_ editing: Bool) {
        if editing {
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

            PlayerBarSlider(
                value: Binding(
                    get: { volume },
                    set: { updateVolume($0, immediately: !adjustingVolume) }
                ),
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
            .onKeyPress(.leftArrow) {
                updateVolume(volume - 0.05)
                return .handled
            }
            .onKeyPress(.rightArrow) {
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
    @Binding var value: Double
    let upperBound: Double
    let expanded: Bool
    var fillColor: Color = .secondary
    var activeFillColor: Color = .accentColor
    var trackStyle: HierarchicalShapeStyle = .quaternary
    var showsGlow = true
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
                        value = min(max(gesture.location.x / width, 0), 1) * upperBound
                    }
                    .onEnded { gesture in
                        guard isEditing else { return }
                        value = min(max(gesture.location.x / width, 0), 1) * upperBound
                        finishEditing()
                    }
            )
        }
        .frame(height: 24)
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
