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
    @State private var trackInfo = TrackInfoCoordinator()

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
                .environment(trackInfo)
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
        Window("Info da faixa", id: "track-info") {
            if let trackID = trackInfo.trackID {
                TrackInfoSheet(trackID: trackID)
                    .id(trackID)
                    .environment(coreStore)
            }
        }
        .defaultSize(width: 560, height: 690)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        SwiftUI.Settings {
            SettingsView()
                .environment(coreStore)
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
    }
}
