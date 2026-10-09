import SwiftUI

private struct ActiveTrackTitle: ViewModifier {
    @Environment(DurvaldCoreStore.self) private var store
    let trackID: Int64
    var activeOverride: Bool? = nil
    var inactiveColor: Color? = nil

    func body(content: Content) -> some View {
        // Observe track changes here, without subscribing the list to playback ticks.
        if activeOverride ?? (store.activeTrackID == trackID) {
            content.foregroundStyle(Color.accentColor)
        } else if let inactiveColor {
            content.foregroundStyle(inactiveColor)
        } else {
            // Preserve the title's inherited style, including list selection styling.
            content
        }
    }
}

extension View {
    func activeTrackTitle(trackID: Int64, activeOverride: Bool? = nil, inactiveColor: Color? = nil) -> some View {
        modifier(ActiveTrackTitle(trackID: trackID, activeOverride: activeOverride, inactiveColor: inactiveColor))
    }
}
