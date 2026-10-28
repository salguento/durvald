import XCTest
import AppKit
@testable import Durvald

@MainActor
final class EmbeddedPlayerControllerTests: XCTestCase {
    private func fixtureCore(link: String = "https://soundcloud.com/forss/flickermood") async throws -> (DurvaldCore, URL, TrackSource) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("embedded-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let core = try await open(config: CoreConfig(databasePath: directory.appendingPathComponent("library.sqlite").path, appSupportDir: directory.path, coversDir: directory.appendingPathComponent("covers").path, keychainService: "embedded-tests-\(UUID())"))
        let session = core.sourceSearchSession()
        let entry = CatalogEntry(reference: CatalogReference(provider: "test", kind: .recording, id: "fixture"), title: "Fixture", artistCredit: nil, versionLabel: nil, durationSeconds: nil, canonicalUrl: nil)
        let page = try await session.search(provider: "service-links", entry: entry, link: link, generation: 1)
        let source = try await session.attachCandidate(candidateId: page.candidates[0].candidateId, trackId: nil, confirmed: true)
        return (core, directory, source)
    }
    private func awaitState(_ core: DurvaldCore, _ desired: EmbeddedPlaybackState, timeout: TimeInterval = 5) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if await core.embeddedPlayback()?.state == desired { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        let state = await core.embeddedPlayback()
        let playback = await core.playback()
        XCTFail("Expected \(desired); observed \(String(describing: state?.state)); position \(playback.positionSeconds), duration \(String(describing: playback.durationSeconds))")
    }
    func testWebKitEventsCommandsAndAcknowledgedStopThroughRealFFI() async throws {
        let (core, directory, source) = try await fixtureCore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = EmbeddedPlayerController { _, _ in
            """
            <html><body><script>
            let position=0;const duration=90;const send=kind=>window.webkit.messageHandlers.durvaldPlayback.postMessage({kind,position,duration});
            window.durvaldCommand=(kind,value)=>{if(kind==='pause')send('paused');if(kind==='play')send('playing');if(kind==='seek'){position=value;send('seeked');if(value===89){send('ended');send('ended');}}if(kind==='volume')window.observedVolume=value;};
            send('ready');send('playing');
            </script></body></html>
            """
        }
        try await controller.connect(to: core)
        _ = try await core.playEmbeddedTrackSource(trackId: source.trackId, sourceId: source.sourceId)
        try await awaitState(core, .playing)
        XCTAssertNotNil(controller.webView)
        try await core.pause(); try await awaitState(core, .paused)
        try await core.seek(seconds: 23)
        for _ in 0..<100 {
            if await core.playback().positionSeconds == 23 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let sought = await core.playback()
        XCTAssertEqual(sought.positionSeconds, 23)
        try await core.resume(); try await awaitState(core, .playing)
        try await core.seek(seconds: 89); try await awaitState(core, .ended)
        let history = try await core.playbackHistoryPage(pageSize: 20, offset: 0)
        XCTAssertTrue(history.items.isEmpty)
        try await core.stop()
        XCTAssertNil(controller.webView)
        let stopped = await core.embeddedPlayback()
        XCTAssertNil(stopped)
        try await core.detachEmbeddedPlaybackHost()
    }
    func testPauseIntentDuringPageLoadingIsDeliveredWhenCommandsBecomeReady() async throws {
        let (core, directory, source) = try await fixtureCore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = EmbeddedPlayerController { _, _ in
            """
            <html><script>
            setTimeout(()=>{
              const send=kind=>window.webkit.messageHandlers.durvaldPlayback.postMessage({kind,position:0,duration:90});
              window.durvaldCommand=(kind)=>{if(kind==='pause')send('paused');};
              send('ready');send('playing');
            },500);
            </script></html>
            """
        }
        try await controller.connect(to: core)
        _ = try await core.playEmbeddedTrackSource(trackId: source.trackId, sourceId: source.sourceId)
        try await core.pause()
        try await awaitState(core, .paused)
        try await core.detachEmbeddedPlaybackHost()
        XCTAssertNil(controller.webView)
    }
    func testLiveSoundCloudWidget() async throws {
        guard ProcessInfo.processInfo.environment["DURVALD_EMBEDDED_LIVE_SMOKE"] == "1" else { throw XCTSkip("Opt-in live SoundCloud smoke") }
        let (core, directory, source) = try await fixtureCore()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Keep the official player visible and mute only for this automated smoke.
        let controller = EmbeddedPlayerController()
        try await controller.connect(to: core)
        try await core.setVolume(volume: 0)
        _ = try await core.playEmbeddedTrackSource(trackId: source.trackId, sourceId: source.sourceId)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.webView
        window.makeKeyAndOrderFront(nil)
        try await awaitState(core, .playing, timeout: 25)
        try await Task.sleep(for: .seconds(2))
        let playing = await core.playback()
        XCTAssertGreaterThan(playing.positionSeconds, 0)
        XCTAssertNotNil(playing.durationSeconds)
        try await core.pause(); try await awaitState(core, .paused)
        try await core.seek(seconds: 10)
        try await core.resume(); try await awaitState(core, .playing)
        try await Task.sleep(for: .seconds(1))
        let sought = await core.playback()
        XCTAssertGreaterThanOrEqual(sought.positionSeconds, 9)
        if let duration = sought.durationSeconds {
            let target = max(0, duration - 3)
            try await core.seek(seconds: UInt64(target))
            // The remote widget can buffer after seeking into an uncached tail.
            // Only a provider FINISH event can satisfy the ended assertion.
            try await awaitState(core, .ended, timeout: 25)
        }
        let history = try await core.playbackHistoryPage(pageSize: 20, offset: 0)
        XCTAssertTrue(history.items.isEmpty, "Seeking to the end must not create a listen")
        try await core.stop()
        XCTAssertNil(controller.webView)
        window.orderOut(nil)
        try await core.detachEmbeddedPlaybackHost()
    }
    func testLiveUnavailableSoundCloudWidget() async throws {
        guard ProcessInfo.processInfo.environment["DURVALD_EMBEDDED_LIVE_SMOKE"] == "1" else { throw XCTSkip("Opt-in live SoundCloud smoke") }
        let (core, directory, source) = try await fixtureCore(link: "https://soundcloud.com/durvald-unavailable-fixture-20261028/this-track-does-not-exist")
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = EmbeddedPlayerController()
        try await controller.connect(to: core)
        _ = try await core.playEmbeddedTrackSource(trackId: source.trackId, sourceId: source.sourceId)
        try await awaitState(core, .failed, timeout: 35)
        XCTAssertNil(controller.webView)
        let snapshot = await core.playback()
        XCTAssertFalse(snapshot.isPlaying)
        try await core.detachEmbeddedPlaybackHost()
    }
}
