import AppKit
import SwiftUI

struct EqualizerSettingsView: View {
    @Environment(DurvaldCoreStore.self) private var store
    @State private var enabled = false
    @State private var preamp: Float = 0
    @State private var gains = Array(repeating: Float.zero, count: 10)
    @State private var preset = "Flat"

    private let frequencies = ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
    private let presets: [(String, [Float])] = [
        ("None", Array(repeating: 0, count: 10)),
        ("Acoustic", [5, 5, 4, 1, 2, 2, 3, 4, 3, 2]),
        ("Classical", [5, 4, 3, 2, -1, -1, 0, 2, 3, 4]),
        ("Dance", [6, 5, 3, 0, 0, -2, -3, -3, 0, 0]),
        ("Deep", [5, 4, 2, 1, 3, 2, 0, -2, -4, -5]),
        ("Electronic", [5, 4, 1, 0, -2, 2, 1, 2, 4, 5]),
        ("Flat", Array(repeating: 0, count: 10)),
        ("Hip-Hop", [5, 4, 1, 3, -1, -1, 1, -1, 2, 3]),
        ("Increase Bass", [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
        ("Increase Treble", [0, 0, 0, 0, 0, 0, 2, 4, 5, 6]),
        ("Increase Vocals", [-2, -1, 0, 2, 4, 5, 4, 2, 0, -1]),
        ("Jazz", [4, 3, 1, 2, -1, -1, 0, 1, 3, 4]),
        ("Latin", [4, 3, 0, 0, -1, -1, -1, 0, 3, 4]),
        ("Loudness", [6, 4, 0, 0, -2, 0, -1, -5, 5, 1]),
        ("Lounge", [-3, -2, -1, 1, 4, 3, 0, -1, 2, 1]),
        ("Piano", [3, 2, 0, 3, 3, 1, 3, 4, 3, 3]),
        ("Pop", [-1, -1, 0, 2, 4, 4, 2, 0, -1, -1]),
        ("R&B", [3, 7, 6, 1, -2, -1, 3, 4, 4, 5]),
        ("Reduce Bass", [-6, -5, -4, -2, 0, 0, 0, 0, 0, 0]),
        ("Reduce Treble", [0, 0, 0, 0, 0, 0, -2, -4, -5, -6]),
        ("Rock", [4, 3, 1, -1, -2, 1, 3, 4, 4, 3]),
        ("Small Speakers", [5, 4, 3, 2, 1, 0, -1, -2, -3, -4]),
        ("Spoken Word", [-4, -3, -1, 0, 3, 4, 4, 3, 1, 0])
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Toggle("Equalizador", isOn: $enabled)
                    .accessibilityIdentifier("settings.equalizer.enabled")
                Spacer()
                Picker("Preset", selection: Binding(get: { preset }, set: selectPreset)) {
                    Text("None").tag("None")
                    Divider()
                    ForEach(Array(presets.dropFirst()), id: \.0) { Text($0.0).tag($0.0) }
                    if !presets.contains(where: { $0.0 == preset }) {
                        Text("Personalizado").tag("Personalizado")
                    }
                }
                .frame(width: 210)
            }

            HStack(spacing: 10) {
                gainSlider(title: "Pre", accessibilityLabel: "Pré-amplificação", value: $preamp)
                Divider()
                ForEach(gains.indices, id: \.self) { index in
                    gainSlider(
                        title: frequencies[index],
                        accessibilityLabel: "Ganho em \(frequencies[index]) Hz",
                        value: Binding(
                            get: { gains[index] },
                            set: { gains[index] = $0; preset = "Personalizado" }
                        )
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    }

    private func selectPreset(_ name: String) {
        guard let values = presets.first(where: { $0.0 == name })?.1 else { return }
        preset = name
        gains = values
        enabled = name != "None"
        if name == "None" { preamp = 0 }
    }

    private func gainSlider(title: String, accessibilityLabel: String, value: Binding<Float>) -> some View {
        VStack(spacing: 5) {
            Text(String(format: "%+.1f", value.wrappedValue))
                .font(.caption.monospacedDigit())
                .frame(width: 36)
            EqualizerGainSlider(value: value, label: accessibilityLabel)
                .frame(width: 36)
                .frame(minHeight: 160, maxHeight: .infinity)
                .layoutPriority(1)
            Text(title).font(.caption)
        }
        .frame(maxHeight: .infinity)
    }

    private func apply(_ settings: EqualizerSettings?) {
        guard let settings, settings.bandGainsDb.count == 10 else { return }
        enabled = settings.enabled
        preamp = settings.preampDb
        gains = settings.bandGainsDb
        // Keep older saved presets compatible without changing their curves.
        switch settings.preset {
        case "Bass Boost": preset = "Increase Bass"
        case "Treble Boost": preset = "Increase Treble"
        case "Vocais": preset = "Increase Vocals"
        default: preset = settings.preset
        }
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

private struct EqualizerGainSlider: NSViewRepresentable {
    @Binding var value: Float
    let label: String
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: Double(value), minValue: -12, maxValue: 12,
                              target: context.coordinator, action: #selector(Coordinator.changeGain(_:)))
        slider.isVertical = true
        slider.controlSize = .regular
        slider.isContinuous = true
        slider.altIncrementValue = 0.25
        slider.setContentHuggingPriority(.defaultLow, for: .vertical)
        slider.setAccessibilityLabel(label)
        slider.toolTip = "\(label) · −12 a +12 dB. Use Option para ajuste fino."
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.parent = self
        slider.floatValue = value
        slider.isEnabled = isEnabled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSlider, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 36, height: proposal.height ?? 160)
    }

    final class Coordinator: NSObject {
        var parent: EqualizerGainSlider

        init(_ parent: EqualizerGainSlider) { self.parent = parent }

        @objc func changeGain(_ sender: NSSlider) {
            parent.value = sender.floatValue
        }
    }
}
