import SwiftUI

struct CollectionPlaybackControls: View {
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.colorScheme) private var colorScheme

    let isEnabled: Bool
    let onPlay: () -> Void
    let onShuffle: () -> Void

    private var backgroundOpacity: Double {
        if colorScheme == .dark {
            return appearsActive ? 0.08 : 0.10
        }
        return appearsActive ? 0.10 : 0.06
    }

    var body: some View {
        HStack(spacing: 10) {
            control("Play", systemImage: "play.fill", action: onPlay)
            control("Shuffle", systemImage: "shuffle", action: onShuffle)
        }
    }

    private func control(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.body.weight(.medium))
                .foregroundStyle(Color.accentColor.opacity(appearsActive ? 1 : 0.63))
                .padding(.horizontal, 16)
                .frame(height: 34)
                .background {
                    Capsule()
                        .fill(Color.primary.opacity(backgroundOpacity))
                }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityIdentifier("collection.\(title.lowercased())")
    }
}
