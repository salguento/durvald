import Foundation

extension PlaybackHistoryItem {
    var observedListeningSummary: String? {
        guard let duration = effectiveDurationSeconds else { return nil }
        return "Ouvido: \(DurationFormatter.text(seconds: durationSeconds, context: .retrospective)) · Duração observada: \(DurationFormatter.text(seconds: duration, context: .track))"
    }
    /// Older callers do not assert an origin or an observed media duration.
    init(id: Int64, trackId: Int64, playedAt: String, durationSeconds: UInt64) {
        self.init(sourceId: nil, effectiveDurationSeconds: nil, id: id, trackId: trackId,
                  playedAt: playedAt, durationSeconds: durationSeconds)
    }
}
