import SwiftUI

/// Local controls share their keys; window commands live in AppCommandID.
enum AppKeyboardShortcuts {
    /// Local keyboard input for the focused progress and volume sliders.
    enum Slider {
        static let decrease: KeyEquivalent = .leftArrow
        static let increase: KeyEquivalent = .rightArrow
    }
}
