import SwiftUI
import AppKit

struct ArtworkView: View {
    let artworkID: String?
    let size: CGFloat
    var aspectRatio: CGFloat = 1
    var alignment: Alignment = .center
    var showsBorder = true
    var onLowerRegionColorLoaded: ((NSColor?) -> Void)? = nil

    var body: some View {
        ArtworkImageView(
            source: artworkID.map(ArtworkSource.managed), size: size,
            aspectRatio: aspectRatio, alignment: alignment, showsBorder: showsBorder,
            onLowerRegionColorLoaded: onLowerRegionColorLoaded
        )
    }
}

/// One request/publication policy for managed covers and inline playlist images.
struct ArtworkImageView: View {
    let source: ArtworkSource?
    let size: CGFloat
    var aspectRatio: CGFloat = 1
    var alignment: Alignment = .center
    var showsBorder = true
    var fallbackSymbol = "music.note"
    var fallbackFont: Font? = nil
    var onLowerRegionColorLoaded: ((NSColor?) -> Void)? = nil

    @Environment(DurvaldCoreStore.self) private var store: DurvaldCoreStore?
    @Environment(\.displayScale) private var displayScale
    @State private var image: NSImage?
    @State private var loadedRequest: Request?

    private struct Request: Equatable {
        let source: ArtworkSource?
        let pixelSize: Int
        let coreID: ObjectIdentifier?
    }

    private var managedArtworkID: String? {
        if case .managed(let id) = source { return id }
        return nil
    }

    var body: some View {
        let core = store?.core
        let request = Request(
            source: source,
            pixelSize: ArtworkRepository.pixelSize(for: size, scale: displayScale),
            coreID: managedArtworkID == nil ? nil : core.map(ObjectIdentifier.init)
        )
        let cached = managedArtworkID.flatMap { id in
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
                    Image(systemName: fallbackSymbol)
                        .font(fallbackFont)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size / aspectRatio, alignment: alignment)
        .clipped()
        .modifier(ArtworkBorderModifier(size: size, isEnabled: showsBorder))
        .task(id: request) {
            guard !Task.isCancelled else { return }
            guard let source else {
                image = nil
                loadedRequest = request
                onLowerRegionColorLoaded?(nil)
                return
            }

            let loaded = try? await ArtworkRepository.shared.image(
                for: source,
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
                if let cgImage, let artworkID = managedArtworkID, let core {
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
