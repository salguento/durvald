//
//  MusicLibraryView.swift
//  Durvald
//
//  Created by Humberto Salguento on 21/08/26.
//

import SwiftUI
import AppKit

struct MusicLibraryView: View {
    @EnvironmentObject private var store: DurvaldCoreStore

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Faixas carregadas: \(store.tracks.count)")
                Spacer()
                Button("Adicionar biblioteca") {
                    chooseLibraryFolder(store: store)
                }
            }

            if let progress = store.scanProgress {
                Text(verbatim: "\(progress.phase): \(progress.processedFiles)/\(progress.totalFiles)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Cancelar scan") { store.cancelScan() }
            }
            List(store.tracks, id: \.id) { track in
                HStack {
                    Button {
                        Task { await store.play(trackID: track.id) }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(track.title)
                            Text(track.artist)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)

                    Button {
                        Task { await store.addToQueue(trackID: track.id) }
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Adicionar \(track.title) à fila")
                }
                .contextMenu {
                    Button("Reproduzir agora") {
                        Task { await store.play(trackID: track.id) }
                    }

                    Button("Adicionar à fila") {
                        Task { await store.addToQueue(trackID: track.id) }
                    }
                }
            }
        }
        .padding()
        .navigationTitle("Músicas")
    }
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
