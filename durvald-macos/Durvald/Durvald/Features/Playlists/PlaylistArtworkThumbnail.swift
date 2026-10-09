import SwiftUI

struct PlaylistArtworkThumbnail: View {
    let playlistID: Int64
    let artworkBase64: String?
    let size: CGFloat

    var body: some View {
        ArtworkImageView(
            source: artworkBase64.map(ArtworkSource.base64), size: size,
            fallbackSymbol: "music.note.list", fallbackFont: .system(size: size * 0.46)
        )
    }
}
