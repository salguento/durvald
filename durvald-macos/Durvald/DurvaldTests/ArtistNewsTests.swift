import XCTest
@testable import Durvald

@MainActor
final class ArtistNewsTests: XCTestCase {
    private func followed(_ id: Int64) -> FollowedArtist {
        FollowedArtist(artist: Artist(id: id, name: "Artista \(id)"),
            identity: ArtistIdentity(artistId: id, status: .resolved, musicbrainzId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                generation: 0, origin: .manual, confirmedMusicbrainzId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", conflictingTags: false),
            generation: 1, followedAt: 1, lastCheckedAt: nil, lastSuccessAt: nil, nextRefreshAt: nil, status: nil, catalogComplete: true)
    }
    func testRefreshIsBoundedAndCancellationStopsRemainingArtists() async {
        let core = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        core.followedArtistsResult = (1...12).map { followed(Int64($0)) }
        var calls: [Int64] = []
        var pending: CheckedContinuation<Void, Never>?
        core.newsRefreshHandler = { id, _ in
            calls.append(id)
            await withCheckedContinuation { pending = $0 }
            return ArtistRefreshResult(artistId: id, identityGeneration: 0, sections: [])
        }
        let state = ArtistNewsRepository()
        await state.initialize(core: core, legacyIDs: "1,2")
        state.refresh(core: core)
        while pending == nil { await Task.yield() }
        state.cancelRefresh(); pending?.resume()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(calls, [1]); XCTAssertFalse(state.updating)
        core.newsRefreshHandler = { id, _ in
            calls.append(id)
            return ArtistRefreshResult(artistId: id, identityGeneration: 0, sections: [])
        }
        calls = []; state.refresh(core: core)
        while state.updating { await Task.yield() }
        XCTAssertEqual(calls.count, 8)
    }
    func testOldSearchCannotReplaceCurrentResultsAndErrorsPreserveCache() async {
        let core = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        let state = ArtistNewsRepository()
        await state.initialize(core: core, legacyIDs: "")
        var pending: CheckedContinuation<ArtistNewsPage, Never>?
        core.newsHandler = { query in
            if query.query == "old" { return await withCheckedContinuation { pending = $0 } }
            return ArtistNewsPage(items: [], followedArtists: [self.followed(2)], total: 7, nextOffset: nil)
        }
        state.query = "old"
        let old = Task { await state.load(core: core) }
        while pending == nil { await Task.yield() }
        state.query = "current"; await state.load(core: core)
        pending?.resume(returning: ArtistNewsPage(items: [], followedArtists: [], total: 99, nextOffset: nil))
        await old.value
        XCTAssertEqual(state.total, 7); XCTAssertEqual(state.followed.count, 1)
        core.newsHandler = { _ in throw CocoaError(.fileReadUnknown) }
        await state.load(core: core)
        XCTAssertEqual(state.total, 7); XCTAssertNotNil(state.error)
    }
    func testRealCoreFeedPersistsSeenAndFollowPreferencesWithoutNetwork() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let core = try await RatingIntegrationFixture.openCore(directory: directory)
        try RatingIntegrationFixture.seedArtistNews(directory: directory)
        let query = ArtistNewsQuery(query: "", unseenOnly: false, kind: nil, sortBy: "date", descending: true, offset: 0, limit: 40)
        let first = try await core.artistNews(query: query)
        XCTAssertEqual(first.total, 2)
        try await core.setArtistNewsSeen(releaseGroupMbid: first.items[0].id, seen: true)
        let refresh = try await core.refreshArtistNews(artistId: 1, force: true)
        XCTAssertTrue(refresh.sections.contains { $0.status == .disabled })
        let state = ArtistNewsRepository()
        await state.initialize(core: core, legacyIDs: "1")
        await state.load(core: core)
        XCTAssertEqual(state.items.filter(\.seen).count, 1)
        let reopened = try await open(config: RatingIntegrationFixture.config(directory: directory))
        let saved = try await reopened.artistNews(query: query)
        XCTAssertEqual(saved.items.filter(\.seen).count, 1)
        try await core.setArtistFollowed(artistId: 1, followed: false)
        try await core.importFollowedArtists(artistIds: [1])
        let unfollowed = try await reopened.artistNews(query: query)
        XCTAssertEqual(unfollowed.total, 0)
        XCTAssertTrue(unfollowed.followedArtists.isEmpty)
    }
}
