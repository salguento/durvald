import Foundation
@testable import Durvald

final class FakeDurvaldCore: DurvaldCore {
    var ratingPreferencesResult = RatingScalePreferences(granularity: .halfStars)
    var ratingConversionResult = RatingConversionPreview(tracks: 0, releases: 0, missingTracks: 0, archivedReleases: 0)
    var changeRatingPreferencesHandler: ((RatingGranularity, RatingRounding?) async throws -> RatingPreferenceChange)?
    var artworkBytesHandler: ((String) async throws -> Data?)?
    var tracksPageHandler: ((UInt64, UInt64) async throws -> TrackPage)?
    var releasesPageHandler: ((UInt64, UInt64) async throws -> ReleasePage)?
    var historyRevisionHandler: (() async throws -> UInt64)?
    var historyHandler: (() async throws -> [PlaybackHistoryItem])?
    var tracksByIDsHandler: (([Int64]) async throws -> [Track])?
    var replayPreviewHandler: ((ReplayRequest) async throws -> ReplayPreview)?
    var saveReplayHandler: ((ReplayRequest, String, String, ReplaySaveMode, Bool, String?) async throws -> Playlist)?
    var updateReplayHandler: ((ReplayRequest, ReplaySaveMode, Bool) async throws -> Playlist)?
    var playlistResult: Playlist?
    var createSmartPlaylistHandler: ((String, String, SmartPlaylistDefinition) async throws -> Playlist)?
    var playlistsHandler: (() async throws -> [Playlist])?
    var snapshot: PlaybackSnapshot
    var trackInfoResult: TrackInfo?
    var releaseTrackResults: [Track] = []
    var discographyPages: [UInt64: ArtistDiscographyPage] = [:]
    private(set) var discographyOffsets: [UInt64] = []
    private(set) var artistRefreshRequests: [ArtistRefreshRequest] = []
    var simulatesQueueMutations = false
    var playlistResultsByID: [Int64: [Track]] = [:]
    var playlistTrackResults: [Track] = []
    private(set) var playlistAdditions: [(trackID: Int64, position: UInt64)] = []
    var trackRatingHandler: ((Int64, UInt8?) async throws -> Void)?
    var releaseRatingChanges: [UInt8?] = []
    var trackRatingError: Error?
    var favoriteError: Error?
    private(set) var favoriteChanges: [Bool] = []
    private(set) var trackRatingChanges: [UInt8?] = []
    var onSeek: ((UInt64) -> Void)?
    var playbackHandler: (() async -> PlaybackSnapshot)?
    var seekHandler: ((UInt64) async throws -> Void)?
    var suspendedPlayback: CheckedContinuation<PlaybackSnapshot, Never>?
    var suspendedSeek: CheckedContinuation<Void, Never>?

    private(set) var pauseCallCount = 0
    private(set) var resumeCallCount = 0
    private(set) var shuffleRequests: [Bool] = []
    private(set) var playbackOperations: [String] = []
    private(set) var seekCalls: [UInt64] = []
    private(set) var maximumConcurrentSeeks = 0
    private var activeSeeks = 0


    init(snapshot: PlaybackSnapshot) {
        self.snapshot = snapshot
        super.init(noPointer: .init())
    }

    required init(unsafeFromRawPointer pointer: UnsafeMutableRawPointer) {
        fatalError("FakeDurvaldCore não aceita ponteiros do backend Rust")
    }

    override func ratingPreferences() async throws -> RatingScalePreferences { ratingPreferencesResult }
    override func ratingConversionPreview() async throws -> RatingConversionPreview { ratingConversionResult }
    override func updateRatingPreferences(granularity: RatingGranularity, rounding: RatingRounding?) async throws -> RatingPreferenceChange {
        if let changeRatingPreferencesHandler { return try await changeRatingPreferencesHandler(granularity, rounding) }
        ratingPreferencesResult = RatingScalePreferences(granularity: granularity)
        return RatingPreferenceChange(preferences: ratingPreferencesResult, converted: ratingConversionResult)
    }

    override func artworkBytes(artworkId: String) async throws -> Data? {
        try await artworkBytesHandler?(artworkId)
    }

    override func playbackHistoryRevision() async throws -> UInt64 {
        try await historyRevisionHandler?() ?? 0
    }

    override func playbackHistory() async throws -> [PlaybackHistoryItem] {
        try await historyHandler?() ?? []
    }

    override func tracksByIds(trackIds: [Int64]) async throws -> [Track] {
        try await tracksByIDsHandler?(trackIds) ?? []
    }

    override func tracksPage(pageSize: UInt64, offset: UInt64) async throws -> TrackPage {
        try await tracksPageHandler?(pageSize, offset) ?? TrackPage(items: [], nextOffset: nil)
    }

    override func releasesPage(pageSize: UInt64, offset: UInt64) async throws -> ReleasePage {
        try await releasesPageHandler?(pageSize, offset) ?? ReleasePage(items: [], nextOffset: nil)
    }

    override func artists() async throws -> [Artist] { [] }

    override func trackInfo(trackId: Int64) async throws -> TrackInfo {
        guard let trackInfoResult else { throw NSError(domain: "FakeDurvaldCore.trackInfo", code: 1) }
        return trackInfoResult
    }

    override func refreshArtist(artistId: Int64, request: ArtistRefreshRequest) async throws -> ArtistRefreshResult {
        artistRefreshRequests.append(request)
        return ArtistRefreshResult(artistId: artistId, identityGeneration: 0, sections: [])
    }

    override func artistDiscography(artistId: Int64, pageSize: UInt64, offset: UInt64) async throws -> ArtistDiscographyPage {
        discographyOffsets.append(offset)
        return discographyPages[offset]!
    }

    override func artistReleases(artistId: Int64) async throws -> [Release] { [] }

    override func playback() async -> PlaybackSnapshot {
        if let playbackHandler {
            return await playbackHandler()
        }
        return snapshot
    }

    override func setTrackFavorite(trackId: Int64, favorite: Bool) async throws {
        if let favoriteError { throw favoriteError }
        favoriteChanges.append(favorite)
        if snapshot.currentTrack?.id == trackId {
            snapshot.currentTrack?.isFavorite = favorite
        }
    }

    override func setTrackRatingHalfSteps(trackId: Int64, ratingHalfSteps rating: UInt8?) async throws {
        if let trackRatingHandler { try await trackRatingHandler(trackId, rating) }
        if let trackRatingError { throw trackRatingError }
        trackRatingChanges.append(rating)
        if snapshot.currentTrack?.id == trackId {
            snapshot.currentTrack?.ratingHalfSteps = rating
        }
    }

    override func setReleaseRatingHalfSteps(releaseId: Int64, ratingHalfSteps: UInt8?) async throws {
        releaseRatingChanges.append(ratingHalfSteps)
    }

    override func pause() async throws {
        pauseCallCount += 1
        snapshot.isPaused = true
        snapshot.isPlaying = false
    }

    override func resume() async throws {
        resumeCallCount += 1
        snapshot.isPaused = false
        snapshot.isPlaying = true
    }

    override func releaseTracks(releaseId: Int64) async throws -> [Track] {
        releaseTrackResults
    }

    override func setShuffleEnabled(enabled: Bool) async throws -> PlaybackSnapshot {
        shuffleRequests.append(enabled)
        snapshot.shuffleEnabled = enabled
        return snapshot
    }

    override func clearQueue() async throws {
        playbackOperations.append("clear")
    }

    override func play(trackId: Int64) async throws -> PlaybackSnapshot {
        playbackOperations.append("play:\(trackId)")
        return snapshot
    }

    override func addToQueue(trackId: Int64) async throws {
        playbackOperations.append("enqueue:\(trackId)")
        if simulatesQueueMutations {
            snapshot.queue.append(QueueItem(trackId: trackId, position: UInt64(snapshot.queue.count)))
        }
    }

    override func moveQueueItem(from: UInt64, to: UInt64) async throws {
        let item = snapshot.queue.remove(at: Int(from))
        snapshot.queue.insert(item, at: Int(to))
        for index in snapshot.queue.indices { snapshot.queue[index].position = UInt64(index) }
    }

    override func createPlaylist(name: String, description: String, artworkBase64: String?) async throws -> Playlist {
        guard let playlistResult else { throw NSError(domain: "FakeDurvaldCore.createPlaylist", code: 1) }
        return playlistResult
    }

    override func replayPreview(request: ReplayRequest) async throws -> ReplayPreview {
        guard let replayPreviewHandler else { throw NSError(domain: "FakeDurvaldCore.replayPreview", code: 1) }
        return try await replayPreviewHandler(request)
    }
    override func saveReplay(request: ReplayRequest, name: String, description: String, mode: ReplaySaveMode,
                             closeAutomatically: Bool, artworkBase64: String?) async throws -> Playlist {
        guard let saveReplayHandler else { throw NSError(domain: "FakeDurvaldCore.saveReplay", code: 1) }
        return try await saveReplayHandler(request, name, description, mode, closeAutomatically, artworkBase64)
    }
    override func updateReplay(request: ReplayRequest, mode: ReplaySaveMode, closeAutomatically: Bool) async throws -> Playlist {
        guard let updateReplayHandler else { throw NSError(domain: "FakeDurvaldCore.updateReplay", code: 1) }
        return try await updateReplayHandler(request, mode, closeAutomatically)
    }

    override func createSmartPlaylist(name: String, description: String, definition: SmartPlaylistDefinition) async throws -> Playlist {
        guard let createSmartPlaylistHandler else { throw NSError(domain: "FakeDurvaldCore.createSmartPlaylist", code: 1) }
        return try await createSmartPlaylistHandler(name, description, definition)
    }

    override func playlists() async throws -> [Playlist] {
        try await playlistsHandler?() ?? []
    }

    override func playlist(playlistId: Int64) async throws -> Playlist {
        guard let playlistResult else { throw NSError(domain: "FakeDurvaldCore.playlist", code: 1) }
        return playlistResult
    }

    override func playlistTracks(playlistId: Int64) async throws -> [Track] { playlistResultsByID[playlistId] ?? playlistTrackResults }

    override func addTrackToPlaylist(playlistId: Int64, trackId: Int64, position: UInt64) async throws -> PlaylistTrack {
        playlistAdditions.append((trackId, position))
        return PlaylistTrack(playlistId: playlistId, trackId: trackId, position: position, addedAt: "")
    }

    override func seek(seconds: UInt64) async throws {
        seekCalls.append(seconds)
        activeSeeks += 1
        maximumConcurrentSeeks = max(maximumConcurrentSeeks, activeSeeks)
        defer { activeSeeks -= 1 }
        if let seekHandler {
            try await seekHandler(seconds)
        } else {
            snapshot.positionSeconds = Double(seconds)
        }
        onSeek?(seconds)
    }
}
