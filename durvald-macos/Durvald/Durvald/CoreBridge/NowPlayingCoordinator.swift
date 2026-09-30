import AppKit
import MediaPlayer

/// Publishes Durvald's playback state to macOS and routes system media commands
/// back through the same store operations used by the app UI.
@MainActor
final class NowPlayingCoordinator {
    private let infoCenter: MPNowPlayingInfoCenter
    private let commandCenter: MPRemoteCommandCenter
    private weak var store: DurvaldCoreStore?
    private var isActive = false
    private var artworkTask: Task<Void, Never>?
    private var publishedTrackID: Int64?
    private var publishedArtworkID: String?
    private var publishedArtwork: MPMediaItemArtwork?

    init(
        infoCenter: MPNowPlayingInfoCenter = .default(),
        commandCenter: MPRemoteCommandCenter = .shared()
    ) {
        self.infoCenter = infoCenter
        self.commandCenter = commandCenter
    }

    func activate(for store: DurvaldCoreStore) {
        self.store = store
        guard !isActive else {
            update(store.playback, core: store.core)
            return
        }

        isActive = true
        installCommandHandlers()
        update(store.playback, core: store.core)
    }

    func update(_ playback: PlaybackSnapshot?, core: DurvaldCore?) {
        guard isActive else { return }
        guard let playback, let track = playback.currentTrack else {
            clear()
            return
        }

        if publishedTrackID != track.id || publishedArtworkID != track.artworkId {
            publishedTrackID = track.id
            publishedArtworkID = track.artworkId
            publishedArtwork = nil
            loadArtwork(for: track, using: core)
        }

        let queue = Self.queueContext(for: playback)
        var information: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.release,
            MPMediaItemPropertyPlaybackDuration: validDuration(playback, track: track),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: validPosition(playback),
            MPNowPlayingInfoPropertyPlaybackRate: playback.isPlaying && !playback.isPaused ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: queue.index,
            MPNowPlayingInfoPropertyPlaybackQueueCount: queue.count
        ]
        if let publishedArtwork {
            information[MPMediaItemPropertyArtwork] = publishedArtwork
        }

        infoCenter.nowPlayingInfo = information
        if playback.isPlaying && !playback.isPaused {
            infoCenter.playbackState = .playing
        } else if playback.isPaused {
            infoCenter.playbackState = .paused
        } else {
            infoCenter.playbackState = .stopped
        }

        updateCommandAvailability(for: playback)
    }

    private func installCommandHandlers() {
        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let store = self?.store else { return }
                guard store.playback?.currentTrack != nil,
                      store.playback?.isPaused == true else { return }
                await store.togglePause()
            }
            return .success
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let store = self?.store else { return }
                guard store.playback?.currentTrack != nil,
                      store.playback?.isPaused == false else { return }
                await store.togglePause()
            }
            return .success
        }
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let store = self?.store else { return }
                await store.togglePause()
            }
            return .success
        }
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let store = self?.store else { return }
                await store.previous()
            }
            return .success
        }
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let store = self?.store else { return }
                await store.next()
            }
            return .success
        }
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let position = positionEvent.positionTime
            Task { @MainActor [weak self] in
                guard let store = self?.store else { return }
                store.seek(to: position)
            }
            return position.isFinite ? .success : .commandFailed
        }
    }

    private func updateCommandAvailability(for playback: PlaybackSnapshot) {
        let hasTrack = playback.currentTrack != nil
        commandCenter.playCommand.isEnabled = hasTrack && playback.isPaused
        commandCenter.pauseCommand.isEnabled = hasTrack && !playback.isPaused
        commandCenter.togglePlayPauseCommand.isEnabled = hasTrack
        commandCenter.previousTrackCommand.isEnabled = hasTrack
        commandCenter.nextTrackCommand.isEnabled = hasTrack
        commandCenter.changePlaybackPositionCommand.isEnabled = hasTrack
    }

    private func loadArtwork(for track: Track, using core: DurvaldCore?) {
        artworkTask?.cancel()
        guard let artworkID = track.artworkId, let core else { return }

        let trackID = track.id
        artworkTask = Task { @MainActor [weak self] in
            let image = try? await ArtworkRepository.shared.image(
                for: artworkID,
                pixelSize: 512,
                using: core
            )
            guard !Task.isCancelled,
                  let self,
                  self.publishedTrackID == trackID,
                  self.publishedArtworkID == artworkID,
                  let image else { return }

            let size = image.size.width > 0 && image.size.height > 0
                ? image.size
                : NSSize(width: 512, height: 512)
            self.publishedArtwork = MPMediaItemArtwork(boundsSize: size) { _ in image }
            self.update(self.store?.playback, core: self.store?.core)
        }
    }

    private func validDuration(_ playback: PlaybackSnapshot, track: Track) -> Double {
        let duration = playback.durationSeconds ?? track.durationSeconds
        return duration.isFinite ? max(0, duration) : 0
    }

    private func validPosition(_ playback: PlaybackSnapshot) -> Double {
        playback.positionSeconds.isFinite ? max(0, playback.positionSeconds) : 0
    }

    nonisolated static func queueContext(for playback: PlaybackSnapshot) -> (index: Int, count: Int) {
        guard let currentTrack = playback.currentTrack else { return (0, 0) }
        let count = max(playback.queue.count, 1)
        if let index = playback.queue.firstIndex(where: { $0.trackId == currentTrack.id }) {
            return (index, count)
        }
        return (min(Int(playback.queuePosition), count - 1), count)
    }

    private func clear() {
        artworkTask?.cancel()
        artworkTask = nil
        publishedTrackID = nil
        publishedArtworkID = nil
        publishedArtwork = nil
        infoCenter.nowPlayingInfo = nil
        infoCenter.playbackState = .stopped
        commandCenter.playCommand.isEnabled = false
        commandCenter.pauseCommand.isEnabled = false
        commandCenter.togglePlayPauseCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false
        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.changePlaybackPositionCommand.isEnabled = false
    }
}
