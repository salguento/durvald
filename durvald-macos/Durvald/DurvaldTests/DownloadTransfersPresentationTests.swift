import XCTest
@testable import Durvald

@MainActor
final class DownloadTransfersPresentationTests: XCTestCase {
    private func job(_ id: String, state: DownloadFileState = .queued, message: String? = nil) -> DownloadTransferJob {
        DownloadTransferJob(jobId: id, peer: "peer", folder: "Album", createdAt: 1, relativeDestination: "durvald/\(id)", remoteDownloadRoot: "/remote/completed", mappedDownloadRoot: "/mounted/completed", libraryDestination: "/music", files: [DownloadTransferFile(index: 0, filename: "Album/Track.wav", sizeBytes: 100, bytesTransferred: state == .completed ? 100 : 0, state: state, queuePosition: nil, importedTrackId: nil, importedPath: nil, message: nil)], cancelRequested: false, message: message)
    }
    private func preview(_ id: String) -> DownloadImportPreview {
        DownloadImportPreview(targetTrackId: nil, resuming: false, reviewToken: "review", jobId: id, fileIndex: 0, title: "Track", artist: "Artist", release: "Album", durationSeconds: 1, sizeBytes: 100, destination: "/music/Track.wav")
    }
    private func loader(jobs: [DownloadTransferJob], refresh: ((String) async throws -> DownloadTransferJob)? = nil) -> DownloadTransfersLoader {
        DownloadTransfersLoader(list: { jobs }, refresh: refresh ?? { self.job($0) }, cancel: { self.job($0, state: .cancelled) }, retry: { self.job($0) }, inspect: { id, _, _ in self.preview(id) }, pending: { id, _ in self.preview(id) })
    }
    private func wait(_ predicate: @escaping () -> Bool) async throws {
        for _ in 0..<100 { if predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Expected acquisition state was not reached")
    }
    func testRestoringTheListDoesNotPollOrImportAndFailuresStopAutomaticPolling() async {
        let model = DownloadTransfersPresentation(); var polls = 0
        let provider = loader(jobs: [job("a")], refresh: { id in polls += 1; return self.job(id, message: "A conexão excedeu o tempo de espera") })
        await model.load(loader: provider, initialID: nil)
        XCTAssertEqual(model.selectedID, "a"); XCTAssertEqual(polls, 0)
        XCTAssertTrue(model.shouldPoll)
        await model.refresh()
        XCTAssertEqual(polls, 1); XCTAssertFalse(model.shouldPoll)
        XCTAssertEqual(model.selected?.files.first?.state, .queued)
        XCTAssertNil(model.preview)
    }
    func testAResponseForTheOldSelectionDoesNotReplaceTheCurrentSelection() async throws {
        let model = DownloadTransfersPresentation()
        var pending: CheckedContinuation<DownloadTransferJob, Never>?
        await model.load(loader: loader(jobs: [job("a"), job("b")], refresh: { id in
            if id == "a" { return await withCheckedContinuation { pending = $0 } }
            return self.job(id, state: .completed)
        }), initialID: "a")
        let old = Task { await model.refresh() }; try await wait { pending != nil }
        model.selectedID = "b"; await model.refresh()
        pending?.resume(returning: job("a", state: .completed)); await old.value
        XCTAssertEqual(model.selected?.jobId, "b"); XCTAssertEqual(model.selected?.files.first?.state, .completed)
        XCTAssertEqual(model.jobs.first { $0.jobId == "a" }?.files.first?.state, .queued)
        XCTAssertNil(model.preview)
    }
    func testCancellationDiscardsInflightProgressAndInspectionRequiresAnExplicitAction() async throws {
        let model = DownloadTransfersPresentation()
        var pending: CheckedContinuation<DownloadTransferJob, Never>?
        await model.load(loader: loader(jobs: [job("a")], refresh: { _ in await withCheckedContinuation { pending = $0 } }), initialID: "a")
        let update = Task { await model.refresh() }; try await wait { pending != nil }
        await model.cancel(); pending?.resume(returning: job("a", state: .downloading)); await update.value
        XCTAssertEqual(model.selected?.files.first?.state, .cancelled)
        XCTAssertNil(model.preview)
        await model.inspect(file: try XCTUnwrap(model.selected?.files.first), path: "/mounted/completed/Track.wav")
        XCTAssertEqual(model.preview?.reviewToken, "review")
        XCTAssertNil(model.selected?.files.first?.importedTrackId)
    }
    func testDefaultTransferConfigurationAndJournalCrossTheRealSwiftBoundaryWithoutNetwork() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("transfer-ffi-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let core = try await open(config: CoreConfig(databasePath: directory.appendingPathComponent("library.sqlite").path, appSupportDir: directory.path, coversDir: directory.appendingPathComponent("covers").path, keychainService: "transfer-ffi-\(UUID())"))
        let settings = try await core.downloadTransferSettings()
        XCTAssertFalse(settings.enabled)
        let list = try await core.downloadTransfers(); XCTAssertTrue(list.isEmpty)
        let session = core.downloadSearchSession()
        do { _ = try await session.enqueueDownload(offerId: "forged", filenames: ["Track.wav"], confirmed: true); XCTFail("A forged offer must not enqueue") }
        catch CoreError.InvalidInput { }
        let after = try await core.downloadTransfers(); XCTAssertTrue(after.isEmpty)
        let tracks = try await core.tracksPage(pageSize: 10, offset: 0); XCTAssertTrue(tracks.items.isEmpty)
        await session.close()
    }
}
