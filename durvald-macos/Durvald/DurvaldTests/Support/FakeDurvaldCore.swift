@testable import Durvald

final class FakeDurvaldCore: DurvaldCore {
    var snapshot: PlaybackSnapshot
    var releaseTrackResults: [Track] = []
    private(set) var pauseCallCount = 0
    private(set) var resumeCallCount = 0
    private(set) var playbackOperations: [String] = []

    init(snapshot: PlaybackSnapshot) {
        self.snapshot = snapshot
        super.init(noPointer: .init())
    }

    required init(unsafeFromRawPointer pointer: UnsafeMutableRawPointer) {
        fatalError("FakeDurvaldCore não aceita ponteiros do backend Rust")
    }

    override func playback() async -> PlaybackSnapshot {
        snapshot
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
}
