import SwiftUI
import AppKit

struct ArtworkView: View {
    let artworkID: String?
    let size: CGFloat
    var aspectRatio: CGFloat = 1
    var alignment: Alignment = .center
    var showsBorder = true
    var onLowerRegionColorLoaded: ((NSColor?) -> Void)? = nil

    @Environment(DurvaldCoreStore.self) private var store
    @Environment(\.displayScale) private var displayScale
    @State private var image: NSImage?
    @State private var loadedRequest: Request?

    private struct Request: Equatable {
        let artworkID: String?
        let pixelSize: Int
        let coreID: ObjectIdentifier?
    }

    var body: some View {
        let core = store.core
        let request = Request(
            artworkID: artworkID,
            pixelSize: ArtworkRepository.pixelSize(for: size, scale: displayScale),
            coreID: core.map(ObjectIdentifier.init)
        )
        let cached = artworkID.flatMap { id in
            core.flatMap { ArtworkRepository.shared.cachedImage(for: id, pixelSize: request.pixelSize, using: $0) }
        }
        let displayedImage = loadedRequest == request ? image : cached

        Group {
            if let displayedImage {
                Image(nsImage: displayedImage)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.secondary.opacity(0.12)
                    Image(systemName: "music.note")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size / aspectRatio, alignment: alignment)
        .clipped()
        .modifier(ArtworkBorderModifier(size: size, isEnabled: showsBorder))
        .task(id: request) {
            guard !Task.isCancelled else { return }
            guard let artworkID, let core else {
                image = nil
                loadedRequest = request
                onLowerRegionColorLoaded?(nil)
                return
            }

            let loaded = try? await ArtworkRepository.shared.image(
                for: artworkID,
                pixelSize: request.pixelSize,
                using: core
            )
            // A recycled/disappearing cell must not receive an older cover.
            guard !Task.isCancelled else { return }
            image = loaded
            loadedRequest = request
            if let onLowerRegionColorLoaded {
                let cgImage = loaded?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                let sample: ArtworkColorRepository.Sample?
                if let cgImage {
                    sample = try? await ArtworkColorRepository.shared.lowerRegionColor(
                        for: .init(coreID: ObjectIdentifier(core), artworkID: artworkID, pixelSize: request.pixelSize),
                        image: cgImage)
                } else {
                    sample = nil
                }
                guard !Task.isCancelled else { return }
                onLowerRegionColorLoaded(sample?.color)
            }
        }
        .accessibilityHidden(true)
    }
}

extension View {
    func artworkGlassBorder(size: CGFloat) -> some View {
        let cornerRadius = min(12, max(4, size * 0.045))
        let borderWidth: CGFloat = size < 80 ? 0.5 : 0.75

        return clipShape(.rect(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(size < 80 ? 0.14 : 0.18),
                        lineWidth: borderWidth
                    )
            }
    }
}

private struct ArtworkBorderModifier: ViewModifier {
    let size: CGFloat
    let isEnabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.artworkGlassBorder(size: size)
        } else {
            content
        }
    }
}
