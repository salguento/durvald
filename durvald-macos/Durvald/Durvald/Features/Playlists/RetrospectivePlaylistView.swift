import SwiftUI

struct RetrospectivePlaylistBanner: View {
    @Environment(DurvaldCoreStore.self) private var store
    let draft: RetrospectivePlaylistDraft
    let tracks: [Track]
    let onOpen: (RetrospectivePlaylistDraft) -> Void
    @State private var artwork: ReplayArtwork?

    private var artworkTracks: [Track] { ReplayArtworkRepository.albumSources(for: tracks, using: store) }
    private var artworkKey: ReplayArtworkRepository.Key {
        ReplayArtworkRepository.key(draft: draft, tracks: artworkTracks, core: store.core)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Seu Replay").font(.title2.bold())
            Button { onOpen(draft) } label: {
                ZStack {
                    if let artwork {
                        AnimatedReplayArtwork(draft: draft, colors: artwork.colors,
                            phase: artwork.phase, artists: artwork.artists)
                        if !artwork.artists.isEmpty {
                            GeometryReader { geometry in
                                Text(artwork.artists)
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(.white.opacity(0.95))
                                    .lineLimit(2)
                                    .frame(width: max(0, geometry.size.width * 0.5 - 24), alignment: .leading)
                                    .padding(24)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                            }
                        }
                    } else {
                        RoundedRectangle(cornerRadius: 20).fill(.quaternary)
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity).frame(height: 280)
                .clipShape(.rect(cornerRadius: 20))
                .contentShape(.rect(cornerRadius: 20))
            }
            .buttonStyle(.plain)
            .disabled(artwork == nil)
            .accessibilityLabel("Abrir \(draft.title)")
            .accessibilityHint("Mostra a prévia antes de salvar na biblioteca")
            .accessibilityIdentifier("retrospective.playlist.banner")
        }
        .task(id: artworkKey) {
            artwork = nil
            let result = await ReplayArtworkRepository.shared.artwork(draft: draft, tracks: artworkTracks, core: store.core)
            guard !Task.isCancelled else { return }
            artwork = result
        }
    }
}

struct RetrospectivePlaylistSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let playlist: Playlist
    let draft: RetrospectivePlaylistDraft
    let onSave: (Bool, Bool) async -> Bool
    @State private var live: Bool
    @State private var closeAutomatically: Bool
    @State private var isSaving = false
    @State private var error: String?

    init(playlist: Playlist, config: RetrospectivePlaylistConfiguration, period: RetrospectivePeriod,
         onSave: @escaping (Bool, Bool) async -> Bool) {
        self.playlist = playlist
        draft = RetrospectivePlaylistDraft(period: period, interval: DateInterval(
            start: Date(timeIntervalSince1970: Double(config.startAt)), end: Date(timeIntervalSince1970: Double(config.endAt))))
        self.onSave = onSave
        _live = State(initialValue: config.mode == "live")
        _closeAutomatically = State(initialValue: config.closeAutomatically)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(playlist.name).font(.title2.bold())
            Form {
                if draft.isCurrent {
                    Picker("Atualização", selection: $live) {
                        Text("Manter atualizada").tag(true)
                        Text("Salvar como está").tag(false)
                    }.pickerStyle(.radioGroup)
                    if live {
                        Toggle("Converter em snapshot ao encerrar o período", isOn: $closeAutomatically)
                    }
                } else {
                    Text("O período terminou. Salvar as alterações fixa a seleção como snapshot.")
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isSaving ? "Salvando…" : "Salvar") {
                    isSaving = true
                    Task {
                        defer { isSaving = false }
                        if await onSave(live, closeAutomatically) { dismiss() }
                        else { error = "Não foi possível salvar as alterações." }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .disabled(isSaving)
        .padding(24).frame(width: 480)
    }
}

struct RetrospectivePlaylistView: View {
    @Environment(DurvaldCoreStore.self) private var store
    let draft: RetrospectivePlaylistDraft
    let onSaved: (Playlist) -> Void
    @State private var preview: ReplayPreview?
    @State private var isLoading = true
    @State private var isChoosingSaveMode = false
    @State private var isSaving = false
    @State private var now = Date()
    @State private var artwork: ReplayArtwork?
    @State private var loadedArtworkKey: ReplayArtworkRepository.Key?

    init(draft: RetrospectivePlaylistDraft, onSaved: @escaping (Playlist) -> Void) {
        self.draft = draft
        self.onSaved = onSaved
    }

    private var tracks: [Track] { preview?.tracks ?? [] }
    private var artworkTracks: [Track] { ReplayArtworkRepository.albumSources(for: tracks, using: store) }
    private var artworkKey: ReplayArtworkRepository.Key {
        ReplayArtworkRepository.key(draft: draft, tracks: artworkTracks, core: store.core)
    }
    private var canSave: Bool {
        !isLoading && !isSaving
            && artwork != nil && loadedArtworkKey == artworkKey
            && store.savedRetrospectivePlaylist(for: draft) == nil && preview?.available == true
    }
    private var current: Bool { preview?.isCurrent == true }
    private var key: LibraryListingKey {
        LibraryListingKey(storeID: ObjectIdentifier(store), payloadRevision: store.historyRepository.revision,
            scope: "retrospective.playlist", query: "\(draft.identity):\(now.timeIntervalSince1970)")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                trackList
            }
            .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("retrospective.playlist.preview")
        .focusedSceneValue(\.pageCommands, replayCommands)
        .task(id: key) {
            isLoading = true
            let result = await store.loadReplayPreview(draft)
            guard !Task.isCancelled else { return }
            preview = result
            isLoading = false
            if let saved = result?.savedPlaylist { onSaved(saved) }
        }
        .task(id: tracks.isEmpty ? nil : artworkKey) {
            guard !tracks.isEmpty, !isLoading else { return }
            let request = artworkKey
            let result = await ReplayArtworkRepository.shared.artwork(draft: draft, tracks: artworkTracks, core: store.core)
            guard !Task.isCancelled else { return }
            artwork = result
            loadedArtworkKey = request
        }
        .task {
            guard draft.isCurrent else { return }
            try? await Task.sleep(for: .seconds(max(0, draft.interval.end.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            now = Date()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in now = Date() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 24) {
            Group {
                if let artwork, loadedArtworkKey == artworkKey {
                    AnimatedReplayArtwork(draft: draft, colors: artwork.colors, phase: artwork.phase, artists: artwork.artists)
                } else {
                    RoundedRectangle(cornerRadius: 14).fill(.quaternary)
                        .overlay { ProgressView().controlSize(.small) }
                }
            }
            .frame(width: 200, height: 200)
            .clipShape(.rect(cornerRadius: 14))
            .accessibilityLabel("Capa de \(draft.title)")
            VStack(alignment: .leading, spacing: 12) {
                Text("PRÉVIA DE PLAYLIST").font(.caption).foregroundStyle(.secondary)
                Text(draft.title).font(.largeTitle.bold())
                Text("\(tracks.count) músicas · Ainda não foi salva na biblioteca")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("retrospective.playlist.summary")
                playbackActions
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var playbackActions: some View {
        HStack(spacing: 12) {
            Button {
                Task { await PlaybackCollection.tracks(tracks, sourceContext: PlaybackSourceContext.replay(draft.identity)).perform(.play, using: store) }
            } label: { Label("Reproduzir", systemImage: "play.fill") }
            .disabled(tracks.isEmpty || isLoading)
            .accessibilityIdentifier("retrospective.playlist.play")

            if store.savedRetrospectivePlaylist(for: draft) == nil {
                Button(isSaving ? "Salvando…" : "Salvar na biblioteca") {
                    if current { isChoosingSaveMode = true }
                    else { save(live: false) }
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                    .accessibilityIdentifier("retrospective.playlist.save")
            }

        }
        .confirmationDialog("Salvar playlist", isPresented: $isChoosingSaveMode, titleVisibility: .visible) {
            Button("Manter atualizada") { save(live: true) }
            Button("Salvar como está") { save(live: false) }
            Button("Cancelar", role: .cancel) { }
        } message: {
            Text("Manter atualizada acompanha as reproduções até o fim do período e então fixa a seleção. Salvar como está guarda a seleção atual.")
        }
    }

    @ViewBuilder
    private var trackList: some View {
        if isLoading {
            ProgressView("Preparando playlist…")
        } else if preview == nil {
            ContentUnavailableView {
                Label("Não foi possível carregar o Replay", systemImage: "exclamationmark.triangle")
            } actions: {
                Button("Tentar novamente") { now = Date() }
            }
        } else if tracks.isEmpty {
            ContentUnavailableView("Replay indisponível neste período", systemImage: "music.note.list",
                description: Text("Ainda não há músicas suficientes para gerar esta playlist."))
        } else {
            LazyVStack(spacing: 0) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    trackRow(track, index: index)
                    Divider()
                }
            }
        }
    }

    private func trackRow(_ track: Track, index: Int) -> some View {
        CollectionTrackRow(track: track, number: "\(index + 1)") {
            Task { await store.playTracks(tracks, startingAt: track.id, shuffleEnabled: nil, sourceContext: PlaybackSourceContext.replay(draft.identity)) }
        }
        .environment(\.playbackSourceContext, PlaybackSourceContext.replay(draft.identity))
        .accessibilityIdentifier("retrospective.playlist.track.\(track.id)")
    }

    private var replayCommands: AppCommandTarget {
        var actions: [AppCommandID: () -> Void] = [:]
        if !isLoading && !tracks.isEmpty {
            actions[.playCollection] = { Task { await PlaybackCollection.tracks(tracks, sourceContext: PlaybackSourceContext.replay(draft.identity)).perform(.play, using: store) } }
            actions[.shuffleCollection] = { Task { await PlaybackCollection.tracks(tracks, sourceContext: PlaybackSourceContext.replay(draft.identity)).perform(.shuffle, using: store) } }
        }
        if canSave { actions[.saveReplay] = { if current { isChoosingSaveMode = true } else { save(live: false) } } }
        return AppCommandTarget(actions: actions)
    }

    private func save(live: Bool) {
        guard canSave, let artwork else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            if let playlist = await store.saveRetrospectivePlaylist(draft, live: live, closeAutomatically: true, artworkBase64: artwork.base64) {
                ReplayArtworkRepository.shared.freeze(artwork, draft: draft, core: store.core)
                onSaved(playlist)
            }
        }
    }
}
