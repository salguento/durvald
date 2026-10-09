import XCTest
@testable import Durvald

@MainActor
final class PlaybackCollectionTests: XCTestCase {
    func testReleaseCommandsUseAlbumOrderAndSetShuffleExplicitly() async {
        await verify(.release(7), input: [3, 1, 2], ordered: [1, 2, 3])
    }

    func testPlaylistCommandsPreserveRepeatedOccurrences() async {
        await verify(.playlist(7), input: [2, 1, 2], ordered: [2, 1, 2])
    }

    func testArtistCommandsPreserveProvidedTrackOrder() async {
        await verify(.tracks(makeTracks([3, 1, 2])), input: [3, 1, 2], ordered: [3, 1, 2])
    }

    func testEmptyArtistCollectionDoesNotReplaceQueueOrShuffle() async {
        let core = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        let store = DurvaldCoreStore(core: core)
        await PlaybackCollection.tracks([]).perform(.play, using: store)
        await PlaybackCollection.tracks([]).perform(.shuffle, using: store)
        XCTAssertTrue(core.playbackOperations.isEmpty)
        XCTAssertTrue(core.shuffleRequests.isEmpty)
    }

    private func verify(_ collection: PlaybackCollection, input: [Int64], ordered: [Int64]) async {
        for action in [PlaybackCollection.Action.play, .shuffle] {
            let core = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
            core.releaseTrackResults = makeTracks(input)
            core.playlistResultsByID[7] = makeTracks(input)
            let store = DurvaldCoreStore(core: core)
            await collection.perform(action, using: store)
            XCTAssertNil(store.errorMessage)
            XCTAssertEqual(core.playbackOperations.first, "clear")
            let operations = Array(core.playbackOperations.dropFirst())
            XCTAssertTrue(operations.first?.hasPrefix("play:") == true)
            XCTAssertTrue(operations.dropFirst().allSatisfy { $0.hasPrefix("enqueue:") })
            let ids = operations.compactMap { Int64($0.split(separator: ":").last!) }
            if action == .play { XCTAssertEqual(ids, ordered) }
            else { XCTAssertEqual(ids.sorted(), ordered.sorted(), "Shuffle preserves every occurrence") }
            XCTAssertEqual(core.shuffleRequests, [action == .shuffle])
            XCTAssertEqual(store.playback?.shuffleEnabled, action == .shuffle)
        }
    }

    private func makeTracks(_ ids: [Int64]) -> [Track] {
        ids.map { Fixtures.track(id: $0, trackNumber: UInt8($0), discNumber: 1) }
    }
}
