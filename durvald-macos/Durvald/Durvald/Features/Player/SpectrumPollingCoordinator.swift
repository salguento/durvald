import Foundation

/// One acquisition loop per core. The same worker serializes enable/disable,
/// so retiring a view cannot disable a replacement or another consumer.
@MainActor
final class SpectrumPollingCoordinator {
    private struct Consumer {
        let publish: ([Float]) -> Void
        let completion: CheckedContinuation<Void, Never>
    }

    private final class Channel {
        let core: DurvaldCore
        var consumers: [UUID: Consumer] = [:]
        init(core: DurvaldCore) { self.core = core }
    }

    private var channels: [ObjectIdentifier: Channel] = [:]
    private let pause: @Sendable () async -> Void
    var consumerCount: Int { channels.values.reduce(0) { $0 + $1.consumers.count } }

    init(pause: @escaping @Sendable () async -> Void = {
        try? await Task.sleep(for: .milliseconds(50))
    }) {
        self.pause = pause
    }

    func observe(core: DurvaldCore, publish: @escaping ([Float]) -> Void) async {
        let key = ObjectIdentifier(core)
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { completion in
                guard !Task.isCancelled else { completion.resume(); return }
                let existing = channels[key]
                let channel = existing ?? Channel(core: core)
                channel.consumers[id] = Consumer(publish: publish, completion: completion)
                channels[key] = channel
                if existing == nil { Task { await run(channel, key: key) } }
            }
        } onCancel: {
            Task { @MainActor in
                self.channels[key]?.consumers.removeValue(forKey: id)?.completion.resume()
            }
        }
    }

    private func run(_ channel: Channel, key: ObjectIdentifier) async {
        var enabled = false
        while true {
            if channel.consumers.isEmpty {
                if enabled {
                    await channel.core.setSpectrumEnabled(enabled: false)
                    enabled = false
                    // Consumers may arrive while disable is in flight. Reconcile
                    // them on this same worker before removing the channel.
                    continue
                }
                channels[key] = nil
                return
            }
            if !enabled {
                await channel.core.setSpectrumEnabled(enabled: true)
                enabled = true
                continue
            }
            let bands = await channel.core.spectrumSnapshot().bands
            guard !channel.consumers.isEmpty else { continue }
            for consumer in channel.consumers.values { consumer.publish(bands) }
            await pause()
        }
    }
}

struct SpectrumPollingKey: Equatable {
    let coreID: ObjectIdentifier?
    let isActive: Bool
    let isVisible: Bool
    let isPlaying: Bool
    var reduceMotion = false
    var shouldAcquire: Bool { coreID != nil && isActive && isVisible && isPlaying }
}
