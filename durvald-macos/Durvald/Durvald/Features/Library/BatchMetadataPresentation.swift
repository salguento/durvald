import Foundation
import Observation

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

struct BatchMetadataFailure: Identifiable {
    let trackID: Int64
    let title: String
    let message: String
    var id: Int64 { trackID }
}

struct BatchMetadataOperationReceipt: Codable {
    static let defaultsKey = "metadata.lastBatchOperation"

    let selectedTrackIDs: [Int64]
    var changedTrackIDs: [Int64]

    static func load(for selectedTrackIDs: [Int64], defaults: UserDefaults = .standard) -> Self? {
        guard let data = defaults.data(forKey: defaultsKey),
              let receipt = try? JSONDecoder().decode(Self.self, from: data),
              receipt.selectedTrackIDs == selectedTrackIDs else { return nil }
        return receipt
    }

    func persist(defaults: UserDefaults = .standard) {
        guard !changedTrackIDs.isEmpty,
              let data = try? JSONEncoder().encode(self) else {
            Self.clear(defaults: defaults)
            return
        }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}

@MainActor
@Observable
final class BatchMetadataPresentation {
    var infos: [TrackInfo] = []
    var draft: BatchMetadataDraft?
    var isWorking = false
    var completed = 0
    var total = 0
    var failures: [BatchMetadataFailure] = []
    var lastOperationTrackIDs: [Int64] = []
    var statusMessage: String?
    struct Request: Equatable {
        let trackIDs: [Int64]
        let coreID: ObjectIdentifier?
        let storeID: ObjectIdentifier
    }
    private var loadedRequest: Request?
    private var trackIDs: [Int64] = []
    @ObservationIgnored private var writesInProgress = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load(trackIDs: [Int64], using store: DurvaldCoreStore) async {
        guard !writesInProgress else { return }
        let selection = Request(trackIDs: trackIDs, coreID: store.core.map(ObjectIdentifier.init), storeID: ObjectIdentifier(store))
        if loadedRequest != selection {
            infos = []
            draft = nil
            lastOperationTrackIDs = []
            failures = []
            statusMessage = nil
        }
        self.trackIDs = trackIDs
        loadedRequest = selection
        let request = UUID()
        generation = request
        guard infos.isEmpty, let core = store.core else {
            if store.core == nil { statusMessage = "A biblioteca ainda está abrindo." }
            return
        }
        isWorking = true
        defer { if generation == request { isWorking = false } }
        total = trackIDs.count
        completed = 0
        failures = []
        statusMessage = nil
        var loaded: [TrackInfo] = []
        for id in trackIDs {
            var failure: Error?
            do { loaded.append(try await core.trackInfo(trackId: id)) }
            catch { failure = error }
            guard !Task.isCancelled, generation == request, store.core === core else { return }
            if let failure { failures.append(.init(trackID: id, title: "Faixa \(id)", message: failure.localizedDescription)) }
            completed += 1
        }
        infos = loaded
        draft = loaded.isEmpty ? nil : BatchMetadataDraft(infos: loaded)
        lastOperationTrackIDs = BatchMetadataOperationReceipt.load(for: trackIDs, defaults: defaults)?.changedTrackIDs ?? []
        isWorking = false
        if !failures.isEmpty { statusMessage = "Algumas faixas não puderam ser carregadas." }
    }

    func save(using store: DurvaldCoreStore, writeChangesToFiles: Bool) async {
        guard !isWorking, let core = store.core, let draft, draft.hasChanges else { return }
        let edits: [TrackMetadataEdit]
        do {
            edits = try infos.map { try draft.applying(to: $0.metadata) }
        } catch {
            statusMessage = error.localizedDescription
            return
        }
        isWorking = true
        writesInProgress = true
        defer { isWorking = false; writesInProgress = false }
        failures = []
        completed = 0
        total = infos.count
        lastOperationTrackIDs = []
        var refreshed: [TrackInfo] = []
        for (info, metadata) in zip(infos, edits) {
            do {
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
        if store.core === core, let last = refreshed.last { await store.refreshAfterMetadataEdit(last) }
        let failedIDs = Set(failures.map(\.trackID))
        infos = refreshed + infos.filter { failedIDs.contains($0.track.id) }
        self.draft = infos.isEmpty ? nil : BatchMetadataDraft(infos: infos)
        statusMessage = failures.isEmpty
            ? "\(lastOperationTrackIDs.count) faixas atualizadas."
            : "\(lastOperationTrackIDs.count) atualizadas; \(failures.count) falharam."
        BatchMetadataOperationReceipt(
            selectedTrackIDs: trackIDs,
            changedTrackIDs: lastOperationTrackIDs
        ).persist(defaults: defaults)
        isWorking = false
    }

    func undoLastOperation(using store: DurvaldCoreStore) async {
        guard !isWorking, let core = store.core, !lastOperationTrackIDs.isEmpty else { return }
        isWorking = true
        writesInProgress = true
        defer { isWorking = false; writesInProgress = false }
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
        if store.core === core, let last = restored.last { await store.refreshAfterMetadataEdit(last) }
        let failedIDs = Set(failures.map(\.trackID))
        lastOperationTrackIDs = lastOperationTrackIDs.filter { failedIDs.contains($0) }
        BatchMetadataOperationReceipt(
            selectedTrackIDs: trackIDs,
            changedTrackIDs: lastOperationTrackIDs
        ).persist(defaults: defaults)
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
