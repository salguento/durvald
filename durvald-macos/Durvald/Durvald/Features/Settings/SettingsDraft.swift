import Foundation

/// A remote snapshot can advance while the user keeps an unsaved draft.
struct SettingsDraft<Value: Equatable> {
    var value: Value
    private(set) var snapshot: Value

    init(_ value: Value) {
        self.value = value
        snapshot = value
    }

    var isDirty: Bool { value != snapshot }

    mutating func receive(_ snapshot: Value) {
        if !isDirty { value = snapshot }
        self.snapshot = snapshot
    }

    mutating func reset(to snapshot: Value) {
        value = snapshot
        self.snapshot = snapshot
    }
}

struct GeneralSettingsValues: Equatable {
    var crossFade = false
    var crossFadeDuration = 5
    var normalizeVolume = false
    var explicitContent = true

    init() {}

    init(_ settings: Settings) {
        crossFade = settings.crossFade
        crossFadeDuration = Int(settings.crossFadeDuration)
        normalizeVolume = settings.normalizeVolume
        explicitContent = settings.explicitContent
    }
}

extension EqualizerSettings {
    /// Normalize legacy labels before comparing the snapshot with the draft.
    var editingValue: EqualizerSettings {
        var value = self
        switch preset {
        case "Bass Boost": value.preset = "Increase Bass"
        case "Treble Boost": value.preset = "Increase Treble"
        case "Vocais": value.preset = "Increase Vocals"
        default: break
        }
        return value
    }
}
