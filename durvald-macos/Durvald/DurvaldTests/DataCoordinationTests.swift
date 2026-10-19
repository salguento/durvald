import XCTest
@testable import Durvald

@MainActor
final class DataCoordinationTests: XCTestCase {
    func testNewArtistLoadRejectsOldResultAndKeepsLatestLoadingFlags() async {
        let gate = CoordinationGate()
        let core = CoordinationTestCore()
        core.artistTrackHandler = { id in
            if id == 1 { await gate.pause() }
            return [Fixtures.track(id: id, trackNumber: 1, discNumber: 1)]
        }
        let store = DurvaldCoreStore(core: core)
        let model = ArtistPresentation()
        let old = Task { await model.load(artistID: 1, using: store, language: "pt") }
        await gate.started()
        await model.load(artistID: 2, using: store, language: "pt")
        XCTAssertEqual(model.tracks.map(\.id), [2])
        await gate.release()
        await old.value
        XCTAssertEqual(model.tracks.map(\.id), [2])
        XCTAssertFalse(model.isLoading)
        await model.prepareLookups()
        XCTAssertNotNil(model.lookups.value.tracksByID[2])
        XCTAssertNil(model.lookups.value.tracksByID[1])
    }

    func testLateDiscographyPageDoesNotReplaceNewArtistCatalog() async {
        let gate = CoordinationGate()
        let core = CoordinationTestCore()
        core.discographyHandler = { id, offset in
            if offset == 10 { await gate.pause() }
            return CoordinationTestCore.page(id)
        }
        let store = DurvaldCoreStore(core: core)
        let model = ArtistPresentation()
        await model.load(artistID: 1, using: store, language: "pt")
        let old = Task { await model.loadMoreDiscography(from: 10) }
        await gate.started()
        await model.load(artistID: 2, using: store, language: "pt")
        await gate.release()
        await old.value
        XCTAssertEqual(model.discographyPage?.artistId, 2)
        XCTAssertFalse(model.isLoadingMoreDiscography)
    }

    func testCancelledArtistLoadDoesNotPublishLateData() async {
        let gate = CoordinationGate()
        let core = CoordinationTestCore()
        core.artistTrackHandler = { id in await gate.pause(); return [Fixtures.track(id: id, trackNumber: 1, discNumber: 1)] }
        let model = ArtistPresentation()
        let task = Task { await model.load(artistID: 1, using: DurvaldCoreStore(core: core), language: "pt") }
        await gate.started()
        task.cancel()
        await gate.release()
        await task.value
        XCTAssertTrue(model.tracks.isEmpty)
        XCTAssertFalse(model.isLoading)
    }

    func testBatchValidatesEntireDraftBeforeWritingAnyTrack() async {
        await withBatch { model, core, store, _ in
            await model.load(trackIDs: [1, 2], using: store)
            model.draft?.title = BatchMetadataValue(isEnabled: true, text: " ", isMixed: false)
            await model.save(using: store, writeChangesToFiles: true)
            XCTAssertTrue(core.savedIDs.isEmpty)
            XCTAssertNotNil(model.statusMessage)
            XCTAssertFalse(model.isWorking)
        }
    }

    func testPartialBatchSaveRecordsOnlySuccessAndUndoRestoresIt() async {
        await withBatch { model, core, store, defaults in
            await model.load(trackIDs: [1, 2], using: store)
            core.failedSaves = [2]
            model.draft?.genre = BatchMetadataValue(isEnabled: true, text: "Jazz", isMixed: false)
            await model.save(using: store, writeChangesToFiles: false)
            XCTAssertEqual(model.lastOperationTrackIDs, [1])
            XCTAssertEqual(model.failures.map(\.trackID), [2])
            XCTAssertEqual(core.infos[1]?.metadata.genre, "Jazz")
            XCTAssertEqual(core.infos[2]?.metadata.genre, "Rock")
            XCTAssertEqual(BatchMetadataOperationReceipt.load(for: [1, 2], defaults: defaults)?.changedTrackIDs, [1])
            await model.undoLastOperation(using: store)
            XCTAssertEqual(core.infos[1]?.metadata.genre, "Rock")
            XCTAssertTrue(model.lastOperationTrackIDs.isEmpty)
            XCTAssertNil(BatchMetadataOperationReceipt.load(for: [1, 2], defaults: defaults))
            XCTAssertFalse(model.isWorking)
        }
    }

    func testFailedUndoRetainsReceiptForRetry() async {
        await withBatch { model, core, store, defaults in
            await model.load(trackIDs: [1, 2], using: store)
            model.draft?.genre = BatchMetadataValue(isEnabled: true, text: "Jazz", isMixed: false)
            await model.save(using: store, writeChangesToFiles: true)
            core.failedUndos = [1]
            await model.undoLastOperation(using: store)
            XCTAssertEqual(model.lastOperationTrackIDs, [1])
            XCTAssertEqual(BatchMetadataOperationReceipt.load(for: [1, 2], defaults: defaults)?.changedTrackIDs, [1])
            core.failedUndos = []
            await model.undoLastOperation(using: store)
            XCTAssertTrue(model.lastOperationTrackIDs.isEmpty)
            XCTAssertEqual(core.infos[1]?.metadata.genre, "Rock")
        }
    }

    func testBatchLoadSelectionChangeRejectsOldResult() async {
        await withBatch { model, core, store, _ in
            let gate = CoordinationGate()
            let first = core.infos[1]!
            core.infoHandler = { id in
                if id == 1 { await gate.pause(); return first }
                return CoordinationTestCore.info(id)
            }
            let old = Task { await model.load(trackIDs: [1], using: store) }
            await gate.started()
            await model.load(trackIDs: [2], using: store)
            await gate.release()
            await old.value
            XCTAssertEqual(model.infos.map { $0.track.id }, [2])
            XCTAssertEqual(model.completed, 1)
            XCTAssertFalse(model.isWorking)
        }
    }

    func testPlaybackCoreChangeStopsQueueConstructionBeforePublication() async {
        let core = CoordinationTestCore()
        var current = true
        core.onPlay = { current = false }
        var publications = 0
        do {
            try await PlaybackCoordinator().playTracks([Fixtures.track, Fixtures.track(id: 2, trackNumber: 2, discNumber: 1)],
                startingAt: nil, shuffle: false, core: core, isCurrent: { current }, publish: { _ in publications += 1 })
            XCTFail("Expected old core operation to stop")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(core.playbackOperations, ["collection"])
        XCTAssertEqual(publications, 0)
    }

    private func withBatch(_ body: (BatchMetadataPresentation, CoordinationTestCore, DurvaldCoreStore, UserDefaults) async -> Void) async {
        let suite = "Durvald.R10Tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let core = CoordinationTestCore()
        core.infos = [1: CoordinationTestCore.info(1), 2: CoordinationTestCore.info(2)]
        await body(BatchMetadataPresentation(defaults: defaults), core, DurvaldCoreStore(core: core), defaults)
    }
}

private final class CoordinationTestCore: DurvaldCore {
    var discographyHandler: (@Sendable (Int64, UInt64) async -> ArtistDiscographyPage)?
    var artistTrackHandler: (@Sendable (Int64) async -> [Track])?
    var infoHandler: (@Sendable (Int64) async -> TrackInfo)?
    var infos: [Int64: TrackInfo] = [:]
    var originals: [Int64: TrackInfo] = [:]
    var failedSaves: Set<Int64> = []
    var failedUndos: Set<Int64> = []
    var savedIDs: [Int64] = []
    var playbackOperations: [String] = []
    var onPlay: (@MainActor () -> Void)?
    init() { super.init(noPointer: .init()) }
    required init(unsafeFromRawPointer pointer: UnsafeMutableRawPointer) {
        fatalError("CoordinationTestCore only supports noPointer fixtures")
    }
    override func artistTracks(artistId: Int64) async throws -> [Track] { await artistTrackHandler?(artistId) ?? [] }
    override func artistReleases(artistId: Int64) async throws -> [Release] { [] }
    override func artistDetails(artistId: Int64, language: String) async throws -> ArtistDetails { throw CocoaError(.fileNoSuchFile) }
    override func artistIdentity(artistId: Int64) async throws -> ArtistIdentity { throw CocoaError(.fileNoSuchFile) }
    override func artistPopularTracks(artistId: Int64) async throws -> ArtistPopularTracks? { nil }
    override func artistDiscography(artistId: Int64, pageSize: UInt64, offset: UInt64) async throws -> ArtistDiscographyPage {
        if let discographyHandler { return await discographyHandler(artistId, offset) }
        return Self.page(artistId)
    }
    static func page(_ artistID: Int64) -> ArtistDiscographyPage {
        .init(artistId: artistID, identityGeneration: 1, catalogGeneration: 1, items: [], nextOffset: nil,
              remoteExhausted: true, remoteNextOffset: nil, remoteTotal: nil, lastSuccessAt: nil, stale: false)
    }

    override func syncArtistReleaseMetadata(artistId: Int64) async throws -> [Release] { [] }
    override func trackInfo(trackId: Int64) async throws -> TrackInfo {
        if let infoHandler { return await infoHandler(trackId) }
        guard let info = infos[trackId] else { throw CocoaError(.fileNoSuchFile) }
        return info
    }
    override func saveTrackMetadata(trackId: Int64, metadata: TrackMetadataEdit, writeToFile: Bool) async throws -> TrackInfo {
        if failedSaves.contains(trackId) { throw CocoaError(.fileWriteNoPermission) }
        savedIDs.append(trackId)
        originals[trackId] = infos[trackId]
        var value = infos[trackId]!
        value.metadata = metadata
        value.track.title = metadata.title
        infos[trackId] = value
        return value
    }
    override func undoTrackMetadata(trackId: Int64) async throws -> TrackInfo {
        if failedUndos.contains(trackId) { throw CocoaError(.fileWriteNoPermission) }
        guard let original = originals.removeValue(forKey: trackId) else { throw CocoaError(.fileNoSuchFile) }
        infos[trackId] = original
        return original
    }
    override func tracksPage(pageSize: UInt64, offset: UInt64) async throws -> TrackPage { .init(items: [], nextOffset: nil) }
    override func releasesPage(pageSize: UInt64, offset: UInt64) async throws -> ReleasePage { .init(items: [], nextOffset: nil) }
    override func artists() async throws -> [Artist] { [] }
    override func clearQueue() async throws { playbackOperations.append("clear") }
    override func playCollection(trackIds: [Int64], sourceContexts: [String], startingPosition: UInt64?, shuffleEnabled: Bool?) async throws -> PlaybackSnapshot {
        playbackOperations.append("collection")
        await onPlay?()
        return Fixtures.playingSnapshot
    }

    override func playWithContext(trackId: Int64, sourceContext: String) async throws -> PlaybackSnapshot {
        var result = try await play(trackId: trackId)
        result.sourceContext = sourceContext
        return result
    }

    override func addToQueueWithContext(trackId: Int64, sourceContext: String) async throws {
        try await addToQueue(trackId: trackId)
    }

    override func play(trackId: Int64) async throws -> PlaybackSnapshot {
        playbackOperations.append("play:\(trackId)")
        await onPlay?()
        return Fixtures.playingSnapshot
    }
    override func addToQueue(trackId: Int64) async throws { playbackOperations.append("enqueue:\(trackId)") }
    static func info(_ id: Int64) -> TrackInfo {
        let track = Fixtures.track(id: id, trackNumber: 1, discNumber: 1)
        return TrackInfo(track: track, metadata: .init(title: track.title, artist: track.artist, albumArtist: track.artist,
            album: track.release, genre: "Rock", year: 2024, trackNumber: 1, discNumber: 1, composer: "", comment: ""), canUndo: false)
    }
}

private actor CoordinationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func pause() async { await withCheckedContinuation { continuation = $0; waiter?.resume(); waiter = nil } }
    func started() async { if continuation != nil { return }; await withCheckedContinuation { waiter = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
