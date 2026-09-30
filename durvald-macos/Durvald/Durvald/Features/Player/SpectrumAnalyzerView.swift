import SwiftUI

struct SpectrumAnalyzerView: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var bands = Array(repeating: Float.zero, count: 16)

    var body: some View {
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
        .task {
            await store.setSpectrumEnabled(true)
            defer { Task { await store.setSpectrumEnabled(false) } }
            while !Task.isCancelled {
                let snapshot = await store.spectrumSnapshot()
                if reduceMotion {
                    bands = snapshot
                } else {
                    withAnimation(.linear(duration: 0.08)) {
                        bands = snapshot
                    }
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }
}
