import Foundation

/// Collection-level playback preserves each source's ordering and occurrence policy.
enum PlaybackCollection {
    case release(Int64)
    case playlist(Int64)
    case tracks([Track])

    enum Action {
        case play, shuffle
    }

    @MainActor
    func perform(_ action: Action, using store: DurvaldCoreStore) async {
        let shuffled = action == .shuffle
        switch self {
        case .release(let id):
            await store.playRelease(releaseID: id, shuffleEnabled: shuffled)
        case .playlist(let id):
            await store.playPlaylist(playlistID: id, startingAtPosition: 0, shuffleEnabled: shuffled)
        case .tracks(let tracks):
            await store.playTracks(tracks, shuffleEnabled: shuffled)
        }
    }
}
