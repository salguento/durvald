//
//  DurvaldApp.swift
//  Durvald
//
//  Created by Humberto Salguento on 20/08/26.
//

import SwiftUI

@main
struct DurvaldApp: App {
    @StateObject private var coreStore = DurvaldCoreStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(coreStore)
                .task {
                    await coreStore.openCoreIfNeeded()
                }
        }
        .commands {
            CommandMenu("Reprodução") {
                Button("Reproduzir ou pausar") {
                    Task { await coreStore.togglePause() }
                }

                Button("Próxima música") {
                    Task { await coreStore.next() }
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command])

                Button("Música anterior") {
                    Task { await coreStore.previous() }
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command])

                Divider()

                Button("Ativar ou desativar aleatório") {
                    Task { await coreStore.toggleShuffle() }
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Button("Alternar repetição") {
                    Task { await coreStore.cycleRepeatMode() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
        SwiftUI.Settings {
            SettingsView()
                .environmentObject(coreStore)
        }
    }
}
