import AppKit
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

    var body: some View {
        let request = Request(
            playlistID: playlistID,
            artworkBase64: artworkBase64,
            pixelSize: ArtworkRepository.pixelSize(for: size, scale: displayScale)
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
            image = nil
            guard let artworkBase64 else {
                image = nil
                return
            }

            do {
                let loaded = try await ArtworkRepository.shared.playlistImage(base64: artworkBase64, pixelSize: request.pixelSize)
                guard !Task.isCancelled else { return }
                image = loaded
            } catch {
                guard !Task.isCancelled else { return }
                image = nil
            }
        }
        .accessibilityHidden(true)
    }
}
