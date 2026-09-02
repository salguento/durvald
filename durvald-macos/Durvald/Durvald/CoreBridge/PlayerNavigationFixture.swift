#if DEBUG
import Foundation

/// An isolated library for previews and navigation UI tests; never opens audio or disk data.
@MainActor
enum PlayerNavigationFixture {
    static func makeStore(longMetadata: Bool = false) -> DurvaldCoreStore {
        let artist = Artist(
            id: 7,
            name: longMetadata ? "Artista de teste com nome extenso e convidados especiais" : "Artista de teste"
        )
        let albumArtist = Artist(id: 9, name: "Vários artistas")
        let track = Track(
            id: 100,
            title: longMetadata ? "Faixa de teste com título extenso — gravação ao vivo e versão completa" : "Faixa de teste",
            artist: artist.name, artistId: artist.id,
            release: "Álbum de teste", releaseId: 42, trackNumber: 1, discNumber: 1,
            durationSeconds: 180, filePath: "/unused/navigation-fixture.mp3",
            artworkId: nil, bitrate: nil, sampleRate: nil, playCount: 0, lastPlayed: nil,
            rating: nil, isFavorite: false, isHidden: false, suggestLess: false
        )
        let album = Release(
            id: 42, title: track.release, artist: albumArtist.name, artistId: albumArtist.id,
            releaseDate: nil, totalTracks: 1, totalDiscs: 1, durationSeconds: 180,
            artworkId: nil, isFavorite: false, isHidden: false, suggestLess: false, rating: nil
        )
        var sameTitleAlbum = album
        sameTitleAlbum.id = 43
        sameTitleAlbum.artistId = 8
        let sameNameArtist = Artist(id: 8, name: artist.name)
        return DurvaldCoreStore(
            playback: PlaybackSnapshot(
                currentTrack: track, positionSeconds: 30, durationSeconds: 180, volume: 0.5,
                isPlaying: false, isPaused: true, queue: [], queuePosition: 0,
                shuffleEnabled: false, repeatMode: .none
            ),
            tracks: [track],
            // Same-name records come first to catch accidental matching by text.
            releases: [sameTitleAlbum, album],
            artists: [sameNameArtist, artist, albumArtist]
        )
    }
}
#endif
