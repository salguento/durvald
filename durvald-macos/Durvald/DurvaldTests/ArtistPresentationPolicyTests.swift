import XCTest
@testable import Durvald

final class ArtistPresentationPolicyTests: XCTestCase {
    func testPortraitPrefersSelectedLastFmThenCommonsBeforeLocalArtwork() {
        XCTAssertEqual(
            ArtistPresentationPolicy.portraitArtworkID(
                portrait: portrait(provider: .lastFm, path: "/managed/lastfm.jpg"),
                localArtworkIDs: ["/local/album.jpg"]
            ),
            "/managed/lastfm.jpg"
        )
        XCTAssertEqual(
            ArtistPresentationPolicy.portraitArtworkID(
                portrait: portrait(provider: .commons, path: "/managed/commons.jpg"),
                localArtworkIDs: ["/local/album.jpg"]
            ),
            "/managed/commons.jpg"
        )
        XCTAssertEqual(
            ArtistPresentationPolicy.portraitArtworkID(
                portrait: nil,
                localArtworkIDs: [nil, "/local/album.jpg"]
            ),
            "/local/album.jpg"
        )
    }

    func testBiographyUsesOverrideThenWikipediaThenLastFm() {
        let wikipedia = biographySource(provider: .wikipedia, text: "Wikipedia biography")
        let lastFm = biographySource(provider: .lastFm, text: "Last.fm biography")

        var selection = ArtistPresentationPolicy.biography(
            overrides: [ArtistFieldOverride(field: .biography, language: "pt", value: "Manual biography")],
            sources: [lastFm, wikipedia]
        )
        XCTAssertEqual(selection?.text, "Manual biography")
        XCTAssertNil(selection?.source)

        selection = ArtistPresentationPolicy.biography(
            overrides: [],
            sources: [lastFm, wikipedia]
        )
        XCTAssertEqual(selection?.text, "Wikipedia biography")
        XCTAssertEqual(selection?.source?.provider, .wikipedia)

        selection = ArtistPresentationPolicy.biography(overrides: [], sources: [lastFm])
        XCTAssertEqual(selection?.text, "Last.fm biography")
        XCTAssertEqual(selection?.source?.provider, .lastFm)
    }

    func testExplicitlyClearedBiographyDoesNotFallBackToProviders() {
        let selection = ArtistPresentationPolicy.biography(
            overrides: [ArtistFieldOverride(field: .biography, language: "pt", value: nil)],
            sources: [biographySource(provider: .wikipedia, text: "Provider biography")]
        )
        XCTAssertNil(selection)
    }

    func testPopularRankingUsesLastFmThenLibraryThenEmpty() {
        let external = ArtistPopularTrack(
            rank: 1,
            title: "External",
            musicbrainzId: nil,
            playCount: 10,
            listeners: 5,
            lastfmUrl: "https://www.last.fm/music/Artist/_/External",
            localTrackId: nil
        )
        let snapshot = ArtistPopularTracks(
            artistId: 1,
            identityGeneration: 1,
            items: [external],
            fetchedAt: 1,
            expiresAt: 2,
            stale: false
        )
        let local = track(id: 7, playCount: 3)

        switch ArtistPresentationPolicy.popularRanking(lastFm: snapshot, localTracks: [local]) {
        case let .lastFm(items):
            XCTAssertEqual(items, [external])
        default:
            XCTFail("Expected the Last.fm ranking")
        }

        switch ArtistPresentationPolicy.popularRanking(lastFm: nil, localTracks: [local]) {
        case let .library(items):
            XCTAssertEqual(items, [local])
        default:
            XCTFail("Expected the library ranking")
        }

        if case .empty = ArtistPresentationPolicy.popularRanking(lastFm: nil, localTracks: []) {
            // Expected.
        } else {
            XCTFail("Expected an empty ranking")
        }
    }

    private func portrait(provider: EnrichmentProvider, path: String) -> ArtistImageReference {
        ArtistImageReference(
            provider: provider,
            providerId: "portrait",
            sourceUrl: "https://example.test/portrait",
            managedPath: path,
            width: nil,
            height: nil,
            attribution: attribution,
            fetchedAt: 1,
            expiresAt: 2,
            stale: false
        )
    }

    private func biographySource(
        provider: EnrichmentProvider,
        text: String
    ) -> ArtistProfileSource {
        ArtistProfileSource(
            provider: provider,
            language: "pt",
            profile: ArtistProfile(
                entityKind: .unknown,
                birthDate: nil,
                birthPlace: nil,
                formationDate: nil,
                formationPlace: nil,
                originPlace: nil,
                biography: text,
                attribution: attribution
            ),
            fetchedAt: 1,
            expiresAt: 2,
            stale: false
        )
    }

    private var attribution: EnrichmentAttribution {
        EnrichmentAttribution(
            sourceUrl: "https://example.test/source",
            author: nil,
            licenseName: nil,
            licenseUrl: nil,
            revision: nil
        )
    }

    private func track(id: Int64, playCount: UInt64) -> Track {
        Track(
            id: id,
            title: "Local",
            artist: "Artist",
            artistId: 1,
            release: "Album",
            releaseId: 1,
            trackNumber: 1,
            discNumber: 1,
            durationSeconds: 180,
            filePath: "/music/local.flac",
            artworkId: nil,
            bitrate: nil,
            sampleRate: nil,
            bitDepth: nil,
            playCount: playCount,
            lastPlayed: nil,
            rating: nil,
            isFavorite: false,
            isHidden: false,
            suggestLess: false
        )
    }
}
