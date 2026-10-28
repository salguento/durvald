import AppKit
import WebKit
import XCTest
@testable import Durvald

@MainActor
final class YouTubePlayerTests: XCTestCase {
    private func wait(_ predicate: @escaping () -> Bool, seconds: Double = 8) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { if predicate() { return }; try await Task.sleep(for: .milliseconds(20)) }
        XCTFail("YouTube host did not reach the expected state")
    }
    private func execute(_ controller: EmbeddedPlayerController, _ kind: EmbeddedCommandKind, value: Double = 0) async -> Bool {
        await withCheckedContinuation { continuation in controller.execute(EmbeddedPlaybackCommand(generation: "youtube-fixture", kind: kind, url: kind == .load ? "https://www.youtube.com/watch?v=M7lc1UVf-VE" : nil, value: value)) { continuation.resume(returning: $0) } }
    }
    private func assertExecute(_ controller: EmbeddedPlayerController, _ kind: EmbeddedCommandKind, value: Double = 0) async {
        let accepted = await execute(controller, kind, value: value); XCTAssertTrue(accepted)
    }
    func testVisibleYouTubeHostUsesNonceScopedLoopbackAndStopsItsServer() async throws {
        var observed: [EmbeddedEventKind] = []
        let controller = EmbeddedPlayerController(eventObserver: { kind, _, _ in observed.append(kind) }, pageBuilder: { _, _ in
            """
            <html><script>
            const send=kind=>window.webkit.messageHandlers.durvaldPlayback.postMessage({kind,position:0,duration:10});
            window.durvaldCommand=kind=>{if(kind==='pause')send('paused');if(kind==='play')send('playing');if(kind==='seek')send('seeked');};
            send('ready');send('playing');
            </script></html>
            """
        })
        await assertExecute(controller, .load)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.webView; window.makeKeyAndOrderFront(nil); defer { window.orderOut(nil) }
        try await wait { observed.contains(.playing) }
        let page = try XCTUnwrap(controller.webView?.url)
        XCTAssertEqual(page.host, "127.0.0.1"); XCTAssertEqual(page.scheme, "http"); XCTAssertGreaterThan(page.path.count, 30)
        let (_, wrong) = try await URLSession.shared.data(from: page.deletingLastPathComponent().appendingPathComponent("unknown"))
        XCTAssertEqual((wrong as? HTTPURLResponse)?.statusCode, 404)
        await assertExecute(controller, .pause); try await wait { observed.contains(.paused) }
        await assertExecute(controller, .seek, value: 3); try await wait { observed.contains(.seeked) }
        await assertExecute(controller, .stop); XCTAssertNil(controller.webView)
    }
    func testLiveOfficialYouTubeVideoControlsAndProgress() async throws {
        guard ProcessInfo.processInfo.environment["DURVALD_YOUTUBE_LIVE_SMOKE"] == "1" else { throw XCTSkip("Opt-in live official YouTube iframe") }
        var observed: [EmbeddedEventKind] = []; var position = 0.0
        let controller = EmbeddedPlayerController(eventObserver: { kind, value, _ in observed.append(kind); position = max(position, value) })
        await assertExecute(controller, .load)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.webView; window.makeKeyAndOrderFront(nil); defer { window.orderOut(nil) }
        try await wait({ observed.contains(.playing) && position > 0.5 || observed.contains(.failed) }, seconds: 30)
        XCTAssertFalse(observed.contains(.failed)); XCTAssertGreaterThan(position, 0.5)
        await assertExecute(controller, .pause); try await wait { observed.contains(.paused) }
        let playing = observed.filter { $0 == .playing }.count
        await assertExecute(controller, .play); try await wait { observed.filter { $0 == .playing }.count > playing }
        await assertExecute(controller, .seek, value: 5); try await wait { observed.contains(.seeked) }
        await assertExecute(controller, .stop); XCTAssertNil(controller.webView)
    }
}
