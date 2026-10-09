import SwiftUI

struct BatchMetadataSheet: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("metadata.writeChangesToFiles") private var writeChangesToFiles = true

    @State private var presentation = BatchMetadataPresentation()

    let trackIDs: [Int64]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Editar metadados de \(trackIDs.count) faixas")
                .font(.title2.weight(.semibold))
            Text("Marque somente os campos que devem ser alterados. Os demais serão preservados.")
                .font(.callout).foregroundStyle(.secondary)

            if presentation.draft != nil {
                Form {
                    Section("Alterações") {
                        batchField("Título", \.title)
                        batchField("Artista", \.artist)
                        batchField("Artista do álbum", \.albumArtist)
                        batchField("Álbum", \.album)
                        batchField("Gênero", \.genre)
                        batchField("Ano", \.year)
                        batchField("Faixa", \.trackNumber)
                        batchField("Disco", \.discNumber)
                        batchField("Compositor", \.composer)
                        batchField("Comentário", \.comment)
                    }
                }
                .formStyle(.grouped)
                .disabled(presentation.isWorking)

                Toggle("Gravar alterações nos arquivos", isOn: $writeChangesToFiles)
                    .disabled(presentation.isWorking)
            } else if !presentation.isWorking {
                ProgressView("Carregando metadados…")
                    .frame(maxWidth: .infinity, minHeight: 220)
            }

            if presentation.isWorking {
                ProgressView(value: Double(presentation.completed), total: Double(max(presentation.total, 1))) {
                    Text("Processando \(presentation.completed) de \(presentation.total)…")
                }
            }
            if let statusMessage = presentation.statusMessage {
                Text(statusMessage).foregroundStyle(presentation.failures.isEmpty ? Color.secondary : Color.red)
                    .textSelection(.enabled)
            }
            if !presentation.failures.isEmpty {
                DisclosureGroup("Falhas (\(presentation.failures.count))") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(presentation.failures) { failure in
                                Text("\(failure.title): \(failure.message)")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                        }
                    }.frame(maxHeight: 110)
                }
            }

            HStack {
                Button("Desfazer operação") { Task { await presentation.undoLastOperation(using: store) } }
                    .disabled(presentation.isWorking || presentation.lastOperationTrackIDs.isEmpty)
                    .accessibilityIdentifier("batchMetadata.undo")
                Spacer()
                Button("Fechar") { dismiss() }.keyboardShortcut(.cancelAction).disabled(presentation.isWorking)
                Button("Aplicar") { Task { await presentation.save(using: store, writeChangesToFiles: writeChangesToFiles) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(presentation.isWorking || !presentation.editing.isDirty)
                    .accessibilityIdentifier("batchMetadata.save")
            }
        }
        .padding(24)
        .frame(minWidth: 620, idealWidth: 680, maxWidth: .infinity,
               minHeight: 520, idealHeight: 760, maxHeight: .infinity)
        .background(WindowTrafficLightsHider())
        .interactiveDismissDisabled(presentation.isWorking)
        .task(id: BatchMetadataPresentation.Request(trackIDs: trackIDs, coreID: store.core.map(ObjectIdentifier.init), storeID: ObjectIdentifier(store))) { await presentation.load(trackIDs: trackIDs, using: store) }
    }

    private func batchField(
        _ title: String,
        _ keyPath: WritableKeyPath<BatchMetadataDraft, BatchMetadataValue>
    ) -> some View {
        HStack {
            Toggle("", isOn: Binding(
                get: { presentation.draft?[keyPath: keyPath].isEnabled ?? false },
                set: { enabled in
                    presentation.draft?[keyPath: keyPath].isEnabled = enabled
                    if enabled { presentation.draft?[keyPath: keyPath].isMixed = false }
                    presentation.statusMessage = nil
                }
            )).labelsHidden()
            TextField(title, text: Binding(
                get: { presentation.draft?[keyPath: keyPath].text ?? "" },
                set: { value in
                    presentation.draft?[keyPath: keyPath].text = value
                    presentation.draft?[keyPath: keyPath].isEnabled = true
                    presentation.draft?[keyPath: keyPath].isMixed = false
                    presentation.statusMessage = nil
                }
            ), prompt: Text(presentation.draft?[keyPath: keyPath].isMixed == true ? "Valores diferentes" : title))
                .disabled(presentation.draft?[keyPath: keyPath].isEnabled != true)
        }
    }

}
