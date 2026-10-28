import XCTest
@testable import Durvald

@MainActor
final class SoulseekSearchPresentationTests: XCTestCase {
    private func group(_ id: String, slot: Bool? = nil, format: String = "flac", bitrate: UInt32? = nil) -> DownloadOfferGroup {
        DownloadOfferGroup(offerId: id, peer: id, folder: "Music/Album", files: [DownloadOfferFile(filename: "Music/Album/01 - First.\(format)", sizeBytes: 100, format: format, durationSeconds: nil, bitrateKbps: bitrate, sampleRateHz: nil, bitDepth: nil)], totalBytes: 100, freeUploadSlot: slot, queueLength: nil, uploadSpeedBytes: nil, matchedTracks: 0, expectedTracks: 0, durationMatches: 0, comparison: "Edição não verificada")
    }
    private func page(_ generation: UInt64, _ state: DownloadSearchState, groups: [DownloadOfferGroup] = [], failure: DownloadSearchFailure? = nil) -> DownloadSearchPage {
        DownloadSearchPage(generation: generation, state: state, groups: groups, failure: failure, truncated: false, cleanupPending: false)
    }
    private func wait(_ predicate: @escaping () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected search state was not published")
    }
    func testOpeningDoesNotSearchAndFiltersKeepUnknownQualityDistinct() async throws {
        let model = SoulseekSearchPresentation()
        var calls = 0
        let offers = [group("unknown"), group("known", slot: true, format: "mp3", bitrate: 320)]
        await model.prepare(SoulseekSearchLoader(search: { _, generation in calls += 1; return self.page(generation, .completed, groups: offers) }, poll: { self.page($0, .completed) }, cancel: { self.page(1, .cancelled) }, close: {}))
        XCTAssertEqual(calls, 0)
        model.start(query: "Artist Album", expected: [])
        try await wait { !model.busy }
        XCTAssertEqual(model.groups.count, 2)
        model.freeSlotsOnly = true
        XCTAssertEqual(model.groups.map(\.offerId), ["known"])
        model.freeSlotsOnly = false; model.minimumBitrate = 320
        XCTAssertEqual(model.groups.map(\.offerId), ["known"])
        model.formatFilter = "flac"
        XCTAssertTrue(model.groups.isEmpty) // The same file must satisfy format and bitrate.
        model.minimumBitrate = 0; model.formatFilter = "flac"
        XCTAssertEqual(model.groups.map(\.offerId), ["unknown"])
        model.formatFilter = ""; model.textFilter = "known"; model.selectedID = "known"
        XCTAssertEqual(model.selected?.peer, "known")
        XCTAssertEqual(calls, 1) // Filtering and inspection make no requests.
        await model.close()
    }
    func testProgressiveResultsRemainVisibleOnTimeout() async throws {
        let model = SoulseekSearchPresentation()
        let offers = [group("peer")]
        await model.prepare(SoulseekSearchLoader(search: { _, generation in self.page(generation, .searching, groups: offers) }, poll: { self.page($0, .timedOut, groups: offers, failure: .timedOut) }, cancel: { self.page(1, .cancelled) }, close: {}))
        model.start(query: "Artist Album", expected: [])
        try await wait { model.page?.state == .searching }
        XCTAssertEqual(model.groups.count, 1)
        try await wait { !model.busy }
        XCTAssertEqual(model.groups.count, 1)
        XCTAssertTrue(model.status.contains("rede"))
        XCTAssertFalse(model.status.contains("não existe"))
        await model.close()
    }
    func testCancellationDiscardsLateResultsAndClosesTheSession() async throws {
        let model = SoulseekSearchPresentation()
        var pending: CheckedContinuation<DownloadSearchPage, Never>?
        var generation: UInt64 = 0
        var closed = false
        await model.prepare(SoulseekSearchLoader(search: { _, current in generation = current; return await withCheckedContinuation { pending = $0 } }, poll: { self.page($0, .completed) }, cancel: { self.page(generation, .cancelled) }, close: { closed = true }))
        model.start(query: "first", expected: [])
        try await wait { pending != nil }
        await model.cancel()
        pending?.resume(returning: page(generation, .completed, groups: [group("obsolete")]))
        await Task.yield()
        XCTAssertEqual(model.page?.state, .cancelled)
        XCTAssertTrue(model.groups.isEmpty)
        XCTAssertFalse(model.busy)
        await model.close()
        XCTAssertTrue(closed)
    }
    func testIndependentFailureMessagesAreActionable() {
        XCTAssertTrue(SoulseekSearchPresentation.message(.authentication).contains("chave"))
        XCTAssertTrue(SoulseekSearchPresentation.message(.disabled).contains("Ajustes"))
        XCTAssertTrue(SoulseekSearchPresentation.message(.unavailable).contains("rede"))
        XCTAssertTrue(SoulseekSearchPresentation.message(.timedOut).contains("rede"))
    }
    func testDefaultCoreSearchIsDisabledAndDoesNotAlterLibraryOrPlayback() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("download-search-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let core = try await open(config: CoreConfig(databasePath: directory.appendingPathComponent("library.sqlite").path, appSupportDir: directory.path, coversDir: directory.appendingPathComponent("covers").path, keychainService: "download-search-\(UUID())"))
        let settings = try await core.downloadSearchSettings()
        XCTAssertFalse(settings.enabled)
        XCTAssertFalse(settings.hasApiKey)
        let before = await core.playback()
        let session = core.downloadSearchSession()
        let result = try await session.search(request: DownloadSearchRequest(query: "Artist Album", expectedTracks: []), generation: 1)
        XCTAssertEqual(result.failure, .disabled)
        let tracks = try await core.tracksPage(pageSize: 10, offset: 0)
        XCTAssertTrue(tracks.items.isEmpty)
        let after = await core.playback()
        XCTAssertEqual(before.currentTrack?.id, after.currentTrack?.id)
        await session.close()
    }
}
