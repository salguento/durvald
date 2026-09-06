import SwiftUI

struct CollectionPlaybackControls: View {
    enum Presentation {
        case separate
        case groupedCompactShuffle
    }

    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.colorScheme) private var colorScheme

    let isEnabled: Bool
    let presentation: Presentation
    let isFavorite: Bool?
    let onToggleFavorite: (() -> Void)?
    let onPlay: () -> Void
    let onShuffle: () -> Void

    init(
        isEnabled: Bool,
        presentation: Presentation = .separate,
        isFavorite: Bool? = nil,
        onToggleFavorite: (() -> Void)? = nil,
        onPlay: @escaping () -> Void,
        onShuffle: @escaping () -> Void
    ) {
        self.isEnabled = isEnabled
        self.presentation = presentation
        self.isFavorite = isFavorite
        self.onToggleFavorite = onToggleFavorite
        self.onPlay = onPlay
        self.onShuffle = onShuffle
    }

    private var backgroundOpacity: Double {
        if colorScheme == .dark {
            return appearsActive ? 0.08 : 0.10
        }
        return appearsActive ? 0.10 : 0.06
    }

    @ViewBuilder
    var body: some View {
        switch presentation {
        case .separate:
            HStack(spacing: 10) {
                control("Play", systemImage: "play.fill", action: onPlay)
                control("Shuffle", systemImage: "shuffle", action: onShuffle)
            }

        case .groupedCompactShuffle:
            HStack(spacing: 10) {
                HStack(spacing: 0) {
                    Button(action: onPlay) {
                        Label("Play", systemImage: "play.fill")
                            .padding(.horizontal, 16)
                            .frame(height: 34)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("collection.play")

                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 1, height: 18)
                        .accessibilityHidden(true)

                    Button(action: onShuffle) {
                        Image(systemName: "shuffle")
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Shuffle")
                    .accessibilityIdentifier("collection.shuffle")
                }
                .background {
                    Capsule()
                        .fill(Color.primary.opacity(backgroundOpacity))
                }
                .contentShape(.capsule)
                .disabled(!isEnabled)

                if let isFavorite, let onToggleFavorite {
                    Button(action: onToggleFavorite) {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .frame(width: 34, height: 34)
                            .background {
                                Circle()
                                    .fill(Color.primary.opacity(backgroundOpacity))
                            }
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .help(isFavorite ? "Desfavoritar álbum" : "Favoritar álbum")
                    .accessibilityLabel(isFavorite ? "Desfavoritar álbum" : "Favoritar álbum")
                    .accessibilityIdentifier("collection.favorite")
                }
            }
            .font(.body.weight(.medium))
            .foregroundStyle(Color.accentColor.opacity(appearsActive ? 1 : 0.63))
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
