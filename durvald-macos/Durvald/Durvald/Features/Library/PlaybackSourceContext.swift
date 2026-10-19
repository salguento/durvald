import SwiftUI

/// The source of a queue occurrence, independent from the current navigation page.
/// Position is the original zero-based position, never the shuffled queue index.
enum PlaybackSourceContext {
    static let library = "library"
    static func release(_ id: Int64) -> String { "release:\(id)" }
    static func playlist(_ id: Int64, position: Int) -> String { "playlist:\(id)#\(position)" }
    static func search(_ query: String) -> String { "search:\(query)" }
    static func artist(_ id: Int64) -> String { "artist:\(id)" }
    static func artistPopular(_ id: Int64) -> String { "artist:\(id):popular" }
    static func replay(_ identity: String) -> String { "replay:\(identity)" }
    static func history(_ id: Int64) -> String { "history:\(id)" }

    static func matches(trackID: Int64, activeTrackID: Int64?, origin: String, activeOrigin: String) -> Bool {
        !origin.isEmpty && origin == activeOrigin && trackID == activeTrackID
    }
}

private struct PlaybackSourceContextKey: EnvironmentKey {
    static let defaultValue = ""
}

extension EnvironmentValues {
    var playbackSourceContext: String {
        get { self[PlaybackSourceContextKey.self] }
        set { self[PlaybackSourceContextKey.self] = newValue }
    }
}
