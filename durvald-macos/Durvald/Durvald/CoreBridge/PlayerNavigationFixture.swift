#if DEBUG
import Foundation

/// An isolated library for previews and navigation UI tests; never opens audio or disk data.
@MainActor
enum PlayerNavigationFixture {
    static func makeStore(longMetadata: Bool = false, scrollable: Bool = false, livePlayback: Bool = false, autoAdvance: Bool = false) -> DurvaldCoreStore {
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
        var tracks = scrollable ? (0..<240).map { index in
            var item = track
            item.id = Int64(100 + index)
            item.title = "Faixa de teste \(index + 1) — Biblioteca para rolagem"
            return item
        } : [track]
        if autoAdvance {
            var first = track
            first.durationSeconds = 14
            var second = track
            second.id = 101
            second.trackNumber = 2
            second.title = "Segunda faixa de teste"
            second.artist = "Outro artista de teste"
            tracks = [first, second]
        }
        let releases = scrollable ? (0..<120).map { index in
            var item = album
            item.id = Int64(42 + index)
            item.title = "Álbum \(index + 1)"
            return item
        } : [sameTitleAlbum, album]
        let snapshot = PlaybackSnapshot(
                currentTrack: tracks[0], positionSeconds: autoAdvance ? 0 : 30,
                durationSeconds: tracks[0].durationSeconds, volume: 0.5,
                isPlaying: livePlayback, isPaused: !livePlayback, queue: scrollable ? tracks.enumerated().map { QueueItem(trackId: $0.element.id, position: UInt64($0.offset)) } : [], queuePosition: 0,
                shuffleEnabled: false, repeatMode: .none
            )
        return DurvaldCoreStore(
            core: livePlayback ? PlaybackClockFixtureCore(snapshot: snapshot, tracks: tracks, autoAdvance: autoAdvance) : nil,
            playback: snapshot,
            tracks: tracks,
            // Same-name records come first to catch accidental matching by text.
            releases: releases,
            artists: [sameNameArtist, artist, albumArtist]
        )
    }
}

/// Exercises the real polling loop without opening audio devices or a database.
private final class PlaybackClockFixtureCore: DurvaldCore, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: PlaybackSnapshot
    private let tracks: [Track]
    private let autoAdvance: Bool
    private var lastUpdate = ContinuousClock.now

    init(snapshot: PlaybackSnapshot, tracks: [Track], autoAdvance: Bool) {
        self.snapshot = snapshot
        self.tracks = tracks
        self.autoAdvance = autoAdvance
        super.init(noPointer: .init())
    }

    required init(unsafeFromRawPointer pointer: UnsafeMutableRawPointer) {
        fatalError("PlaybackClockFixtureCore has no Rust pointer")
    }

    private func updateClock() {
        let now = ContinuousClock.now
        let elapsed = lastUpdate.duration(to: now).components
        if snapshot.isPlaying {
            snapshot.positionSeconds += Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            if autoAdvance, let duration = snapshot.durationSeconds,
               snapshot.positionSeconds >= duration,
               let currentIndex = tracks.firstIndex(where: { $0.id == snapshot.currentTrack?.id }),
               tracks.indices.contains(currentIndex + 1) {
                let next = tracks[currentIndex + 1]
                snapshot.currentTrack = next
                snapshot.durationSeconds = next.durationSeconds
                snapshot.positionSeconds -= duration
                snapshot.queue = [QueueItem(trackId: next.id, position: 0)]
            }
        }
        lastUpdate = now
    }

    override func playback() async -> PlaybackSnapshot {
        lock.withLock {
            updateClock()
            return snapshot
        }
    }

    override func releaseTracks(releaseId: Int64) throws -> [Track] {
        lock.withLock {
            tracks.filter { $0.releaseId == releaseId }
        }
    }

    override func pause() async throws {
        lock.withLock {
            updateClock()
            snapshot.isPaused = true
            snapshot.isPlaying = false
        }
    }

    override func resume() async throws {
        lock.withLock {
            updateClock()
            snapshot.isPaused = false
            snapshot.isPlaying = true
        }
    }

    override func seek(seconds: UInt64) async throws {
        lock.withLock {
            updateClock()
            snapshot.positionSeconds = Double(seconds)
        }
    }
}
#endif
