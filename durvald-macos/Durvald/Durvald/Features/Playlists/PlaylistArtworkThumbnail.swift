import AppKit
import ImageIO
import SwiftUI

struct PlaylistArtworkThumbnail: View {
    let playlistID: Int64
    let artworkBase64: String?
    let size: CGFloat

    @Environment(\.displayScale) private var displayScale
    @State private var image: NSImage?

    private struct Request: Equatable {
        let playlistID: Int64
        let artworkBase64: String?
        let pixelSize: Int
    }

    private struct DecodedImage: @unchecked Sendable {
        let value: CGImage?
    }

    var body: some View {
        let request = Request(
            playlistID: playlistID,
            artworkBase64: artworkBase64,
            pixelSize: max(1, Int((size * displayScale).rounded(.up)))
        )

        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.secondary.opacity(0.12)
                    Image(systemName: "music.note.list")
                        .font(.system(size: size * 0.46))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .artworkGlassBorder(size: size)
        .task(id: request) {
            guard let artworkBase64 else {
                image = nil
                return
            }

            let decoded = await Task.detached(priority: .userInitiated) {
                guard let data = Data(base64Encoded: artworkBase64),
                      let source = CGImageSourceCreateWithData(data as CFData, nil)
                else {
                    return DecodedImage(value: nil)
                }

                let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: request.pixelSize,
                    kCGImageSourceShouldCacheImmediately: true
                ] as CFDictionary)
                return DecodedImage(value: thumbnail)
            }.value

            guard !Task.isCancelled else { return }
            image = decoded.value.map { NSImage(cgImage: $0, size: .zero) }
        }
        .accessibilityHidden(true)
    }
}
