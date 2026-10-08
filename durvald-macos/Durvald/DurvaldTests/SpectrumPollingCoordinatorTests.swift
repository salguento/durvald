import XCTest
@testable import Durvald

@MainActor
final class SpectrumPollingCoordinatorTests: XCTestCase {
    func testPolicyRequiresCoreActiveSceneVisibilityAndPlayback() {
        let core = NSObject()
        for mask in 0..<16 {
            let key = SpectrumPollingKey(coreID: mask & 1 != 0 ? ObjectIdentifier(core) : nil,
                isActive: mask & 2 != 0, isVisible: mask & 4 != 0, isPlaying: mask & 8 != 0)
            XCTAssertEqual(key.shouldAcquire, mask == 15)
        }
        var key = SpectrumPollingKey(coreID: ObjectIdentifier(core), isActive: true, isVisible: true, isPlaying: true)
        key.reduceMotion = true
        XCTAssertTrue(key.shouldAcquire, "Reduce Motion changes animation, not acquisition eligibility")
    }

    func testScalarPlaybackFlagTracksPauseResumeAndInitialState() async {
        let fake = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        let store = DurvaldCoreStore(core: fake, playback: Fixtures.playingSnapshot)
        XCTAssertTrue(store.isPlaybackPlaying)
        await store.togglePause()
        XCTAssertFalse(store.isPlaybackPlaying)
        await store.togglePause()
        XCTAssertTrue(store.isPlaybackPlaying)
        XCTAssertFalse(DurvaldCoreStore().isPlaybackPlaying)
    }

    func testConsumersShareReadsAndOnlyLastCancellationDisables() async {
        let core = SpectrumTestCore()
        let cadence = SpectrumTestCadence()
        let coordinator = SpectrumPollingCoordinator(pause: { await cadence.wait() })
        var firstFrames = 0
        var secondFrames = 0
        let first = Task { await coordinator.observe(core: core) { _ in firstFrames += 1 } }
        await until { await cadence.isWaiting }
        let second = Task { await coordinator.observe(core: core) { _ in secondFrames += 1 } }
        await until { coordinator.consumerCount == 2 }
        await cadence.advance()
        await until { (await cadence.isWaiting) && secondFrames == 1 }
        XCTAssertEqual(core.readCount, 2)
        XCTAssertEqual(core.toggles, [true])
        first.cancel()
        await first.value
        let retiredFrames = firstFrames
        await cadence.advance()
        await until { (await cadence.isWaiting) && secondFrames == 2 }
        XCTAssertEqual(firstFrames, retiredFrames)
        XCTAssertEqual(core.toggles, [true])
        second.cancel()
        await second.value
        await cadence.advance()
        await until { core.toggles == [true, false] }
        XCTAssertEqual(core.readCount, 3)
        XCTAssertEqual(coordinator.consumerCount, 0)
    }

    func testCancelledInFlightReadDoesNotPublishOrReadAgain() async {
        let core = SpectrumTestCore()
        core.holdRead = true
        let coordinator = SpectrumPollingCoordinator()
        var frames = 0
        let consumer = Task { await coordinator.observe(core: core) { _ in frames += 1 } }
        await until { core.readContinuation != nil }
        consumer.cancel()
        await consumer.value
        core.releaseRead()
        await until { core.toggles == [true, false] }
        XCTAssertEqual(frames, 0)
        XCTAssertEqual(core.readCount, 1)
    }

    func testReplacementDuringDisableIsReenabledBySameWorker() async {
        let core = SpectrumTestCore()
        core.holdDisable = true
        let cadence = SpectrumTestCadence()
        let coordinator = SpectrumPollingCoordinator(pause: { await cadence.wait() })
        let first = Task { await coordinator.observe(core: core) { _ in } }
        await until { await cadence.isWaiting }
        first.cancel()
        await first.value
        await cadence.advance()
        await until { core.disableContinuation != nil }
        var frames = 0
        let replacement = Task { await coordinator.observe(core: core) { _ in frames += 1 } }
        await until { coordinator.consumerCount == 1 }
        XCTAssertEqual(core.toggles, [true, false])
        core.releaseDisable()
        await until { (await cadence.isWaiting) && frames == 1 }
        XCTAssertEqual(core.toggles, [true, false, true])
        replacement.cancel()
        await replacement.value
        await cadence.advance()
        await until { core.toggles == [true, false, true, false] }
    }

    func testAlreadyCancelledConsumerDoesNotEnableCore() async {
        let core = SpectrumTestCore()
        let coordinator = SpectrumPollingCoordinator()
        let task = Task { await coordinator.observe(core: core) { _ in XCTFail("Cancelled consumer received bands") } }
        task.cancel()
        await task.value
        XCTAssertEqual(core.toggles, [])
        XCTAssertEqual(core.readCount, 0)
        XCTAssertEqual(coordinator.consumerCount, 0)
    }

    private func until(_ condition: () async -> Bool) async {
        for _ in 0..<1000 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for spectrum lifecycle")
    }
}

@MainActor
private final class SpectrumTestCore: DurvaldCore {
    var toggles: [Bool] = []
    var readCount = 0
    var holdRead = false
    var holdDisable = false
    var readContinuation: CheckedContinuation<Void, Never>?
    var disableContinuation: CheckedContinuation<Void, Never>?

    init() { super.init(noPointer: .init()) }
    required init(unsafeFromRawPointer pointer: UnsafeMutableRawPointer) { fatalError("Test core") }

    override func setSpectrumEnabled(enabled: Bool) async {
        toggles.append(enabled)
        if !enabled && holdDisable {
            holdDisable = false
            await withCheckedContinuation { disableContinuation = $0 }
        }
    }

    override func spectrumSnapshot() async -> SpectrumSnapshot {
        readCount += 1
        if holdRead { await withCheckedContinuation { readContinuation = $0 } }
        return SpectrumSnapshot(bands: Array(repeating: 0.5, count: 16))
    }

    func releaseRead() { holdRead = false; readContinuation?.resume(); readContinuation = nil }
    func releaseDisable() { disableContinuation?.resume(); disableContinuation = nil }
}

private actor SpectrumTestCadence {
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func advance() { continuation?.resume(); continuation = nil }
}
