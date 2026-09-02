import Foundation
import SwiftUI
import Combine
// import DurvaldCoreFFI // substitua pelo módulo efetivamente gerado

@MainActor
final class DurvaldCoreStore: ObservableObject {

    @Published private(set) var playback: PlaybackSnapshot?
    @Published private(set) var isSeeking = false
    @Published private(set) var scanProgress: ScanProgress?
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var releases: [Release] = []
    @Published private(set) var artists: [Artist] = []
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var history: [PlaybackHistoryItem] = []
    @Published var errorMessage: String?
    @Published private(set) var appSettings: Settings?
    @Published private(set) var libraryPaths: [String] = []


    private(set) var core: DurvaldCore?
    private var playbackPollingTask: Task<Void, Never>?
    private var scanProgressPollingTask: Task<Void, Never>?
    private static let libraryBookmarksKey = "durvald.library-security-bookmarks"
    private var activeLibraryScopes: [URL] = []
    private var volumeTask: Task<Void, Never>?
    private var isChangingTrack = false
    private var isMovingQueue = false
    private var seekTask: Task<Void, Never>?
    private var seekRequestID = 0
    private var pendingSeek: SeekRequest?

    private struct SeekRequest {
        let id: Int
        let trackID: Int64
        let seconds: UInt64
    }

    private struct SendableCore: @unchecked Sendable {
        let value: DurvaldCore
    }

    init(
        core: DurvaldCore? = nil,
        playback: PlaybackSnapshot? = nil,
        tracks: [Track] = [],
        releases: [Release] = [],
        artists: [Artist] = []
    ) {
        self.core = core
        self.playback = playback
        self.tracks = tracks
        self.releases = releases
        self.artists = artists
    }


    func openCoreIfNeeded() async {
        guard core == nil else { return }

        do {
            restoreLibraryAccess()

            let openedCore = try await open(config: try makeConfig())
            let initialPlayback = await openedCore.playback()
            core = openedCore
            try reloadLibrary(using: openedCore)
            libraryPaths = try openedCore.libraryPaths()
            appSettings = try openedCore.settings()
            playback = initialPlayback

            startPlaybackPolling()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func startPlaybackPolling() {
        playbackPollingTask?.cancel()

        playbackPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }

                if let core = self.core,
                   !self.isChangingTrack,
                   !self.isMovingQueue,
                   !self.isSeeking {
                    let revision = self.seekRequestID
                    let snapshot = await core.playback()
                    // A seek/track change can start while this read is suspended.
                    guard !Task.isCancelled else { return }
                    if !self.isChangingTrack, !self.isMovingQueue, !self.isSeeking {
                        self.publishPlayback(snapshot, revision: revision)
                    }
                }

                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func reloadLibrary(using core: DurvaldCore) throws {
        tracks = try core.tracks()
        releases = try core.releases()
        artists = try core.artists()
        playlists = try core.playlists()
        history = try core.playbackHistory()
    }

    func searchLibrary(query: String) async -> SearchResults {
        guard let core else {
            return SearchResults(
                tracks: [],
                releases: [],
                artists: [],
                playlists: []
            )
        }

        let sendableCore = SendableCore(value: core)

        do {
            return try await Task.detached(priority: .userInitiated) {
                try sendableCore.value.search(query: query)
            }.value
        } catch {
            errorMessage = String(describing: error)
            return SearchResults(
                tracks: [],
                releases: [],
                artists: [],
                playlists: []
            )
        }
    }

    func tracks(forReleaseID releaseID: Int64) async -> [Track] {
        guard let core else { return [] }

        let sendableCore = SendableCore(value: core)

        do {
            let tracks = try await Task.detached(priority: .userInitiated) {
                try sendableCore.value.releaseTracks(releaseId: releaseID)
            }.value

            return tracks.sorted { lhs, rhs in
                if lhs.discNumber != rhs.discNumber {
                    return lhs.discNumber < rhs.discNumber
                }

                if lhs.trackNumber != rhs.trackNumber {
                    return lhs.trackNumber < rhs.trackNumber
                }

                return lhs.id < rhs.id
            }
        } catch {
            errorMessage = String(describing: error)
            return []
        }
    }

    private func makeConfig() throws -> CoreConfig {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Durvald", isDirectory: true)

        let config = CoreConfig(
            databasePath: appSupport.appendingPathComponent("music.db3").path,
            appSupportDir: appSupport.path,
            coversDir: appSupport.appendingPathComponent("covers").path,
            keychainService: "com.durvald.player"
        )
        return config
    }

    func addAndScanLibraryFolder(_ url: URL) {
        do {
            try saveAndStartLibraryAccess(for: url)
        } catch {
            errorMessage = "Não foi possível acessar a pasta selecionada: \(error)"
            return
        }

        Task {
            print("Durvald: pasta selecionada para scan: \(url.path)")
            guard let core else {
                errorMessage = "O core ainda está abrindo. Tente novamente em instantes."
                return
            }
            startScanProgressPolling()
            do {
                defer {
                    scanProgressPollingTask?.cancel()
                    scanProgressPollingTask = nil
                    scanProgress = nil
                }
                try core.addLibraryPath(path: url.path)
                libraryPaths = try core.libraryPaths()
                let result = try await core.scanConfiguredLibrary()
                print(
                    "Durvald: scan concluído — encontrados: \(result.totalFilesFound), novos: \(result.newTracksAdded), atualizados: \(result.updatedTracks), erros: \(result.errors)"
                )
                try reloadLibrary(using: core)

                if !result.errors.isEmpty {
                    errorMessage = result.errors.joined(separator: "\n")
                } else if result.totalFilesFound == 0 {
                    errorMessage = "Nenhum arquivo suportado foi encontrado. O MVP aceita MP3, WAV, FLAC, Ogg Vorbis e OGA."
                } else {
                    print("Scan concluído: \(result.newTracksAdded) nova(s), \(result.updatedTracks) atualizada(s), \(tracks.count) faixa(s) na biblioteca.")
                }
            } catch {
                errorMessage = String(describing: error)
            }
        }
    }
    
    func removeLibraryFolder(path: String) {
        guard let core else {
            errorMessage = "O core ainda está abrindo. Tente novamente em instantes."
            return
        }

        do {
            try core.removeLibraryPath(path: path)
            removeLibraryAccess(forPath: path)

            libraryPaths.removeAll { configuredPath in
                standardizedLibraryPath(configuredPath)
                    == standardizedLibraryPath(path)
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func startScanProgressPolling() {
        scanProgressPollingTask?.cancel()
        scanProgressPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard let core = self.core else { return }
                self.scanProgress = try? core.scanProgress()
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    func cancelScan() {
        guard let core else {
            errorMessage = "Não há core disponível para cancelar o scan."
            return
        }
        do { try core.cancelLibraryScan() }
        catch { errorMessage = String(describing: error) }
    }

    func play(trackID: Int64) async {
        guard let core else {
            errorMessage = "O core ainda está abrindo."
            return
        }

        guard !isChangingTrack else { return }

        isChangingTrack = true
        await finishSeekBeforeChangingTrack()
        defer {
            isChangingTrack = false
            seekRequestID &+= 1
        }

        print("Durvald: solicitando reprodução da faixa \(trackID).")

        do {
            let snapshot = try await core.play(trackId: trackID)
            playback = snapshot
            print("Durvald: reprodução iniciada; pausada: \(snapshot.isPaused).")
        } catch {
            print("Durvald: falha ao iniciar reprodução: \(error)")
            errorMessage = String(describing: error)
        }
    }

    func playRelease(releaseID: Int64) async {
        guard let core, !isChangingTrack else { return }

        isChangingTrack = true
        await finishSeekBeforeChangingTrack()
        defer {
            isChangingTrack = false
            seekRequestID &+= 1
        }

        do {
            let tracks = try core.releaseTracks(releaseId: releaseID).sorted {
                if $0.discNumber != $1.discNumber {
                    return $0.discNumber < $1.discNumber
                }

                if $0.trackNumber != $1.trackNumber {
                    return $0.trackNumber < $1.trackNumber
                }

                return $0.id < $1.id
            }

            guard let firstTrack = tracks.first else {
                errorMessage = "Este álbum não possui faixas."
                return
            }

            try await core.clearQueue()
            playback = try await core.play(trackId: firstTrack.id)

            for track in tracks.dropFirst() {
                try await core.addToQueue(trackId: track.id)
            }

            await refreshPlayback()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func saveAndStartLibraryAccess(for url: URL) throws {
        // Keep the exact URL returned by NSOpenPanel. Normalizing it before
        // opening the security scope can discard the sandbox authorization.
        let scopedURL = url
        let canonicalPath = scopedURL.standardizedFileURL.path
        if activeLibraryScopes.contains(where: { $0.standardizedFileURL.path == canonicalPath }) {
            return
        }

        let bookmark = try scopedURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        var bookmarks = UserDefaults.standard.dictionary(forKey: Self.libraryBookmarksKey) ?? [:]
        bookmarks[canonicalPath] = bookmark
        UserDefaults.standard.set(bookmarks, forKey: Self.libraryBookmarksKey)

        guard scopedURL.startAccessingSecurityScopedResource() else {
            throw CocoaError(.fileReadNoPermission)
        }
        activeLibraryScopes.append(scopedURL)
    }
    
    private func removeLibraryAccess(forPath path: String) {
        let canonicalPath = standardizedLibraryPath(path)

        var bookmarks = UserDefaults.standard.dictionary(
            forKey: Self.libraryBookmarksKey
        ) ?? [:]

        bookmarks.removeValue(forKey: canonicalPath)

        UserDefaults.standard.set(
            bookmarks,
            forKey: Self.libraryBookmarksKey
        )

        let removedScopes = activeLibraryScopes.filter { url in
            standardizedLibraryPath(url.path) == canonicalPath
        }

        removedScopes.forEach {
            $0.stopAccessingSecurityScopedResource()
        }

        activeLibraryScopes.removeAll { url in
            standardizedLibraryPath(url.path) == canonicalPath
        }
    }

    private func standardizedLibraryPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .path
    }

    private func restoreLibraryAccess() {
        let bookmarks = UserDefaults.standard.dictionary(forKey: Self.libraryBookmarksKey) ?? [:]
        for value in bookmarks.values {
            guard let data = value as? Data else { continue }
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else { continue }
            guard !activeLibraryScopes.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) else { continue }
            if url.startAccessingSecurityScopedResource() {
                activeLibraryScopes.append(url.standardizedFileURL)
            }
        }
    }

    func previous() async {
        guard let core, !isChangingTrack else { return }

        isChangingTrack = true
        await finishSeekBeforeChangingTrack()
        defer {
            isChangingTrack = false
            seekRequestID &+= 1
        }

        do {
            playback = try await core.previousTrack()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func next() async {
        guard let core, !isChangingTrack else { return }

        isChangingTrack = true
        await finishSeekBeforeChangingTrack()
        defer {
            isChangingTrack = false
            seekRequestID &+= 1
        }

        do {
            playback = try await core.nextTrack()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func togglePause() async {
        guard let core, let playback, playback.currentTrack != nil else { return }

        do {
            if playback.isPaused {
                try await core.resume()
            } else {
                try await core.pause()
            }

            await self.refreshPlayback()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func setVolume(_ value: Double) async {
        guard let core else { return }
        do {
            try await core.setVolume(volume: Float(min(max(value, 0), 1)))
            await refreshPlayback()
        } catch { errorMessage = String(describing: error) }
    }

    func seek(to seconds: Double) {
        guard let core, !isChangingTrack, seconds.isFinite,
              var optimisticSnapshot = playback,
              let trackID = optimisticSnapshot.currentTrack?.id,
              let duration = optimisticSnapshot.durationSeconds,
              duration.isFinite, duration > 0
        else { return }

        // The current FFI accepts whole seconds. Show the same target we send,
        // rather than first showing a fraction and then snapping back on receipt.
        let target = min(max(seconds, 0).rounded(), duration.rounded(.down))
        guard let coreSeconds = UInt64(exactly: target) else { return }
        seekRequestID &+= 1
        pendingSeek = SeekRequest(id: seekRequestID, trackID: trackID, seconds: coreSeconds)
        isSeeking = true
        optimisticSnapshot.positionSeconds = target
        playback = optimisticSnapshot

        // One worker owns the FFI calls. Cancelling a Swift task does not undo
        // a command already sent to the audio engine; queue only the latest target.
        guard seekTask == nil else { return }
        seekTask = Task { [weak self] in
            await self?.performPendingSeeks(using: core)
        }
    }

    private func performPendingSeeks(using core: DurvaldCore) async {
        defer {
            seekTask = nil
            isSeeking = false
        }

        while let request = pendingSeek {
            do {
                // Coalesce quick successive clicks without seeking continuously
                // while the slider is being dragged.
                try await Task.sleep(for: .milliseconds(60))
                guard pendingSeek?.id == request.id else { continue }
                try await core.seek(seconds: request.seconds)
                let clock = ContinuousClock()
                let started = clock.now
                let deadline = started.advanced(by: .seconds(3))
                var consecutiveConfirmations = 0

                while pendingSeek?.id == request.id {
                    try Task.checkCancellation()
                    let snapshot = await core.playback()
                    guard pendingSeek?.id == request.id else { break }

                    let elapsed = started.duration(to: clock.now).components
                    let elapsedSeconds = Double(elapsed.seconds)
                        + Double(elapsed.attoseconds) / 1e18
                    let target = Double(request.seconds)
                    let upperTolerance = snapshot.isPlaying ? elapsedSeconds + 0.25 : 0.25
                    let arrived = snapshot.positionSeconds >= target - 0.10
                        && snapshot.positionSeconds <= target + upperTolerance
                    let changedTrack = snapshot.currentTrack?.id != request.trackID
                    consecutiveConfirmations = arrived ? consecutiveConfirmations + 1 : 0
                    let confirmed = consecutiveConfirmations >= 2

                    if confirmed || changedTrack || clock.now >= deadline {
                        pendingSeek = nil
                        // Invalidate reads started before the acknowledgement too.
                        seekRequestID &+= 1
                        publishPlayback(snapshot, revision: seekRequestID)
                        if !confirmed && !changedTrack {
                            errorMessage = "O áudio não confirmou a nova posição. Tente novamente."
                        }
                        break
                    }

                    // Kira queues seek_to; returning from the FFI is not an audio
                    // acknowledgement. Keep the target until the decoder catches up.
                    try await Task.sleep(for: .milliseconds(50))
                }
            } catch {
                if Task.isCancelled {
                    pendingSeek = nil
                    return
                }
                guard pendingSeek?.id == request.id else { continue }
                pendingSeek = nil
                seekRequestID &+= 1
                let revision = seekRequestID
                let snapshot = await core.playback()
                guard revision == seekRequestID else { continue }
                // Recover from the actual engine state, never an old full snapshot.
                publishPlayback(snapshot, revision: revision)
                errorMessage = String(describing: error)
            }
        }
    }

    /// Shared by polling and non-seek actions such as volume, pause and queue edits.
    func refreshPlayback() async {
        guard let core else { return }
        let revision = seekRequestID
        let snapshot = await core.playback()
        publishPlayback(snapshot, revision: revision)
    }

    private func publishPlayback(_ snapshot: PlaybackSnapshot, revision: Int) {
        guard revision == seekRequestID else { return }
        var snapshot = snapshot
        if let request = pendingSeek {
            guard snapshot.currentTrack?.id == request.trackID else { return }
            snapshot.positionSeconds = Double(request.seconds)
        }
        playback = snapshot
    }

    private func finishSeekBeforeChangingTrack() async {
        seekRequestID &+= 1
        pendingSeek = nil
        // Let an already dispatched command finish before loading another track.
        await seekTask?.value
    }

    func scheduleVolume(_ value: Double, immediately: Bool = false) {
        volumeTask?.cancel()

        let normalized = Float(min(max(value, 0), 1))

        // Atualização otimista da interface.
        if var snapshot = playback {
            snapshot.volume = normalized
            playback = snapshot
        }

        volumeTask = Task { [weak self] in
            if !immediately {
                try? await Task.sleep(for: .milliseconds(50))
            }

            guard !Task.isCancelled, let self, let core = self.core else { return }

            do {
                try await core.setVolume(volume: normalized)
                await self.refreshPlayback()
            } catch {
                guard !Task.isCancelled else { return }
                self.errorMessage = String(describing: error)
            }
        }
    }
    
    var queue: [QueueItem] {
        playback?.queue ?? []
    }

    func setTrackFavorite(trackID: Int64, favorite: Bool) {
        guard let core else {
            errorMessage = "O core ainda está abrindo. Tente novamente em instantes."
            return
        }

        do {
            try core.setTrackFavorite(trackId: trackID, favorite: favorite)
            if let index = tracks.firstIndex(where: { $0.id == trackID }) {
                tracks[index].isFavorite = favorite
            }
            if playback?.currentTrack?.id == trackID {
                playback?.currentTrack?.isFavorite = favorite
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func addToQueue(trackID: Int64) async {
        guard let core else { return }

        do {
            try await core.addToQueue(trackId: trackID)
            await refreshPlayback()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func playQueueItem(at position: UInt64) async {
        guard let core, !isChangingTrack else { return }

        isChangingTrack = true
        await finishSeekBeforeChangingTrack()
        defer {
            isChangingTrack = false
            seekRequestID &+= 1
        }

        do {
            playback = try await core.playQueueItem(position: position)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func removeQueueItem(at position: UInt64) async {
        guard let core else { return }

        do {
            try await core.removeFromQueue(position: position)
            await refreshPlayback()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func moveQueueItem(from: UInt64, to: UInt64) {
        guard let core else { return }
        guard !isMovingQueue else { return }
        guard var optimisticSnapshot = playback else { return }
        guard let sourceIndex = optimisticSnapshot.queue.firstIndex(
            where: { $0.position == from }
        ) else { return }
        guard let destinationIndex = optimisticSnapshot.queue.firstIndex(
            where: { $0.position == to }
        ) else { return }
        guard sourceIndex > 0, destinationIndex > 0 else { return }
        guard sourceIndex != destinationIndex else { return }

        isMovingQueue = true

        let previousSnapshot = optimisticSnapshot
        let movedItem = optimisticSnapshot.queue.remove(
            at: sourceIndex
        )

        optimisticSnapshot.queue.insert(
            movedItem,
            at: destinationIndex
        )

        for index in optimisticSnapshot.queue.indices {
            optimisticSnapshot.queue[index].position = UInt64(index)
        }

        // Publica a nova ordem imediatamente e confirma com o core em seguida.
        playback = optimisticSnapshot

        Task {
            defer {
                isMovingQueue = false
            }

            do {
                let revision = seekRequestID
                try await core.moveQueueItem(
                    from: from,
                    to: to
                )

                let confirmedSnapshot = await core.playback()
                publishPlayback(confirmedSnapshot, revision: revision)
            } catch {
                // Roll back only the queue, not a position superseded by a seek.
                if var snapshot = playback {
                    snapshot.queue = previousSnapshot.queue
                    playback = snapshot
                }
                errorMessage = String(describing: error)
            }
        }
    }

    func clearQueue() async {
        guard let core else { return }

        do {
            try await core.clearQueue()
            await refreshPlayback()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func toggleShuffle() async {
        guard let core else { return }

        do {
            let enabled = !(playback?.shuffleEnabled ?? false)
            let revision = seekRequestID
            let snapshot = try await core.setShuffleEnabled(enabled: enabled)
            publishPlayback(snapshot, revision: revision)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func cycleRepeatMode() async {
        guard let core else { return }

        let next: RepeatMode
        switch playback?.repeatMode ?? .none {
        case .none:
            next = .all
        case .all:
            next = .one
        case .one:
            next = .none
        }

        do {
            let revision = seekRequestID
            let snapshot = try await core.setRepeatMode(mode: next)
            publishPlayback(snapshot, revision: revision)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func refreshHistory() {
        guard let core else { return }

        do {
            history = try core.playbackHistory()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func updateSettings(
        crossFade: Bool,
        crossFadeDuration: UInt32,
        normalizeVolume: Bool,
        explicitContent: Bool
    ) {
        guard let core else { return }

        do {
            var settings = try core.settings()

            settings.crossFade = crossFade
            settings.crossFadeDuration = crossFadeDuration
            settings.normalizeVolume = normalizeVolume
            settings.explicitContent = explicitContent

            // Autoplay, fonte, qualidade e opções ainda não implementadas
            // no cliente macOS permanecem intocados.
            try core.updateSettings(settings: settings)
            appSettings = settings
        } catch {
            errorMessage = String(describing: error)
        }
    }

    deinit {
        playbackPollingTask?.cancel()
        scanProgressPollingTask?.cancel()
        seekTask?.cancel()
        activeLibraryScopes.forEach { $0.stopAccessingSecurityScopedResource() }
    }
}
