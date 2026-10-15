import SwiftUI

struct CollectionPlaybackControls: View {
    enum Presentation {
        case separate
        case groupedCompactShuffle
        case prominentPlay
    }

    @Environment(DurvaldCoreStore.self) private var store
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.colorScheme) private var colorScheme

    let isEnabled: Bool
    let presentation: Presentation
    let controlHeight: CGFloat
    let isFavorite: Bool?
    let onToggleFavorite: (() -> Void)?
    let collection: PlaybackCollection
    let iconControlWidth: CGFloat

    init(
        isEnabled: Bool,
        presentation: Presentation = .separate,
        controlHeight: CGFloat = 34,
        isFavorite: Bool? = nil,
        onToggleFavorite: (() -> Void)? = nil,
        collection: PlaybackCollection,
        iconControlWidth: CGFloat = 38
    ) {
        self.isEnabled = isEnabled
        self.presentation = presentation
        self.controlHeight = controlHeight
        self.isFavorite = isFavorite
        self.onToggleFavorite = onToggleFavorite
        self.collection = collection
        self.iconControlWidth = iconControlWidth
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
                control("Play", systemImage: "play.fill", action: { perform(.play) })
                control("Shuffle", systemImage: "shuffle", action: { perform(.shuffle) })
            }

        case .prominentPlay:
            HStack(spacing: 8) {
                Button { perform(.play) } label: {
                    Label("Reproduzir", systemImage: "play.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: controlHeight)
                        .background(Color.accentColor, in: .capsule)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("collection.play")

                Button { perform(.shuffle) } label: {
                    Image(systemName: "shuffle")
                        .frame(width: iconControlWidth, height: controlHeight)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .help("Reproduzir aleatoriamente")
                .accessibilityLabel("Reproduzir aleatoriamente")
                .accessibilityIdentifier("collection.shuffle")
            }
            .disabled(!isEnabled)

        case .groupedCompactShuffle:
            HStack(spacing: 10) {
                HStack(spacing: 0) {
                    Button(action: { perform(.play) }) {
                        Label("Play", systemImage: "play.fill")
                            .padding(.horizontal, 16)
                            .frame(height: controlHeight)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("collection.play")

                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 1, height: 18)
                        .accessibilityHidden(true)

                    Button(action: { perform(.shuffle) }) {
                        Image(systemName: "shuffle")
                            .padding(.horizontal, 14)
                            .frame(height: controlHeight)
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
                            .frame(width: controlHeight, height: controlHeight)
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

    private func perform(_ action: PlaybackCollection.Action) {
        guard isEnabled else { return }
        Task { await collection.perform(action, using: store) }
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
                .frame(height: controlHeight)
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

/// Shared circular actions for collection headers; size scales the symbols too.
struct CollectionHeaderPlayLabel: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "play.fill")
            .font(.system(size: size * 28 / 72, weight: .semibold))
            .foregroundStyle(.black.opacity(0.85))
            .offset(x: size / 36)
            .frame(width: size, height: size)
            .background(.white, in: .circle)
            .contentShape(.circle)
    }
}

struct CollectionHeaderActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    let size: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.375, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .frame(width: size, height: size)
            .contentShape(.circle)
            .background(.black.opacity(0.3), in: .circle)
            .glassEffect(.regular.tint(.black.opacity(0.2)).interactive(), in: .circle)
            .overlay { Circle().strokeBorder(.white.opacity(0.08), lineWidth: 1) }
            .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.65 : 1)
    }
}
