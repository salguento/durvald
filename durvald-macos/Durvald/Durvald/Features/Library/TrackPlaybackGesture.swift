import SwiftUI

extension View {
    func playTrackOnDoubleClick(_ action: @escaping () -> Void) -> some View {
        contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture(count: 2)
                    .onEnded { _ in action() }
            )
    }
}
