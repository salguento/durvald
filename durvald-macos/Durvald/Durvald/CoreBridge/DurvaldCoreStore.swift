import Foundation
import SwiftUI
import Observation
// import DurvaldCoreFFI // substitua pelo módulo efetivamente gerado

@MainActor
@Observable
final class DurvaldCoreStore {
    #if DEBUG
    @ObservationIgnored var replayPreviewFixture: ((ReplayRequest) -> ReplayPreview)?
    @ObservationIgnored var catalogDetailFixture: (() -> any CatalogDetailLoading)?
    @ObservationIgnored var catalogSearchFixture: (() -> any CatalogSearchLoading)?
    #endif
    @ObservationIgnored private var retrospectiveHistoryRevision: UInt64?
    @ObservationIgnored private var isRefreshingRetrospectivePlaylists = false
    private var savedRetrospectivePlaylistIDs: [String: Int64] = [:]
    @ObservationIgnored private var retrospectivePlaylistSaves: [String: Task<Playlist?, Never>] = [:]

    // Observation tracks only the properties each view reads. The playback clock
    // must not invalidate library lists, the sidebar or every artwork cell.
    private(set) var playback: PlaybackSnapshot? {
        didSet {
            if let value = playback?.volume, value > 0 { volumeBeforeMute = Double(value) }
            let playbackActivityChanged = oldValue?.isPlaying != playback?.isPlaying
            let origin = playback?.sourceContext ?? ""
            if activeSourceContext != origin { activeSourceContext = origin }
            let trackID = playback?.currentTrack?.id
            if activeTrackID != trackID { activeTrackID = trackID }
            let updatedQueue = playback?.queue ?? []
            if queue != updatedQueue { queue = updatedQueue }
            let paused = playback?.isPaused ?? true
            if isPlaybackPaused != paused { isPlaybackPaused = paused }
            let playing = playback?.isPlaying ?? false
            if isPlaybackPlaying != playing { isPlaybackPlaying = playing }
            if playbackActivityChanged { startPlaybackPolling() }
            nowPlaying?.update(playback, core: core)
        }
    }
    private(set) var activeSourceContext = ""
    private(set) var activeTrackID: Int64?
    private(set) var queueRevision: UInt64 = 0
    private(set) var queue: [QueueItem] = [] {
        didSet { queueRevision &+= 1 }
    }
    private(set) var isPlaybackPaused = true
    private(set) var isPlaybackPlaying = false
    private(set) var isSeeking = false
    private(set) var scanProgress: ScanProgress?
    private(set) var isScanningLibrary = false
    private(set) var lastScanResult: ScanResult?
    private(set) var tracksRevision: UInt64 = 0
    private(set) var tracks: [Track] = [] {
        didSet {
            loadedTracksByID = firstRecordIndex(tracks, key: { $0.id })
            tracksRevision &+= 1
        }
    }
    @ObservationIgnored private var loadedTracksByID: [Int64: Track] = [:]
    @ObservationIgnored private var loadedReleasesByID: [Int64: Release] = [:]
    @ObservationIgnored private var loadedArtistsByID: [Int64: Artist] = [:]
    private(set) var hasLoadedAllTracks = false
    private(set) var releasesRevision: UInt64 = 0
    private(set) var releases: [Release] = [] {
        didSet {
            loadedReleasesByID = firstRecordIndex(releases, key: { $0.id })
            releasesRevision &+= 1
        }
    }
    private(set) var artistsRevision: UInt64 = 0
    private(set) var artists: [Artist] = [] {
        didSet {
            loadedArtistsByID = firstRecordIndex(artists, key: { $0.id })
            artistsRevision &+= 1
        }
    }
    private(set) var playlistsRevision: UInt64 = 0
    private(set) var playlists: [Playlist] = [] {
        didSet {
            let ids = Set(playlists.map(\.id))
            savedRetrospectivePlaylistIDs = savedRetrospectivePlaylistIDs.filter { ids.contains($0.value) }
            playlistsRevision &+= 1
        }
    }
    private(set) var history: [PlaybackHistoryItem] = []
    @ObservationIgnored let historyRepository = PlaybackHistoryRepository()
    @ObservationIgnored let artistNews = ArtistNewsRepository()
    @ObservationIgnored let homeRepository = HomeLibraryRepository()
    @ObservationIgnored let homeRecommendations = LocalRecommendationsRepository()
    var isLoadingListenList = false
    var classificationRevision: UInt64 = 0
    var listenListEntries: [ListenListEntry] = []
    var albumCollectionAddRequest: AlbumCollectionAddRequest?
    var listenListGeneration: UInt64 = 0
    var isChangingListenList = false
    var listenListError: String?

    var personalTags = UserTagLibrary(tags: [], trackLinks: [], releaseLinks: [])
    var personalTagsRevision: UInt64 = 0
    var personalTagsLoadGeneration: UInt64 = 0
    var isUpdatingPersonalTags = false
    var personalTagsError: String?
    var personalTagEditor: PersonalTagSelection?

    private(set) var metadataRevision = 0 {
        didSet { invalidateCatalog() }
    }
    private(set) var libraryCatalogRevision: UInt64 = 0
    @ObservationIgnored private let libraryRepository: LibraryRepository
    var errorMessage: String?
    private(set) var ratingGranularity: RatingGranularity = .halfStars
    private(set) var isChangingRatingScale = false
    private(set) var ratingScaleRevision: UInt64 = 0
    private(set) var appSettings: Settings?
    private(set) var audioOutputState: AudioOutputState?
    private(set) var equalizerMetrics: EqualizerMetrics?
    private(set) var libraryPaths: [String] = []
    /// Configurações de enriquecimento de metadados. Nil até o core ser inicializado.
    private(set) var enrichmentSettings: EnrichmentSettings?
    private(set) var isUpdatingLibraryMetadata = false
    private(set) var metadataUpdateCompleted = 0
    private(set) var metadataUpdateTotal = 0


    private(set) var core: DurvaldCore? {
        didSet {
            invalidateCatalog()
            historyRepository.reset()
            favoriteEdits.removeAll()
            ratingEdits.removeAll()
            releaseRatingEdits.removeAll()
            ratingGranularity = .halfStars
            ratingScaleRevision &+= 1
        }
    }
    @ObservationIgnored private var playbackPollingTask: Task<Void, Never>?
    @ObservationIgnored let spectrumPolling = SpectrumPollingCoordinator()
    @ObservationIgnored private let personalWrites = PersonalWriteQueue()
    @ObservationIgnored private var favoriteEdits: [Int64: PersonalValueEdit<Bool>] = [:]
    @ObservationIgnored private var releaseRatingEdits: [Int64: PersonalValueEdit<UInt8?>] = [:]
    @ObservationIgnored private var ratingEdits: [Int64: PersonalValueEdit<UInt8?>] = [:]
    @ObservationIgnored private var historyRefreshTask: Task<Void, Never>?
    let embeddedPlayer = EmbeddedPlayerController()
    @ObservationIgnored nonisolated(unsafe) private var embeddedCore: DurvaldCore?
    @ObservationIgnored private var nowPlaying: NowPlayingCoordinator?
    @ObservationIgnored private var scanProgressPollingTask: Task<Void, Never>?
    @ObservationIgnored private var libraryFileWatcher: LibraryFileWatcher?
    @ObservationIgnored private var libraryWatchDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var libraryWatcherReconnectTask: Task<Void, Never>?
    @ObservationIgnored private var periodicLibraryRescanTask: Task<Void, Never>?
    @ObservationIgnored private var pendingAutomaticScanRoots = Set<String>()
    @ObservationIgnored private var pendingFullLibraryRescan = false
    @ObservationIgnored private var monitoredLibraryRoots = Set<String>()
    @ObservationIgnored private var hasInitializedLibraryMonitoring = false
    @ObservationIgnored private var deferredInitializationTask: Task<Void, Never>?
    @ObservationIgnored private var audioOutputPollingTask: Task<Void, Never>?
    private static let libraryBookmarksKey = "durvald.library-security-bookmarks"
    @ObservationIgnored private var activeLibraryScopes: [URL] = []
    @ObservationIgnored private var volumeTask: Task<Void, Never>?
    @ObservationIgnored private let playbackCoordinator = PlaybackCoordinator()
    private(set) var isChangingTrack = false
    @ObservationIgnored private var isMovingQueue = false
    @ObservationIgnored private var seekTask: Task<Void, Never>?
    @ObservationIgnored private var seekRequestID = 0
    @ObservationIgnored private var pendingSeek: SeekRequest?
    @ObservationIgnored private var nextTracksOffset: UInt64?
    @ObservationIgnored private var nextReleasesOffset: UInt64?
    @ObservationIgnored private var nextHistoryOffset: UInt64?
    @ObservationIgnored private var isLoadingTracksPage = false
    @ObservationIgnored private var isLoadingReleasesPage = false
    @ObservationIgnored private var isLoadingHistoryPage = false
    private static let libraryPageSize: UInt64 = 100
    private static let pagePrefetchDistance = 12
    // Playback commands publish their snapshots immediately. Keep this loop as
    // a low-frequency reconciliation path for progress and automatic track
    // transitions instead of crossing FFI and querying SQLite four times a second.
    private static let activePlaybackPollingInterval = Duration.seconds(1)
    private static let idlePlaybackPollingInterval = Duration.seconds(5)
    private static let libraryWatchDebounceInterval = Duration.seconds(2)
    private static let libraryWatcherReconnectInterval = Duration.seconds(30)
    private static let periodicLibraryRescanInterval = Duration.seconds(6 * 60 * 60)

    private struct SeekRequest {
        let id: Int
        let trackID: Int64
        let seconds: UInt64
    }

    private struct SendableCore: @unchecked Sendable {
        let value: DurvaldCore
    }

    init(
        core: DurvaldCore? = nil,
        playback: PlaybackSnapshot? = nil,
        tracks: [Track] = [],
        releases: [Release] = [],
        artists: [Artist] = [],
        history: [PlaybackHistoryItem] = [],
        fileMetadata: FileMetadataRepository = FileMetadataRepository()
    ) {
        self.libraryRepository = LibraryRepository(files: fileMetadata)
        self.core = core
        self.playback = playback
        self.activeSourceContext = playback?.sourceContext ?? ""
        self.activeTrackID = playback?.currentTrack?.id
        self.queue = playback?.queue ?? []
        self.isPlaybackPaused = playback?.isPaused ?? true
        self.isPlaybackPlaying = playback?.isPlaying ?? false
        self.tracks = tracks
        self.releases = releases
        self.artists = artists
        self.history = history
        loadedTracksByID = firstRecordIndex(tracks, key: { $0.id })
        loadedReleasesByID = firstRecordIndex(releases, key: { $0.id })
        loadedArtistsByID = firstRecordIndex(artists, key: { $0.id })
        historyRepository.seed(entries: history, tracks: tracks)
    }

    // Observe the scalar revision while keeping the indexes out of Observation.
    // Indexes update with the arrays so menu actions see optimistic edits at once.
    func loadedTrack(id: Int64) -> Track? {
        _ = tracksRevision
        return loadedTracksByID[id]
    }

    func loadedRelease(id: Int64?) -> Release? {
        _ = releasesRevision
        guard let id else { return nil }
        return loadedReleasesByID[id]
    }

    func loadedArtist(id: Int64?) -> Artist? {
        _ = artistsRevision
        guard let id else { return nil }
        return loadedArtistsByID[id]
    }

    private func invalidateCatalog() {
        libraryCatalogRevision &+= 1
        libraryRepository.invalidate()
        historyRepository.invalidateTracks()
    }

    /// File metadata shared by all collections, scoped to this catalog revision.
    func fileSizes(for paths: [String]) async throws -> [String: Int64] {
        try await libraryRepository.fileSizes(for: paths)
    }

    /// Complete snapshots shared by library screens and playlist import. These
    /// do not mutate the visible, paginated collections or gate initial rendering.
    func completeCatalogTracks() async throws -> [Track] {
        try await libraryRepository.completeTracks(core: core, visible: tracks, isComplete: hasLoadedAllTracks)
    }

    func completeCatalogReleases() async throws -> [Release] {
        try await libraryRepository.completeReleases(core: core, visible: releases)
    }

    func activateSystemMediaControls() {
        if nowPlaying == nil {
            nowPlaying = NowPlayingCoordinator()
        }
        nowPlaying?.activate(for: self)
    }

    func lyrics(for trackID: Int64) async throws -> String? {
        guard let core else { return nil }
        return try await core.trackLyrics(trackId: trackID)
    }

    func openCoreIfNeeded() async {
        guard core == nil else { return }

        do {
            restoreLibraryAccess()

            let openedCore = try await open(config: try makeConfig())
            let initialPlayback = await openedCore.playback()
            core = openedCore
            try await embeddedPlayer.connect(to: openedCore)
            embeddedCore = openedCore
            playback = initialPlayback
            startPlaybackPolling()
            try await reloadPrimaryLibrary(using: openedCore)
            startDeferredInitialization(using: openedCore)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func startPlaybackPolling() {
        playbackPollingTask?.cancel()

        playbackPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }

                let interval = self.playback?.isPlaying == true
                    ? Self.activePlaybackPollingInterval
                    : Self.idlePlaybackPollingInterval
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }

                if let core = self.core,
                   !self.isChangingTrack,
                   !self.isMovingQueue,
                   !self.isSeeking {
                    let revision = self.seekRequestID
                    let snapshot = await core.playback()
                    await self.embeddedPlayer.refresh()
                    // A seek/track change can start while this read is suspended.
                    guard !Task.isCancelled else { return }
                    if !self.isChangingTrack, !self.isMovingQueue, !self.isSeeking {
                        self.publishPlayback(snapshot, revision: revision)
                        if self.historyRepository.hasRequestedHistory { self.scheduleHistoryRefresh() }
                        await self.refreshRetrospectivePlaylistsIfNeeded()
                    }
                }

            }
        }
    }

    private func reloadPrimaryLibrary(using core: DurvaldCore) async throws {
        invalidateCatalog()
        defer { invalidateCatalog() }
        hasLoadedAllTracks = false
        async let loadedTracks = core.tracksPage(
            pageSize: Self.libraryPageSize,
            offset: 0
        )
        async let loadedReleases = core.releasesPage(
            pageSize: Self.libraryPageSize,
            offset: 0
        )
        async let loadedArtists = core.artists()
        let result = try await (
            loadedTracks,
            loadedReleases,
            loadedArtists
        )
        tracks = result.0.items
        nextTracksOffset = result.0.nextOffset
        hasLoadedAllTracks = nextTracksOffset == nil
        releases = result.1.items
        nextReleasesOffset = result.1.nextOffset
        artists = result.2
    }

    func sourcesDidChange() async {
        invalidateCatalog()
        await refreshLibraryCatalog()
        await refreshPlayback()
    }

    func refreshLibraryCatalog() async {
        guard let core else { return }
        do { try await reloadPrimaryLibrary(using: core) }
        catch { errorMessage = String(describing: error) }
    }

    private func startDeferredInitialization(using core: DurvaldCore) {
        deferredInitializationTask?.cancel()
        deferredInitializationTask = Task { [weak self] in
            // Give SwiftUI an opportunity to render the primary catalog before
            // issuing secondary collection and settings queries.
            await Task.yield()
            guard let self, self.core === core, !Task.isCancelled else { return }

            await self.refreshRatingPreferences()
            do {
                self.playlists = try await core.playlists()
                guard !Task.isCancelled else { return }

                let historyPage = try await core.playbackHistoryPage(
                    pageSize: Self.libraryPageSize,
                    offset: 0
                )
                self.history = historyPage.items
                self.nextHistoryOffset = historyPage.nextOffset
                self.historyRepository.seed(entries: self.history, tracks: self.tracks)
                guard !Task.isCancelled else { return }

                self.libraryPaths = try await core.libraryPaths()
                self.restartLibraryMonitoring()
                self.publishSettings(try await core.settings())
                if let state = try? await core.audioOutputState() { self.publishAudioOutputState(state) }
                self.startAudioOutputPolling(using: core)
                self.enrichmentSettings = try? await core.enrichmentSettings()
            } catch {
                guard !Task.isCancelled else { return }
                self.errorMessage = String(describing: error)
            }
        }
    }

    func loadMoreTracks(ifNeededAfter trackID: Int64) async {
        guard shouldPrefetch(after: trackID, in: tracks),
              let core,
              let offset = nextTracksOffset,
              !isLoadingTracksPage else { return }

        isLoadingTracksPage = true
        defer { isLoadingTracksPage = false }
        do {
            let page = try await core.tracksPage(
                pageSize: Self.libraryPageSize,
                offset: offset
            )
            let loadedIDs = Set(tracks.map(\.id))
            tracks.append(contentsOf: page.items.filter { !loadedIDs.contains($0.id) })
            nextTracksOffset = page.nextOffset
            hasLoadedAllTracks = nextTracksOffset == nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func loadMoreReleases(ifNeededAfter releaseID: Int64) async {
        guard shouldPrefetch(after: releaseID, in: releases),
              let core,
              let offset = nextReleasesOffset,
              !isLoadingReleasesPage else { return }

        isLoadingReleasesPage = true
        defer { isLoadingReleasesPage = false }
        do {
            let page = try await core.releasesPage(
                pageSize: Self.libraryPageSize,
                offset: offset
            )
            let loadedIDs = Set(releases.map(\.id))
            releases.append(contentsOf: page.items.filter { !loadedIDs.contains($0.id) })
            nextReleasesOffset = page.nextOffset
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func loadMoreHistory(ifNeededAfter historyID: Int64) async {
        guard shouldPrefetch(after: historyID, in: history),
              let core,
              let offset = nextHistoryOffset,
              !isLoadingHistoryPage else { return }

        isLoadingHistoryPage = true
        defer { isLoadingHistoryPage = false }
        do {
            let page = try await core.playbackHistoryPage(
                pageSize: Self.libraryPageSize,
                offset: offset
            )
            let loadedIDs = Set(history.map(\.id))
            history.append(contentsOf: page.items.filter { !loadedIDs.contains($0.id) })
            nextHistoryOffset = page.nextOffset
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func shouldPrefetch<Item>(
        after id: Int64,
        in items: [Item],
        id itemID: (Item) -> Int64
    ) -> Bool {
        guard let index = items.firstIndex(where: { itemID($0) == id }) else { return false }
        return index >= max(items.count - Self.pagePrefetchDistance, 0)
    }

    private func shouldPrefetch(after id: Int64, in items: [Track]) -> Bool {
        shouldPrefetch(after: id, in: items, id: \.id)
    }

    private func shouldPrefetch(after id: Int64, in items: [Release]) -> Bool {
        shouldPrefetch(after: id, in: items, id: \.id)
    }

    private func shouldPrefetch(after id: Int64, in items: [PlaybackHistoryItem]) -> Bool {
        shouldPrefetch(after: id, in: items, id: \.id)
    }

    @discardableResult
    func createPlaylist(
        named name: String,
        description: String = "",
        artworkBase64: String? = nil
    ) async -> Playlist? {
        guard let core else {
            errorMessage = "O core ainda está abrindo."
            return nil
        }

        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return nil }

        do {
            let playlist = try await core.createPlaylist(
                name: normalizedName,
                description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                artworkBase64: artworkBase64
            )
            playlists.append(playlist)
            return playlist
        } catch {
            errorMessage = String(describing: error)
            return nil
        }
    }

    @discardableResult
    func createSmartPlaylist(
        named name: String,
        description: String,
        definition: SmartPlaylistDefinition
    ) async -> Playlist? {
        guard let core else { errorMessage = "O core ainda está abrindo."; return nil }
        do {
            let playlist = try await core.createSmartPlaylist(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                definition: definition
            )
            if let index = playlists.firstIndex(where: { $0.id == playlist.id }) {
                playlists[index] = playlist
            } else {
                playlists.append(playlist)
            }
            return playlist
        } catch { errorMessage = String(describing: error); return nil }
    }

    /// The core is authoritative; this is only a navigation cache of its replies.
    func loadReplayPreview(_ draft: RetrospectivePlaylistDraft) async -> ReplayPreview? {
        #if DEBUG
        if let fixture = replayPreviewFixture { return fixture(draft.request) }
        #endif
        guard let core else { return nil }
        do {
            let preview = try await core.replayPreview(request: draft.request)
            guard !Task.isCancelled else { return nil }
            if let saved = preview.savedPlaylist {
                if let index = playlists.firstIndex(where: { $0.id == saved.id }) {
                    if playlists[index] != saved { playlists[index] = saved }
                } else { playlists.append(saved) }
                savedRetrospectivePlaylistIDs[draft.identity] = saved.id
            } else { savedRetrospectivePlaylistIDs[draft.identity] = nil }
            return preview
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
            return nil
        }
    }

    func reloadPlaylists() async throws {
        guard let core else { return }
        playlists = try await core.playlists()
    }

    func savedRetrospectivePlaylist(for draft: RetrospectivePlaylistDraft) -> Playlist? {
        guard let id = savedRetrospectivePlaylistIDs[draft.identity] else { return nil }
        return playlists.first { $0.id == id }
    }

    func saveRetrospectivePlaylist(_ draft: RetrospectivePlaylistDraft,
                                   live: Bool, closeAutomatically: Bool, artworkBase64: String? = nil) async -> Playlist? {
        if let pending = retrospectivePlaylistSaves[draft.identity] { return await pending.value }
        guard let core else { return nil }
        let task = Task { @MainActor () -> Playlist? in
            do {
                let saved = try await core.saveReplay(request: draft.request, name: draft.title,
                    description: "",
                    mode: live ? .live : .snapshot, closeAutomatically: closeAutomatically, artworkBase64: artworkBase64)
                if let index = playlists.firstIndex(where: { $0.id == saved.id }) { playlists[index] = saved }
                else { playlists.append(saved) }
                savedRetrospectivePlaylistIDs[draft.identity] = saved.id
                return saved
            } catch { errorMessage = error.localizedDescription; return nil }
        }
        retrospectivePlaylistSaves[draft.identity] = task
        defer { retrospectivePlaylistSaves[draft.identity] = nil }
        return await task.value
    }

    func updateReplay(_ draft: RetrospectivePlaylistDraft, live: Bool, closeAutomatically: Bool) async -> Bool {
        guard let core else { return false }
        do {
            let saved = try await core.updateReplay(request: draft.request, mode: live ? .live : .snapshot,
                                                    closeAutomatically: closeAutomatically)
            if let index = playlists.firstIndex(where: { $0.id == saved.id }) { playlists[index] = saved }
            savedRetrospectivePlaylistIDs[draft.identity] = saved.id
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func refreshRetrospectivePlaylistsIfNeeded() async {
        guard let core, !isRefreshingRetrospectivePlaylists else { return }
        let configs = playlists.compactMap(RetrospectivePlaylistConfiguration.read)
        guard !configs.isEmpty else { return }
        if !historyRepository.hasRequestedHistory { scheduleHistoryRefresh() }
        let expired = configs.contains { $0.closeAutomatically && Double($0.endAt) <= Date().timeIntervalSince1970 }
        guard expired || retrospectiveHistoryRevision != historyRepository.revision else { return }
        isRefreshingRetrospectivePlaylists = true
        defer { isRefreshingRetrospectivePlaylists = false }
        let revision = historyRepository.revision
        let playlistRevision = playlistsRevision
        do {
            let updated = try await core.playlists()
            guard playlistsRevision == playlistRevision else { return }
            if playlists != updated { playlists = updated }
            retrospectiveHistoryRevision = revision
        } catch { errorMessage = String(describing: error) }
    }

    func updateSmartPlaylist(
        id: Int64,
        name: String,
        description: String,
        definition: SmartPlaylistDefinition
    ) async -> Playlist? {
        guard let core else { return nil }
        do {
            try await core.updateSmartPlaylist(
                playlistId: id, name: name, description: description, definition: definition
            )
            let updated = try await core.playlist(playlistId: id)
            if let index = playlists.firstIndex(where: { $0.id == id }) { playlists[index] = updated }
            return updated
        } catch { errorMessage = String(describing: error); return nil }
    }

    func importM3U8(from url: URL) async throws -> PlaylistImportReport {
        guard let core else { throw PlaylistTransferError.cannotCreatePlaylist }
        let requestedPaths = try await FileImportService.shared.playlistPaths(from: url)
        let indexedTracks = try await completeCatalogTracks().filter { $0.filePath != nil }
        let tracksByPath = try await FileImportService.shared.pathIndex(indexedTracks.compactMap(\.filePath))
        try Task.checkCancellation()

        let playlistName = url.deletingPathExtension().lastPathComponent
        guard let playlist = await createPlaylist(named: playlistName) else {
            throw PlaylistTransferError.cannotCreatePlaylist
        }
        var importedCount = 0
        var missing: [String] = []
        var failures: [String] = []
        for requested in requestedPaths {
            let requestedURL = requested.url
            guard let index = tracksByPath[requested.canonicalPath] else {
                missing.append(requestedURL.path)
                continue
            }
            do {
                _ = try await core.addTrackToPlaylist(
                    playlistId: playlist.id,
                    trackId: indexedTracks[index].id,
                    position: UInt64(importedCount)
                )
                importedCount += 1
            } catch {
                failures.append("\(requestedURL.path): \(error.localizedDescription)")
            }
        }
        let refreshed = (try? await core.playlist(playlistId: playlist.id)) ?? playlist
        if let index = playlists.firstIndex(where: { $0.id == playlist.id }) {
            playlists[index] = refreshed
        }
        return PlaylistImportReport(
            playlist: refreshed,
            importedCount: importedCount,
            missingPaths: missing,
            failures: failures
        )
    }

    func exportM3U8(playlist: Playlist, relativePaths: Bool) async throws -> URL {
        guard let core else { throw PlaylistTransferError.cannotCreatePlaylist }
        let tracks = try await core.playlistTracks(playlistId: playlist.id)
        guard let destination = await PlaylistTransferService.chooseExportURL(defaultName: playlist.name) else {
            throw PlaylistTransferError.exportCancelled
        }
        let content = PlaylistTransferService.m3u8(
            tracks: tracks,
            destination: destination,
            relativePaths: relativePaths
        )
        try PlaylistTransferService.write(content, to: destination)
        return destination
    }

    @discardableResult
    func updatePlaylist(
        id: Int64,
        name: String,
        description: String,
        artworkBase64: String?
    ) async -> Playlist? {
        guard let core else {
            errorMessage = "O core ainda está abrindo."
            return nil
        }

        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return nil }

        do {
            try await core.updatePlaylist(
                playlistId: id,
                name: normalizedName,
                description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                artworkBase64: artworkBase64
            )
            let playlist = try await core.playlist(playlistId: id)
            if let index = playlists.firstIndex(where: { $0.id == id }) {
                playlists[index] = playlist
            } else {
                playlists.append(playlist)
            }
            return playlist
        } catch {
            errorMessage = String(describing: error)
            return nil
        }
    }

    @discardableResult
    func deletePlaylist(id: Int64) async -> Bool {
        guard let core else {
            errorMessage = "O core ainda está abrindo."
            return false
        }

        do {
            try await core.deletePlaylist(playlistId: id)
            playlists.removeAll { $0.id == id }
            return true
        } catch {
            errorMessage = String(describing: error)
            return false
        }
    }

    @discardableResult
    func addTrack(_ trackID: Int64, to playlist: Playlist) -> Bool {
        guard let core else {
            errorMessage = "O core ainda está abrindo."
            return false
        }

        let currentTrackCount = playlists.first(where: { $0.id == playlist.id })?.trackCount
            ?? playlist.trackCount
        Task {
            do {
                _ = try await core.addTrackToPlaylist(
                    playlistId: playlist.id,
                    trackId: trackID,
                    position: currentTrackCount
                )
                if let index = playlists.firstIndex(where: { $0.id == playlist.id }) {
                    playlists[index].trackCount += 1
                }
            } catch {
                errorMessage = String(describing: error)
            }
        }
        return true
    }

    func searchLibrary(query: String) async -> SearchResults {
        guard let core else {
            return SearchResults(
                tracks: [],
                releases: [],
                artists: [],
                playlists: []
            )
        }

        do {
            return try await core.search(query: query)
        } catch {
            errorMessage = String(describing: error)
            return SearchResults(
                tracks: [],
                releases: [],
                artists: [],
                playlists: []
            )
        }
    }

    func tracks(forReleaseID releaseID: Int64) async -> [Track] {
        guard let core else {
            return tracks.filter { $0.releaseId == releaseID }.sorted {
                if $0.discNumber != $1.discNumber { return $0.discNumber < $1.discNumber }
                if $0.trackNumber != $1.trackNumber { return $0.trackNumber < $1.trackNumber }
                return $0.id < $1.id
            }
        }

        let sendableCore = SendableCore(value: core)

        do {
            let tracks = try await Task.detached(priority: .userInitiated) {
                try await sendableCore.value.releaseTracks(releaseId: releaseID)
            }.value

            return tracks.sorted { lhs, rhs in
                if lhs.discNumber != rhs.discNumber {
                    return lhs.discNumber < rhs.discNumber
                }

                if lhs.trackNumber != rhs.trackNumber {
                    return lhs.trackNumber < rhs.trackNumber
                }

                return lhs.id < rhs.id
            }
        } catch {
            errorMessage = String(describing: error)
            return []
        }
    }

    func tracks(forArtistID artistID: Int64) async -> [Track] {
        guard let core else {
            return tracks.filter { $0.artistId == artistID }.sorted {
                if $0.discNumber != $1.discNumber { return $0.discNumber < $1.discNumber }
                if $0.trackNumber != $1.trackNumber { return $0.trackNumber < $1.trackNumber }
                return $0.id < $1.id
            }
        }
        let sendableCore = SendableCore(value: core)

        do {
            return try await Task.detached(priority: .userInitiated) {
                try await sendableCore.value.artistTracks(artistId: artistID)
            }.value
        } catch {
            errorMessage = String(describing: error)
            return []
        }
    }

    func releases(forArtistID artistID: Int64) async -> [Release] {
        guard let core else { return releases.filter { $0.artistId == artistID } }
        let sendableCore = SendableCore(value: core)

        do {
            return try await Task.detached(priority: .userInitiated) {
                try await sendableCore.value.artistReleases(artistId: artistID)
            }.value
        } catch {
            errorMessage = String(describing: error)
            return []
        }
    }

    func tracks(forPlaylistID playlistID: Int64) async -> [Track] {
        guard let core else { return [] }
        let sendableCore = SendableCore(value: core)

        do {
            return try await Task.detached(priority: .userInitiated) {
                try await sendableCore.value.playlistTracks(playlistId: playlistID)
            }.value
        } catch {
            errorMessage = String(describing: error)
            return []
        }
    }

    @discardableResult
    func movePlaylistTrack(
        playlistID: Int64,
        from sourcePosition: Int,
        to destinationPosition: Int
    ) async -> Bool {
        guard let core else {
            errorMessage = "O core ainda está abrindo."
            return false
        }
        guard sourcePosition >= 0, destinationPosition >= 0 else { return false }

        do {
            try await core.movePlaylistTrack(
                playlistId: playlistID,
                from: UInt64(sourcePosition),
                to: UInt64(destinationPosition)
            )
            return true
        } catch {
            errorMessage = String(describing: error)
            return false
        }
    }

    private func makeConfig() throws -> CoreConfig {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Durvald", isDirectory: true)

        let config = CoreConfig(
            databasePath: appSupport.appendingPathComponent("music.db3").path,
            appSupportDir: appSupport.path,
            coversDir: appSupport.appendingPathComponent("covers").path,
            keychainService: "com.durvald.player"
        )
        return config
    }

    func addAndScanLibraryFolder(_ url: URL) {
        guard !isScanningLibrary else { return }
        do {
            try saveAndStartLibraryAccess(for: url)
        } catch {
            errorMessage = "Não foi possível acessar a pasta selecionada: \(error)"
            return
        }

        print("Durvald: pasta selecionada para scan: \(url.path)")
        beginLibraryScan(allowNoConfiguredPaths: true) {
            guard let core = self.core else { return }
            try await core.addLibraryPath(path: url.path)
            self.libraryPaths = try await core.libraryPaths()
            self.restartLibraryMonitoring()
        }
    }

    func updateLibrary() {
        beginLibraryScan()
    }

    private func beginLibraryScan(
        allowNoConfiguredPaths: Bool = false,
        paths: [String]? = nil,
        isAutomatic: Bool = false,
        beforeScan: @escaping @MainActor () async throws -> Void = {}
    ) {
        guard !isScanningLibrary else {
            if isAutomatic {
                if let paths {
                    pendingAutomaticScanRoots.formUnion(paths)
                } else {
                    pendingFullLibraryRescan = true
                }
            }
            return
        }
        guard core != nil else {
            errorMessage = "O core ainda está abrindo. Tente novamente em instantes."
            return
        }
        guard allowNoConfiguredPaths || !libraryPaths.isEmpty else {
            errorMessage = "Adicione uma pasta à biblioteca antes de atualizar."
            return
        }

        isScanningLibrary = true
        lastScanResult = nil
        errorMessage = nil
        startScanProgressPolling()

        Task {
            defer {
                scanProgressPollingTask?.cancel()
                scanProgressPollingTask = nil
                scanProgress = nil
                finishLibraryScan()
            }
            do {
                try await beforeScan()
                guard let core else { return }
                let result: ScanResult
                if let paths {
                    result = try await core.scanLibrary(paths: paths)
                } else {
                    result = try await core.scanConfiguredLibrary()
                }
                lastScanResult = result
                // The core scan is over at this point. Hide cancellation before
                // the post-scan catalog reload so a late click cannot target a
                // scan that has already completed.
                scanProgressPollingTask?.cancel()
                scanProgressPollingTask = nil
                scanProgress = nil
                print(
                    "Durvald: scan concluído — encontrados: \(result.totalFilesFound), novos: \(result.newTracksAdded), atualizados: \(result.updatedTracks), removidos: \(result.removedTracks), erros: \(result.errors)"
                )
                try await reloadPrimaryLibrary(using: core)
                // Apply metadata already cached on disk, but never turn a local
                // library scan into an implicit full-catalog network refresh.
                if !isAutomatic {
                    await updateLibraryMetadata()
                }
                startDeferredInitialization(using: core)

                if !result.errors.isEmpty {
                    errorMessage = result.errors.joined(separator: "\n")
                } else if result.totalFilesFound == 0, !isAutomatic {
                    errorMessage = "Nenhum arquivo suportado foi encontrado. O MVP aceita MP3, WAV, FLAC, Ogg Vorbis e OGA."
                }
            } catch {
                errorMessage = String(describing: error)
            }
        }
    }

    private func finishLibraryScan() {
        isScanningLibrary = false

        if pendingFullLibraryRescan {
            pendingFullLibraryRescan = false
            pendingAutomaticScanRoots.removeAll()
            let roots = monitoredLibraryRoots.sorted()
            if !roots.isEmpty {
                beginLibraryScan(paths: roots, isAutomatic: true)
            }
        } else if !pendingAutomaticScanRoots.isEmpty {
            let roots = coalescedScanPaths(pendingAutomaticScanRoots)
            pendingAutomaticScanRoots.removeAll()
            if !roots.isEmpty {
                beginLibraryScan(paths: roots, isAutomatic: true)
            }
        }
    }
    
    func removeLibraryFolder(path: String) {
        guard let core else {
            errorMessage = "O core ainda está abrindo. Tente novamente em instantes."
            return
        }

        Task {
            do {
                try await core.removeLibraryPath(path: path)
                removeLibraryAccess(forPath: path)

                libraryPaths.removeAll { configuredPath in
                    standardizedLibraryPath(configuredPath)
                        == standardizedLibraryPath(path)
                }
                restartLibraryMonitoring()
            } catch {
                errorMessage = String(describing: error)
            }
        }
    }

    func startScanProgressPolling() {
        scanProgressPollingTask?.cancel()
        scanProgressPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard let core = self.core else { return }
                self.scanProgress = try? core.scanProgress()
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    func cancelScan() {
        guard let core else {
            errorMessage = "Não há core disponível para cancelar o scan."
            return
        }
        do { try core.cancelLibraryScan() }
        catch { errorMessage = String(describing: error) }
    }

    var hasCurrentPlayback: Bool { playback?.currentTrack != nil || embeddedPlayer.status != nil }
    var canSeekCurrentPlayback: Bool {
        guard hasCurrentPlayback else { return false }
        if let status = embeddedPlayer.status {
            return status.seekAvailable && status.state != .failed && status.state != .ended
        }
        return true
    }

    func playEmbeddedSource(_ source: TrackSource) async {
        guard let core, !isChangingTrack else { return }
        isChangingTrack = true
        await finishSeekBeforeChangingTrack()
        defer { isChangingTrack = false; seekRequestID &+= 1 }
        do {
            playback = try await core.playEmbeddedTrackSource(trackId: source.trackId, sourceId: source.sourceId)
            await embeddedPlayer.refresh()
        } catch { errorMessage = String(describing: error) }
    }

    func play(trackID: Int64, sourceContext: String = PlaybackSourceContext.library) async {
        guard let core else {
            errorMessage = "O core ainda está abrindo."
            return
        }

        guard !isChangingTrack else { return }

        isChangingTrack = true
        await finishSeekBeforeChangingTrack()
        defer {
            isChangingTrack = false
            seekRequestID &+= 1
        }

        print("Durvald: solicitando reprodução da faixa \(trackID).")

        do {
            let snapshot = try await core.playWithContext(trackId: trackID, sourceContext: sourceContext)
            playback = snapshot
            print("Durvald: reprodução iniciada; pausada: \(snapshot.isPaused).")
        } catch {
            print("Durvald: falha ao iniciar reprodução: \(error)")
            errorMessage = String(describing: error)
        }
    }

    func playRelease(
        releaseID: Int64,
        startingAt trackID: Int64? = nil,
        shuffleEnabled: Bool? = nil
    ) async {
        guard let core, !isChangingTrack else { return }

        isChangingTrack = true
        await finishSeekBeforeChangingTrack()
        defer {
            isChangingTrack = false
            seekRequestID &+= 1
        }

        do {
            guard self.core === core else { return }
            try await playbackCoordinator.playRelease(id: releaseID, startingAt: trackID, shuffle: shuffleEnabled, core: core,
                isCurrent: { self.core === core }, publish: { self.playback = $0 })
            guard self.core === core else { return }
            await refreshPlayback()
        } catch {
            if self.core === core { errorMessage = String(describing: error) }
        }
    }

    func playTracks(
        _ tracks: [Track],
        startingAt trackID: Int64? = nil,
        shuffleEnabled: Bool? = nil,
        sourceContext: String = ""
    ) async {
        guard let core, !isChangingTrack, !tracks.isEmpty else { return }

        isChangingTrack = true
        await finishSeekBeforeChangingTrack()
        defer {
            isChangingTrack = false
            seekRequestID &+= 1
        }

        do {
            guard self.core === core else { return }
            try await playbackCoordinator.playTracks(tracks, startingAt: trackID, shuffle: shuffleEnabled, sourceContext: sourceContext, core: core,
                isCurrent: { self.core === core }, publish: { self.playback = $0 })
            guard self.core === core else { return }
            await refreshPlayback()
        } catch {
            if self.core === core { errorMessage = String(describing: error) }
        }
    }

    func playPlaylist(
        playlistID: Int64,
        startingAtPosition position: Int? = nil,
        shuffleEnabled: Bool? = nil
    ) async {
        guard let core, !isChangingTrack else { return }

        isChangingTrack = true
        await finishSeekBeforeChangingTrack()
        defer {
            isChangingTrack = false
            seekRequestID &+= 1
        }

        do {
            guard self.core === core else { return }
            try await playbackCoordinator.playPlaylist(id: playlistID, position: position, shuffle: shuffleEnabled, core: core,
                isCurrent: { self.core === core }, publish: { self.playback = $0 })
            guard self.core === core else { return }
            await refreshPlayback()
        } catch {
            if self.core === core { errorMessage = String(describing: error) }
        }
    }

    private func restartLibraryMonitoring() {
        libraryFileWatcher?.stop()
        libraryFileWatcher = nil
        libraryWatcherReconnectTask?.cancel()
        libraryWatcherReconnectTask = nil

        restoreLibraryAccess()

        let configuredRoots = Set(libraryPaths.map(standardizedLibraryPath))
        let accessibleRoots = Set(activeLibraryScopes.compactMap { url -> String? in
            let path = standardizedLibraryPath(url.path)
            var isDirectory: ObjCBool = false
            guard configuredRoots.contains(path),
                  FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            return path
        })

        let reconnectedRoots = accessibleRoots.subtracting(monitoredLibraryRoots)
        monitoredLibraryRoots = accessibleRoots
        if !accessibleRoots.isEmpty {
            libraryFileWatcher = LibraryFileWatcher(paths: accessibleRoots.sorted()) { [weak self] events in
                Task { @MainActor [weak self] in
                    self?.handleLibraryFileEvents(events)
                }
            }
        }

        if hasInitializedLibraryMonitoring, !reconnectedRoots.isEmpty {
            pendingAutomaticScanRoots.formUnion(reconnectedRoots)
            scheduleDebouncedAutomaticScan()
        }
        hasInitializedLibraryMonitoring = true

        if accessibleRoots != configuredRoots {
            scheduleLibraryWatcherReconnect()
        }
        if libraryPaths.isEmpty {
            periodicLibraryRescanTask?.cancel()
            periodicLibraryRescanTask = nil
        }
        startPeriodicLibraryRescanIfNeeded()
    }

    private func handleLibraryFileEvents(_ events: [LibraryFileWatcher.Event]) {
        guard !events.isEmpty else { return }

        if events.contains(where: \.requiresReconnect) {
            restartLibraryMonitoring()
        }

        if events.contains(where: \.requiresFullRescan) {
            pendingFullLibraryRescan = true
            scheduleDebouncedAutomaticScan()
            return
        }

        for event in events {
            guard event.affectsLibraryContent else { continue }
            guard let root = monitoredLibraryRoots.first(where: {
                event.path == $0 || event.path.hasPrefix($0 + "/")
            }) else { continue }
            let eventURL = URL(fileURLWithPath: event.path)
            var scanPath = root
            if event.path != root {
                var isDirectory: ObjCBool = false
                let eventStillExists = FileManager.default.fileExists(
                    atPath: event.path,
                    isDirectory: &isDirectory
                )
                if event.isDirectory, eventStillExists, isDirectory.boolValue {
                    scanPath = standardizedLibraryPath(event.path)
                } else {
                    scanPath = standardizedLibraryPath(
                        eventURL.deletingLastPathComponent().path
                    )
                }
            }
            pendingAutomaticScanRoots.insert(scanPath)
        }
        scheduleDebouncedAutomaticScan()
    }

    private func scheduleDebouncedAutomaticScan() {
        guard pendingFullLibraryRescan || !pendingAutomaticScanRoots.isEmpty else { return }
        libraryWatchDebounceTask?.cancel()
        libraryWatchDebounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.libraryWatchDebounceInterval)
            } catch {
                return
            }
            guard let self else { return }

            if self.pendingFullLibraryRescan {
                self.pendingFullLibraryRescan = false
                self.pendingAutomaticScanRoots.removeAll()
                let roots = self.monitoredLibraryRoots.sorted()
                guard !roots.isEmpty else {
                    self.scheduleLibraryWatcherReconnect()
                    return
                }
                self.beginLibraryScan(paths: roots, isAutomatic: true)
                return
            }

            let availableRoots = self.pendingAutomaticScanRoots.filter { path in
                self.monitoredLibraryRoots.contains(where: { root in
                    path == root || path.hasPrefix(root + "/")
                })
            }
            self.pendingAutomaticScanRoots.removeAll()
            guard !availableRoots.isEmpty else { return }
            self.beginLibraryScan(
                paths: self.coalescedScanPaths(Set(availableRoots)),
                isAutomatic: true
            )
        }
    }

    private func coalescedScanPaths(_ paths: Set<String>) -> [String] {
        let sorted = paths.sorted {
            $0.split(separator: "/").count < $1.split(separator: "/").count
        }
        var result: [String] = []
        for path in sorted where !result.contains(where: {
            path == $0 || path.hasPrefix($0 + "/")
        }) {
            result.append(path)
        }
        return result.sorted()
    }

    private func scheduleLibraryWatcherReconnect() {
        libraryWatcherReconnectTask?.cancel()
        libraryWatcherReconnectTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.libraryWatcherReconnectInterval)
            } catch {
                return
            }
            self?.restartLibraryMonitoring()
        }
    }

    private func startPeriodicLibraryRescanIfNeeded() {
        guard periodicLibraryRescanTask == nil, !libraryPaths.isEmpty else { return }
        periodicLibraryRescanTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.periodicLibraryRescanInterval)
                } catch {
                    return
                }
                guard let availableRoots = self?.monitoredLibraryRoots.sorted() else { return }
                guard !availableRoots.isEmpty else {
                    self?.scheduleLibraryWatcherReconnect()
                    continue
                }
                self?.beginLibraryScan(paths: availableRoots, isAutomatic: true)
            }
        }
    }

    private func saveAndStartLibraryAccess(for url: URL) throws {
        // Keep the exact URL returned by NSOpenPanel. Normalizing it before
        // opening the security scope can discard the sandbox authorization.
        let scopedURL = url
        let canonicalPath = scopedURL.standardizedFileURL.path
        if activeLibraryScopes.contains(where: { $0.standardizedFileURL.path == canonicalPath }) {
            return
        }

        let bookmark = try scopedURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        var bookmarks = UserDefaults.standard.dictionary(forKey: Self.libraryBookmarksKey) ?? [:]
        bookmarks[canonicalPath] = bookmark
        UserDefaults.standard.set(bookmarks, forKey: Self.libraryBookmarksKey)

        guard scopedURL.startAccessingSecurityScopedResource() else {
            throw CocoaError(.fileReadNoPermission)
        }
        activeLibraryScopes.append(scopedURL)
    }
    
    private func removeLibraryAccess(forPath path: String) {
        let canonicalPath = standardizedLibraryPath(path)

        var bookmarks = UserDefaults.standard.dictionary(
            forKey: Self.libraryBookmarksKey
        ) ?? [:]

        bookmarks.removeValue(forKey: canonicalPath)

        UserDefaults.standard.set(
            bookmarks,
            forKey: Self.libraryBookmarksKey
        )

        let removedScopes = activeLibraryScopes.filter { url in
            standardizedLibraryPath(url.path) == canonicalPath
        }

        removedScopes.forEach {
            $0.stopAccessingSecurityScopedResource()
        }

        activeLibraryScopes.removeAll { url in
            standardizedLibraryPath(url.path) == canonicalPath
        }
    }

    private func standardizedLibraryPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .path
    }

    private func restoreLibraryAccess() {
        var bookmarks = UserDefaults.standard.dictionary(forKey: Self.libraryBookmarksKey) ?? [:]
        var refreshedBookmarks: [String: Data] = [:]
        for (storedPath, value) in bookmarks {
            guard let data = value as? Data else { continue }
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else { continue }
            if isStale,
               let refreshed = try? url.bookmarkData(
                   options: .withSecurityScope,
                   includingResourceValuesForKeys: nil,
                   relativeTo: nil
               ) {
                refreshedBookmarks[storedPath] = refreshed
            }
            guard !activeLibraryScopes.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) else { continue }
            if url.startAccessingSecurityScopedResource() {
                activeLibraryScopes.append(url.standardizedFileURL)
            }
        }
        if !refreshedBookmarks.isEmpty {
            bookmarks.merge(refreshedBookmarks) { _, refreshed in refreshed }
            UserDefaults.standard.set(bookmarks, forKey: Self.libraryBookmarksKey)
        }
    }

    func previous() async {
        guard let core, !isChangingTrack else { return }

        isChangingTrack = true
        await finishSeekBeforeChangingTrack()
        defer {
            isChangingTrack = false
            seekRequestID &+= 1
        }

        do {
            playback = try await core.previousTrack()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func next() async {
        guard let core, !isChangingTrack else { return }

        isChangingTrack = true
        await finishSeekBeforeChangingTrack()
        defer {
            isChangingTrack = false
            seekRequestID &+= 1
        }

        do {
            playback = try await core.nextTrack()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func togglePause() async {
        guard let core, let playback, hasCurrentPlayback else { return }

        do {
            if playback.isPaused {
                try await core.resume()
            } else {
                try await core.pause()
            }

            await self.refreshPlayback()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func setVolume(_ value: Double) async {
        guard let core else { return }
        do {
            try await core.setVolume(volume: Float(min(max(value, 0), 1)))
            await refreshPlayback()
        } catch { errorMessage = String(describing: error) }
    }

    func seek(to seconds: Double) {
        guard canSeekCurrentPlayback else { return }
        if playback?.currentTrack == nil, let core, seconds.isFinite, seconds >= 0,
           let duration = playback?.durationSeconds {
            let target = UInt64(min(seconds, duration).rounded(.down))
            Task { do { try await core.seek(seconds: target); await refreshPlayback() } catch { errorMessage = String(describing: error) } }
            return
        }
        guard let core, !isChangingTrack, seconds.isFinite,
              var optimisticSnapshot = playback,
              let trackID = optimisticSnapshot.currentTrack?.id,
              let duration = optimisticSnapshot.durationSeconds,
              duration.isFinite, duration > 0
        else { return }

        // The current FFI accepts whole seconds. Show the same target we send,
        // rather than first showing a fraction and then snapping back on receipt.
        let target = min(max(seconds, 0).rounded(), duration.rounded(.down))
        guard let coreSeconds = UInt64(exactly: target) else { return }
        seekRequestID &+= 1
        pendingSeek = SeekRequest(id: seekRequestID, trackID: trackID, seconds: coreSeconds)
        isSeeking = true
        optimisticSnapshot.positionSeconds = target
        playback = optimisticSnapshot

        // One worker owns the FFI calls. Cancelling a Swift task does not undo
        // a command already sent to the audio engine; queue only the latest target.
        guard seekTask == nil else { return }
        seekTask = Task { [weak self] in
            await self?.performPendingSeeks(using: core)
        }
    }

    private func performPendingSeeks(using core: DurvaldCore) async {
        defer {
            seekTask = nil
            isSeeking = false
        }

        while let request = pendingSeek {
            do {
                // Coalesce quick successive clicks without seeking continuously
                // while the slider is being dragged.
                try await Task.sleep(for: .milliseconds(60))
                guard pendingSeek?.id == request.id else { continue }
                try await core.seek(seconds: request.seconds)
                let clock = ContinuousClock()
                let started = clock.now
                let deadline = started.advanced(by: .seconds(3))
                var consecutiveConfirmations = 0

                while pendingSeek?.id == request.id {
                    try Task.checkCancellation()
                    let snapshot = await core.playback()
                    guard pendingSeek?.id == request.id else { break }

                    let elapsed = started.duration(to: clock.now).components
                    let elapsedSeconds = Double(elapsed.seconds)
                        + Double(elapsed.attoseconds) / 1e18
                    let target = Double(request.seconds)
                    let upperTolerance = snapshot.isPlaying ? elapsedSeconds + 0.25 : 0.25
                    let arrived = snapshot.positionSeconds >= target - 0.10
                        && snapshot.positionSeconds <= target + upperTolerance
                    let changedTrack = snapshot.currentTrack?.id != request.trackID
                    consecutiveConfirmations = arrived ? consecutiveConfirmations + 1 : 0
                    let confirmed = consecutiveConfirmations >= 2

                    if confirmed || changedTrack || clock.now >= deadline {
                        pendingSeek = nil
                        // Invalidate reads started before the acknowledgement too.
                        seekRequestID &+= 1
                        publishPlayback(snapshot, revision: seekRequestID)
                        if !confirmed && !changedTrack {
                            errorMessage = "O áudio não confirmou a nova posição. Tente novamente."
                        }
                        break
                    }

                    // Kira queues seek_to; returning from the FFI is not an audio
                    // acknowledgement. Keep the target until the decoder catches up.
                    try await Task.sleep(for: .milliseconds(50))
                }
            } catch {
                if Task.isCancelled {
                    pendingSeek = nil
                    return
                }
                guard pendingSeek?.id == request.id else { continue }
                pendingSeek = nil
                seekRequestID &+= 1
                let revision = seekRequestID
                let snapshot = await core.playback()
                guard revision == seekRequestID else { continue }
                // Recover from the actual engine state, never an old full snapshot.
                publishPlayback(snapshot, revision: revision)
                errorMessage = String(describing: error)
            }
        }
    }

    /// Shared by polling and non-seek actions such as volume, pause and queue edits.
    func refreshPlayback() async {
        guard let core else { return }
        let revision = seekRequestID
        let snapshot = await core.playback()
        await embeddedPlayer.refresh()
        publishPlayback(snapshot, revision: revision)
    }

    private func publishPlayback(_ snapshot: PlaybackSnapshot, revision: Int) {
        guard revision == seekRequestID else { return }
        var snapshot = snapshot
        if let request = pendingSeek {
            guard snapshot.currentTrack?.id == request.trackID else { return }
            snapshot.positionSeconds = Double(request.seconds)
        }
        if var track = snapshot.currentTrack {
            if let edit = favoriteEdits[track.id], edit.isPending { track.isFavorite = edit.value }
            if let edit = ratingEdits[track.id], edit.isPending { track.ratingHalfSteps = edit.value }
            snapshot.currentTrack = track
        }
        guard playback != snapshot else { return }
        playback = snapshot
    }

    private func finishSeekBeforeChangingTrack() async {
        seekRequestID &+= 1
        pendingSeek = nil
        // Let an already dispatched command finish before loading another track.
        await seekTask?.value
    }

    private(set) var volumeBeforeMute: Double = 0.5
    var isVolumeMuted: Bool { playback?.volume == 0 }

    func toggleMute() {
        guard let playback else { return }
        if playback.volume == 0 { scheduleVolume(volumeBeforeMute, immediately: true) }
        else {
            volumeBeforeMute = Double(playback.volume)
            scheduleVolume(0, immediately: true)
        }
    }

    func adjustVolume(by delta: Double) {
        guard let playback else { return }
        scheduleVolume(Double(playback.volume) + delta, immediately: true)
    }

    func scheduleVolume(_ value: Double, immediately: Bool = false) {
        volumeTask?.cancel()

        let normalized = Float(min(max(value, 0), 1))

        if normalized > 0 { volumeBeforeMute = Double(normalized) }
        // Atualização otimista da interface.
        if var snapshot = playback {
            snapshot.volume = normalized
            playback = snapshot
        }

        volumeTask = Task { [weak self] in
            if !immediately {
                try? await Task.sleep(for: .milliseconds(50))
            }

            guard !Task.isCancelled, let self, let core = self.core else { return }

            do {
                try await core.setVolume(volume: normalized)
                await self.refreshPlayback()
            } catch {
                guard !Task.isCancelled else { return }
                self.errorMessage = String(describing: error)
            }
        }
    }
    

    @discardableResult
    func setTrackFavorite(trackID: Int64, favorite: Bool, fallbackTrack: Track? = nil) async -> Bool {
        guard let core else {
            errorMessage = "O core ainda está abrindo. Tente novamente em instantes."
            return false
        }
        let baseline = loadedTrack(id: trackID)
            ?? (playback?.currentTrack?.id == trackID ? playback?.currentTrack : nil) ?? fallbackTrack
        let previous = baseline?.isFavorite ?? false
        var edit = favoriteEdits[trackID] ?? PersonalValueEdit(previous)
        let ticket = edit.begin(favorite)
        favoriteEdits[trackID] = edit
        publishFavorite(favorite, trackID: trackID)
        return await personalWrites.perform(key: "favorite.\(trackID)") { [self] in
            guard self.core === core else { return false }
            let succeeded: Bool
            do {
                try await core.setTrackFavorite(trackId: trackID, favorite: favorite)
                succeeded = true
            } catch { if self.core === core { errorMessage = String(describing: error) }; succeeded = false }
            guard self.core === core, var latest = favoriteEdits[trackID] else { return false }
            latest.finish(ticket, succeeded: succeeded)
            favoriteEdits[trackID] = latest.isPending ? latest : nil
            publishFavorite(latest.value, trackID: trackID)
            metadataRevision &+= 1
            return succeeded
        }
    }

    @discardableResult
    func setTrackRating(trackID: Int64, rating: UInt8?, fallbackTrack: Track? = nil) async -> Bool {
        guard !isChangingRatingScale else { return false }
        let scaleRevision = ratingScaleRevision
        guard let core else {
            errorMessage = "O core ainda está abrindo. Tente novamente em instantes."
            return false
        }
        let baseline = loadedTrack(id: trackID)
            ?? (playback?.currentTrack?.id == trackID ? playback?.currentTrack : nil) ?? fallbackTrack
        let previous = baseline?.ratingHalfSteps
        var edit = ratingEdits[trackID] ?? PersonalValueEdit(previous)
        let ticket = edit.begin(rating)
        ratingEdits[trackID] = edit
        publishRating(rating, trackID: trackID)
        return await personalWrites.perform(key: "rating.\(trackID)") { [self] in
            guard self.core === core else { return false }
            let succeeded: Bool
            do {
                try await core.setTrackRatingHalfSteps(trackId: trackID, ratingHalfSteps: rating)
                succeeded = true
            } catch { if self.core === core { errorMessage = String(describing: error) }; succeeded = false }
            guard self.core === core, scaleRevision == ratingScaleRevision, var latest = ratingEdits[trackID] else { return false }
            latest.finish(ticket, succeeded: succeeded)
            ratingEdits[trackID] = latest.isPending ? latest : nil
            publishRating(latest.value, trackID: trackID)
            metadataRevision &+= 1
            return succeeded
        }
    }

    private func publishFavorite(_ favorite: Bool, trackID: Int64) {
        if let index = tracks.firstIndex(where: { $0.id == trackID }), tracks[index].isFavorite != favorite {
            tracks[index].isFavorite = favorite
        }
        if playback?.currentTrack?.id == trackID { playback?.currentTrack?.isFavorite = favorite }
    }

    private func publishRating(_ rating: UInt8?, trackID: Int64) {
        if let index = tracks.firstIndex(where: { $0.id == trackID }), tracks[index].ratingHalfSteps != rating {
            tracks[index].ratingHalfSteps = rating
        }
        if playback?.currentTrack?.id == trackID { playback?.currentTrack?.ratingHalfSteps = rating }
    }

    func refreshRatingPreferences() async {
        guard let core, !isChangingRatingScale else { return }
        let revision = ratingScaleRevision
        do {
            let preferences = try await core.ratingPreferences()
            guard self.core === core, !isChangingRatingScale, revision == ratingScaleRevision else { return }
            if ratingGranularity != preferences.granularity {
                ratingGranularity = preferences.granularity
                ratingScaleRevision &+= 1
            }
        } catch { if self.core === core { errorMessage = String(describing: error) } }
    }

    func previewRatingConversion() async throws -> RatingConversionPreview {
        guard let core else { throw CocoaError(.coderInvalidValue) }
        return try await core.ratingConversionPreview()
    }

    @discardableResult
    func changeRatingGranularity(_ granularity: RatingGranularity, rounding: RatingRounding?) async -> Bool {
        guard let core, !isChangingRatingScale else { return false }
        isChangingRatingScale = true
        // Block new edits and drain existing writes before invalidating UI tickets.
        // The core converts the resulting snapshot and preference atomically.
        defer { isChangingRatingScale = false; ratingScaleRevision &+= 1 }
        await personalWrites.waitForPendingWrites()
        guard self.core === core else { return false }
        ratingScaleRevision &+= 1
        ratingEdits.removeAll()
        releaseRatingEdits.removeAll()
        do {
            let result = try await core.updateRatingPreferences(granularity: granularity, rounding: rounding)
            guard self.core === core else { return false }
            ratingGranularity = result.preferences.granularity
        } catch {
            errorMessage = String(describing: error)
            metadataRevision &+= 1
            return false
        }
        do {
            async let trackPage = refreshedRatingWindow(count: tracks.count) { size, offset in
                let page = try await core.tracksPage(pageSize: size, offset: offset)
                return (page.items, page.nextOffset)
            }
            async let releasePage = refreshedRatingWindow(count: releases.count) { size, offset in
                let page = try await core.releasesPage(pageSize: size, offset: offset)
                return (page.items, page.nextOffset)
            }
            async let refreshedPlayback = core.playback()
            async let refreshedPlaylists = core.playlists()
            let result = try await (trackPage, releasePage, refreshedPlayback, refreshedPlaylists)
            guard self.core === core else { return false }
            tracks = result.0.0
            nextTracksOffset = result.0.1
            hasLoadedAllTracks = nextTracksOffset == nil
            releases = result.1.0
            nextReleasesOffset = result.1.1
            playback = result.2
            playlists = result.3
        } catch {
            errorMessage = "Escala salva; falha ao atualizar as avaliações: \(error)"
        }
        metadataRevision &+= 1
        return true
    }

    /// The core caps each page. Continue until the previously loaded window is
    /// restored, keeping its next cursor so subsequent scrolling still works.
    private func refreshedRatingWindow<Item>(count: Int,
        fetch: (UInt64, UInt64) async throws -> ([Item], UInt64?)) async throws -> ([Item], UInt64?) {
        let target = max(Int(Self.libraryPageSize), count)
        var items: [Item] = []
        var offset: UInt64 = 0
        while true {
            let (page, next) = try await fetch(UInt64(target - items.count), offset)
            items.append(contentsOf: page)
            guard let next, items.count < target else { return (items, next) }
            guard !page.isEmpty, next > offset else {
                throw CocoaError(.coderInvalidValue)
            }
            offset = next
        }
    }

    func refreshAfterMetadataEdit(_ info: TrackInfo) async {
        guard let core else { return }
        if playback?.currentTrack?.id == info.track.id { playback?.currentTrack = info.track }
        do {
            let trackPageSize = max(Self.libraryPageSize, UInt64(tracks.count))
            let releasePageSize = max(Self.libraryPageSize, UInt64(releases.count))
            async let refreshedTracks = core.tracksPage(pageSize: trackPageSize, offset: 0)
            async let refreshedReleases = core.releasesPage(pageSize: releasePageSize, offset: 0)
            async let refreshedArtists = core.artists()
            let result = try await (refreshedTracks, refreshedReleases, refreshedArtists)
            tracks = result.0.items
            nextTracksOffset = result.0.nextOffset
            hasLoadedAllTracks = nextTracksOffset == nil
            releases = result.1.items
            nextReleasesOffset = result.1.nextOffset
            artists = result.2
        } catch {
            errorMessage = "Metadados salvos; falha ao atualizar a biblioteca: \(error)"
        }
        metadataRevision &+= 1
    }

    func setReleaseFavorite(releaseID: Int64, favorite: Bool) {
        guard let core else {
            errorMessage = "O core ainda está abrindo. Tente novamente em instantes."
            return
        }

        Task {
            do {
                try await core.setReleaseFavorite(releaseId: releaseID, favorite: favorite)
                metadataRevision &+= 1
                if let index = releases.firstIndex(where: { $0.id == releaseID }) {
                    releases[index].isFavorite = favorite
                }
            } catch {
                errorMessage = String(describing: error)
            }
        }
    }

    @discardableResult
    func setReleaseRating(releaseID: Int64, rating: UInt8?, fallbackRelease: Release? = nil) async -> Bool {
        guard !isChangingRatingScale else { return false }
        let scaleRevision = ratingScaleRevision
        guard let core else { errorMessage = "O core ainda está abrindo. Tente novamente em instantes."; return false }
        let previous = (releases.first { $0.id == releaseID } ?? fallbackRelease)?.ratingHalfSteps
        var edit = releaseRatingEdits[releaseID] ?? PersonalValueEdit(previous)
        let ticket = edit.begin(rating)
        releaseRatingEdits[releaseID] = edit
        publishReleaseRating(rating, releaseID: releaseID)
        return await personalWrites.perform(key: "release.rating.\(releaseID)") { [self] in
            guard self.core === core else { return false }
            let succeeded: Bool
            do { try await core.setReleaseRatingHalfSteps(releaseId: releaseID, ratingHalfSteps: rating); succeeded = true }
            catch { if self.core === core { errorMessage = String(describing: error) }; succeeded = false }
            guard self.core === core, scaleRevision == ratingScaleRevision, var latest = releaseRatingEdits[releaseID] else { return false }
            latest.finish(ticket, succeeded: succeeded)
            releaseRatingEdits[releaseID] = latest.isPending ? latest : nil
            publishReleaseRating(latest.value, releaseID: releaseID)
            metadataRevision &+= 1
            return succeeded
        }
    }

    private func publishReleaseRating(_ rating: UInt8?, releaseID: Int64) {
        if let index = releases.firstIndex(where: { $0.id == releaseID }), releases[index].ratingHalfSteps != rating {
            releases[index].ratingHalfSteps = rating
        }
    }

    func setPlaylistFavorite(playlistID: Int64, favorite: Bool) {
        guard let core else {
            errorMessage = "O core ainda está abrindo. Tente novamente em instantes."
            return
        }

        Task {
            do {
                try await core.setPlaylistFavorite(playlistId: playlistID, favorite: favorite)
                if let index = playlists.firstIndex(where: { $0.id == playlistID }) {
                    playlists[index].isFavorite = favorite
                }
            } catch {
                errorMessage = String(describing: error)
            }
        }
    }

    func addToQueue(trackID: Int64) async {
        guard let core else { return }

        do {
            try await core.addToQueueWithContext(trackId: trackID, sourceContext: "queue")
            await refreshPlayback()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func orderedReleaseTracks(_ releaseID: Int64) async throws -> [Track] {
        guard let core else { return [] }
        return try await core.releaseTracks(releaseId: releaseID).sorted {
            if $0.discNumber != $1.discNumber { return $0.discNumber < $1.discNumber }
            if $0.trackNumber != $1.trackNumber { return $0.trackNumber < $1.trackNumber }
            return $0.id < $1.id
        }
    }

    func enqueuePlaylist(playlistID: Int64, playNext: Bool = false) async {
        guard let core else { return }
        do {
            let tracks = try await core.playlistTracks(playlistId: playlistID)
            guard !tracks.isEmpty else { errorMessage = "Esta playlist não possui faixas."; return }
            try await enqueueTracks(tracks, playNext: playNext)
        } catch {
            errorMessage = String(describing: error)
            await refreshPlayback()
        }
    }

    @discardableResult
    func addPlaylist(_ playlistID: Int64, to target: Playlist) async -> Bool {
        guard let core else { return false }
        do {
            let tracks = try await core.playlistTracks(playlistId: playlistID)
            guard !tracks.isEmpty else { errorMessage = "Esta playlist não possui faixas."; return false }
            try await appendTracks(tracks, to: target)
            return true
        } catch {
            errorMessage = String(describing: error)
            return false
        }
    }

    func insertTracksIntoQueue(_ ids: [Int64], at position: UInt64) async {
        guard let core else { return }
        do {
            var destination = position
            for id in ids {
                try await core.addToQueueWithContext(trackId: id, sourceContext: "queue")
                let snapshot = await core.playback()
                if let appended = snapshot.queue.last, appended.position > destination {
                    try await core.moveQueueItem(from: appended.position, to: destination)
                }
                destination += 1
            }
            await refreshPlayback()
        } catch { errorMessage = String(describing: error) }
    }

    func enqueueSelection(_ tracks: [Track], playNext: Bool = false) async {
        do { try await enqueueTracks(tracks, playNext: playNext) }
        catch { errorMessage = String(describing: error) }
    }

    private func enqueueTracks(_ tracks: [Track], playNext: Bool) async throws {
        guard let core else { return }
        let initial = await core.playback()
        var destination: UInt64 = initial.currentTrack == nil ? 0 : 1
        for track in tracks {
            try await core.addToQueueWithContext(trackId: track.id, sourceContext: "queue")
            if playNext {
                let snapshot = await core.playback()
                if let appended = snapshot.queue.last, appended.position > destination {
                    try await core.moveQueueItem(from: appended.position, to: destination)
                }
                destination += 1
            }
        }
        await refreshPlayback()
    }

    func addSelectionToPlaylist(_ ids: [Int64], playlist: Playlist) async {
        guard let core, !playlist.isSmart else { return }
        do {
            var tracks: [Track] = []
            for id in ids { tracks.append(try await core.track(trackId: id)) }
            try await appendTracks(tracks, to: playlist)
        } catch { errorMessage = String(describing: error) }
    }

    private func appendTracks(_ tracks: [Track], to playlist: Playlist) async throws {
        guard let core else { return }
        let existing = try await core.playlistTracks(playlistId: playlist.id)
        for (offset, track) in tracks.enumerated() {
            _ = try await core.addTrackToPlaylist(playlistId: playlist.id,
                trackId: track.id, position: UInt64(existing.count + offset))
            if let index = playlists.firstIndex(where: { $0.id == playlist.id }) {
                playlists[index].trackCount += 1
            }
        }
    }

    func enqueueRelease(releaseID: Int64, playNext: Bool = false) async {
        guard core != nil else { return }
        do {
            let tracks = try await orderedReleaseTracks(releaseID)
            guard !tracks.isEmpty else {
                errorMessage = "Este álbum não possui faixas."
                return
            }
            try await enqueueTracks(tracks, playNext: playNext)
        } catch {
            errorMessage = String(describing: error)
            await refreshPlayback()
        }
    }

    @discardableResult
    func addRelease(_ releaseID: Int64, to playlist: Playlist) async -> Bool {
        guard core != nil else { return false }
        do {
            let tracks = try await orderedReleaseTracks(releaseID)
            guard !tracks.isEmpty else {
                errorMessage = "Este álbum não possui faixas."
                return false
            }
            try await appendTracks(tracks, to: playlist)
            return true
        } catch {
            errorMessage = String(describing: error)
            return false
        }
    }

    func playNext(trackID: Int64) async {
        guard let core else { return }
        do {
            try await core.addToQueueWithContext(trackId: trackID, sourceContext: "queue")
            let snapshot = await core.playback()
            let destination: UInt64 = snapshot.currentTrack == nil ? 0 : 1
            if let appended = snapshot.queue.last, appended.position > destination {
                try await core.moveQueueItem(from: appended.position, to: destination)
            }
            await refreshPlayback()
        } catch {
            errorMessage = String(describing: error)
            await refreshPlayback()
        }
    }

    func playQueueItem(at position: UInt64) async {
        guard let core, !isChangingTrack else { return }

        isChangingTrack = true
        await finishSeekBeforeChangingTrack()
        defer {
            isChangingTrack = false
            seekRequestID &+= 1
        }

        do {
            playback = try await core.playQueueItem(position: position)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func removeQueueItem(at position: UInt64) async {
        guard let core else { return }

        do {
            try await core.removeFromQueue(position: position)
            await refreshPlayback()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func moveQueueItem(from: UInt64, to: UInt64) {
        guard let core else { return }
        guard !isMovingQueue else { return }
        guard var optimisticSnapshot = playback else { return }
        guard let sourceIndex = optimisticSnapshot.queue.firstIndex(
            where: { $0.position == from }
        ) else { return }
        guard let destinationIndex = optimisticSnapshot.queue.firstIndex(
            where: { $0.position == to }
        ) else { return }
        guard sourceIndex > 0, destinationIndex > 0 else { return }
        guard sourceIndex != destinationIndex else { return }

        isMovingQueue = true

        let previousSnapshot = optimisticSnapshot
        let movedItem = optimisticSnapshot.queue.remove(
            at: sourceIndex
        )

        optimisticSnapshot.queue.insert(
            movedItem,
            at: destinationIndex
        )

        for index in optimisticSnapshot.queue.indices {
            optimisticSnapshot.queue[index].position = UInt64(index)
        }

        // Publica a nova ordem imediatamente e confirma com o core em seguida.
        playback = optimisticSnapshot

        Task {
            defer {
                isMovingQueue = false
            }

            do {
                let revision = seekRequestID
                try await core.moveQueueItem(
                    from: from,
                    to: to
                )

                let confirmedSnapshot = await core.playback()
                publishPlayback(confirmedSnapshot, revision: revision)
            } catch {
                // Roll back only the queue, not a position superseded by a seek.
                if var snapshot = playback {
                    snapshot.queue = previousSnapshot.queue
                    playback = snapshot
                }
                errorMessage = String(describing: error)
            }
        }
    }

    func clearQueue() async {
        guard let core else { return }

        do {
            try await core.clearQueue()
            await refreshPlayback()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func toggleShuffle() async {
        guard let core else { return }

        do {
            let enabled = !(playback?.shuffleEnabled ?? false)
            let revision = seekRequestID
            let snapshot = try await core.setShuffleEnabled(enabled: enabled)
            publishPlayback(snapshot, revision: revision)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func cycleRepeatMode() async {
        guard let core else { return }

        let next: RepeatMode
        switch playback?.repeatMode ?? .none {
        case .none:
            next = .all
        case .all:
            next = .one
        case .one:
            next = .none
        }

        do {
            let revision = seekRequestID
            let snapshot = try await core.setRepeatMode(mode: next)
            publishPlayback(snapshot, revision: revision)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func scheduleHistoryRefresh() {
        guard historyRefreshTask == nil else { return }
        // History conversion and batch reads must not delay playback progress.
        historyRefreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshHistory()
            self.historyRefreshTask = nil
        }
    }

    func refreshHistory() async {
        guard let core else {
            historyRepository.seed(entries: history, tracks: tracks)
            return
        }
        do {
            try await historyRepository.refresh(core: core, catalogRevision: libraryCatalogRevision,
                                                tracksRevision: tracksRevision, knownTracks: tracks)
        } catch is CancellationError {
            // A newer revision or another consumer will retry; keep the snapshot.
        } catch {
            errorMessage = String(describing: error)
        }
    }

    @discardableResult
    func updateSettings(
        crossFade: Bool,
        crossFadeDuration: UInt32,
        normalizeVolume: Bool,
        explicitContent: Bool
    ) async -> Bool {
        guard let core else { return false }
        do {
            var settings = try await core.settings()
            guard self.core === core, !Task.isCancelled else { return false }
            settings.crossFade = crossFade
            settings.crossFadeDuration = crossFadeDuration
            settings.normalizeVolume = normalizeVolume
            settings.explicitContent = explicitContent
            // Preserve settings outside this form.
            try await core.updateSettings(settings: settings)
            guard self.core === core, !Task.isCancelled else { return false }
            publishSettings(settings)
            return true
        } catch {
            guard self.core === core else { return false }
            errorMessage = String(describing: error)
            return false
        }
    }

    func refreshAudioOutputs() async {
        guard let core else { return }
        do {
            let state = try await core.audioOutputState()
            guard self.core === core, !Task.isCancelled else { return }
            publishAudioOutputState(state)
            if let settings = try? await core.settings(), self.core === core, !Task.isCancelled {
                publishSettings(settings)
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func startAudioOutputPolling(using core: DurvaldCore) {
        audioOutputPollingTask?.cancel()
        audioOutputPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.core === core, !Task.isCancelled else { return }
                if let state = try? await core.audioOutputState() {
                    guard self.core === core, !Task.isCancelled else { return }
                    self.publishAudioOutputState(state)
                }
            }
        }
    }

    @discardableResult
    func selectAudioOutputDevice(_ deviceID: String?) async -> Bool {
        guard let core else { return false }
        do {
            let state = try await core.selectAudioOutputDevice(deviceId: deviceID)
            guard self.core === core, !Task.isCancelled else { return false }
            publishAudioOutputState(state)
            if let settings = try? await core.settings(), self.core === core, !Task.isCancelled {
                publishSettings(settings)
            }
            return true
        } catch {
            errorMessage = String(describing: error)
            return false
        }
    }

    @discardableResult
    func updateEqualizer(_ equalizer: EqualizerSettings) async -> Bool {
        guard let core else { return false }
        do {
            var settings = try await core.settings()
            guard self.core === core, !Task.isCancelled else { return false }
            settings.equalizer = equalizer
            try await core.updateSettings(settings: settings)
            guard self.core === core, !Task.isCancelled else { return false }
            publishSettings(settings)
            await refreshEqualizerMetrics()
            return self.core === core && !Task.isCancelled
        } catch {
            guard self.core === core else { return false }
            errorMessage = String(describing: error)
            return false
        }
    }

    func refreshEqualizerMetrics() async {
        guard let core else { return }
        let metrics = await core.equalizerMetrics()
        guard self.core === core, !Task.isCancelled else { return }
        publishEqualizerMetrics(metrics)
    }

    @discardableResult
    func publishSettings(_ settings: Settings) -> Bool {
        guard appSettings != settings else { return false }
        appSettings = settings
        return true
    }

    @discardableResult
    func publishAudioOutputState(_ state: AudioOutputState) -> Bool {
        guard audioOutputState != state else { return false }
        audioOutputState = state
        return true
    }

    @discardableResult
    func publishEqualizerMetrics(_ metrics: EqualizerMetrics) -> Bool {
        guard equalizerMetrics != metrics else { return false }
        equalizerMetrics = metrics
        return true
    }

    // MARK: - Enriquecimento de metadados

    /// Lê a identidade persistida do artista sem iniciar uma consulta remota.
    func artistIdentity(artistId: Int64) async -> ArtistIdentity? {
        guard let core else { return nil }
        do {
            return try await core.artistIdentity(artistId: artistId)
        } catch {
            errorMessage = String(describing: error)
            return nil
        }
    }

    /// Procura candidatos no MusicBrainz. Estados esperados de conectividade são
    /// devolvidos no próprio resultado e não se tornam um erro global da interface.
    func resolveArtistCandidates(artistId: Int64) async -> ArtistIdentityCandidates? {
        guard let core else { return nil }
        do {
            return try await core.resolveArtistCandidates(artistId: artistId)
        } catch {
            errorMessage = String(describing: error)
            return nil
        }
    }

    /// Confirma explicitamente um candidato e devolve a nova geração da identidade.
    func confirmArtistIdentity(artistId: Int64, musicbrainzId: String) async -> ArtistIdentity? {
        guard let core else { return nil }
        do {
            return try await core.confirmArtistIdentity(
                artistId: artistId,
                musicbrainzId: musicbrainzId
            )
        } catch {
            errorMessage = String(describing: error)
            return nil
        }
    }

    /// Remove a confirmação manual e relê o estado resultante do banco local.
    func clearArtistIdentity(artistId: Int64) async -> ArtistIdentity? {
        guard let core else { return nil }
        do {
            try await core.clearArtistIdentity(artistId: artistId)
            return try await core.artistIdentity(artistId: artistId)
        } catch {
            errorMessage = String(describing: error)
            return nil
        }
    }

    /// Retorna os detalhes locais do artista (cache SQLite) para o idioma preferido.
    /// Nunca faz chamadas de rede; seguro chamar mesmo offline ou com enriquecimento desabilitado.
    func artistDetails(artistId: Int64, language: String) async -> ArtistDetails? {
        guard let core else { return nil }
        do {
            return try await core.artistDetails(artistId: artistId, language: language)
        } catch {
            errorMessage = String(describing: error)
            return nil
        }
    }

    /// Lê exclusivamente o snapshot SQLite da discografia remota. Esta chamada
    /// nunca inicia rede e continua disponível com enriquecimento offline.
    func artistDiscography(
        artistId: Int64,
        pageSize: UInt64 = 200,
        offset: UInt64 = 0
    ) async -> ArtistDiscographyPage? {
        guard let core else { return nil }
        do {
            return try await core.artistDiscography(
                artistId: artistId,
                pageSize: pageSize,
                offset: offset
            )
        } catch {
            errorMessage = String(describing: error)
            return nil
        }
    }

    /// Examines every page of the stored MusicBrainz catalog, independently
    /// of how far the user has scrolled in the discography.
    func latestArtistRelease(artistId: Int64) async -> ExternalReleaseGroup? {
        guard let firstPage = await artistDiscography(artistId: artistId) else { return nil }
        var items = firstPage.items
        var page = firstPage
        while let offset = page.nextOffset {
            guard !Task.isCancelled,
                  let next = await artistDiscography(artistId: artistId, offset: offset),
                  next.identityGeneration == firstPage.identityGeneration,
                  next.catalogGeneration == firstPage.catalogGeneration else { return nil }
            items.append(contentsOf: next.items)
            guard next.nextOffset == nil || next.nextOffset! > offset else { return nil }
            page = next
        }
        guard !Task.isCancelled else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.dateComponents([.year, .month, .day], from: Date())
        return ArtistPresentationPolicy.latestRelease(
            in: items,
            today: ArtistPartialDate(year: Int32(today.year!), month: UInt8(today.month!), day: UInt8(today.day!))
        )
    }

    /// Lê exclusivamente o ranking Last.fm persistido pelo core. Abrir a tela
    /// do artista nunca dispara uma consulta ao provedor.
    func artistPopularTracks(artistId: Int64) async -> ArtistPopularTracks? {
        guard let core else { return nil }
        do {
            return try await core.artistPopularTracks(artistId: artistId)
        } catch {
            errorMessage = String(describing: error)
            return nil
        }
    }

    /// Busca, sob demanda, uma edição representativa e sua lista informativa
    /// de faixas. Nenhuma faixa externa é adicionada à biblioteca ou à fila.
    func externalReleaseDetails(
        artistId: Int64,
        releaseGroupMbid: String,
        reportErrors: Bool = true
    ) async -> ExternalReleaseDetails? {
        guard let core else { return nil }
        do {
            return try await core.externalReleaseDetails(
                artistId: artistId,
                releaseGroupMbid: releaseGroupMbid
            )
        } catch {
            if reportErrors {
                errorMessage = String(describing: error)
            }
            return nil
        }
    }

    /// Solicita um lote limitado de discografia e capas. O chamador relê o
    /// snapshot local depois; falhas de rede não removem dados já publicados.
    func refreshArtistCatalog(
        artistId: Int64,
        language: String,
        force: Bool = false
    ) async -> ArtistRefreshResult? {
        guard let core else { return nil }
        do {
            let result = try await core.refreshArtist(
                artistId: artistId,
                request: ArtistRefreshRequest(
                    sections: [.discography, .covers, .popularTracks],
                    language: language,
                    force: force
                )
            )
            let refreshedReleases = try await core.artistReleases(artistId: artistId)
            let refreshedByID = Dictionary(uniqueKeysWithValues: refreshedReleases.map { ($0.id, $0) })
            releases = releases.map { refreshedByID[$0.id] ?? $0 }
            metadataRevision &+= 1
            return result
        } catch {
            errorMessage = String(describing: error)
            return nil
        }
    }

    /// Aplica imediatamente os metadados do catálogo MusicBrainz armazenado e
    /// publica a coleção local atualizada. Não depende de rede.
    func syncArtistReleaseMetadata(artistId: Int64) async -> [Release]? {
        guard let core else { return nil }
        do {
            let refreshedReleases = try await core.syncArtistReleaseMetadata(artistId: artistId)
            let refreshedByID = Dictionary(uniqueKeysWithValues: refreshedReleases.map { ($0.id, $0) })
            releases = releases.map { refreshedByID[$0.id] ?? $0 }
            metadataRevision &+= 1
            return refreshedReleases
        } catch {
            errorMessage = String(describing: error)
            return nil
        }
    }

    func syncReleaseMetadata(artistId: Int64, releaseId: Int64) async -> Release? {
        guard let releases = await syncArtistReleaseMetadata(artistId: artistId) else {
            return nil
        }
        return releases.first(where: { $0.id == releaseId })
    }

    /// Atualiza toda a biblioteca em série para respeitar os limites dos
    /// provedores. O cache local é sempre aplicado; rede só é usada quando o
    /// enriquecimento está habilitado e fora do modo offline.
    func updateLibraryMetadata(refreshRemote: Bool = false) async {
        guard let core, !isUpdatingLibraryMetadata else { return }

        isUpdatingLibraryMetadata = true
        metadataUpdateCompleted = 0
        metadataUpdateTotal = artists.count
        defer { isUpdatingLibraryMetadata = false }

        let shouldRefreshRemote = refreshRemote
            && enrichmentSettings?.enabled == true
            && enrichmentSettings?.offline == false
        var refreshedByID: [Int64: Release] = [:]

        for artist in artists {
            guard !Task.isCancelled else { break }
            do {
                if shouldRefreshRemote {
                    _ = try await core.refreshArtist(
                        artistId: artist.id,
                        request: ArtistRefreshRequest(
                            sections: [.profile, .portrait, .discography, .popularTracks, .similarArtists],
                            language: enrichmentSettings?.preferredLanguage ?? "pt",
                            force: false
                        )
                    )
                }
                let artistReleases = try await core.syncArtistReleaseMetadata(artistId: artist.id)
                for release in artistReleases {
                    refreshedByID[release.id] = release
                }
            } catch {
                // Continue with the remaining artists; one unavailable provider
                // must not prevent cached metadata from updating the library.
                print("Durvald: falha ao atualizar metadados de \(artist.name): \(error)")
            }
            metadataUpdateCompleted += 1
        }

        if !refreshedByID.isEmpty {
            releases = releases.map { refreshedByID[$0.id] ?? $0 }
            metadataRevision &+= 1
        }
    }

    /// Atualiza perfil/retrato e preserva tanto o diagnóstico por seção quanto
    /// a releitura do cache local. Falha remota não apaga conteúdo publicado.
    func refreshArtistDetailsWithResult(
        artistId: Int64,
        language: String,
        force: Bool = false
    ) async -> (details: ArtistDetails?, result: ArtistRefreshResult?) {
        guard let core else { return (nil, nil) }
        do {
            let result = try await core.refreshArtist(
                artistId: artistId,
                request: ArtistRefreshRequest(
                    sections: [.profile, .portrait, .similarArtists],
                    language: language,
                    force: force
                )
            )
            let details = try await core.artistDetails(artistId: artistId, language: language)
            return (details, result)
        } catch {
            errorMessage = String(describing: error)
            return (try? await core.artistDetails(artistId: artistId, language: language), nil)
        }
    }

    /// Compatibilidade para chamadores que precisam apenas do snapshot local.
    func refreshArtistDetails(artistId: Int64, language: String) async -> ArtistDetails? {
        await refreshArtistDetailsWithResult(artistId: artistId, language: language).details
    }

    /// Atualiza somente as seções solicitadas; usado pelos retries contextuais.
    func refreshArtistSections(
        artistId: Int64,
        language: String,
        sections: [ArtistRefreshSection],
        force: Bool = false
    ) async -> ArtistRefreshResult? {
        guard let core, !sections.isEmpty else { return nil }
        do {
            return try await core.refreshArtist(
                artistId: artistId,
                request: ArtistRefreshRequest(
                    sections: sections,
                    language: language,
                    force: force
                )
            )
        } catch {
            errorMessage = String(describing: error)
            return nil
        }
    }

    /// Persiste novas preferências de enriquecimento e atualiza a propriedade observável.
    /// Não inicia nenhuma operação de rede.
    @discardableResult
    func configureEnrichment(_ settings: EnrichmentSettings) async -> Bool {
        guard let core else { return false }
        do {
            try await core.configureEnrichment(settings: settings)
            guard self.core === core, !Task.isCancelled else { return false }
            enrichmentSettings = settings
            return true
        } catch {
            guard self.core === core else { return false }
            errorMessage = String(describing: error)
            return false
        }
    }

    deinit {
        if let activeCore = embeddedCore { Task { try? await activeCore.detachEmbeddedPlaybackHost() } }
        historyRefreshTask?.cancel()
        playbackPollingTask?.cancel()
        scanProgressPollingTask?.cancel()
        libraryFileWatcher?.stop()
        libraryWatchDebounceTask?.cancel()
        libraryWatcherReconnectTask?.cancel()
        periodicLibraryRescanTask?.cancel()
        deferredInitializationTask?.cancel()
        audioOutputPollingTask?.cancel()
        seekTask?.cancel()
        activeLibraryScopes.forEach { $0.stopAccessingSecurityScopedResource() }
    }
}
