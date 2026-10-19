import SwiftUI

/// A stable number/indicator slot that becomes a single-click play control on row hover.
struct TrackPositionPlayButton: View {
    let trackID: Int64
    let title: String
    let number: String
    let isRowHovered: Bool
    var isActiveOverride: Bool? = nil
    var width: CGFloat = 34
    let onPlay: () -> Void
    @FocusState private var isFocused: Bool

    private var showsPlay: Bool { isRowHovered || isFocused }

    var body: some View {
        ZStack {
            AlbumTrackPosition(trackID: trackID, number: number, isActiveOverride: isActiveOverride)
                .opacity(showsPlay ? 0 : 1)
                .accessibilityHidden(showsPlay)
            Button(action: onPlay) {
                Image(systemName: "play.fill")
                    .font(.callout)
                    .foregroundStyle(showsPlay ? Color.primary : Color.clear)
                    .frame(width: width, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($isFocused)
            .accessibilityHidden(false)
            .help("Reproduzir \(title)")
            .accessibilityLabel("Reproduzir \(title)")
            .accessibilityIdentifier("track.\(trackID).positionPlay")
        }
        .frame(width: width, height: 24)
    }

}

/// Keeps artist-row hover observation local to the row instead of the whole page.
struct TrackPlaybackHoverRegion<Content: View>: View {
    @ViewBuilder let content: (Bool) -> Content
    @State private var isHovered = false
    var body: some View {
        content(isHovered)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}
