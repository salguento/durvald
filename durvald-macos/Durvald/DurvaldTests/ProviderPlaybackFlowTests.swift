import AppKit
import XCTest
@testable import Durvald

@MainActor
final class ProviderPlaybackFlowTests: XCTestCase {
    private func waitForPlaying(_ core: DurvaldCore) async throws {
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            if await core.embeddedPlayback()?.state == .playing { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("The selected SoundCloud source did not start")
    }
    private func verifyFlow(live: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("provider-flow-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let core = try await open(config: CoreConfig(databasePath: directory.appendingPathComponent("library.sqlite").path, appSupportDir: directory.path, coversDir: directory.appendingPathComponent("covers").path, keychainService: "provider-flow-\(UUID())"))
        let controller: EmbeddedPlayerController
        if live { controller = EmbeddedPlayerController() }
        else {
            controller = EmbeddedPlayerController { _, _ in
                """
                <html><script>
                const send=kind=>window.webkit.messageHandlers.durvaldPlayback.postMessage({kind,position:0,duration:213});
                window.durvaldCommand=(kind)=>{if(kind==='pause')send('paused');if(kind==='play')send('playing');};
                send('ready');send('playing');
                </script></html>
                """
            }
        }
        try await controller.connect(to: core)
        try await core.setVolume(volume: 0)
        let entry = try core.soundcloudLinkEntry(url: "https://soundcloud.com/forss/flickermood?tracking=discard", title: "Flickermood", artist: "Forss")
        let session = core.sourceSearchSession()
        let page = try await session.search(provider: "service-links", entry: entry, link: nil, generation: 1)
        let pageBefore = try await core.tracksPage(pageSize: 10, offset: 0)
        XCTAssertTrue(pageBefore.items.isEmpty)
        _ = try await session.previewCandidate(candidateId: page.candidates[0].candidateId)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.webView
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await waitForPlaying(core)
        await controller.refresh()
        let initial = try XCTUnwrap(controller.status)
        XCTAssertNil(initial.trackId)
        let during = try await core.tracksPage(pageSize: 10, offset: 0)
        XCTAssertTrue(during.items.isEmpty)
        let duringPlayback = await core.playback()
        XCTAssertNil(duringPlayback.currentTrack)
        if live {
            try await Task.sleep(for: .seconds(2))
            let progress = await core.playback()
            XCTAssertGreaterThan(progress.positionSeconds, 0)
        }
        let saved = try await core.saveListeningSource(generation: initial.generation, trackId: nil, confirmed: true)
        let again = try await core.saveListeningSource(generation: initial.generation, trackId: nil, confirmed: true)
        XCTAssertEqual(saved.sourceId, again.sourceId)
        await controller.refresh()
        XCTAssertEqual(controller.status?.generation, initial.generation)
        XCTAssertEqual(controller.status?.trackId, saved.trackId)
        let after = try await core.tracksPage(pageSize: 10, offset: 0)
        XCTAssertEqual(after.items.count, 1)
        let history = try await core.playbackHistoryPage(pageSize: 10, offset: 0)
        XCTAssertTrue(history.items.isEmpty)
        try await core.stop()
        _ = try await core.play(trackId: saved.trackId)
        window.contentView = controller.webView
        try await waitForPlaying(core)
        try await core.setSoundcloudPlaybackEnabled(enabled: false)
        XCTAssertNil(controller.webView)
        let paused = await core.embeddedPlayback()
        XCTAssertNil(paused)
        let enabled = await core.soundcloudPlaybackEnabled()
        XCTAssertFalse(enabled)
        await session.close()
        try await core.detachEmbeddedPlaybackHost()
    }
    func testListenSaveAndDefaultPlaybackThroughRealWebKitAndFFI() async throws { try await verifyFlow(live: false) }
    func testLiveSoundCloudListenThenSave() async throws {
        guard ProcessInfo.processInfo.environment["DURVALD_EMBEDDED_LIVE_SMOKE"] == "1" else { throw XCTSkip("Opt-in live provider flow") }
        try await verifyFlow(live: true)
    }
    func testLiveSharedSoundCloudLinkFromTheReportedForm() async throws {
        guard ProcessInfo.processInfo.environment["DURVALD_EMBEDDED_LIVE_SMOKE"] == "1" else { throw XCTSkip("Opt-in SoundCloud sharing link smoke") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shared-link-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let core = try await open(config: CoreConfig(databasePath: directory.appendingPathComponent("library.sqlite").path, appSupportDir: directory.path, coversDir: directory.appendingPathComponent("covers").path, keychainService: "shared-link-\(UUID())"))
        let input = "https://on.soundcloud.com/ZSZsO6wnA78EIUvH3i"
        let entry = try await core.resolveSoundcloudLinkEntry(url: input, title: "Snooze This On", artist: "Gold Lip")
        XCTAssertEqual(entry.canonicalUrl, "https://soundcloud.com/goldlip/snooze-this-on")
        XCTAssertEqual(entry.reference.id, "goldlip/snooze-this-on")
        XCTAssertEqual(entry.title, "Snooze This On")
        XCTAssertEqual(entry.artistCredit, "Gold Lip")
        let session = core.sourceSearchSession()
        let page = try await session.search(provider: "service-links", entry: entry, link: input, generation: 1)
        XCTAssertNil(page.failure)
        XCTAssertEqual(page.candidates.first?.canonicalUrl, entry.canonicalUrl)
        let library = try await core.tracksPage(pageSize: 10, offset: 0)
        XCTAssertTrue(library.items.isEmpty)
        await session.close()
    }

}
