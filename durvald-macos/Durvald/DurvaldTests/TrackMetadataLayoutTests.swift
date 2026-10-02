import AppKit
import SwiftUI
import XCTest
@testable import Durvald

@MainActor
final class TrackMetadataLayoutTests: XCTestCase {
    func testRenderMetadataWindow() throws {
        let fake = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        var track = Fixtures.track
        track.title = "another night"
        track.artist = "Oklou"
        track.release = "Galore"
        fake.trackInfoResult = TrackInfo(track: track, metadata: TrackMetadataEdit(
            title: track.title, artist: track.artist, albumArtist: track.artist, album: track.release,
            genre: "", year: 2020, trackNumber: 10, discNumber: 1, composer: "", comment: ""
        ), canUndo: false)
        let host = NSHostingView(rootView: TrackInfoSheet(trackID: track.id)
            .environment(DurvaldCoreStore(core: fake, tracks: [track]))
            .preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 780),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.frame.width, 680, accuracy: 1)
        XCTAssertEqual(host.frame.height, 780, accuracy: 1)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/durvald-metadata-reference.png"))
    }
}
