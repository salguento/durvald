import SwiftUI

struct PlaylistArtworkThumbnail: View {
    let playlistID: Int64
    let artworkBase64: String?
    let size: CGFloat

    @State private var recipe: ReplayArtworkRecipe?

    var body: some View {
        Group {
            if let recipe {
                AnimatedReplayArtwork(draft: recipe.draft, colors: recipe.colors, phase: recipe.phase, artists: recipe.artists)
                    .frame(width: size, height: size)
                    .clipped()
            } else {
                ArtworkImageView(
                    source: artworkBase64.map(ArtworkSource.base64), size: size,
                    fallbackSymbol: "music.note.list", fallbackFont: .system(size: size * 0.46)
                )
            }
        }
        .clipShape(.rect(cornerRadius: min(12, max(4, size * 0.045))))
        .task(id: artworkBase64) {
            recipe = nil
            guard size >= 128, let artworkBase64 else { return }
            let decoded = await Task.detached(priority: .utility) { ReplayArtworkRecipe.read(base64: artworkBase64) }.value
            guard !Task.isCancelled else { return }
            recipe = decoded
        }
    }
}
