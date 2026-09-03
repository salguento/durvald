import SwiftUI

struct AlbumTrackPosition: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let trackID: Int64
    let number: String

    var body: some View {
        Group {
            if store.activeTrackID == trackID && !store.isPlaybackPaused {
                // Keep the number's layout slot and center the wider symbol on it.
                Text(number)
                    .monospacedDigit()
                    .hidden()
                    .overlay {
                        PlaybackActivityIndicator(
                            isAnimating: !reduceMotion
                        )
                            .frame(width: 14, height: 14)
                            .allowsHitTesting(false)
                            .accessibilityLabel("Em reprodução")
                            .accessibilityIdentifier("album.track.\(trackID).playbackIndicator")
                    }
            } else {
                Text(number)
                    .foregroundStyle(store.activeTrackID == trackID ? Color.accentColor : Color.secondary)
                    .monospacedDigit()
                    .accessibilityIdentifier("album.track.\(trackID).number")
            }
        }
        .font(.callout)
        .frame(width: 34, alignment: .trailing)
    }
}
