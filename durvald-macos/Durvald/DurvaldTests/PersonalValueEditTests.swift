import AppKit
import XCTest
@testable import Durvald

@MainActor
final class PersonalValueEditTests: XCTestCase {
    func testRatingToggleClearsAndFailedClearRestoresConfirmedValue() {
        var edit = PersonalValueEdit<UInt8?>(3)
        let cleared = PersonalValueLabels.ratingAfterClick(3, current: edit.value)
        XCTAssertNil(cleared)
        let ticket = edit.begin(cleared)
        XCTAssertEqual(PersonalValueLabels.rating(edit.value), "Sem avaliação")
        edit.receive(3)
        XCTAssertNil(edit.value, "Snapshot echoes must not replace a pending click")
        edit.finish(ticket, succeeded: false)
        XCTAssertEqual(edit.value, 3)
        XCTAssertEqual(PersonalValueLabels.rating(edit.value), "3 de 5")
    }

    func testOutOfOrderAcknowledgementsAndFailuresKeepLatestConfirmedValue() {
        var edit = PersonalValueEdit<UInt8?>(1)
        let first = edit.begin(2)
        let second = edit.begin(5)
        edit.finish(second, succeeded: false)
        edit.finish(first, succeeded: true)
        XCTAssertEqual(edit.value, 2)
        let third = edit.begin(3)
        let fourth = edit.begin(4)
        edit.finish(fourth, succeeded: true)
        edit.finish(third, succeeded: true)
        XCTAssertEqual(edit.value, 4)
    }

    func testBothFailuresRestoreOriginalValueAndReuseRejectsOldCompletion() {
        var edit = PersonalValueEdit(false)
        let first = edit.begin(true)
        let second = edit.begin(false)
        edit.finish(first, succeeded: false)
        edit.finish(second, succeeded: false)
        XCTAssertFalse(edit.value)
        let stale = edit.begin(true)
        edit.reset(false)
        edit.finish(stale, succeeded: true)
        XCTAssertFalse(edit.value)
        XCTAssertEqual(PersonalValueLabels.favoriteValue(edit.value), "Não favorita")
    }

    func testUnchangedSourceDuringReuseDoesNotEraseSuccessfulOptimisticValue() {
        var edit = PersonalValueEdit(false)
        let ticket = edit.begin(true)
        edit.finish(ticket, succeeded: true)
        edit.receive(false)
        XCTAssertTrue(edit.value)
        edit.receive(true)
        edit.receive(false)
        XCTAssertFalse(edit.value, "A changed external snapshot is authoritative after completion")
    }

    func testReleaseRatingFailureRestoresAlbumSnapshot() async {
        let core = PersonalEditTestCore()
        var release = Fixtures.release
        release.rating = 4
        let store = DurvaldCoreStore(core: core, releases: [release])
        let succeeded = await store.setReleaseRating(releaseID: release.id, rating: nil)
        XCTAssertFalse(succeeded)
        XCTAssertEqual(store.releases.first?.rating, 4)
    }

    func testNativeFavoriteAndRatingRestoreAfterFailedCommit() async {
        var track = Fixtures.track
        track.rating = 3
        let favorite = MusicLibraryNativeControlCell(identifier: .init("favorite"), kind: .favorite)
        favorite.configure(track: track, selected: false,
                           onFavoriteChange: { _ in false }, onRatingChange: { _ in false })
        favorite.buttons[0].performClick(nil)
        XCTAssertEqual(favorite.buttons[0].accessibilityValue() as? String, "Favorita")
        await Task.yield()
        XCTAssertEqual(favorite.buttons[0].accessibilityValue() as? String, "Não favorita")
        let rating = MusicLibraryNativeControlCell(identifier: .init("rating"), kind: .rating)
        rating.configure(track: track, selected: false,
                         onFavoriteChange: { _ in false }, onRatingChange: { _ in false })
        rating.buttons[2].performClick(nil)
        await Task.yield()
        XCTAssertEqual(rating.buttons[2].accessibilityValue() as? String, "3 de 5")
        XCTAssertTrue(rating.buttons.allSatisfy { !$0.isHidden })
    }

    func testNativeReuseIgnoresHeldCommitFromPreviousTrack() async {
        var pending: CheckedContinuation<Bool, Never>?
        let cell = MusicLibraryNativeControlCell(identifier: .init("favorite"), kind: .favorite)
        cell.configure(track: Fixtures.track, selected: false,
            onFavoriteChange: { _ in await withCheckedContinuation { pending = $0 } },
            onRatingChange: { _ in true })
        cell.buttons[0].performClick(nil)
        await Task.yield()
        XCTAssertNotNil(pending)
        cell.configure(track: Fixtures.track(id: 2, trackNumber: 2, discNumber: 1), selected: false,
            onFavoriteChange: { _ in true }, onRatingChange: { _ in true })
        pending?.resume(returning: true)
        await Task.yield()
        XCTAssertEqual(cell.buttons[0].accessibilityIdentifier(), "track.2.favorite")
        XCTAssertEqual(cell.buttons[0].accessibilityValue() as? String, "Não favorita")
    }

    func testStoreFavoriteFailureRestoresLibraryAndPlayer() async {
        let core = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        core.favoriteError = NSError(domain: "favorite", code: 1)
        let store = DurvaldCoreStore(core: core, playback: Fixtures.playingSnapshot, tracks: [Fixtures.track])
        let succeeded = await store.setTrackFavorite(trackID: Fixtures.track.id, favorite: true)
        XCTAssertFalse(succeeded)
        XCTAssertFalse(store.tracks[0].isFavorite)
        XCTAssertFalse(store.playback?.currentTrack?.isFavorite ?? true)
    }

    func testSerializedRatingFailuresRestoreOriginalInsteadOfFailedOptimisticValue() async {
        for firstSucceeded in [false, true] {
            let core = PersonalEditTestCore()
            var track = Fixtures.track
            track.rating = 1
            let store = DurvaldCoreStore(core: core, tracks: [track])
            let first = Task { await store.setTrackRating(trackID: track.id, rating: 2) }
            await until { core.pending != nil }
            let second = Task { await store.setTrackRating(trackID: track.id, rating: 5) }
            await until { store.tracks[0].rating == 5 }
            XCTAssertEqual(core.values, [2])
            await store.refreshPlayback()
            XCTAssertEqual(store.playback?.currentTrack?.rating, 5,
                           "Playback polling must not replace a pending personal edit")
            if firstSucceeded { core.pending?.resume(returning: ()) }
            else { core.pending?.resume(throwing: NSError(domain: "rating", code: 1)) }
            core.pending = nil
            _ = await first.value
            await until { core.values.count == 2 && core.pending != nil }
            XCTAssertEqual(store.tracks[0].rating, 5, "Older failure preserves newer optimistic edit")
            core.pending?.resume(throwing: NSError(domain: "rating", code: 2))
            core.pending = nil
            _ = await second.value
            XCTAssertEqual(store.tracks[0].rating, firstSucceeded ? 2 : 1)
        }
    }

    private func until(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Pending edit did not reach expected state")
    }
}

private final class PersonalEditTestCore: DurvaldCore {
    var values: [UInt8?] = []
    var pending: CheckedContinuation<Void, Error>?
    init() { super.init(noPointer: .init()) }
    required init(unsafeFromRawPointer pointer: UnsafeMutableRawPointer) { fatalError("No Rust pointer") }
    override func playback() async -> PlaybackSnapshot { Fixtures.playingSnapshot }
    override func setReleaseRating(releaseId: Int64, rating: UInt8?) async throws {
        throw NSError(domain: "releaseRating", code: 1)
    }
    override func setTrackRating(trackId: Int64, rating: UInt8?) async throws {
        values.append(rating)
        try await withCheckedThrowingContinuation { pending = $0 }
    }
}
