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
            artworkId: nil, bitrate: nil, sampleRate: nil, bitDepth: nil, playCount: 0, lastPlayed: nil,
            rating: nil, isFavorite: false, isHidden: false, suggestLess: false
        )
        let album = Release(
            id: 42, title: track.release, artist: albumArtist.name, artistId: albumArtist.id,
            releaseDate: nil, genres: [], composers: [], producers: [],
            totalTracks: 1, totalDiscs: 1, durationSeconds: 180,
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
        if ProcessInfo.processInfo.arguments.contains("--collection-play-fixture") {
            tracks = (0..<4).map { index in
                var item = track
                item.id = Int64(100 + index)
                item.trackNumber = UInt8(index + 1)
                item.title = "Faixa de teste \(index + 1)"
                return item
            }
        }
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
                sourceContext: ProcessInfo.processInfo.arguments.contains("--playlist-origin-fixture")
                    ? PlaybackSourceContext.playlist(7, position: 0) : PlaybackSourceContext.release(42),
                currentTrack: tracks[0], positionSeconds: autoAdvance ? 0 : 30,
                durationSeconds: tracks[0].durationSeconds, volume: 0.5,
                isPlaying: livePlayback, isPaused: !livePlayback, queue: scrollable ? tracks.enumerated().map { QueueItem(trackId: $0.element.id, position: UInt64($0.offset)) } : [], queuePosition: 0,
                shuffleEnabled: false, repeatMode: .none
            )
        var history = scrollable ? tracks.enumerated().map { index, track in
            PlaybackHistoryItem(id: Int64(index + 1), trackId: track.id,
                                playedAt: Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted)), durationSeconds: 180)
        } : []
        if ProcessInfo.processInfo.arguments.contains("--retrospective-date-fixture") {
            history += [
                PlaybackHistoryItem(id: 10_001, trackId: tracks[0].id, playedAt: "2024-02-29T12:00:00Z", durationSeconds: 180),
                PlaybackHistoryItem(id: 10_002, trackId: tracks[0].id, playedAt: "2025-12-15T12:00:00Z", durationSeconds: 180)
            ]
        }
        let store = DurvaldCoreStore(
            core: (livePlayback || ProcessInfo.processInfo.arguments.contains("--home-library-fixture")) ? PlaybackClockFixtureCore(
                snapshot: snapshot,
                tracks: tracks,
                releases: releases,
                autoAdvance: autoAdvance
            ) : nil,
            playback: snapshot,
            tracks: tracks,
            // Same-name records come first to catch accidental matching by text.
            releases: releases,
            artists: [sameNameArtist, artist, albumArtist],
            history: history
        )
        let exampleTracks = Array(tracks.prefix(10))
        store.replayPreviewFixture = { request in
            let now = Int64(Date().timeIntervalSince1970)
            let current = request.startAt <= now && now < request.endAt
            return ReplayPreview(request: request, tracks: current && scrollable ? exampleTracks : [],
                eligibleCount: current && scrollable ? 10 : 1, minimum: 5, standard: 10, maximum: 25,
                available: current && scrollable, isCurrent: current, savedPlaylist: nil)
        }
        if ProcessInfo.processInfo.arguments.contains("--collection-play-fixture") {
            Task { try? await store.reloadPlaylists() }
        }
        return store
    }
}

/// Exercises the real polling loop without opening audio devices or a database.
private final class PlaybackClockFixtureCore: DurvaldCore, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: PlaybackSnapshot
    private let tracks: [Track]
    private let releases: [Release]
    private let autoAdvance: Bool
    private var lastUpdate = ContinuousClock.now

    init(snapshot: PlaybackSnapshot, tracks: [Track], releases: [Release], autoAdvance: Bool) {
        self.snapshot = snapshot
        self.tracks = tracks
        self.releases = releases
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

    override func playCollection(trackIds: [Int64], sourceContexts: [String], startingPosition: UInt64?, shuffleEnabled: Bool?) async throws -> PlaybackSnapshot {
        try lock.withLock {
            let start = Int(startingPosition ?? 0)
            guard trackIds.indices.contains(start), sourceContexts.count == trackIds.count,
                  let track = tracks.first(where: { $0.id == trackIds[start] }) else {
                throw CoreError.InvalidInput(message: "Invalid fixture collection")
            }
            snapshot.currentTrack = track
            snapshot.sourceContext = sourceContexts[start]
            snapshot.positionSeconds = 0
            snapshot.durationSeconds = track.durationSeconds
            snapshot.isPlaying = true
            snapshot.isPaused = false
            snapshot.shuffleEnabled = shuffleEnabled ?? snapshot.shuffleEnabled
            let remaining = snapshot.shuffleEnabled ? trackIds.indices.filter { $0 != start }.shuffled()
                : Array(trackIds.indices.dropFirst(start + 1))
            snapshot.queue = ([trackIds[start]] + remaining.map { trackIds[$0] }).enumerated().map {
                QueueItem(trackId: $0.element, position: UInt64($0.offset))
            }
            lastUpdate = .now
            return snapshot
        }
    }

    override func playbackHistory() async throws -> [PlaybackHistoryItem] { [] }

    override func playbackHistoryRevision() async throws -> UInt64 { 0 }

    override func homeLibrary(limit: UInt64) async throws -> HomeLibrary {
        HomeLibrary(recentlyPlayed: Array(releases.prefix(Int(limit))),
                    recentlyAdded: Array(releases.reversed().prefix(Int(limit))))
    }

    override func playlists() async throws -> [Playlist] {
        guard ProcessInfo.processInfo.arguments.contains("--collection-play-fixture") else { return [] }
        return [Playlist(id: 7, name: "Playlist de teste", description: "", artworkId: nil,
                         isFavorite: false, suggestLess: false, trackCount: UInt64(tracks.count),
                         createdAt: "2026-10-19", updatedAt: "2026-10-19", isSmart: false, smartDefinition: nil)]
    }

    override func playlistTracks(playlistId: Int64) async throws -> [Track] {
        tracks
    }

    override func releaseTracks(releaseId: Int64) async throws -> [Track] {
        lock.withLock {
            tracks.filter { $0.releaseId == releaseId }
        }
    }

    override func artist(artistId: Int64) async throws -> Artist {
        Artist(id: artistId, name: tracks.first(where: { $0.artistId == artistId })?.artist ?? "Artista de teste")
    }

    override func release(releaseId: Int64) async throws -> Release {
        guard let release = releases.first(where: { $0.id == releaseId }) else {
            throw CoreError.NotFound(message: "Fixture release not found")
        }
        return release
    }

    override func tracksByIds(trackIds: [Int64]) async throws -> [Track] {
        let ids = Set(trackIds)
        return tracks.filter { ids.contains($0.id) }
    }

    override func artistTracks(artistId: Int64) async throws -> [Track] {
        lock.withLock {
            tracks.filter { $0.artistId == artistId }
        }
    }

    override func artistReleases(artistId: Int64) async throws -> [Release] {
        lock.withLock {
            releases.filter { $0.artistId == artistId }
        }
    }

    override func artistIdentity(artistId: Int64) async throws -> ArtistIdentity {
        ArtistIdentity(artistId: artistId, status: .unresolved, musicbrainzId: nil, generation: 0,
                       origin: nil, confirmedMusicbrainzId: nil, conflictingTags: false)
    }

    override func artistDetails(artistId: Int64, language: String) async throws -> ArtistDetails {
        let name = tracks.first(where: { $0.artistId == artistId })?.artist ?? "Artista de teste"
        return ArtistDetails(similarArtists: [], similarArtistsFetchedAt: nil,
            artist: Artist(id: artistId, name: name), identityStatus: .unresolved, musicbrainzId: nil,
            identityGeneration: 0, requestedLanguage: language, sources: [], portrait: nil, overrides: [])
    }

    override func artistDiscography(
        artistId: Int64,
        pageSize: UInt64,
        offset: UInt64
    ) async throws -> ArtistDiscographyPage {
        ArtistDiscographyPage(artistId: artistId, identityGeneration: 0, catalogGeneration: 0,
            items: [], nextOffset: nil, remoteExhausted: true, remoteNextOffset: nil,
            remoteTotal: 0, lastSuccessAt: nil, stale: false)
    }

    override func artistPopularTracks(artistId: Int64) async throws -> ArtistPopularTracks? {
        nil
    }

    override func track(trackId: Int64) async throws -> Track {
        guard let track = lock.withLock({ tracks.first(where: { $0.id == trackId }) }) else {
            throw CoreError.NotFound(message: "Fixture track \(trackId) not found")
        }
        return track
    }

    override func syncArtistReleaseMetadata(artistId: Int64) async throws -> [Release] {
        // AlbumView performs this local synchronization when it opens. The UI
        // fixture has no Rust pointer, so keep the generated UniFFI method from
        // trying to clone the deliberately pointerless fake core.
        []
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
