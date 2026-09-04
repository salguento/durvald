import SwiftUI

extension View {
    func playTrackOnDoubleClick(_ action: @escaping () -> Void) -> some View {
        contentShape(Rectangle())
            .onTapGesture(count: 2, perform: action)
    }
}
