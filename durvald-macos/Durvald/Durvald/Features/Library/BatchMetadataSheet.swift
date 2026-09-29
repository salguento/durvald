import SwiftUI

struct BatchMetadataValue: Equatable {
    var isEnabled = false
    var text = ""
    var isMixed = false
}

struct BatchMetadataDraft: Equatable {
    var title = BatchMetadataValue()
    var artist = BatchMetadataValue()
    var albumArtist = BatchMetadataValue()
    var album = BatchMetadataValue()
    var genre = BatchMetadataValue()
    var year = BatchMetadataValue()
    var trackNumber = BatchMetadataValue()
    var discNumber = BatchMetadataValue()
    var composer = BatchMetadataValue()
    var comment = BatchMetadataValue()

    init() {}

    init(infos: [TrackInfo]) {
        func common(_ values: [String]) -> BatchMetadataValue {
            guard let first = values.first else { return BatchMetadataValue() }
            let mixed = values.dropFirst().contains { $0 != first }
            return BatchMetadataValue(text: mixed ? "" : first, isMixed: mixed)
        }
        title = common(infos.map(\.metadata.title))
        artist = common(infos.map(\.metadata.artist))
        albumArtist = common(infos.map(\.metadata.albumArtist))
        album = common(infos.map(\.metadata.album))
        genre = common(infos.map(\.metadata.genre))
        year = common(infos.map { $0.metadata.year.map(String.init) ?? "" })
        trackNumber = common(infos.map { $0.metadata.trackNumber.map(String.init) ?? "" })
        discNumber = common(infos.map { $0.metadata.discNumber.map(String.init) ?? "" })
        composer = common(infos.map(\.metadata.composer))
        comment = common(infos.map(\.metadata.comment))
    }

    var hasChanges: Bool {
        [title, artist, albumArtist, album, genre, year, trackNumber, discNumber, composer, comment]
            .contains(where: \.isEnabled)
    }

    func applying(to source: TrackMetadataEdit) throws -> TrackMetadataEdit {
        func number(_ field: BatchMetadataValue, name: String, maximum: UInt32) throws -> UInt32? {
            guard field.isEnabled else { return nil }
            let value = field.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            guard let parsed = UInt32(value), parsed <= maximum, name != "Ano" || parsed > 0 else {
                throw TrackMetadataDraft.DraftError.invalid("\(name): informe um número válido até \(maximum).")
            }
            return parsed
        }
        func required(_ field: BatchMetadataValue, current: String, name: String) throws -> String {
            guard field.isEnabled else { return current }
            guard !field.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TrackMetadataDraft.DraftError.invalid("\(name) não pode ficar vazio.")
            }
            return field.text
        }
        return TrackMetadataEdit(
            title: try required(title, current: source.title, name: "Título"),
            artist: try required(artist, current: source.artist, name: "Artista"),
            albumArtist: albumArtist.isEnabled ? albumArtist.text : source.albumArtist,
            album: try required(album, current: source.album, name: "Álbum"),
            genre: genre.isEnabled ? genre.text : source.genre,
            year: year.isEnabled ? try number(year, name: "Ano", maximum: 9999) : source.year,
            trackNumber: trackNumber.isEnabled ? try number(trackNumber, name: "Faixa", maximum: 255) : source.trackNumber,
            discNumber: discNumber.isEnabled ? try number(discNumber, name: "Disco", maximum: 255) : source.discNumber,
            composer: composer.isEnabled ? composer.text : source.composer,
            comment: comment.isEnabled ? comment.text : source.comment
        )
    }
}

private struct BatchMetadataFailure: Identifiable {
    let trackID: Int64
    let title: String
    let message: String
    var id: Int64 { trackID }
}

struct BatchMetadataOperationReceipt: Codable {
    static let defaultsKey = "metadata.lastBatchOperation"

    let selectedTrackIDs: [Int64]
    var changedTrackIDs: [Int64]

    static func load(for selectedTrackIDs: [Int64]) -> Self? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let receipt = try? JSONDecoder().decode(Self.self, from: data),
              receipt.selectedTrackIDs == selectedTrackIDs else { return nil }
        return receipt
    }

    func persist() {
        guard !changedTrackIDs.isEmpty,
              let data = try? JSONEncoder().encode(self) else {
            Self.clear()
            return
        }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}

struct BatchMetadataSheet: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("metadata.writeChangesToFiles") private var writeChangesToFiles = true

    let trackIDs: [Int64]

    @State private var infos: [TrackInfo] = []
    @State private var draft: BatchMetadataDraft?
    @State private var isWorking = false
    @State private var completed = 0
    @State private var total = 0
    @State private var failures: [BatchMetadataFailure] = []
    @State private var lastOperationTrackIDs: [Int64] = []
    @State private var statusMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Editar metadados de \(trackIDs.count) faixas")
                .font(.title2.weight(.semibold))
            Text("Marque somente os campos que devem ser alterados. Os demais serão preservados.")
                .font(.callout).foregroundStyle(.secondary)

            if draft != nil {
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
                .disabled(isWorking)

                Toggle("Gravar alterações nos arquivos", isOn: $writeChangesToFiles)
                    .disabled(isWorking)
            } else if !isWorking {
                ProgressView("Carregando metadados…")
                    .frame(maxWidth: .infinity, minHeight: 220)
            }

            if isWorking {
                ProgressView(value: Double(completed), total: Double(max(total, 1))) {
                    Text("Processando \(completed) de \(total)…")
                }
            }
            if let statusMessage {
                Text(statusMessage).foregroundStyle(failures.isEmpty ? Color.secondary : Color.red)
                    .textSelection(.enabled)
            }
            if !failures.isEmpty {
                DisclosureGroup("Falhas (\(failures.count))") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(failures) { failure in
                                Text("\(failure.title): \(failure.message)")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                        }
                    }.frame(maxHeight: 110)
                }
            }

            HStack {
                Button("Desfazer operação") { Task { await undoLastOperation() } }
                    .disabled(isWorking || lastOperationTrackIDs.isEmpty)
                    .accessibilityIdentifier("batchMetadata.undo")
                Spacer()
                Button("Fechar") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isWorking)
                Button("Aplicar") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking || draft?.hasChanges != true)
                    .accessibilityIdentifier("batchMetadata.save")
            }
        }
        .padding(24)
        .frame(width: 620, height: 760)
        .background(WindowTrafficLightsHider())
        .interactiveDismissDisabled(isWorking)
        .task { await load() }
    }

    private func batchField(
        _ title: String,
        _ keyPath: WritableKeyPath<BatchMetadataDraft, BatchMetadataValue>
    ) -> some View {
        HStack {
            Toggle("", isOn: Binding(
                get: { draft?[keyPath: keyPath].isEnabled ?? false },
                set: { enabled in
                    draft?[keyPath: keyPath].isEnabled = enabled
                    if enabled { draft?[keyPath: keyPath].isMixed = false }
                    statusMessage = nil
                }
            )).labelsHidden()
            TextField(title, text: Binding(
                get: { draft?[keyPath: keyPath].text ?? "" },
                set: { value in
                    draft?[keyPath: keyPath].text = value
                    draft?[keyPath: keyPath].isEnabled = true
                    draft?[keyPath: keyPath].isMixed = false
                    statusMessage = nil
                }
            ), prompt: Text(draft?[keyPath: keyPath].isMixed == true ? "Valores diferentes" : title))
                .disabled(draft?[keyPath: keyPath].isEnabled != true)
        }
    }

    private func load() async {
        guard infos.isEmpty, let core = store.core else {
            if store.core == nil { statusMessage = "A biblioteca ainda está abrindo." }
            return
        }
        isWorking = true
        total = trackIDs.count
        completed = 0
        failures = []
        var loaded: [TrackInfo] = []
        for id in trackIDs {
            do { loaded.append(try await core.trackInfo(trackId: id)) }
            catch { failures.append(.init(trackID: id, title: "Faixa \(id)", message: error.localizedDescription)) }
            completed += 1
        }
        infos = loaded
        draft = loaded.isEmpty ? nil : BatchMetadataDraft(infos: loaded)
        lastOperationTrackIDs = BatchMetadataOperationReceipt.load(for: trackIDs)?.changedTrackIDs ?? []
        isWorking = false
        if !failures.isEmpty { statusMessage = "Algumas faixas não puderam ser carregadas." }
    }

    private func save() async {
        guard !isWorking, let core = store.core, let draft, draft.hasChanges else { return }
        do {
            _ = try infos.map { try draft.applying(to: $0.metadata) }
        } catch {
            statusMessage = error.localizedDescription
            return
        }
        isWorking = true
        failures = []
        completed = 0
        total = infos.count
        lastOperationTrackIDs = []
        var refreshed: [TrackInfo] = []
        for info in infos {
            do {
                let metadata = try draft.applying(to: info.metadata)
                let value = try await core.saveTrackMetadata(
                    trackId: info.track.id,
                    metadata: metadata,
                    writeToFile: writeChangesToFiles
                )
                refreshed.append(value)
                lastOperationTrackIDs.append(info.track.id)
            } catch {
                failures.append(.init(trackID: info.track.id, title: info.track.title, message: error.localizedDescription))
            }
            completed += 1
        }
        if let last = refreshed.last { await store.refreshAfterMetadataEdit(last) }
        infos = refreshed + infos.filter { failed in failures.contains { $0.trackID == failed.track.id } }
        self.draft = infos.isEmpty ? nil : BatchMetadataDraft(infos: infos)
        statusMessage = failures.isEmpty
            ? "\(lastOperationTrackIDs.count) faixas atualizadas."
            : "\(lastOperationTrackIDs.count) atualizadas; \(failures.count) falharam."
        BatchMetadataOperationReceipt(
            selectedTrackIDs: trackIDs,
            changedTrackIDs: lastOperationTrackIDs
        ).persist()
        isWorking = false
    }

    private func undoLastOperation() async {
        guard !isWorking, let core = store.core, !lastOperationTrackIDs.isEmpty else { return }
        isWorking = true
        failures = []
        completed = 0
        total = lastOperationTrackIDs.count
        var restored: [TrackInfo] = []
        for id in lastOperationTrackIDs.reversed() {
            do { restored.append(try await core.undoTrackMetadata(trackId: id)) }
            catch {
                let title = infos.first(where: { $0.track.id == id })?.track.title ?? "Faixa \(id)"
                failures.append(.init(trackID: id, title: title, message: error.localizedDescription))
            }
            completed += 1
        }
        if let last = restored.last { await store.refreshAfterMetadataEdit(last) }
        let failedIDs = Set(failures.map(\.trackID))
        lastOperationTrackIDs = lastOperationTrackIDs.filter { failedIDs.contains($0) }
        BatchMetadataOperationReceipt(
            selectedTrackIDs: trackIDs,
            changedTrackIDs: lastOperationTrackIDs
        ).persist()
        await reloadAfterUndo(core: core)
        statusMessage = failures.isEmpty
            ? "Operação desfeita em \(restored.count) faixas."
            : "\(restored.count) restauradas; \(failures.count) falharam."
        isWorking = false
    }

    private func reloadAfterUndo(core: DurvaldCore) async {
        var values: [TrackInfo] = []
        for id in trackIDs {
            if let value = try? await core.trackInfo(trackId: id) { values.append(value) }
        }
        infos = values
        draft = values.isEmpty ? nil : BatchMetadataDraft(infos: values)
    }
}
