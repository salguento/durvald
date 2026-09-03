//
//  DurvaldApp.swift
//  Durvald
//
//  Created by Humberto Salguento on 20/08/26.
//

import SwiftUI

@main
struct DurvaldApp: App {
    @State private var coreStore: DurvaldCoreStore

    init() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing"), arguments.contains("--player-navigation-fixture") {
            _coreStore = State(initialValue: PlayerNavigationFixture.makeStore(
                longMetadata: arguments.contains("--long-player-metadata"),
                scrollable: arguments.contains("--scroll-effect-fixture"),
                livePlayback: arguments.contains("--playback-clock-fixture"),
                autoAdvance: arguments.contains("--album-transition-fixture")
            ))
            return
        }
        #endif
        _coreStore = State(initialValue: DurvaldCoreStore())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(coreStore)
                .task {
                    guard !ProcessInfo.processInfo.arguments.contains("--ui-testing") else {
                        #if DEBUG
                        if ProcessInfo.processInfo.arguments.contains("--playback-clock-fixture") {
                            coreStore.startPlaybackPolling()
                        }
                        #endif
                        return
                    }
                    await coreStore.openCoreIfNeeded()
                }
        }
        // Keep the standard titlebar compositor for native scroll-edge blur.
        // ContentView removes only the title; hiddenTitleBar disables the effect.
        .defaultSize(width: 900, height: 620)
        .windowResizability(.contentMinSize)
        .commands {
            AppCommands(store: coreStore)
        }
        SwiftUI.Settings {
            SettingsView()
                .environment(coreStore)
        }
    }
}
