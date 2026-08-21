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
                .task { await coreStore.openCoreIfNeeded() }
        }
    }
}
