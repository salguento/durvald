import Observation
import XCTest
@testable import Durvald

@MainActor
final class SettingsStateTests: XCTestCase {
    func testGeneralDraftSurvivesAudioAndEqualizerUpdates() {
        var remote = settingsFixture()
        var draft = SettingsDraft(GeneralSettingsValues(remote))
        draft.value.crossFade = true
        draft.value.crossFadeDuration = 12
        remote.preferredOutputDeviceId = "DAC"
        remote.equalizer.enabled = true
        draft.receive(GeneralSettingsValues(remote))
        XCTAssertTrue(draft.isDirty)
        XCTAssertTrue(draft.value.crossFade)
        XCTAssertEqual(draft.value.crossFadeDuration, 12)
    }

    func testDirtyEqualizerSurvivesRemoteChangesAndCleanDraftTracksThem() {
        var draft = SettingsDraft(settingsFixture().equalizer)
        var remote = draft.value
        remote.preampDb = 2
        draft.receive(remote)
        XCTAssertEqual(draft.value.preampDb, 2)
        XCTAssertFalse(draft.isDirty)
        draft.value.bandGainsDb[0] = 7
        remote.preampDb = 3
        draft.receive(remote)
        XCTAssertEqual(draft.value.bandGainsDb[0], 7)
        XCTAssertEqual(draft.value.preampDb, 2)
        XCTAssertEqual(draft.snapshot.preampDb, 3)
        XCTAssertTrue(draft.isDirty)
    }

    func testSaveAcknowledgementKeepsEditsMadeWhileSaving() {
        var draft = SettingsDraft(settingsFixture().equalizer)
        draft.value.preampDb = 4
        let submitted = draft.value
        draft.value.preampDb = 6
        draft.receive(submitted)
        XCTAssertEqual(draft.value.preampDb, 6)
        XCTAssertTrue(draft.isDirty)
        draft.receive(draft.value)
        XCTAssertFalse(draft.isDirty)
        var next = draft.value
        next.preampDb = 8
        draft.receive(next)
        XCTAssertEqual(draft.value.preampDb, 8)
    }

    func testLegacyPresetsNormalizeWithoutChangingCurves() {
        for (old, new) in [("Bass Boost", "Increase Bass"), ("Treble Boost", "Increase Treble"), ("Vocais", "Increase Vocals")] {
            var remote = settingsFixture().equalizer
            remote.preset = old
            remote.bandGainsDb[0] = 5
            let normalized = remote.editingValue
            XCTAssertEqual(normalized.preset, new)
            XCTAssertEqual(normalized.bandGainsDb, remote.bandGainsDb)
            var draft = SettingsDraft(normalized)
            draft.receive(remote.editingValue)
            XCTAssertFalse(draft.isDirty)
        }
    }

    func testPendingAudioSelectionSurvivesPollingAndCanRollBack() {
        var draft = SettingsDraft("A")
        draft.value = "B"
        draft.receive("A")
        XCTAssertEqual(draft.value, "B")
        draft.reset(to: "A")
        XCTAssertFalse(draft.isDirty)
        draft.value = "B"
        draft.receive("B")
        XCTAssertFalse(draft.isDirty)
    }

    func testUnchangedRefreshesDoNotNotifyObserversAndChangesDo() async {
        let core = SettingsTestCore()
        let store = DurvaldCoreStore(core: core)
        await store.refreshAudioOutputs()
        await store.refreshEqualizerMetrics()
        let notifications = SettingsNotificationCounter()
        withObservationTracking {
            _ = store.appSettings
            _ = store.audioOutputState
            _ = store.equalizerMetrics
        } onChange: { notifications.increment() }
        await store.refreshAudioOutputs()
        await store.refreshEqualizerMetrics()
        XCTAssertEqual(notifications.value, 0)
        core.output.usingFallback = true
        await store.refreshAudioOutputs()
        XCTAssertEqual(notifications.value, 1)
        XCTAssertEqual(store.audioOutputState?.usingFallback, true)
        withObservationTracking {
            _ = store.equalizerMetrics
        } onChange: { notifications.increment() }
        core.metrics.processedFrames = 128
        await store.refreshEqualizerMetrics()
        XCTAssertEqual(notifications.value, 2)
        XCTAssertEqual(store.equalizerMetrics?.processedFrames, 128)
    }

    func testSettingsReadFailureKeepsPublishedSnapshot() async {
        let core = SettingsTestCore()
        let store = DurvaldCoreStore(core: core)
        await store.refreshAudioOutputs()
        let previous = store.appSettings
        core.failSettings = true
        await store.refreshAudioOutputs()
        XCTAssertEqual(store.appSettings, previous)
        core.failSelection = true
        let succeeded = await store.selectAudioOutputDevice("DAC")
        XCTAssertFalse(succeeded)
        XCTAssertEqual(store.audioOutputState?.preferredDeviceId, nil)
    }

    func testEqualizerSaveAcknowledgesSnapshotAndFailureKeepsIt() async {
        let core = SettingsTestCore()
        let store = DurvaldCoreStore(core: core)
        await store.refreshAudioOutputs()
        var equalizer = core.configuration.equalizer
        equalizer.preampDb = 5
        await store.updateEqualizer(equalizer)
        XCTAssertEqual(store.appSettings?.equalizer, equalizer)
        core.failUpdate = true
        equalizer.preampDb = 9
        await store.updateEqualizer(equalizer)
        XCTAssertEqual(store.appSettings?.equalizer.preampDb, 5)
    }

    func testCancelledMetricsReadDoesNotPublish() async {
        let core = SettingsTestCore()
        core.holdMetrics = true
        let store = DurvaldCoreStore(core: core)
        let task = Task { await store.refreshEqualizerMetrics() }
        for _ in 0..<100 where core.metricsContinuation == nil {
            await Task.yield()
        }
        XCTAssertNotNil(core.metricsContinuation)
        task.cancel()
        core.metricsContinuation?.resume(returning: core.metrics)
        core.metricsContinuation = nil
        await task.value
        XCTAssertNil(store.equalizerMetrics)
    }
}

private func settingsFixture() -> Settings {
    Settings(crossFade: false, crossFadeDuration: 5, normalizeVolume: false,
             explicitContent: true, autoplay: false, preferredAudioQuality: 0,
             preferredAudioSource: "local", downloadPath: "", openOnStartup: false,
             minimizeOnClose: false, onboardingComplete: true, preferredOutputDeviceId: nil,
             equalizer: EqualizerSettings(enabled: false, preampDb: 0,
                 bandGainsDb: Array(repeating: 0, count: 10), preset: "Flat"))
}

private final class SettingsTestCore: DurvaldCore {
    var configuration = settingsFixture()
    var output = AudioOutputState(devices: [], preferredDeviceId: nil,
                                  activeDeviceId: nil, usingFallback: false)
    var metrics = EqualizerMetrics(processedFrames: 0, processingNanoseconds: 0,
                                   averageNanosecondsPerFrame: 0)
    var failSettings = false
    var failSelection = false
    var failUpdate = false
    var holdMetrics = false
    var metricsContinuation: CheckedContinuation<EqualizerMetrics, Never>?

    init() { super.init(noPointer: .init()) }
    required init(unsafeFromRawPointer pointer: UnsafeMutableRawPointer) {
        fatalError("Test core has no Rust pointer")
    }
    override func settings() async throws -> Settings {
        if failSettings { throw NSError(domain: "settings", code: 1) }
        return configuration
    }
    override func updateSettings(settings: Settings) async throws {
        if failUpdate { throw NSError(domain: "settings", code: 2) }
        configuration = settings
    }
    override func audioOutputState() async throws -> AudioOutputState { output }
    override func selectAudioOutputDevice(deviceId: String?) async throws -> AudioOutputState {
        if failSelection { throw NSError(domain: "settings", code: 3) }
        output.preferredDeviceId = deviceId
        configuration.preferredOutputDeviceId = deviceId
        return output
    }
    override func equalizerMetrics() async -> EqualizerMetrics {
        if holdMetrics {
            return await withCheckedContinuation { metricsContinuation = $0 }
        }
        return metrics
    }
}

private final class SettingsNotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
