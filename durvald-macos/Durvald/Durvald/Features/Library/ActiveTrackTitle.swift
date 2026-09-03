import SwiftUI

private struct ActiveTrackTitle: ViewModifier {
    @Environment(DurvaldCoreStore.self) private var store
    let trackID: Int64

    func body(content: Content) -> some View {
        // Observe track changes here, without subscribing the list to playback ticks.
        if store.activeTrackID == trackID {
            content.foregroundStyle(Color.accentColor)
        } else {
            // Preserve the title's inherited style, including list selection styling.
            content
        }
    }
}

extension View {
    func activeTrackTitle(trackID: Int64) -> some View {
        modifier(ActiveTrackTitle(trackID: trackID))
    }
}
