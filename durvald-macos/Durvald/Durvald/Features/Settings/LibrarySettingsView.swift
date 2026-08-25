import AppKit
import SwiftUI

struct LibrarySettingsView: View {
    @EnvironmentObject private var store: DurvaldCoreStore
    @State private var pathPendingRemoval: String?

    var body: some View {
        Form {
            Section("Pastas da biblioteca") {
                if store.libraryPaths.isEmpty {
                    Text("Nenhuma pasta configurada")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.libraryPaths, id: \.self) { path in
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)

                            Text(path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                                .help(path)
                                .accessibilityLabel(
                                    "Pasta da biblioteca: \(path)"
                                )

                            Spacer()

                            Button("Remover", role: .destructive) {
                                pathPendingRemoval = path
                            }
                            .buttonStyle(.borderless)
                            .disabled(store.scanProgress != nil)
                            .accessibilityIdentifier(
                                "settings.library.removeFolder.\(path)"
                            )
                        }
                    }
                }

                HStack {
                    Spacer()

                    Button("Adicionar pasta…") {
                        chooseLibraryFolder()
                    }
                    .disabled(store.scanProgress != nil)
                    .accessibilityIdentifier(
                        "settings.library.addFolder"
                    )
                }
            }

            if let progress = store.scanProgress {
                Section("Atualização da biblioteca") {
                    ProgressView(
                        value: Double(progress.processedFiles),
                        total: Double(max(progress.totalFiles, 1))
                    )

                    Text(
                        verbatim: """
                        \(progress.phase): \
                        \(progress.processedFiles)/\(progress.totalFiles)
                        """
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    HStack {
                        Spacer()

                        Button("Cancelar scan", role: .cancel) {
                            store.cancelScan()
                        }
                        .accessibilityIdentifier(
                            "settings.library.cancelScan"
                        )
                    }
                }
            }
        }
        .confirmationDialog(
            "Remover pasta da biblioteca?",
            isPresented: Binding(
                get: {
                    pathPendingRemoval != nil
                },
                set: { isPresented in
                    if !isPresented {
                        pathPendingRemoval = nil
                    }
                }
            ),
            titleVisibility: .visible,
            presenting: pathPendingRemoval
        ) { path in
            Button("Remover pasta", role: .destructive) {
                store.removeLibraryFolder(path: path)
                pathPendingRemoval = nil
            }

            Button("Cancelar", role: .cancel) {
                pathPendingRemoval = nil
            }
        } message: { path in
            Text(
                """
                O Durvald deixará de escanear \(path). \
                As músicas já indexadas não serão apagadas.
                """
            )
        }
    }

    @MainActor
    private func chooseLibraryFolder() {
        let panel = NSOpenPanel()

        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Adicionar"
        panel.message = """
        Selecione uma pasta que contenha sua biblioteca de músicas.
        """

        guard panel.runModal() == .OK,
              let url = panel.url else {
            return
        }

        store.addAndScanLibraryFolder(url)
    }
}
