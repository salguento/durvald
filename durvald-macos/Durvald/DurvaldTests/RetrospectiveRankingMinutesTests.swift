import Foundation
import XCTest
@testable import Durvald

final class RetrospectiveRankingMinutesTests: XCTestCase {
    private func track(_ id: Int64, artistID: Int64, releaseID: Int64) -> Track {
        var track = Fixtures.track
        track.id = id
        track.artistId = artistID
        track.releaseId = releaseID
        track.title = "Faixa \(id)"
        track.artist = "Artista \(artistID)"
        return track
    }
    func testMinutesAggregateAcrossTracksForArtistAndAlbumBeforeConversion() {
        let first = track(1, artistID: 10, releaseID: 100)
        let second = track(2, artistID: 10, releaseID: 100)
        var accumulator = RetrospectiveRankingSnapshot.Accumulator(tracks: [1: first, 2: second], releases: [:])
        accumulator.record(trackID: 1, isCurrent: true, durationSeconds: 59)
        accumulator.record(trackID: 2, isCurrent: true, durationSeconds: 61)
        accumulator.record(trackID: 1, isCurrent: false, durationSeconds: 600)
        let snapshot = accumulator.snapshot()
        XCTAssertEqual(snapshot[.artists].top.first?.listenedSeconds, 120)
        XCTAssertEqual(snapshot[.artists].top.first?.minutesLabel, "2 minutos")
        XCTAssertEqual(snapshot[.albums].top.first?.listenedSeconds, 120)
        XCTAssertEqual(snapshot[.tracks].top.first?.id, 1)
        XCTAssertEqual(snapshot[.tracks].top.first?.minutesLabel, "0 minutos")
    }
    func testArtistsAndAlbumsSortByMinutesWhileSongsSortByPlays() {
        let first = track(1, artistID: 10, releaseID: 100)
        let second = track(2, artistID: 20, releaseID: 200)
        var accumulator = RetrospectiveRankingSnapshot.Accumulator(tracks: [1: first, 2: second], releases: [:])
        accumulator.record(trackID: 1, isCurrent: true, durationSeconds: 30)
        accumulator.record(trackID: 1, isCurrent: true, durationSeconds: 30)
        accumulator.record(trackID: 2, isCurrent: true, durationSeconds: 180)
        let snapshot = accumulator.snapshot()
        XCTAssertEqual(snapshot[.artists].top.map(\.id), [20, 10])
        XCTAssertEqual(snapshot[.albums].top.map(\.id), [200, 100])
        XCTAssertEqual(snapshot[.tracks].top.map(\.id), [1, 2])
    }
    func testMissingMetadataStillKeepsRecordedMinutesAndOverflowSaturates() {
        var accumulator = RetrospectiveRankingSnapshot.Accumulator(tracks: [:], releases: [:])
        accumulator.record(trackID: 999, isCurrent: true, durationSeconds: .max)
        accumulator.record(trackID: 999, isCurrent: true, durationSeconds: 60)
        let snapshot = accumulator.snapshot()
        XCTAssertEqual(snapshot[.tracks].top.first?.listenedSeconds, .max)
        XCTAssertEqual(snapshot.unresolvedListens, 2)
        XCTAssertTrue(snapshot[.artists].top.isEmpty)
    }
}
