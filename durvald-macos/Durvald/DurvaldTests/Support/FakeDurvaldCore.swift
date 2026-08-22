@testable import Durvald

final class FakeDurvaldCore: DurvaldCore {
    var snapshot: PlaybackSnapshot
    private(set) var pauseCallCount = 0
    private(set) var resumeCallCount = 0

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
}
