import SwiftUI

struct EqualizerSettingsView: View {
    @Environment(DurvaldCoreStore.self) private var store
    @State private var enabled = false
    @State private var preamp: Float = 0
    @State private var gains = Array(repeating: Float.zero, count: 10)
    @State private var preset = "Flat"

    private let frequencies = ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
    private let presets: [(String, [Float])] = [
        ("Flat", Array(repeating: 0, count: 10)),
        ("Bass Boost", [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
        ("Treble Boost", [0, 0, 0, 0, 0, 0, 2, 4, 5, 6]),
        ("Vocais", [-2, -1, 0, 2, 4, 5, 4, 2, 0, -1]),
        ("Rock", [4, 3, 1, -1, -2, 1, 3, 4, 4, 3])
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Toggle("Equalizador", isOn: $enabled)
                    .accessibilityIdentifier("settings.equalizer.enabled")
                Spacer()
                Picker("Preset", selection: $preset) {
                    ForEach(presets, id: \.0) { Text($0.0).tag($0.0) }
                    if !presets.contains(where: { $0.0 == preset }) {
                        Text("Personalizado").tag("Personalizado")
                    }
                }
                .frame(width: 210)
            }

            HStack(spacing: 10) {
                gainSlider(title: "Pre", value: $preamp)
                Divider().frame(height: 180)
                ForEach(gains.indices, id: \.self) { index in
                    gainSlider(
                        title: frequencies[index],
                        value: Binding(
                            get: { gains[index] },
                            set: { gains[index] = $0; preset = "Personalizado" }
                        )
                    )
                }
            }
            .disabled(!enabled)

            HStack {
                if let metrics = store.equalizerMetrics {
                    Text(metricsText(metrics))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Salvar") {
                    Task {
                        await store.updateEqualizer(EqualizerSettings(
                            enabled: enabled,
                            preampDb: preamp,
                            bandGainsDb: gains,
                            preset: preset
                        ))
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .task {
            apply(store.appSettings?.equalizer)
            while !Task.isCancelled {
                await store.refreshEqualizerMetrics()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onChange(of: store.appSettings) { _, settings in
            apply(settings?.equalizer)
        }
        .onChange(of: preset) { _, newPreset in
            guard let values = presets.first(where: { $0.0 == newPreset })?.1 else { return }
            gains = values
        }
    }

    private func gainSlider(title: String, value: Binding<Float>) -> some View {
        VStack(spacing: 5) {
            Text(String(format: "%+.0f", value.wrappedValue))
                .font(.caption2.monospacedDigit())
                .frame(width: 28)
            Slider(value: value, in: -12...12, step: 1)
                .frame(width: 130)
                .rotationEffect(.degrees(-90))
                .frame(width: 28, height: 130)
            Text(title).font(.caption2)
        }
    }

    private func apply(_ settings: EqualizerSettings?) {
        guard let settings, settings.bandGainsDb.count == 10 else { return }
        enabled = settings.enabled
        preamp = settings.preampDb
        gains = settings.bandGainsDb
        preset = settings.preset
    }

    private func metricsText(_ metrics: EqualizerMetrics) -> String {
        guard metrics.processedFrames > 0 else { return "DSP aguardando reprodução" }
        return String(
            format: "DSP %.1f ns/quadro · %llu quadros",
            metrics.averageNanosecondsPerFrame,
            metrics.processedFrames
        )
    }
}
