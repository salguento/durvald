//
//  ContentView.swift
//  Durvald
//
//  Created by Humberto Salguento on 20/08/26.
//

import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var store: DurvaldCoreStore
    @State private var selection: LibraryDestination? = .songs

    var body: some View {
        NavigationSplitView {
            List(LibraryDestination.allCases, selection: $selection) { item in
                Label(item.title, systemImage: item.icon)
                    .tag(item)
                    .accessibilityIdentifier("sidebar.\(item.rawValue)")
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            VStack(spacing: 0) {
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()
                PlayerBar()
            }
        }
        .alert(
            "Erro",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )
        ) {
            Button("OK") {
                store.errorMessage = nil
            }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .songs {
        case .songs:
            MusicLibraryView()
        case .albums:
            AlbumsView()
        case .artists:
            ArtistsView()
        case .playlists:
            PlaylistsView()
        case .history:
            HistoryView()
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(DurvaldCoreStore())
}

@MainActor
private func chooseLibraryFolder(store: DurvaldCoreStore) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Adicionar biblioteca"
    if panel.runModal() == .OK, let url = panel.url {
        store.addAndScanLibraryFolder(url)
    }
}
