@testable import Durvald

enum Fixtures {
    static var track: Track {
        track(id: 1, trackNumber: 1, discNumber: 1)
    }

    static func track(
        id: Int64,
        trackNumber: UInt8,
        discNumber: UInt8
    ) -> Track {
        Track(
            id: id,
            title: "Faixa \(id)",
            artist: "Artista",
            artistId: 1,
            release: "Álbum",
            releaseId: 1,
            trackNumber: trackNumber,
            discNumber: discNumber,
            durationSeconds: 180,
            filePath: "/tmp/durvald-test.mp3",
            artworkId: nil,
            bitrate: nil,
            sampleRate: nil,
            playCount: 0,
            lastPlayed: nil,
            rating: nil,
            isFavorite: false,
            isHidden: false,
            suggestLess: false
        )
    }

    static var playingSnapshot: PlaybackSnapshot {
        PlaybackSnapshot(
            currentTrack: track,
            positionSeconds: 10,
            durationSeconds: 180,
            volume: 0.5,
            isPlaying: true,
            isPaused: false,
            queue: [],
            queuePosition: 0,
            shuffleEnabled: false,
            repeatMode: .none
        )
    }
}
