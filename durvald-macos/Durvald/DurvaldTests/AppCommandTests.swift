import XCTest
@testable import Durvald

@MainActor
final class AppCommandTests: XCTestCase {
    func testCatalogHasUniqueIdentifiersAndShortcuts() {
        XCTAssertEqual(Set(AppCommandID.allCases.map(\.rawValue)).count, AppCommandID.allCases.count)
        let shortcuts = AppCommandID.allCases.filter { $0.shortcut != nil }.map(\.shortcutLabel)
        XCTAssertEqual(Set(shortcuts).count, shortcuts.count)
        XCTAssertEqual(AppCommandID.back.shortcutLabel, "⌘[")
        XCTAssertEqual(AppCommandID.forward.shortcutLabel, "⌘]")
        XCTAssertEqual(AppCommandID.playPause.shortcutLabel, "Espaço")
        XCTAssertEqual(AppCommandID.rate1.ratingHalfSteps, 1)
        XCTAssertNil(AppCommandID.clearRating.ratingHalfSteps)
    }

    func testSelectionNeverFallsBackToThePlayingTrackOrAnotherWindow() {
        var hits = 0
        let window = AppCommandTarget(actions: [.info: { hits += 100 }, .playPause: { hits += 1 }])
        let selection = AppCommandTarget(actions: [.info: { hits += 10 }])
        XCTAssertNil(AppCommandDispatch.action(.info, window: window, page: nil, selection: nil, isMain: true, editing: false))
        XCTAssertNil(AppCommandDispatch.action(.info, window: window, page: nil, selection: selection, isMain: false, editing: false))
        XCTAssertNil(AppCommandDispatch.action(.playPause, window: window, page: nil, selection: selection, isMain: false, editing: false))
        AppCommandDispatch.action(.info, window: window, page: nil, selection: selection, isMain: true, editing: false)?()
        XCTAssertEqual(hits, 10)
    }

    func testEditingPreservesSelectionAndTransportKeysButAllowsExplicitSearch() {
        let target = AppCommandTarget(actions: Dictionary(uniqueKeysWithValues: AppCommandID.allCases.map { ($0, {}) }))
        for id in AppCommandID.allCases where id.usesSelection || [.playPause, .playCollection, .shuffleCollection, .volumeUp, .volumeDown, .seekBack, .seekForward].contains(id) {
            XCTAssertNil(AppCommandDispatch.action(id, window: target, page: target, selection: target, isMain: true, editing: true), id.rawValue)
        }
        XCTAssertNotNil(AppCommandDispatch.action(.search, window: target, page: nil, selection: nil, isMain: true, editing: true))
        XCTAssertNil(AppCommandDispatch.action(.playCollection, window: nil, page: nil, selection: nil, isMain: true, editing: false))
    }

    func testBatchInfoUsesSelectionAndPlayRetainsCallerOccurrence() {
        let store = DurvaldCoreStore()
        let info = TrackInfoCoordinator()
        var playedOccurrence: Int?
        let first = Fixtures.track
        let second = Fixtures.track(id: 2, trackNumber: 2, discNumber: 1)
        let target = AppCommandTarget.tracks([first, second], store: store, info: info,
            creation: PlaylistCreationCoordinator(), navigation: TrackMenuNavigation()) { playedOccurrence = 3 }
        target.perform(.info)
        XCTAssertEqual(info.trackIDs, [1, 2])
        target.perform(.playSelection)
        XCTAssertEqual(playedOccurrence, 3)
        XCTAssertFalse(AppCommandTarget.tracks([], store: store, info: info,
            creation: PlaylistCreationCoordinator(), navigation: TrackMenuNavigation(), play: {}).contains(.playSelection))
    }

    func testFocusedDuplicateUsesItsOriginalPlaylistOccurrence() async {
        let core = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        core.playlistResultsByID[7] = [Fixtures.track, Fixtures.track(id: 2, trackNumber: 2, discNumber: 1), Fixtures.track]
        let store = DurvaldCoreStore(core: core)
        let done = expectation(description: "Selected occurrence played")
        let target = AppCommandTarget.tracks([Fixtures.track], store: store, info: TrackInfoCoordinator(),
            creation: PlaylistCreationCoordinator(), navigation: TrackMenuNavigation()) {
                Task { await store.playPlaylist(playlistID: 7, startingAtPosition: 2); done.fulfill() }
            }
        target.perform(.playSelection)
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(core.collectionRequests.first?.start, 2)
        XCTAssertEqual(core.collectionRequests.first?.contexts, ["playlist:7#0", "playlist:7#1", "playlist:7#2"])
    }

    func testMuteRestoresSharedVolumeAfterButtonOrCommandChanges() {
        var snapshot = Fixtures.playingSnapshot
        snapshot.volume = 0.73
        let store = DurvaldCoreStore(playback: snapshot)
        store.toggleMute()
        XCTAssertEqual(store.playback?.volume, 0)
        XCTAssertTrue(store.isVolumeMuted)
        store.toggleMute()
        XCTAssertEqual(store.playback?.volume ?? 0, 0.73, accuracy: 0.001)
        store.toggleMute()
        store.adjustVolume(by: 0.05)
        XCTAssertFalse(store.isVolumeMuted)
        store.toggleMute()
        store.toggleMute()
        XCTAssertEqual(store.playback?.volume ?? 0, 0.05, accuracy: 0.001)
    }
}
