import Observation
import Foundation
import SwiftUI

@MainActor
@Observable
final class TrackInfoCoordinator {
    var trackID: Int64?
    @ObservationIgnored var presentWindow: (() -> Void)?

    func open(trackID: Int64) {
        self.trackID = trackID
        presentWindow?()
    }
}

struct TrackMetadataDraft: Equatable {
    var title: String
    var artist: String
    var albumArtist: String
    var album: String
    var genre: String
    var year: String
    var trackNumber: String
    var discNumber: String
    var composer: String
    var comment: String

    init(_ value: TrackMetadataEdit) {
        title = value.title
        artist = value.artist
        albumArtist = value.albumArtist
        album = value.album
        genre = value.genre
        year = value.year.map(String.init) ?? ""
        trackNumber = value.trackNumber.map(String.init) ?? ""
        discNumber = value.discNumber.map(String.init) ?? ""
        composer = value.composer
        comment = value.comment
    }

    func metadata() throws -> TrackMetadataEdit {
        func number(_ text: String, name: String, maximum: UInt32) throws -> UInt32? {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            guard let value = UInt32(text), value <= maximum, name != "Ano" || value > 0 else {
                throw DraftError.invalid("\(name): informe um número válido até \(maximum).")
            }
            return value
        }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DraftError.invalid("Título, artista e álbum são obrigatórios.")
        }
        return TrackMetadataEdit(
            title: title, artist: artist, albumArtist: albumArtist, album: album, genre: genre,
            year: try number(year, name: "Ano", maximum: 9999),
            trackNumber: try number(trackNumber, name: "Faixa", maximum: 255),
            discNumber: try number(discNumber, name: "Disco", maximum: 255),
            composer: composer, comment: comment
        )
    }

    enum DraftError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case .invalid(let message) = self { message } else { nil } }
    }
}

struct TrackInfoSheet: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("metadata.writeChangesToFiles") private var writeChangesToFiles = true
    let trackID: Int64

    @State private var info: TrackInfo?
    @State private var draft: TrackMetadataDraft?
    @State private var original: TrackMetadataDraft?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Info da faixa").font(.title2.weight(.semibold))

            if let info, draft != nil {
                Form {
                    Section("Metadados") {
                        field("Título", \.title)
                        field("Artista", \.artist)
                        field("Artista do álbum", \.albumArtist)
                        field("Álbum", \.album)
                        field("Gênero", \.genre)
                        field("Ano", \.year)
                        field("Faixa", \.trackNumber)
                        field("Disco", \.discNumber)
                        field("Compositor", \.composer)
                        field("Comentário", \.comment)
                    }
                    Section("Arquivo") {
                        LabeledContent("Duração", value: durationText(info.track.durationSeconds))
                        if let bitrate = info.track.bitrate {
                            LabeledContent("Bitrate", value: "\(bitrate) kbps")
                        }
                        if let rate = info.track.sampleRate {
                            LabeledContent("Taxa de amostragem", value: "\(rate) Hz")
                        }
                        if let depth = info.track.bitDepth {
                            LabeledContent("Profundidade", value: "\(depth) bits")
                        }
                        Text(info.track.filePath)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }
                .formStyle(.grouped)
                .disabled(isSaving)
                Toggle("Gravar alterações no arquivo", isOn: $writeChangesToFiles)
                    .disabled(isSaving)
                Text(writeChangesToFiles
                     ? "As tags serão gravadas no arquivo e a biblioteca será atualizada. Um backup permite desfazer."
                     : "As alterações serão mantidas apenas no Durvald, inclusive após novos scans.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if errorMessage == nil {
                ProgressView("Carregando metadados…")
                    .frame(maxWidth: .infinity, minHeight: 160)
            }

            if isSaving { ProgressView("Salvando…") }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).textSelection(.enabled)
                    .accessibilityIdentifier("trackInfo.error")
            }
            if let statusMessage {
                Text(statusMessage).foregroundStyle(.secondary)
                    .accessibilityIdentifier("trackInfo.status")
            }

            HStack {
                Button("Desfazer última alteração") { Task { await undo() } }
                    .disabled(isSaving || info?.canUndo != true || draft != original)
                    .accessibilityIdentifier("trackInfo.undo")
                Spacer()
                Button(draft == original ? "Fechar" : "Cancelar") { dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(isSaving)
                Button("Salvar") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || draft == nil || draft == original)
                    .accessibilityIdentifier("trackInfo.save")
            }
        }
        .padding(24)
        .frame(width: 560, height: 690)
        .background(WindowTrafficLightsHider())
        .interactiveDismissDisabled(isSaving || draft != original)
        .task { await load() }
    }

    private func field(_ title: String, _ keyPath: WritableKeyPath<TrackMetadataDraft, String>) -> some View {
        TextField(title, text: Binding(
            get: { draft?[keyPath: keyPath] ?? "" },
            set: { value in
                draft?[keyPath: keyPath] = value
                errorMessage = nil
                statusMessage = nil
            }
        ))
    }

    private func durationText(_ duration: Double) -> String {
        let seconds = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func accept(_ value: TrackInfo) {
        info = value
        draft = TrackMetadataDraft(value.metadata)
        original = draft
    }

    private func load() async {
        guard let core = store.core else {
            errorMessage = "A biblioteca ainda está abrindo. Tente novamente em instantes."
            return
        }
        do { accept(try await core.trackInfo(trackId: trackID)) }
        catch { errorMessage = error.localizedDescription }
    }

    private func save() async {
        guard !isSaving, let draft, let core = store.core else { return }
        errorMessage = nil
        statusMessage = nil
        do {
            let metadata = try draft.metadata()
            isSaving = true
            defer { isSaving = false }
            let value = try await core.saveTrackMetadata(trackId: trackID, metadata: metadata, writeToFile: writeChangesToFiles)
            accept(value)
            await store.refreshAfterMetadataEdit(value)
            statusMessage = "Salvo."
        } catch { errorMessage = "Não foi possível salvar: \(error.localizedDescription)" }
    }

    private func undo() async {
        guard !isSaving, let core = store.core else { return }
        isSaving = true
        errorMessage = nil
        statusMessage = nil
        defer { isSaving = false }
        do {
            let value = try await core.undoTrackMetadata(trackId: trackID)
            accept(value)
            await store.refreshAfterMetadataEdit(value)
            statusMessage = "Alteração desfeita."
        } catch { errorMessage = "Não foi possível desfazer: \(error.localizedDescription)" }
    }
}
