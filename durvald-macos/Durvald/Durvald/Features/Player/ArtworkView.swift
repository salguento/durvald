import SwiftUI
import AppKit

struct ArtworkView: View {
    let artworkID: String?
    let size: CGFloat

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
        .frame(width: size, height: size)
        .artworkGlassBorder(size: size)
        .task(id: request) {
            guard let artworkID, let core else {
                image = nil
                loadedRequest = request
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
