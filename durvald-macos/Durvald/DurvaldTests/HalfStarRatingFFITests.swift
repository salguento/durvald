import AppKit
import XCTest
@testable import Durvald

/// These tests cross the generated Swift/UniFFI bridge into the embedded Rust
/// library and a real SQLite file. No FakeDurvaldCore or user database is used.
@MainActor
final class HalfStarRatingFFITests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("durvald-ratings-\(UUID())")
    }
    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    func testEveryRatingSurvivesTheBridgeAndRestartIncludingNilAndZero() async throws {
        var core: DurvaldCore? = try await RatingIntegrationFixture.openCore(directory: directory, count: 12)
        let values: [UInt8?] = [nil] + (0...10).map { UInt8($0) }
        for (index, value) in values.enumerated() {
            try await core!.setTrackRatingHalfSteps(trackId: Int64(index + 1), ratingHalfSteps: value)
            try await core!.setReleaseRatingHalfSteps(releaseId: Int64(index + 1), ratingHalfSteps: value)
        }
        core = nil
        let reopened = try await open(config: RatingIntegrationFixture.config(directory: directory))
        for (index, expected) in values.enumerated() {
            let id = Int64(index + 1)
            let track = try await reopened.tracksByIds(trackIds: [id]).first
            let release = try await reopened.release(releaseId: id)
            XCTAssertEqual(track?.ratingHalfSteps, expected)
            XCTAssertEqual(release.ratingHalfSteps, expected)
        }
        do {
            try await reopened.setTrackRatingHalfSteps(trackId: 4, ratingHalfSteps: 11)
            XCTFail("Out-of-range values must cross the FFI as errors")
        } catch CoreError.InvalidInput { } catch { XCTFail("Unexpected error: \(error)") }
        let unchanged = try await reopened.tracksByIds(trackIds: [4]).first
        XCTAssertEqual(unchanged?.ratingHalfSteps, 2)
    }

    func testNativeControlPersistsFractionalRatingThroughStoreAndRealCore() async throws {
        let core = try await RatingIntegrationFixture.openCore(directory: directory)
        let loaded = try await core.tracksByIds(trackIds: [4])
        let track = try XCTUnwrap(loaded.first)
        let store = DurvaldCoreStore(core: core, tracks: [track])
        let cell = MusicLibraryNativeControlCell(identifier: .init("rating"), kind: .rating)
        var saved: Bool?
        let committed = expectation(description: "Rating persisted through UniFFI")
        cell.configure(track: track, selected: false, onFavoriteChange: { _ in true }, onRatingChange: { value in
            let result = await store.setTrackRating(trackID: track.id, rating: value)
            saved = result
            committed.fulfill()
            return result
        })
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{F702}", charactersIgnoringModifiers: "\u{F702}",
            isARepeat: false, keyCode: 123))
        cell.buttons[4].keyDown(with: event) // left half of the fifth star = 4.5
        await fulfillment(of: [committed], timeout: 5)
        XCTAssertEqual(saved, true)
        let persisted = try await core.tracksByIds(trackIds: [4]).first
        XCTAssertEqual(persisted?.ratingHalfSteps, 9)
        XCTAssertEqual(store.loadedTrack(id: 4)?.ratingHalfSteps, 9)
    }

    func testWholeStarConversionBothDirectionsPersistsAndUpdatesSmartMembership() async throws {
        for rounding in [RatingRounding.up, .down] {
            let path = directory.appendingPathComponent(rounding == .up ? "up" : "down")
            var core: DurvaldCore? = try await RatingIntegrationFixture.openCore(directory: path)
            func definition(_ value: String) -> SmartPlaylistDefinition {
                .init(matchAll: true, rules: [.init(field: "rating", comparison: "greater_or_equal", value: value)],
                      limit: nil, sortBy: "rating", descending: true)
            }
            let whole = try await core!.createSmartPlaylist(name: "Four stars", description: "", definition: definition("4"))
            let half = try await core!.createSmartPlaylist(name: "Four and a half", description: "", definition: definition("4.5"))
            let before = try await core!.playlistTracks(playlistId: whole.id)
            let halfBefore = try await core!.playlistTracks(playlistId: half.id)
            XCTAssertEqual(before.map(\.id), [7, 6, 5])
            XCTAssertEqual(halfBefore.map(\.id), [7, 6])
            do {
                _ = try await core!.updateRatingPreferences(granularity: .wholeStars, rounding: nil)
                XCTFail("Existing fractions require explicit rounding")
            } catch CoreError.InvalidInput { } catch { XCTFail("Unexpected error: \(error)") }
            let result = try await core!.updateRatingPreferences(granularity: .wholeStars, rounding: rounding)
            XCTAssertEqual(result.converted.tracks, 3)
            XCTAssertEqual(result.converted.releases, 3)
            do {
                try await core!.setReleaseRatingHalfSteps(releaseId: 4, ratingHalfSteps: 7)
                XCTFail("The persisted whole-star policy must reject half stars")
            } catch CoreError.InvalidInput { } catch { XCTFail("Unexpected error: \(error)") }
            core = nil
            let reopened = try await open(config: RatingIntegrationFixture.config(directory: path))
            let preferences = try await reopened.ratingPreferences()
            XCTAssertEqual(preferences.granularity, .wholeStars)
            let rounded = try await reopened.tracksByIds(trackIds: [1, 2, 3, 4, 5, 6, 7]).sorted { $0.id < $1.id }
            XCTAssertEqual(rounded.map(\.ratingHalfSteps), rounding == .up ? [nil, 0, 2, 8, 8, 10, 10] : [nil, 0, 0, 6, 8, 8, 10])
            let after = try await reopened.playlistTracks(playlistId: whole.id)
            let halfAfter = try await reopened.playlistTracks(playlistId: half.id)
            XCTAssertEqual(Set(after.map(\.id)), rounding == .up ? [4, 5, 6, 7] : [5, 6, 7])
            XCTAssertEqual(Set(halfAfter.map(\.id)), rounding == .up ? [6, 7] : [7])
            _ = try await reopened.updateRatingPreferences(granularity: .halfStars, rounding: nil)
            let restored = try await reopened.tracksByIds(trackIds: [4]).first
            XCTAssertEqual(restored?.ratingHalfSteps, rounding == .up ? 8 : 6, "Returning to half stars must not restore fractions")
        }
    }

    func testConversionRetainsLoadedCatalogBeyondCorePageCapAndFurtherScrolling() async throws {
        let core = try await RatingIntegrationFixture.openCore(directory: directory, count: 301)
        let firstTracks = try await core.tracksPage(pageSize: 200, offset: 0)
        let moreTracks = try await core.tracksPage(pageSize: 50, offset: 200)
        let firstReleases = try await core.releasesPage(pageSize: 200, offset: 0)
        let moreReleases = try await core.releasesPage(pageSize: 50, offset: 200)
        let tracks = firstTracks.items + moreTracks.items
        let releases = firstReleases.items + moreReleases.items
        let store = DurvaldCoreStore(core: core, tracks: tracks, releases: releases)
        let changed = await store.changeRatingGranularity(.wholeStars, rounding: .up)
        XCTAssertTrue(changed, store.errorMessage ?? "")
        XCTAssertEqual(store.tracks.map(\.id), tracks.map(\.id))
        XCTAssertEqual(store.releases.map(\.id), releases.map(\.id))
        XCTAssertTrue(store.tracks.allSatisfy { $0.ratingHalfSteps.map { $0.isMultiple(of: 2) } ?? true })
        XCTAssertTrue(store.releases.allSatisfy { $0.ratingHalfSteps.map { $0.isMultiple(of: 2) } ?? true })
        await store.loadMoreTracks(ifNeededAfter: store.tracks.last!.id)
        await store.loadMoreReleases(ifNeededAfter: store.releases.last!.id)
        XCTAssertEqual(store.tracks.count, 301)
        XCTAssertEqual(store.releases.count, 301)
        XCTAssertEqual(Set(store.tracks.map(\.id)).count, 301)
        XCTAssertEqual(Set(store.releases.map(\.id)).count, 301)
    }
}
