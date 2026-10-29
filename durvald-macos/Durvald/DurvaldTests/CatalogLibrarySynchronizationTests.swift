import XCTest
@testable import Durvald

@MainActor
final class CatalogLibrarySynchronizationTests: XCTestCase {
    private func withLibrary(_ operation: (DurvaldCore, DurvaldCoreStore) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-sync-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let core = try await open(config: CoreConfig(
            databasePath: root.appendingPathComponent("library.sqlite").path,
            appSupportDir: root.path,
            coversDir: root.appendingPathComponent("covers").path,
            keychainService: "catalog-sync-\(UUID())"
        ))
        let store = DurvaldCoreStore(core: core)
        await store.refreshLibraryCatalog()
        XCTAssertTrue(store.artists.isEmpty)
        try await operation(core, store)
    }

    private var artist: CatalogEntry {
        CatalogEntry(reference: CatalogReference(provider: "musicbrainz", kind: .artist,
                                                  id: "11111111-1111-4111-8111-111111111111"),
                     title: "Artista salvo em Explorar", artistCredit: nil, versionLabel: nil,
                     durationSeconds: nil, canonicalUrl: nil)
    }

    func testSavingArtistPublishesItToTheExistingStoreAndArtistListingWithoutRestart() async throws {
        try await withLibrary { core, store in
            // Exercise the same native loader used by the Explore details screen.
            let loader = try XCTUnwrap(store.makeCatalogDetailLoader())
            let revision = store.libraryCatalogRevision
            let artistsRevision = store.artistsRevision
            let saved = try await loader.save(self.artist)
            let id = try XCTUnwrap(saved.localArtistId)
            XCTAssertEqual(store.artists.map(\.id), [id])
            XCTAssertEqual(store.loadedArtist(id: id)?.name, self.artist.title)
            XCTAssertGreaterThan(store.artistsRevision, artistsRevision)
            XCTAssertGreaterThan(store.libraryCatalogRevision, revision)
            let listing = ArtistListingSnapshot.build(artists: store.artists, releases: store.releases,
                                                      localIDs: [], key: .init(), recency: [:])
            XCTAssertEqual(listing.items.map(\.id), [id])
            let repeated = try await loader.save(self.artist)
            XCTAssertEqual(repeated.localArtistId, id)
            XCTAssertEqual(store.artists.map(\.id), [id])
            let persisted = try await core.artists()
            XCTAssertEqual(store.artists, persisted)
            await loader.close()
        }
    }

    func testFollowingNewArtistAlsoPublishesTheMaterializedArtist() async throws {
        try await withLibrary { core, store in
            let loader = try XCTUnwrap(store.makeCatalogDetailLoader())
            let saved = try await loader.follow(self.artist, followed: true)
            let id = try XCTUnwrap(saved.localArtistId)
            XCTAssertEqual(store.artists.map(\.id), [id])
            let followed = try await core.followedArtists()
            XCTAssertEqual(followed.map { $0.artist.id }, [id])
            _ = try await loader.follow(self.artist, followed: false)
            XCTAssertEqual(store.artists.map(\.id), [id], "Unfollowing must preserve the saved artist")
            await loader.close()
        }
    }

    func testListenLaterPublishesItsNewArtistAndFailedSaveDoesNotPublishAChange() async throws {
        try await withLibrary { core, store in
            let loader = try XCTUnwrap(store.makeCatalogDetailLoader())
            let release = CatalogEntry(reference: CatalogReference(provider: "musicbrainz", kind: .releaseGroup,
                                                                   id: "22222222-2222-4222-8222-222222222222"),
                                       title: "Álbum para ouvir depois", artistCredit: self.artist.title,
                                       versionLabel: nil, durationSeconds: nil, canonicalUrl: nil)
            try await loader.listen(release, artist: self.artist)
            XCTAssertEqual(store.artists.map(\.name), [self.artist.title])
            let listening = try await core.listenList()
            XCTAssertEqual(listening.count, 1)
            let before = store.artists
            let revision = store.libraryCatalogRevision
            var invalid = self.artist
            invalid.title = " "
            do {
                _ = try await loader.save(invalid)
                XCTFail("Invalid input must not be saved")
            } catch CoreError.InvalidInput { }
            XCTAssertEqual(store.artists, before)
            XCTAssertEqual(store.libraryCatalogRevision, revision)
            await loader.close()
        }
    }
}
