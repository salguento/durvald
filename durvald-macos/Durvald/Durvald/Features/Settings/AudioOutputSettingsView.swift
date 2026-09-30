import SwiftUI

struct AudioOutputSettingsView: View {
    @Environment(DurvaldCoreStore.self) private var store
    @State private var selectedDeviceID = ""
    @State private var isApplyingSelection = false

    var body: some View {
        Form {
            Section("Saída de áudio") {
                Picker("Dispositivo", selection: $selectedDeviceID) {
                    Text("Padrão do sistema").tag("")
                    ForEach(store.audioOutputState?.devices ?? [], id: \.id) { device in
                        Text(device.isDefault ? "\(device.name) — padrão" : device.name)
                            .tag(device.id)
                    }
                }
                .accessibilityIdentifier("settings.audio.output-device")

                if store.audioOutputState?.usingFallback == true {
                    Label(
                        "O dispositivo preferido está indisponível. Usando a saída padrão até ele reconectar.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                if let activeName = activeDeviceName {
                    LabeledContent("Em uso", value: activeName)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task {
            await store.refreshAudioOutputs()
            syncSelection()
        }
        .onChange(of: store.audioOutputState) { _, _ in
            syncSelection()
        }
        .onChange(of: selectedDeviceID) { oldValue, newValue in
            guard oldValue != newValue, !isApplyingSelection else { return }
            Task {
                await store.selectAudioOutputDevice(newValue.isEmpty ? nil : newValue)
            }
        }
    }

    private var activeDeviceName: String? {
        guard let state = store.audioOutputState,
              let activeID = state.activeDeviceId else { return nil }
        return state.devices.first { $0.id == activeID }?.name ?? activeID
    }

    private func syncSelection() {
        let preferred = store.audioOutputState?.preferredDeviceId ?? ""
        guard selectedDeviceID != preferred else { return }
        isApplyingSelection = true
        selectedDeviceID = preferred
        Task { @MainActor in
            await Task.yield()
            isApplyingSelection = false
        }
    }
}
