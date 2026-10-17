import AppKit
import SwiftUI
import XCTest
@testable import Durvald

@MainActor
final class HalfStarRatingIntegrationTests: XCTestCase {
    func testTrackAndReleaseWritesPreserveHalfStars() async {
        let core = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        let store = DurvaldCoreStore(core: core, playback: core.snapshot, tracks: [Fixtures.track], releases: [Fixtures.release])
        let trackSaved = await store.setTrackRating(trackID: 1, rating: 7)
        XCTAssertTrue(trackSaved)
        let releaseSaved = await store.setReleaseRating(releaseID: 1, rating: 9)
        XCTAssertTrue(releaseSaved)
        XCTAssertEqual(core.trackRatingChanges, [7])
        XCTAssertEqual(core.releaseRatingChanges, [9])
        XCTAssertEqual(store.tracks.first?.ratingHalfSteps, 7)
        XCTAssertEqual(store.playback?.currentTrack?.ratingHalfSteps, 7)
        XCTAssertEqual(store.releases.first?.ratingHalfSteps, 9)
    }

    func testPersistedWholeScaleLoadsAndHalfScaleDoesNotRestoreFractions() async {
        let core = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        core.ratingPreferencesResult = .init(granularity: .wholeStars)
        var track = Fixtures.track
        track.ratingHalfSteps = 6
        core.snapshot.currentTrack = track
        core.tracksPageHandler = { _, _ in .init(items: [track], nextOffset: nil) }
        let store = DurvaldCoreStore(core: core, tracks: [track])
        await store.refreshRatingPreferences()
        XCTAssertEqual(store.ratingGranularity, .wholeStars)
        var requestedRounding: RatingRounding?
        core.changeRatingPreferencesHandler = { granularity, rounding in
            requestedRounding = rounding
            return .init(preferences: .init(granularity: granularity), converted: core.ratingConversionResult)
        }
        let changed = await store.changeRatingGranularity(.halfStars, rounding: nil)
        XCTAssertTrue(changed)
        XCTAssertNil(requestedRounding)
        XCTAssertEqual(store.ratingGranularity, .halfStars)
        XCTAssertEqual(store.tracks.first?.ratingHalfSteps, 6)
    }

    func testWholeStarContextMenuUsesExactEvenValuesAndDisablesDuringConversion() {
        var album = Fixtures.release
        album.ratingHalfSteps = 8
        let definitions = LibraryMenuDefinition.build(track: nil, selectedTracks: [], album: album, playlist: nil,
            ratingsEnabled: true, ratingGranularity: .wholeStars, ratingEditingEnabled: false, additionalActions: [])
        let menu = NSMenu()
        NativeLibraryMenuPresenter.populate(menu, items: definitions, target: NSObject(),
            selector: { _ in NSSelectorFromString("unused:") }, playlistPicker: NSMenu(), containingPlaylists: NSMenu())
        let choices = menu.items.first { $0.title == "Avaliação" }!.submenu!.items.filter { !$0.isSeparatorItem }
        XCTAssertEqual(choices.map(\.tag), [-1, 0, 2, 4, 6, 8, 10])
        XCTAssertEqual(choices.filter { $0.state == .on }.map(\.tag), [8])
        XCTAssertTrue(choices.allSatisfy { !$0.isEnabled })
    }

    func testConversionReloadsAuthoritativePagesAndPlayback() async {
        let core = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        var converted = Fixtures.track
        converted.ratingHalfSteps = 8
        var release = Fixtures.release
        release.ratingHalfSteps = 6
        let initialTracks = (1...151).map { Fixtures.track(id: Int64($0), trackNumber: 1, discNumber: 1) }
        var requests: [(RatingGranularity, RatingRounding?)] = []
        core.changeRatingPreferencesHandler = { granularity, rounding in
            requests.append((granularity, rounding))
            return RatingPreferenceChange(preferences: .init(granularity: granularity),
                converted: .init(tracks: 1, releases: 1, missingTracks: 2, archivedReleases: 3))
        }
        var requestedSize: UInt64?
        core.tracksPageHandler = { size, _ in
            requestedSize = size
            return TrackPage(items: [converted] + Array(initialTracks.dropFirst()), nextOffset: 151)
        }
        core.releasesPageHandler = { _, _ in ReleasePage(items: [release], nextOffset: nil) }
        core.snapshot.currentTrack = converted
        let store = DurvaldCoreStore(core: core, playback: Fixtures.playingSnapshot, tracks: initialTracks, releases: [Fixtures.release])
        let previousRevision = store.metadataRevision
        let changed = await store.changeRatingGranularity(.wholeStars, rounding: .up)
        XCTAssertTrue(changed)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.0, .wholeStars)
        XCTAssertEqual(requests.first?.1, .up)
        XCTAssertEqual(store.ratingGranularity, .wholeStars)
        XCTAssertEqual(requestedSize, 151, "Keep the entire loaded page window")
        XCTAssertEqual(store.tracks.count, 151)
        XCTAssertEqual(store.tracks.first?.ratingHalfSteps, 8)
        XCTAssertEqual(store.releases.first?.ratingHalfSteps, 6)
        XCTAssertEqual(store.playback?.currentTrack?.ratingHalfSteps, 8)
        XCTAssertGreaterThan(store.metadataRevision, previousRevision)
        XCTAssertFalse(store.isChangingRatingScale)
    }

    func testPreviewDoesNotMutateAndFailedConversionPreservesScale() async throws {
        let core = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        core.ratingConversionResult = .init(tracks: 3, releases: 1, missingTracks: 2, archivedReleases: 4)
        var calls = 0
        core.changeRatingPreferencesHandler = { _, _ in
            calls += 1
            throw NSError(domain: "conversion", code: 1)
        }
        var track = Fixtures.track
        track.ratingHalfSteps = 7
        let store = DurvaldCoreStore(core: core, tracks: [track])
        let counts = try await store.previewRatingConversion()
        XCTAssertEqual(counts.tracks + counts.releases + counts.missingTracks + counts.archivedReleases, 10)
        XCTAssertEqual(calls, 0, "Opening or cancelling the confirmation must not convert ratings")
        let changed = await store.changeRatingGranularity(.wholeStars, rounding: .down)
        XCTAssertFalse(changed)
        XCTAssertEqual(store.ratingGranularity, .halfStars)
        XCTAssertEqual(store.tracks.first?.ratingHalfSteps, 7)
        XCTAssertFalse(store.isChangingRatingScale)
        XCTAssertNotNil(store.errorMessage)
    }

    func testScaleChangeWaitsForPendingWriteAndBlocksNewEdits() async {
        let core = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        var pending: CheckedContinuation<Void, Never>?
        core.trackRatingHandler = { _, _ in await withCheckedContinuation { pending = $0 } }
        var conversionStarted = false
        core.changeRatingPreferencesHandler = { granularity, _ in
            conversionStarted = true
            core.snapshot.currentTrack?.ratingHalfSteps = 8
            return .init(preferences: .init(granularity: granularity), converted: core.ratingConversionResult)
        }
        core.tracksPageHandler = { _, _ in .init(items: [core.snapshot.currentTrack!], nextOffset: nil) }
        let store = DurvaldCoreStore(core: core, tracks: [Fixtures.track])
        let edit = Task { await store.setTrackRating(trackID: 1, rating: 7) }
        for _ in 0..<100 where pending == nil { await Task.yield() }
        XCTAssertNotNil(pending)
        let change = Task { await store.changeRatingGranularity(.wholeStars, rounding: .up) }
        for _ in 0..<100 where !store.isChangingRatingScale { await Task.yield() }
        XCTAssertTrue(store.isChangingRatingScale)
        XCTAssertFalse(conversionStarted)
        let rejected = await store.setTrackRating(trackID: 1, rating: 5)
        XCTAssertFalse(rejected)
        pending?.resume()
        let edited = await edit.value
        let changed = await change.value
        XCTAssertTrue(edited)
        XCTAssertTrue(changed)
        XCTAssertEqual(core.trackRatingChanges, [7])
        XCTAssertEqual(store.tracks.first?.ratingHalfSteps, 8)
        XCTAssertFalse(store.isChangingRatingScale)
    }

    func testNativeHalfStarKeyboardTargetAndWholeStarPolicy() async throws {
        let cell = MusicLibraryNativeControlCell(identifier: .init("rating"), kind: .rating)
        var values: [UInt8?] = []
        cell.configure(track: Fixtures.track, selected: false,
            onFavoriteChange: { _ in true }, onRatingChange: { values.append($0); return true })
        let button = try XCTUnwrap(cell.buttons[3] as? RatingStarButton)
        let left = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{F702}", charactersIgnoringModifiers: "\u{F702}",
            isARepeat: false, keyCode: 123))
        button.keyDown(with: left)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(values, [7])
        XCTAssertEqual(button.accessibilityValue() as? String, PersonalValueLabels.rating(7))
        cell.configure(track: Fixtures.track, selected: false, granularity: .wholeStars, ratingRevision: 1,
            onFavoriteChange: { _ in true }, onRatingChange: { values.append($0); return true })
        XCTAssertFalse(button.allowsHalfStars)
        button.performClick(nil)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(values, [7, 8])
        cell.configure(track: Fixtures.track, selected: false, editable: false, ratingRevision: 2,
            onFavoriteChange: { _ in true }, onRatingChange: { _ in XCTFail("Disabled during conversion"); return true })
        XCTAssertFalse(button.isEnabled)
    }

    func testSettingsAndRatingControlsRender() async throws {
        let store = DurvaldCoreStore(core: FakeDurvaldCore(snapshot: Fixtures.playingSnapshot))
        let host = NSHostingView(rootView: HStack {
            SettingsView()
            VStack(alignment: .leading, spacing: 20) {
                Text("Meias estrelas")
                ForEach([UInt8(0), 1, 7, 10], id: \.self) { value in
                    RatingControl(rating: value, isEditable: true)
                }
            }.padding().frame(width: 200)
        }.environment(store))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 820, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        for _ in 0..<20 { await Task.yield() }
        host.layoutSubtreeIfNeeded()
        let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        let data = try XCTUnwrap(image.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = "Half-star controls and settings"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}
