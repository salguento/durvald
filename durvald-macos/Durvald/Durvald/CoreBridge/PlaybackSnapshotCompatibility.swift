import Foundation

extension PlaybackSnapshot {
    init(currentTrack: Track?, positionSeconds: Double, durationSeconds: Double?, volume: Float,
         isPlaying: Bool, isPaused: Bool, queue: [QueueItem], queuePosition: UInt64,
         shuffleEnabled: Bool, repeatMode: RepeatMode) {
        self.init(sourceContext: "", currentTrack: currentTrack, positionSeconds: positionSeconds,
                  durationSeconds: durationSeconds, volume: volume, isPlaying: isPlaying,
                  isPaused: isPaused, queue: queue, queuePosition: queuePosition,
                  shuffleEnabled: shuffleEnabled, repeatMode: repeatMode)
    }
}
