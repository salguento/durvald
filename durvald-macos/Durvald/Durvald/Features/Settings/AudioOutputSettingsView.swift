import SwiftUI

struct AudioOutputSettingsView: View {
    @Environment(DurvaldCoreStore.self) private var store
    @State private var draft = SettingsDraft("")
    @State private var isApplyingSelection = false

    var body: some View {
        Form {
            Section("Saída de áudio") {
                Picker("Dispositivo", selection: Binding(get: { draft.value }, set: selectDevice)) {
                    Text("Padrão do sistema").tag("")
                    ForEach(store.audioOutputState?.devices ?? [], id: \.id) { device in
                        Text(device.isDefault ? "\(device.name) — padrão" : device.name)
                            .tag(device.id)
                    }
                }
                .accessibilityIdentifier("settings.audio.output-device")
                .disabled(isApplyingSelection)

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
    }

    private var activeDeviceName: String? {
        guard let state = store.audioOutputState,
              let activeID = state.activeDeviceId else { return nil }
        return state.devices.first { $0.id == activeID }?.name ?? activeID
    }

    private func syncSelection() {
        guard let state = store.audioOutputState else { return }
        draft.receive(state.preferredDeviceId ?? "")
    }

    private func selectDevice(_ deviceID: String) {
        guard deviceID != draft.value, !isApplyingSelection else { return }
        draft.value = deviceID
        isApplyingSelection = true
        Task { @MainActor in
            let succeeded = await store.selectAudioOutputDevice(deviceID.isEmpty ? nil : deviceID)
            if succeeded {
                syncSelection()
            } else {
                draft.reset(to: store.audioOutputState?.preferredDeviceId ?? "")
            }
            isApplyingSelection = false
        }
    }
}
