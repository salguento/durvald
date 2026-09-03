import SwiftUI

/// Central definitions; views and commands retain ownership of their actions
/// and availability so shortcuts follow the active window and control state.
enum AppKeyboardShortcuts {
    static let search = KeyboardShortcut("k", modifiers: .command)
    static let goBack = KeyboardShortcut(.leftArrow, modifiers: .command)
    static let goForward = KeyboardShortcut(.rightArrow, modifiers: .command)
    static let toggleQueue = KeyboardShortcut("l", modifiers: [.command, .option])

    static let playPause = KeyboardShortcut(.space, modifiers: [])
    static let increaseVolume = KeyboardShortcut(.upArrow, modifiers: .command)
    static let decreaseVolume = KeyboardShortcut(.downArrow, modifiers: .command)
    static let toggleShuffle = KeyboardShortcut("s", modifiers: [.command, .shift])
    static let cycleRepeat = KeyboardShortcut("r", modifiers: [.command, .shift])

    /// Local keyboard input for the focused progress and volume sliders.
    enum Slider {
        static let decrease: KeyEquivalent = .leftArrow
        static let increase: KeyEquivalent = .rightArrow
    }
}
