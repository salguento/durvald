import Foundation

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
