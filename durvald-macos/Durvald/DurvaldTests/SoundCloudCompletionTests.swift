import AppKit
import XCTest
import WebKit
import CoreGraphics
@testable import Durvald

@MainActor
final class SoundCloudCompletionTests: XCTestCase {
    private struct Fixture {
        let core: DurvaldCore
        let directory: URL
        let source: TrackSource
        let local: Track
    }
    private func fixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("soundcloud-completion-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audio = directory.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        var wave = Data()
        func text(_ value: String) { wave.append(Data(value.utf8)) }
        func u32(_ value: UInt32) { var v = value.littleEndian; wave.append(Data(bytes: &v, count: 4)) }
        func u16(_ value: UInt16) { var v = value.littleEndian; wave.append(Data(bytes: &v, count: 2)) }
        let bytes: UInt32 = 44_100 * 2 * 30
        text("RIFF"); u32(36 + bytes); text("WAVEfmt "); u32(16); u16(1); u16(1)
        u32(44_100); u32(88_200); u16(2); u16(16); text("data"); u32(bytes)
        wave.append(Data(repeating: 0, count: Int(bytes)))
        try wave.write(to: audio.appendingPathComponent("next.wav"))
        let core = try await open(config: CoreConfig(databasePath: directory.appendingPathComponent("library.sqlite").path,
            appSupportDir: directory.path, coversDir: directory.appendingPathComponent("covers").path,
            keychainService: "soundcloud-completion-\(UUID())"))
        _ = try await core.scanLibrary(paths: [audio.path])
        let tracks = try await core.tracksPage(pageSize: 10, offset: 0)
        let local = try XCTUnwrap(tracks.items.first)
        let session = core.sourceSearchSession()
        let entry = CatalogEntry(reference: CatalogReference(provider: "test", kind: .recording, id: UUID().uuidString),
            title: "Completion fixture", artistCredit: nil, versionLabel: nil, durationSeconds: nil, canonicalUrl: nil)
        let page = try await session.search(provider: "service-links", entry: entry,
            link: "https://soundcloud.com/forss/flickermood", generation: 1)
        let source = try await session.attachCandidate(candidateId: page.candidates[0].candidateId, trackId: nil, confirmed: true)
        await session.close()
        try await core.setVolume(volume: 0)
        return Fixture(core: core, directory: directory, source: source, local: local)
    }
    private func wait(_ seconds: TimeInterval, until predicate: () async throws -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if try await predicate() { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
    private func record(_ name: String, _ report: [String: Any]) throws {
        guard let path = ProcessInfo.processInfo.environment["DURVALD_SOUNDCLOUD_COMPLETION_REPORT_DIR"] else { return }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("\(name).json"), options: .atomic)
    }
    private func run(live: Bool, seekNearEnd: Bool) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        var events: [[String: Any]] = []
        var lastProgressSample: TimeInterval = -10
        let started = Date()
        let observer: (EmbeddedEventKind, Double, Double?) -> Void = { kind, position, duration in
            let elapsed = Date().timeIntervalSince(started)
            if kind != .progress || elapsed - lastProgressSample >= 10 {
                if kind == .progress { lastProgressSample = elapsed }
                events.append(["kind": String(describing: kind), "elapsed": Date().timeIntervalSince(started), "position": position, "duration": duration as Any? ?? NSNull()])
            }
        }
        let controller: EmbeddedPlayerController
        if live { controller = EmbeddedPlayerController(eventObserver: observer) }
        else {
            controller = EmbeddedPlayerController(eventObserver: observer, pageBuilder: { _, _ in
                """
                <html><script>
                let position=0;const duration=2;const send=kind=>window.webkit.messageHandlers.durvaldPlayback.postMessage({kind,position,duration});
                window.durvaldCommand=(kind,value)=>{if(kind==='pause')send('paused');if(kind==='play')send('playing');if(kind==='seek'){position=value;send('seeked');}};
                send('ready');send('playing');setTimeout(()=>{position=.6;send('progress');},650);
                setTimeout(()=>{position=1.2;send('progress');},1250);setTimeout(()=>{position=2;send('ended');send('ended');},2100);
                </script></html>
                """
            })
        }
        try await controller.connect(to: f.core)
        let activity = live ? ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Validate official player completion") : nil
        defer { if let activity { ProcessInfo.processInfo.endActivity(activity) } }
        if live { NSApp.activate() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 210), styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil); window.contentView = nil }
        _ = try await f.core.playCollection(trackIds: [f.source.trackId, f.local.id, f.local.id], sourceContexts: ["completion.remote", "completion.next", "completion.duplicate"], startingPosition: 0, shuffleEnabled: false)
        window.contentView = controller.webView; window.makeKeyAndOrderFront(nil)
        let initialQueue = try await f.core.queue()
        let initialEmbedded = await f.core.embeddedPlayback()
        let generation = try XCTUnwrap(initialEmbedded?.generation)
        let playing = try await wait(30) { await f.core.playback().isPlaying }
        XCTAssertTrue(playing, "Official widget must begin playback")
        if playing && seekNearEnd {
            let observed = try await wait(10) { await f.core.playback().positionSeconds > 0.5 }
            XCTAssertTrue(observed)
            let beforeSeek = await f.core.playback()
            let duration = try XCTUnwrap(beforeSeek.durationSeconds)
            try await f.core.seek(seconds: UInt64(max(0, duration - 3)))
        }
        let terminal = try await wait(live && !seekNearEnd ? 260 : 45) {
            let playback = await f.core.playback()
            let embedded = await f.core.embeddedPlayback()
            return playback.currentTrack?.id == f.local.id || embedded?.state == .failed
        }
        let playback = await f.core.playback()
        let embedded = await f.core.embeddedPlayback()
        let history = try await f.core.playbackHistoryPage(pageSize: 20, offset: 0)
        let finish = events.contains { $0["kind"] as? String == "ended" }
        let advanced = playback.currentTrack?.id == f.local.id
        let failureRecoverable = embedded?.state == .failed && embedded?.message?.isEmpty == false && !playback.isPlaying
        if finish {
            XCTAssertTrue(advanced, "Observed FINISH must advance the canonical queue")
            XCTAssertEqual(playback.sourceContext, "completion.next")
            XCTAssertEqual(playback.queue.first?.occurrenceId, initialQueue.dropFirst().first?.occurrenceId)
            XCTAssertEqual(playback.queue.count, 2, "Duplicate FINISH must not skip another occurrence")
            let expected = seekNearEnd ? 0 : 1
            XCTAssertEqual(history.items.count, expected)
            if !seekNearEnd {
                XCTAssertEqual(history.items.first?.trackId, f.source.trackId)
                XCTAssertEqual(history.items.first?.sourceId, f.source.sourceId)
                XCTAssertNotNil(history.items.first?.effectiveDurationSeconds)
            }
            // Re-delivery from the previous generation cannot touch the next item.
            try await f.core.reportEmbeddedPlaybackEvent(event: EmbeddedPlaybackEvent(generation: generation, sequence: 999_999,
                kind: .ended, positionSeconds: 213, durationSeconds: 214))
            let again = await f.core.playback()
            let againHistory = try await f.core.playbackHistoryPage(pageSize: 20, offset: 0)
            XCTAssertEqual(again.queue.first?.occurrenceId, playback.queue.first?.occurrenceId)
            XCTAssertEqual(againHistory.items.count, expected)
        } else {
            XCTAssertTrue(failureRecoverable, "Missing FINISH must produce a recoverable failure")
            XCTAssertTrue(history.items.isEmpty, "No history without a transport completion")
            XCTAssertEqual(playback.currentTrack?.id, f.source.trackId)
            XCTAssertEqual(playback.queue.count, 3, "Failure must preserve next occurrences")
        }
        XCTAssertTrue(terminal)
        let name = live ? (seekNearEnd ? "seek-near-end" : "natural-end") : "fixture-completion"
        try record(name, ["case": name, "live": live, "finish_observed": finish, "queue_advanced": advanced,
            "recoverable_failure": failureRecoverable, "history_count": history.items.count,
            "heard_seconds": history.items.first?.durationSeconds as Any? ?? NSNull(),
            "effective_duration_seconds": history.items.first?.effectiveDurationSeconds as Any? ?? NSNull(), "elapsed_seconds": Date().timeIntervalSince(started),
            "events": events, "completion_without_seek": !seekNearEnd, "terminal_observed": terminal,
            "terminal_position_seconds": playback.positionSeconds,
            "reported_duration_seconds": playback.durationSeconds as Any? ?? NSNull()])
        try await f.core.stop()
        try await f.core.detachEmbeddedPlaybackHost()
        XCTAssertNil(controller.webView)
        if live && !seekNearEnd { XCTAssertTrue(finish, "Natural completion needs a real FINISH; failure recovery alone is insufficient") }
    }
    func testSoundCloudAdapterSeeksWithoutPlayAndOnlyFinishesOnSDKEvent() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        var finishes = 0
        let fakeSDK = """
        window.fixture={handlers:{},plays:0,seeks:[],emit(name,data){(this.handlers[name]||[]).forEach(f=>f(data||{}));}};
        const fakeWidget={bind(name,fn){(fixture.handlers[name]??=[]).push(fn);if(name==='ready')setTimeout(()=>fixture.emit('ready'),0);},
        getDuration(fn){fn(90000);},setVolume(){},isPaused(fn){fn(false);},
        play(){fixture.plays++;fixture.emit('play');},pause(){fixture.emit('pause');},seekTo(value){fixture.seeks.push(value);fixture.emit('seek',{currentPosition:value});}};
        window.SC={Widget:()=>fakeWidget};SC.Widget.Events={READY:'ready',PLAY:'play',PAUSE:'pause',SEEK:'seek',PLAY_PROGRESS:'progress',FINISH:'finish',ERROR:'error'};
        """
        let sdkURL = "data:text/javascript;base64," + Data(fakeSDK.utf8).base64EncodedString()
        let controller = EmbeddedPlayerController(eventObserver: { kind, _, _ in if kind == .ended { finishes += 1 } }, pageBuilder: { url, volume in
            EmbeddedPlayerController.html(url: url, volume: volume)
                .replacingOccurrences(of: "https://w.soundcloud.com/player/api.js", with: sdkURL)
                .replacingOccurrences(of: "https://w.soundcloud.com/player/?url=", with: "about:blank#")
        })
        try await controller.connect(to: f.core)
        _ = try await f.core.playEmbeddedTrackSource(trackId: f.source.trackId, sourceId: f.source.sourceId)
        let ready = try await wait(5) { await f.core.playback().isPlaying }
        XCTAssertTrue(ready)
        let view = try XCTUnwrap(controller.webView)
        try await f.core.seek(seconds: 89)
        let sought = try await wait(5) { await f.core.playback().positionSeconds == 89 }
        XCTAssertTrue(sought)
        let playCalls = try await view.evaluateJavaScript("fixture.plays") as? Int
        XCTAssertEqual(playCalls, 1, "Seek must not issue another PLAY before the asynchronous seek settles")
        try await f.core.pause()
        let paused = try await wait(5) { await f.core.playback().isPaused }
        XCTAssertTrue(paused)
        try await f.core.seek(seconds: 45)
        let pausedSeek = try await wait(5) { await f.core.playback().positionSeconds == 45 }
        XCTAssertTrue(pausedSeek)
        let pausedPlayCalls = try await view.evaluateJavaScript("fixture.plays") as? Int
        XCTAssertEqual(pausedPlayCalls, 1, "Seek while paused must remain paused")
        try await f.core.resume()
        let resumed = try await wait(5) { await f.core.playback().isPlaying }
        XCTAssertTrue(resumed)
        _ = try await view.evaluateJavaScript("fixture.emit('progress',{currentPosition:90000});")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(finishes, 0, "Position at duration is not a provider FINISH")
        _ = try await view.evaluateJavaScript("fixture.emit('finish',{currentPosition:90000});fixture.emit('finish',{currentPosition:90000});")
        let ended = try await wait(5) { await f.core.embeddedPlayback()?.state == .ended }
        XCTAssertTrue(ended)
        XCTAssertEqual(finishes, 1)
        let history = try await f.core.playbackHistoryPage(pageSize: 20, offset: 0)
        XCTAssertTrue(history.items.isEmpty)
        try await f.core.detachEmbeddedPlaybackHost()
    }

    func testExplicitFailureRetryAndManualNextPreserveQueueWithoutHistory() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let controller = EmbeddedPlayerController(pageBuilder: { _, _ in
            "<html><script>window.durvaldCommand=()=>{};const send=kind=>window.webkit.messageHandlers.durvaldPlayback.postMessage({kind,position:0,duration:90});send('ready');send('playing');</script></html>"
        })
        try await controller.connect(to: f.core)
        _ = try await f.core.playCollection(trackIds: [f.source.trackId, f.local.id, f.local.id], sourceContexts: ["remote", "next", "duplicate"], startingPosition: 0, shuffleEnabled: false)
        let playing = try await wait(5) { await f.core.playback().isPlaying }
        XCTAssertTrue(playing)
        let initial = await f.core.playback()
        let firstState = await f.core.embeddedPlayback()
        let first = try XCTUnwrap(firstState?.generation)
        try await f.core.reportEmbeddedPlaybackEvent(event: EmbeddedPlaybackEvent(generation: first, sequence: 100, kind: .failed, positionSeconds: 0, durationSeconds: 90))
        try await controller.retryFailedPlayback(generation: first)
        let resumed = try await wait(5) { await f.core.playback().isPlaying }
        XCTAssertTrue(resumed)
        let secondState = await f.core.embeddedPlayback()
        let second = try XCTUnwrap(secondState?.generation)
        XCTAssertNotEqual(first, second)
        let retry = await f.core.playback()
        XCTAssertEqual(retry.queue, initial.queue)
        try await f.core.reportEmbeddedPlaybackEvent(event: EmbeddedPlaybackEvent(generation: second, sequence: 100, kind: .failed, positionSeconds: 0, durationSeconds: 90))
        let next = try await f.core.nextTrack()
        XCTAssertEqual(next.currentTrack?.id, f.local.id)
        XCTAssertEqual(next.queue.count, 2)
        try await controller.retryFailedPlayback(generation: second)
        let afterStaleRetry = await f.core.playback()
        XCTAssertEqual(afterStaleRetry.queue.first?.occurrenceId, next.queue.first?.occurrenceId)
        let history = try await f.core.playbackHistoryPage(pageSize: 20, offset: 0)
        XCTAssertTrue(history.items.isEmpty)
        try await f.core.stop()
        try await f.core.detachEmbeddedPlaybackHost()
    }

    func testFixtureCompletionRecordsOnceAndPreservesFollowingDuplicate() async throws { try await run(live: false, seekNearEnd: false) }
    private func requireLiveEnvironment() throws {
        guard ProcessInfo.processInfo.environment["DURVALD_SOUNDCLOUD_COMPLETION_LIVE"] == "1" else { throw XCTSkip("Opt-in real SoundCloud completion") }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        if session?["CGSSessionScreenIsLocked"] as? Bool == true {
            throw XCTSkip("Live completion requires an unlocked graphical session; no playback result is approved while locked")
        }
    }
    func testLiveNaturalCompletionAdvancesQueueAndRecordsHistoryOnce() async throws {
        try requireLiveEnvironment()
        try await run(live: true, seekNearEnd: false)
    }
    func testLiveSeekNearEndEitherFinishesOrRecoversWithoutHistory() async throws {
        try requireLiveEnvironment()
        try await run(live: true, seekNearEnd: true)
    }
}
