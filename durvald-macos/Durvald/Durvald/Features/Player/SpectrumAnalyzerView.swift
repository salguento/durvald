import SwiftUI

struct SpectrumAnalyzerView: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @State private var bands = Array(repeating: Float.zero, count: 16)
    @State private var isVisible = false
    @State private var acquisitionID: UUID?

    var body: some View {
        let core = store.core
        let pollingKey = SpectrumPollingKey(coreID: core.map(ObjectIdentifier.init),
            isActive: scenePhase == .active, isVisible: isVisible, isPlaying: store.isPlaybackPlaying,
            reduceMotion: reduceMotion)
        GeometryReader { geometry in
            let spacing: CGFloat = 3
            let count = max(bands.count, 1)
            let width = max(2, (geometry.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))

            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(Array(bands.enumerated()), id: \.offset) { _, value in
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.accentColor.opacity(0.55), .accentColor],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(
                            width: width,
                            height: max(2, geometry.size.height * CGFloat(value))
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Analisador de espectro")
        .accessibilityIdentifier("player.spectrum")
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false; acquisitionID = nil }
        .task(id: pollingKey) {
            guard !Task.isCancelled else { return }
            let sessionID = UUID()
            acquisitionID = sessionID
            defer { if acquisitionID == sessionID { acquisitionID = nil } }
            guard pollingKey.shouldAcquire, let core else {
                bands = Array(repeating: 0, count: 16)
                return
            }
            await store.spectrumPolling.observe(core: core) { snapshot in
                guard acquisitionID == sessionID, bands != snapshot else { return }
                if reduceMotion {
                    bands = snapshot
                } else {
                    withAnimation(.linear(duration: 0.08)) {
                        bands = snapshot
                    }
                }
            }
        }
    }
}
