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

    var body: some View {
        VStack(spacing: 12) {
            Text("Durvald Core conectado")
            Button("Ler settings") {
                do {
                    guard let core = store.core else {
                        store.errorMessage = "O core ainda está abrindo."
                        return
                    }
                    let settings = try core.settings()
                    print("Crossfade: \(settings.crossFade)")
                } catch {
                    store.errorMessage = String(describing: error)
                }
            }
            Button("Adicionar e escanear biblioteca") {
                chooseLibraryFolder(store: store)
            }
            if let progress = store.scanProgress {
                Text(verbatim: "\(progress.phase): \(progress.processedFiles)/\(progress.totalFiles)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Cancelar scan") { store.cancelScan() }
            }
            Text("Faixas carregadas: \(store.tracks.count)")
            List(store.tracks, id: \.id) { track in
                Button {
                    Task { await store.play(trackID: track.id) }
                } label: {
                    VStack(alignment: .leading) {
                        Text(track.title)
                        Text(track.artist).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, minHeight: 260)
        }
        .safeAreaInset(edge: .bottom) {
            PlayerBar()
        }
        .padding()
        .alert("Erro", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
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
