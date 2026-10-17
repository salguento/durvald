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
        RatingPreferences.migrateFilterPreferences()
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing"), arguments.contains("--ratings-integration-fixture") {
            let layout = MusicLibraryColumnLayout(order: [.title, .rating],
                hidden: Set(MusicLibraryColumn.allCases.filter { $0 != .title && $0 != .rating }), widths: [:])
            let encoded = (try? JSONEncoder().encode(layout)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            UserDefaults.standard.setVolatileDomain([
                RatingPreferences.enabledKey: true, "library.music.columnLayout": encoded,
                "library.music.onlyFavorites": false, "library.music.sort": "title",
                "library.music.groupArtwork": false, "library.music.trackNumberColumnIntroduced": true,
            ], forName: UserDefaults.argumentDomain)
        }
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
                        if ProcessInfo.processInfo.arguments.contains("--ratings-integration-fixture"), coreStore.core == nil,
                           let fixtureID = ProcessInfo.processInfo.environment["DURVALD_RATING_FIXTURE_ID"],
                           UUID(uuidString: fixtureID) != nil {
                            // Each sandbox has its own temporary directory. Pass only
                            // an identifier, never a path outside the app's sandbox.
                            let directory = FileManager.default.temporaryDirectory
                                .appendingPathComponent("durvald-rating-ui-" + fixtureID)
                            do { coreStore = try await RatingIntegrationFixture.makeStore(directory: directory) }
                            catch { coreStore.errorMessage = "Rating fixture failed: \(error)" }
                        }
                        if ProcessInfo.processInfo.arguments.contains("--playback-clock-fixture") {
                            coreStore.startPlaybackPolling()
                        }
                        #endif
                        return
                    }
                    coreStore.activateSystemMediaControls()
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
            Group {
                if trackInfo.trackIDs.count > 1 {
                    BatchMetadataSheet(trackIDs: trackInfo.trackIDs)
                        .id(trackInfo.trackIDs)
                        .environment(coreStore)
                } else if let trackID = trackInfo.trackID {
                    TrackInfoSheet(
                        trackID: trackID,
                        navigationTrackIDs: trackInfo.navigationTrackIDs.isEmpty
                            ? coreStore.tracks.map(\.id) : trackInfo.navigationTrackIDs,
                        onSelectTrack: { trackInfo.trackIDs = [$0] }
                    )
                        .id(trackID)
                        .environment(coreStore)
                }
            }
            .background(MetadataWindowBounds(referenceWindow: trackInfo.referenceWindow))
        }
        .defaultSize(width: 680, height: 780)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        Window("Opções de visualização", id: "music-view-options") {
            MusicLibraryViewOptions()
        }
        .defaultSize(width: 420, height: 620)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        SwiftUI.Settings {
            SettingsView()
                .environment(coreStore)
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
    }
}
