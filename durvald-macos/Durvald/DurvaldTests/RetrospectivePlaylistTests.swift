import Foundation
import XCTest
@testable import Durvald

@MainActor
final class RetrospectivePlaylistTests: XCTestCase {
    private var draft: RetrospectivePlaylistDraft {
        RetrospectivePlaylistDraft(period: .daily, interval: DateInterval(start: Date(timeIntervalSince1970: 1000), end: Date(timeIntervalSince1970: 2000)))
    }
    private func saved(_ id: Int64 = 42) -> Playlist {
        Playlist(id: id, name: "Nome alterado", description: "", artworkId: nil,
            isFavorite: false, suggestLess: false, trackCount: 10, createdAt: "", updatedAt: "",
            isSmart: false, smartDefinition: nil)
    }
    private func response(saved: Playlist? = nil, tracks: [Track] = [], available: Bool = true) -> ReplayPreview {
        ReplayPreview(request: draft.request, tracks: tracks, eligibleCount: UInt32(tracks.count), minimum: 5,
            standard: 10, maximum: 25, available: available, isCurrent: false, savedPlaylist: saved)
    }

    func testClientOnlyConvertsCalendarBoundariesAndLocalizesTitle() {
        for (scope, expected) in [(RetrospectivePeriod.daily, ReplayPeriod.daily), (.weekly, .weekly), (.monthly, .monthly), (.yearly, .yearly)] {
            let draft = RetrospectivePlaylistDraft(period: scope, interval: draft.interval)
            XCTAssertEqual(draft.request.period, expected)
            XCTAssertEqual(draft.request.startAt, 1000)
            XCTAssertEqual(draft.request.endAt, 2000)
            XCTAssertTrue(draft.title.hasPrefix("Replay · "))
        }
    }

    func testPreviewDisplaysCoreOrderWithoutReadingOrRankingClientHistory() async throws {
        let core = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        let ordered = [Fixtures.track(id: 8, trackNumber: 1, discNumber: 1), Fixtures.track(id: 2, trackNumber: 1, discNumber: 1)]
        let response = response(tracks: ordered)
        core.replayPreviewHandler = { request in
            XCTAssertEqual(request, self.draft.request)
            return response
        }
        core.historyHandler = { XCTFail("Replay previews must not download playback history"); return [] }
        let store = DurvaldCoreStore(core: core)
        let preview = await store.loadReplayPreview(draft)
        XCTAssertEqual(preview?.tracks.map(\.id), [8, 2])
        XCTAssertEqual(preview?.available, true, "Eligibility comes from the core, not client thresholds")
        XCTAssertTrue(store.playlists.isEmpty)
    }

    func testCoreIdentityIsRestoredWithoutArtworkOrSmartRules() async throws {
        let core = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        let saved = saved()
        let response = response(saved: saved)
        core.replayPreviewHandler = { _ in response }
        for _ in 0..<2 {
            let store = DurvaldCoreStore(core: core)
            let preview = await store.loadReplayPreview(draft)
            XCTAssertEqual(preview?.savedPlaylist, saved)
            XCTAssertEqual(store.savedRetrospectivePlaylist(for: draft), saved)
            XCTAssertEqual(store.playlists.count, 1)
        }
    }

    func testSavingDelegatesModeArtworkAndPolicyToCoreAndCoalescesRequests() async throws {
        let core = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        let store = DurvaldCoreStore(core: core)
        let saved = saved()
        var calls = 0
        core.saveReplayHandler = { request, name, _, mode, close, artwork in
            calls += 1
            XCTAssertEqual(request, self.draft.request)
            XCTAssertEqual(name, self.draft.title)
            XCTAssertEqual(mode, .live, "The core decides whether a closed period must become a snapshot")
            XCTAssertFalse(close)
            XCTAssertEqual(artwork, "cover")
            await Task.yield()
            return saved
        }
        async let first = store.saveRetrospectivePlaylist(draft, live: true, closeAutomatically: false, artworkBase64: "cover")
        async let concurrent = store.saveRetrospectivePlaylist(draft, live: true, closeAutomatically: false, artworkBase64: "cover")
        let result = await (first, concurrent)
        XCTAssertEqual(result.0, saved)
        XCTAssertEqual(result.1, saved)
        XCTAssertEqual(calls, 1)
        _ = await store.saveRetrospectivePlaylist(draft, live: true, closeAutomatically: false, artworkBase64: "cover")
        XCTAssertEqual(store.playlists.count, 1, "An idempotent core response must not duplicate the local list")
    }

    func testFailedSaveLeavesLibraryUnchangedAndCanBeRetried() async {
        let core = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        let store = DurvaldCoreStore(core: core)
        core.saveReplayHandler = { _, _, _, _, _, _ in throw NSError(domain: "Storage", code: 1) }
        let failure = await store.saveRetrospectivePlaylist(draft, live: false, closeAutomatically: true)
        XCTAssertNil(failure)
        XCTAssertTrue(store.playlists.isEmpty)
        let saved = saved()
        core.saveReplayHandler = { _, _, _, _, _, _ in saved }
        let retried = await store.saveRetrospectivePlaylist(draft, live: false, closeAutomatically: true)
        XCTAssertEqual(retried, saved)
    }

    func testLifecycleChangesUseDedicatedCoreAPI() async {
        let core = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        let saved = saved()
        core.updateReplayHandler = { request, mode, close in
            XCTAssertEqual(request, self.draft.request)
            XCTAssertEqual(mode, .snapshot)
            XCTAssertTrue(close)
            return saved
        }
        let store = DurvaldCoreStore(core: core)
        let result = await store.updateReplay(draft, live: false, closeAutomatically: true)
        XCTAssertTrue(result)
    }

    func testSavingReplacesDraftHistoryEvenWhenFinishingOnAnotherPage() async throws {
        let core = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        let saved = saved()
        core.saveReplayHandler = { _, _, _, _, _, _ in saved }
        let store = DurvaldCoreStore(core: core)
        var history = LibraryNavigationHistory()
        history.navigate(to: .retrospectivePlaylist(draft))
        history.navigate(to: .songs)
        let result = await store.saveRetrospectivePlaylist(draft, live: false, closeAutomatically: true)
        history.replace(.retrospectivePlaylist(draft), with: .playlist(try XCTUnwrap(result)))
        XCTAssertEqual(history.current, .songs)
        history.goBack()
        XCTAssertEqual(history.currentRoute, .playlist(saved))
    }
}
