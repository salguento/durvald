import SwiftUI
import AppKit

struct ArtworkView: View {
    let artworkID: String?
    let size: CGFloat

    @EnvironmentObject private var store: DurvaldCoreStore
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
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
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: artworkID) {
            image = nil

            guard
                let artworkID,
                let core = store.core
            else {
                image = nil
                return
            }

            image = try? await ArtworkRepository.shared.image(
                for: artworkID,
                using: core
            )
        }
        .accessibilityHidden(true)
    }
}
