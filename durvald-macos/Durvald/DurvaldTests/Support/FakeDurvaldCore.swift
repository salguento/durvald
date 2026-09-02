@testable import Durvald

final class FakeDurvaldCore: DurvaldCore {
    var snapshot: PlaybackSnapshot
    var releaseTrackResults: [Track] = []
    var favoriteError: Error?
    private(set) var favoriteChanges: [Bool] = []
    var onSeek: ((UInt64) -> Void)?
    var playbackHandler: (() async -> PlaybackSnapshot)?
    var seekHandler: ((UInt64) async throws -> Void)?
    var suspendedPlayback: CheckedContinuation<PlaybackSnapshot, Never>?
    var suspendedSeek: CheckedContinuation<Void, Never>?

    private(set) var pauseCallCount = 0
    private(set) var resumeCallCount = 0
    private(set) var playbackOperations: [String] = []
    private(set) var seekCalls: [UInt64] = []
    private(set) var maximumConcurrentSeeks = 0
    private var activeSeeks = 0


    init(snapshot: PlaybackSnapshot) {
        self.snapshot = snapshot
        super.init(noPointer: .init())
    }

    required init(unsafeFromRawPointer pointer: UnsafeMutableRawPointer) {
        fatalError("FakeDurvaldCore não aceita ponteiros do backend Rust")
    }

    override func playback() async -> PlaybackSnapshot {
        if let playbackHandler {
            return await playbackHandler()
        }
        return snapshot
    }

    override func setTrackFavorite(trackId: Int64, favorite: Bool) throws {
        if let favoriteError { throw favoriteError }
        favoriteChanges.append(favorite)
        if snapshot.currentTrack?.id == trackId {
            snapshot.currentTrack?.isFavorite = favorite
        }
    }

    override func pause() async throws {
        pauseCallCount += 1
        snapshot.isPaused = true
        snapshot.isPlaying = false
    }

    override func resume() async throws {
        resumeCallCount += 1
        snapshot.isPaused = false
        snapshot.isPlaying = true
    }

    override func releaseTracks(releaseId: Int64) throws -> [Track] {
        releaseTrackResults
    }

    override func clearQueue() async throws {
        playbackOperations.append("clear")
    }

    override func play(trackId: Int64) async throws -> PlaybackSnapshot {
        playbackOperations.append("play:\(trackId)")
        return snapshot
    }

    override func addToQueue(trackId: Int64) async throws {
        playbackOperations.append("enqueue:\(trackId)")
    }

    override func seek(seconds: UInt64) async throws {
        seekCalls.append(seconds)
        activeSeeks += 1
        maximumConcurrentSeeks = max(maximumConcurrentSeeks, activeSeeks)
        defer { activeSeeks -= 1 }
        if let seekHandler {
            try await seekHandler(seconds)
        } else {
            snapshot.positionSeconds = Double(seconds)
        }
        onSeek?(seconds)
    }
}
