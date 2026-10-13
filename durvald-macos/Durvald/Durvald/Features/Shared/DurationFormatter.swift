import Foundation

/// Contexts preserve the existing information density of each surface.
enum DurationFormatter {
    enum Context {
        case track, library, retrospective, albumSummary, albumHeader
    }

    static func text(_ duration: Double?, context: Context = .track, unknown: String? = nil,
                     rounding: FloatingPointRoundingRule = .toNearestOrAwayFromZero) -> String {
        guard let duration, duration.isFinite,
              duration.rounded(rounding) < Double(Int.max) else { return unknown ?? "0:00" }
        let seconds = UInt64(max(0, duration.rounded(rounding)))
        if seconds == 0, let unknown { return unknown }
        return text(seconds: seconds, context: context)
    }

    static func text(seconds: UInt64, context: Context) -> String {
        let hours = seconds / 3600
        let minutes = seconds / 60 % 60
        switch context {
        case .track:
            return "\(seconds / 60):\(padded(seconds % 60))"
        case .library, .retrospective:
            return hours > 0
                ? "\(hours):\(padded(minutes)):\(padded(seconds % 60))"
                : "\(minutes):\(padded(seconds % 60))"
        case .albumSummary:
            let minuteText = "\(minutes) \(minutes == 1 ? "minuto" : "minutos")"
            return hours > 0 ? "\(hours) \(hours == 1 ? "hora" : "horas"), \(minuteText)" : minuteText
        case .albumHeader:
            if hours > 0 { return minutes > 0 ? "\(hours) h \(minutes) min" : "\(hours) h" }
            return "\(minutes) min"
        }
    }

    /// Round the aggregate once, preserving subsecond contributions. Invalid
    /// durations contribute nothing, and an unrepresentable total saturates.
    static func totalSeconds<S: Sequence>(_ durations: S) -> Int where S.Element == Double {
        let limit = Double(Int.max)
        let total = durations.reduce(0.0) { total, duration in
            guard duration.isFinite, duration > 0 else { return total }
            return min(limit, total + duration)
        }.rounded()
        return total >= limit ? Int.max : Int(total)
    }

    static func totalSeconds<S: Sequence>(_ durations: S) -> UInt64 where S.Element == UInt64 {
        durations.reduce(0) { total, duration in
            let result = total.addingReportingOverflow(duration)
            return result.overflow ? .max : result.partialValue
        }
    }

    private static func padded(_ value: UInt64) -> String { value < 10 ? "0\(value)" : String(value) }
}
