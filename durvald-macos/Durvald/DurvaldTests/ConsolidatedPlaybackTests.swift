import Foundation
import XCTest
@testable import Durvald

@MainActor
final class ConsolidatedPlaybackTests: XCTestCase {
    final class Host: EmbeddedPlaybackHost {
        func execute(command: EmbeddedPlaybackCommand) -> Bool { true }
    }
    func testRemoteHistoryAndActivePreferencePassThroughTheRealSwiftBoundary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("consolidated-ffi-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let core = try await open(config: CoreConfig(databasePath: directory.appendingPathComponent("library.sqlite").path, appSupportDir: directory.path, coversDir: directory.appendingPathComponent("covers").path, keychainService: "consolidated-ffi-\(UUID())"))
        let track = try await core.saveRemoteTrack(entry: CatalogEntry(reference: CatalogReference(provider: "soundcloud", kind: .audioTrack, id: "fixture/consolidated"), title: "Remote fixture", artistCredit: "Fixture Artist", versionLabel: nil, durationSeconds: 999, canonicalUrl: "https://soundcloud.com/fixture/consolidated"))
        XCTAssertNil(track.filePath)
        let sources = try await core.trackSources(trackId: track.id)
        let source = try XCTUnwrap(sources.first)
        try await core.preferTrackSource(trackId: track.id, sourceId: source.sourceId)
        try await core.setEmbeddedPlaybackHost(host: Host())
        _ = try await core.playEmbeddedTrackSource(trackId: track.id, sourceId: source.sourceId)
        let model = SourceManagementPresentation()
        await model.load(entry: .sourceEntry(track), loader: NativeSourceManager(core: core, changed: {}, playbackChanged: {}))
        XCTAssertEqual(model.activeSourceID, source.sourceId)
        let status = await core.playbackSourceStatus()
        XCTAssertEqual(status?.preferredSourceId, source.sourceId)
        let snapshot = await core.embeddedPlayback()
        let generation = try XCTUnwrap(snapshot?.generation)
        for (sequence, kind) in [(UInt64(1), EmbeddedEventKind.ready), (UInt64(2), .playing)] {
            try await core.reportEmbeddedPlaybackEvent(event: EmbeddedPlaybackEvent(generation: generation, sequence: sequence, kind: kind, positionSeconds: 0, durationSeconds: 2))
        }
        try await Task.sleep(for: .milliseconds(1100))
        try await core.reportEmbeddedPlaybackEvent(event: EmbeddedPlaybackEvent(generation: generation, sequence: 3, kind: .progress, positionSeconds: 1.1, durationSeconds: 2))
        try await core.reportEmbeddedPlaybackEvent(event: EmbeddedPlaybackEvent(generation: generation, sequence: 4, kind: .ended, positionSeconds: 2, durationSeconds: 2))
        let history = try await core.playbackHistory()
        let entry = try XCTUnwrap(history.first)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(entry.sourceId, source.sourceId)
        XCTAssertEqual(entry.effectiveDurationSeconds, 2)
        XCTAssertEqual(entry.durationSeconds, 1)
        XCTAssertNotNil(entry.observedListeningSummary)
        let summary = RetrospectiveWeekSnapshot.build(entries: history, now: Date(), calendar: Calendar.current, tracksByID: [track.id: track], period: .daily)
        XCTAssertEqual(summary.currentTotal, 1)
        XCTAssertEqual(summary.listenedSeconds, 1)
        model.cancel()
        try await core.stop()
    }
    func testLegacyHistoryKeepsUnknownOriginAndItsRecordedTime() {
        let legacy = PlaybackHistoryItem(id: 1, trackId: 3, playedAt: "2026-10-28T12:00:00Z", durationSeconds: 61)
        XCTAssertNil(legacy.sourceId)
        XCTAssertNil(legacy.effectiveDurationSeconds)
        XCTAssertNil(legacy.observedListeningSummary)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let summary = RetrospectiveWeekSnapshot.build(entries: [legacy], now: try! Date.ISO8601FormatStyle().parse("2026-10-28T15:00:00Z"), calendar: calendar, period: .yearly)
        XCTAssertEqual(summary.listenedSeconds, 61)
    }
}
