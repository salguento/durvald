import Foundation
import Observation

@MainActor
@Observable
final class ArtistPresentation {
    var lookupRevision: UInt64 = 0
    var lookups = PreparedLibraryListing(ArtistLookupSnapshot())
    var tracks: [Track] = [] {
        didSet { lookupRevision &+= 1 }
    }
    var albums: [Release] = [] {
        didSet { lookupRevision &+= 1 }
    }
    var details: ArtistDetails?
    var identity: ArtistIdentity?
    var identityCandidates: ArtistIdentityCandidates?
    var discographyItems: [ExternalReleaseGroup] = [] {
        didSet { lookupRevision &+= 1 }
    }
    var latestRelease: ExternalReleaseGroup?
    var discographyPageRevision: UInt64 = 0
    var discographyPage: ArtistDiscographyPage? {
        didSet { discographyPageRevision &+= 1 }
    }
    var popularTracks: ArtistPopularTracks?
    var popularTrackArtworkIDs: [String: String] = [:]
    var popularTrackReleaseGroupIDs: [String: String] = [:]
    var releaseDetailsByGroupID: [String: ExternalReleaseDetails] = [:] {
        didSet { lookupRevision &+= 1 }
    }
    var isCachingReleaseTracks = false
    var similarArtistArtworkIDs: [Int64: String] = [:]
    var catalogRefreshResults: [ArtistRefreshSectionResult] = []
    var isRefreshingCatalog = false
    var isLoadingMoreDiscography = false
    var isIdentityPickerPresented = false
    var isLoadingIdentityCandidates = false
    var isSavingIdentity = false
    var selectedCandidateID: String?
    var isLoading = true
    struct Request: Equatable {
        let artistID: Int64
        let coreID: ObjectIdentifier?
        let language: String
    }

    private struct Context {
        let artistID: Int64
        let store: DurvaldCoreStore
        let language: String
        let core: DurvaldCore?
    }
    @ObservationIgnored private var context: Context?
    @ObservationIgnored private var generation = UUID()

    private func isCurrent(_ request: UUID, _ context: Context) -> Bool {
        !Task.isCancelled && generation == request && context.store.core === context.core
    }

    func load(artistID: Int64, using store: DurvaldCoreStore, language: String,
              informationOnly: Bool = false) async {
        let request = UUID()
        generation = request
        let context = Context(artistID: artistID, store: store, language: language, core: store.core)
        self.context = context
        defer { if generation == request { isLoading = false } }

        isLoading = true
        tracks = []
        albums = []
        isRefreshingCatalog = false
        isLoadingMoreDiscography = false
        isLoadingIdentityCandidates = false
        isSavingIdentity = false
        isIdentityPickerPresented = false
        details = nil
        identity = nil
        identityCandidates = nil
        selectedCandidateID = nil
        discographyItems = []
        latestRelease = nil
        discographyPage = nil
        popularTracks = nil
        popularTrackArtworkIDs = [:]
        popularTrackReleaseGroupIDs = [:]
        releaseDetailsByGroupID = [:]
        isCachingReleaseTracks = false
        similarArtistArtworkIDs = [:]
        catalogRefreshResults = []
        if informationOnly {
            async let loadedAlbums = store.releases(forArtistID: artistID)
            async let loadedDetails = store.artistDetails(artistId: artistID,
                language: Locale.current.language.languageCode?.identifier ?? "en")
            async let loadedIdentity = store.artistIdentity(artistId: artistID)
            let result = await (loadedAlbums, loadedDetails, loadedIdentity)
            guard isCurrent(request, context) else { return }
            albums = result.0
            details = result.1
            identity = result.2
            return
        }
        async let loadedTracks = store.tracks(forArtistID: artistID)
        async let loadedAlbums = store.releases(forArtistID: artistID)
        async let loadedIdentity = store.artistIdentity(artistId: artistID)
        async let loadedDetails = store.artistDetails(
            artistId: artistID,
            language: language
        )
        async let loadedDiscography = store.artistDiscography(artistId: artistID)
        async let loadedPopularTracks = store.artistPopularTracks(artistId: artistID)
        let (resolvedTracks, resolvedAlbums, resolvedIdentity, resolvedDetails, resolvedDiscography, resolvedPopularTracks) = await (
            loadedTracks,
            loadedAlbums,
            loadedIdentity,
            loadedDetails,
            loadedDiscography,
            loadedPopularTracks
        )
        guard isCurrent(request, context) else { return }
        tracks = resolvedTracks.sorted {
            if $0.release != $1.release {
                return $0.release.localizedStandardCompare($1.release) == .orderedAscending
            }
            if $0.discNumber != $1.discNumber { return $0.discNumber < $1.discNumber }
            if $0.trackNumber != $1.trackNumber { return $0.trackNumber < $1.trackNumber }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        albums = resolvedAlbums.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        identity = resolvedIdentity
        popularTracks = resolvedPopularTracks
        details = resolvedDetails
        if let resolvedDiscography {
            applyDiscographyPage(resolvedDiscography, reset: true)
        }
        isLoading = false
        if let synchronizedAlbums = await store.syncArtistReleaseMetadata(artistId: artistID) {
            guard isCurrent(request, context) else { return }
            albums = synchronizedAlbums.sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }
        guard isCurrent(request, context) else { return }
        await cacheReleaseTracksAndResolvePopularArtwork()
    }

    func reconcileReleases(using store: DurvaldCoreStore) {
        albums = albums.map { store.loadedRelease(id: $0.id) ?? $0 }
    }

    func presentIdentityPicker() {
        selectedCandidateID = nil
        if identity?.status != .resolved { identityCandidates = nil }
        isIdentityPickerPresented = true
    }

    func loadLatestRelease() async {
        guard let context, isCurrent(generation, context) else { return }
        let request = generation
        guard discographyPage != nil else { latestRelease = nil; return }
        let release = await context.store.latestArtistRelease(artistId: context.artistID)
        guard isCurrent(request, context) else { return }
        latestRelease = release
    }

    func prepareLookups() async {
        guard let context else { return }
        let key = LibraryListingKey(storeID: ObjectIdentifier(context.store), payloadRevision: lookupRevision,
                                   scope: String(context.artistID))
        let payload = (tracks, albums, discographyItems, releaseDetailsByGroupID)
        await lookups.prepare(key: key, payload: payload) { payload in
            ArtistLookupSnapshot.build(tracks: payload.0, albums: payload.1, discography: payload.2, details: payload.3)
        }
    }

    func refreshLocalLibrary(using store: DurvaldCoreStore, artistID: Int64) async {
        guard let context, context.artistID == artistID, context.store === store else { return }
        let request = generation
        async let loadedTracks = store.tracks(forArtistID: artistID)
        async let loadedAlbums = store.releases(forArtistID: artistID)
        let result = await (loadedTracks, loadedAlbums)
        guard isCurrent(request, context) else { return }
        tracks = result.0
        albums = result.1
    }

    func loadIdentityCandidates() async {
        guard let context, isCurrent(generation, context) else { return }
        let request = generation
        let store = context.store
        let artistID = context.artistID

        guard !isLoadingIdentityCandidates, !isSavingIdentity else { return }
        isLoadingIdentityCandidates = true
        defer { if generation == request { isLoadingIdentityCandidates = false } }

        let result = await store.resolveArtistCandidates(artistId: artistID)
        guard isCurrent(request, context) else { return }
        guard let result else { identityCandidates = nil; return }
        identity = result.identity
        identityCandidates = result
        if let selectedCandidateID,
           !result.candidates.contains(where: { $0.musicbrainzId == selectedCandidateID }) {
            self.selectedCandidateID = nil
        }
    }

    func confirmSelectedIdentity() async {
        guard let context, isCurrent(generation, context) else { return }
        let request = generation
        let store = context.store
        let artistID = context.artistID

        guard let selectedCandidateID, !isSavingIdentity else { return }
        isSavingIdentity = true
        defer { if generation == request { isSavingIdentity = false } }

        guard let confirmed = await store.confirmArtistIdentity(
            artistId: artistID,
            musicbrainzId: selectedCandidateID
        ) else { return }

        guard isCurrent(request, context) else { return }
        identity = confirmed
        identityCandidates = nil
        self.selectedCandidateID = nil
        isIdentityPickerPresented = false
        await reloadCachedEnrichment()
        guard isCurrent(request, context) else { return }
        await refreshEnrichment()
    }

    func clearIdentity() async {
        guard let context, isCurrent(generation, context) else { return }
        let request = generation
        let store = context.store
        let artistID = context.artistID

        guard !isSavingIdentity else { return }
        isSavingIdentity = true
        defer { if generation == request { isSavingIdentity = false } }

        guard let cleared = await store.clearArtistIdentity(artistId: artistID) else {
            isSavingIdentity = false
            return
        }
        guard isCurrent(request, context) else { return }
        identity = cleared
        identityCandidates = nil
        selectedCandidateID = nil
        await reloadCachedEnrichment()
        guard isCurrent(request, context) else { return }
        isSavingIdentity = false

        if cleared.status != .resolved {
            await loadIdentityCandidates()
        }
    }

    func reloadCachedEnrichment() async {
        guard let context, isCurrent(generation, context) else { return }
        let request = generation
        let store = context.store
        let artistID = context.artistID
        let language = context.language

        async let cachedDetails = store.artistDetails(
            artistId: artistID,
            language: language
        )
        async let cachedDiscography = store.artistDiscography(artistId: artistID)
        async let cachedPopularTracks = store.artistPopularTracks(artistId: artistID)
        let (newDetails, newDiscography, newPopularTracks) = await (cachedDetails, cachedDiscography, cachedPopularTracks)
        guard isCurrent(request, context) else { return }
        popularTracks = newPopularTracks
        details = newDetails
        catalogRefreshResults = []
        if let newDiscography {
            applyDiscographyPage(newDiscography, reset: true)
        } else {
            discographyItems = []
            discographyPage = nil
        }
    }

    func refreshEnrichment(force: Bool = false) async {
        guard let context, isCurrent(generation, context) else { return }
        let request = generation
        let store = context.store
        let artistID = context.artistID
        let language = context.language

        guard !isRefreshingCatalog else { return }
        isRefreshingCatalog = true
        defer { if generation == request { isRefreshingCatalog = false } }

        async let refreshedDetails = store.refreshArtistDetailsWithResult(
            artistId: artistID,
            language: language,
            force: force
        )
        async let refreshedCatalog = store.refreshArtistCatalog(
            artistId: artistID,
            language: language,
            force: force
        )
        let (detailsRefresh, catalogResult) = await (refreshedDetails, refreshedCatalog)
        guard isCurrent(request, context) else { return }
        let newPopularTracks = await store.artistPopularTracks(artistId: artistID)
        guard isCurrent(request, context) else { return }
        popularTracks = newPopularTracks
        if let newDetails = detailsRefresh.details {
            details = newDetails
        }
        catalogRefreshResults = mergeRefreshResults(
            detailsRefresh.result?.sections ?? [],
            catalogResult?.sections ?? []
        )
        if catalogResult != nil,
           let refreshedPage = await store.artistDiscography(artistId: artistID) {
            guard isCurrent(request, context) else { return }
            applyDiscographyPage(refreshedPage, reset: true)
        }
    }

    func retryEnrichmentSection(_ section: ArtistRefreshSection) async {
        guard let context, isCurrent(generation, context) else { return }
        let request = generation
        let store = context.store
        let artistID = context.artistID
        let language = context.language

        guard !isRefreshingCatalog else { return }
        isRefreshingCatalog = true
        defer { if generation == request { isRefreshingCatalog = false } }
        guard let result = await store.refreshArtistSections(
            artistId: artistID, language: language,
            sections: [section], force: true
        ) else { return }
        guard isCurrent(request, context) else { return }
        mergeRefreshResults(result.sections)
        switch section {
        case .profile, .portrait, .similarArtists:
            let newDetails = await store.artistDetails(artistId: artistID, language: language)
            guard isCurrent(request, context) else { return }
            details = newDetails

        case .discography, .covers:
            if let page = await store.artistDiscography(artistId: artistID) {
                guard isCurrent(request, context) else { return }
                applyDiscographyPage(page, reset: true)
                await cacheReleaseTracksAndResolvePopularArtwork()
            }

        case .popularTracks:
            let newPopularTracks = await store.artistPopularTracks(artistId: artistID)
            guard isCurrent(request, context) else { return }
            popularTracks = newPopularTracks
        }
    }

    func applyDiscographyPage(_ page: ArtistDiscographyPage, reset: Bool) {
        if reset || discographyPage?.catalogGeneration != page.catalogGeneration {
            discographyItems = page.items
        } else {
            let known = Set(discographyItems.map(\.musicbrainzId))
            discographyItems.append(contentsOf: page.items.filter { !known.contains($0.musicbrainzId) })
        }
        discographyPage = page
    }

    func loadMoreDiscography(from offset: UInt64) async {
        guard let context, isCurrent(generation, context) else { return }
        let request = generation
        let store = context.store
        let artistID = context.artistID

        guard !isLoadingMoreDiscography else { return }
        isLoadingMoreDiscography = true
        defer { if generation == request { isLoadingMoreDiscography = false } }
        if let page = await store.artistDiscography(artistId: artistID, offset: offset) {
            guard isCurrent(request, context) else { return }
            applyDiscographyPage(page, reset: false)
            await cacheReleaseTracksAndResolvePopularArtwork()
        }
    }

    func refreshCatalog() async {
        guard let context, isCurrent(generation, context) else { return }
        let request = generation
        let store = context.store
        let artistID = context.artistID
        let language = context.language

        guard !isRefreshingCatalog else { return }
        isRefreshingCatalog = true
        defer { if generation == request { isRefreshingCatalog = false } }
        let result = await store.refreshArtistCatalog(
            artistId: artistID,
            language: language
        )
        guard isCurrent(request, context) else { return }
        let newPopularTracks = await store.artistPopularTracks(artistId: artistID)
        guard isCurrent(request, context) else { return }
        popularTracks = newPopularTracks
        if let result {
            guard isCurrent(request, context) else { return }
            mergeRefreshResults(result.sections)
        }
        if result != nil, let page = await store.artistDiscography(artistId: artistID) {
            guard isCurrent(request, context) else { return }
            applyDiscographyPage(page, reset: true)
            let newAlbums = await store.releases(forArtistID: artistID).sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            guard isCurrent(request, context) else { return }
            albums = newAlbums
            await cacheReleaseTracksAndResolvePopularArtwork()
        }
    }

    func loadSimilarArtistPortrait(_ similar: SimilarArtist) async {
        guard let context, isCurrent(generation, context) else { return }
        let request = generation
        let store = context.store
        let language = context.language

        if let managedPath = similar.portrait?.managedPath {
            guard isCurrent(request, context) else { return }
            similarArtistArtworkIDs[similar.artistId] = managedPath
            return
        }
        guard store.enrichmentSettings?.enabled == true,
              store.enrichmentSettings?.offline == false else { return }
        _ = await store.refreshArtistSections(
            artistId: similar.artistId,
            language: language,
            sections: [.portrait]
        )
        guard !Task.isCancelled,
              let refreshed = await store.artistDetails(
                  artistId: similar.artistId,
                  language: language
              ),
              let managedPath = refreshed.portrait?.managedPath else { return }
        guard isCurrent(request, context) else { return }
        similarArtistArtworkIDs[similar.artistId] = managedPath
    }

    func cacheReleaseTracksAndResolvePopularArtwork() async {
        guard let context, isCurrent(generation, context) else { return }
        let request = generation
        let store = context.store
        let artistID = context.artistID

        guard !isCachingReleaseTracks else { return }
        let pending = discographyItems.filter {
            releaseDetailsByGroupID[$0.musicbrainzId] == nil
        }
        guard !pending.isEmpty else {
            rebuildPopularTrackArtworkIDs()
            return
        }
        isCachingReleaseTracks = true
        defer { if generation == request { isCachingReleaseTracks = false } }

        for release in pending {
            guard isCurrent(request, context) else { return }
            guard let releaseDetails = await store.externalReleaseDetails(
                artistId: artistID,
                releaseGroupMbid: release.musicbrainzId,
                reportErrors: false
            ) else { continue }
            guard isCurrent(request, context) else { return }
            releaseDetailsByGroupID[release.musicbrainzId] = releaseDetails
            rebuildPopularTrackArtworkIDs()
        }
    }

    func rebuildPopularTrackArtworkIDs() {
        var artworkByTitle: [String: String] = [:]
        var releaseGroupByTitle: [String: String] = [:]
        for release in discographyItems {
            guard let details = releaseDetailsByGroupID[release.musicbrainzId] else { continue }
            for track in details.tracks {
                for key in PopularTrackTitle.keys(track.title) {
                    if releaseGroupByTitle[key] == nil {
                        releaseGroupByTitle[key] = release.musicbrainzId
                    }
                    if let artworkID = release.artwork?.image.managedPath,
                       artworkByTitle[key] == nil {
                        artworkByTitle[key] = artworkID
                        releaseGroupByTitle[key] = release.musicbrainzId
                    }
                }
            }
        }
        popularTrackArtworkIDs = artworkByTitle
        popularTrackReleaseGroupIDs = releaseGroupByTitle
    }

    private func mergeRefreshResults(_ groups: [ArtistRefreshSectionResult]...) -> [ArtistRefreshSectionResult] {
        var merged: [ArtistRefreshSectionResult] = []
        for result in groups.flatMap({ $0 }) {
            if let index = merged.firstIndex(where: { $0.section == result.section }) {
                merged[index] = result
            } else {
                merged.append(result)
            }
        }
        return merged
    }

    private func mergeRefreshResults(_ incoming: [ArtistRefreshSectionResult]) {
        catalogRefreshResults = mergeRefreshResults(catalogRefreshResults, incoming)
    }

}
