import SwiftUI

struct SoulseekSearchView: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let initialQuery: String
    var expectedTracks: [DownloadExpectedTrack] = []
    @State private var query = ""
    @State private var presentation = SoulseekSearchPresentation()
    @State private var offerToDownload: DownloadOfferGroup?
    @State private var showDownloadSelection = false
    @State private var showTransfers = false
    @State private var queuedJobID: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Buscar opções de download").font(.title2)
                Spacer()
                SettingsLink { Text("Ajustes") }
                Button("Fechar") { Task { await presentation.close(); dismiss() } }.keyboardShortcut(.cancelAction)
            }
            HStack {
                TextField("Artista, faixa, álbum ou edição", text: $query).onSubmit { search() }
                Button("Buscar") { search() }.disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 || store.core == nil)
                    .accessibilityIdentifier("soulseek.search")
                Button("Cancelar busca") { Task { await presentation.cancel() } }.disabled(!presentation.busy)
            }
            Text("Ofertas temporárias da rede Soulseek. Selecionar uma pasta apenas mostra seus arquivos. A extensão e o nome não comprovam qualidade, edição nem disponibilidade.").font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Filtrar usuário, pasta ou arquivo", text: $presentation.textFilter)
                Picker("Formato", selection: $presentation.formatFilter) {
                    Text("Todos").tag("")
                    ForEach(["flac", "mp3", "ogg", "wav", "m4a", "aac", "opus", "aiff", "alac"], id: \.self) { Text($0.uppercased()).tag($0) }
                }.frame(width: 150)
                Picker("Bitrate observado", selection: $presentation.minimumBitrate) {
                    Text("Qualquer").tag(0); Text("≥ 192 kbps").tag(192); Text("≥ 320 kbps").tag(320)
                }.frame(width: 190)
                Toggle("Slot livre", isOn: $presentation.freeSlotsOnly)
            }
            if !expectedTracks.isEmpty { Text("Comparação com \(expectedTracks.count) faixas carregadas da referência. Confira a tracklist completa e a edição antes de escolher.").font(.caption).foregroundStyle(.secondary) }
            HStack {
                if presentation.busy { ProgressView().controlSize(.small) }
                Text(presentation.status).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let error = presentation.error { Text(error).foregroundStyle(.red) }
            if presentation.page?.truncated == true { Text("Resultados limitados a 200 respostas e 5.000 arquivos. Refine a consulta.").font(.caption) }
            if presentation.page?.cleanupPending == true { Text("Não foi possível confirmar a remoção da busca no slskd. Ela tem prazo limitado; confira a instância quando a conexão voltar.").font(.caption) }
            HSplitView {
                List(selection: $presentation.selectedID) {
                    ForEach(presentation.groups, id: \.offerId) { group in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(group.folder).lineLimit(2)
                            Text("\(group.peer) · \(group.files.count) arquivos · \(size(group.totalBytes))").font(.caption)
                            Text(availability(group)).font(.caption).foregroundStyle(.secondary)
                            if group.expectedTracks > 0 { Text("\(group.matchedTracks)/\(group.expectedTracks) faixas compatíveis").font(.caption) }
                        }.tag(group.offerId)
                    }
                }.frame(minWidth: 280)
                ScrollView {
                    if let group = presentation.selected {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(group.peer).font(.headline)
                            Text(group.folder).textSelection(.enabled)
                            Text(group.comparison).font(.caption).foregroundStyle(.secondary)
                            Button("Selecionar arquivos para download…") { offerToDownload = group; showDownloadSelection = true }
                            ForEach(group.files, id: \.filename) { file in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(file.filename.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? file.filename)
                                    Text(quality(file)).font(.caption).foregroundStyle(.secondary)
                                }
                                Divider()
                            }
                        }.padding().frame(maxWidth: .infinity, alignment: .leading)
                    } else { Text("Selecione uma pasta para inspecionar os arquivos.").foregroundStyle(.secondary).padding() }
                }.frame(minWidth: 300)
            }
        }.padding(20).frame(minWidth: 860, idealWidth: 960, minHeight: 560)
        .task(id: store.core.map(ObjectIdentifier.init)) {
            query = initialQuery
            if let core = store.core { await presentation.prepare(SoulseekSearchLoader(session: core.downloadSearchSession())) }
        }
        .onDisappear { Task { await presentation.close() } }
        .sheet(isPresented: $showDownloadSelection, onDismiss: { if queuedJobID != nil { showTransfers = true } }) {
            if let offer = offerToDownload { DownloadSelectionView(group: offer) { filenames in
                let job = try await presentation.enqueue(offerID: offer.offerId, filenames: filenames)
                queuedJobID = job.jobId
            } }
        }
        .sheet(isPresented: $showTransfers) { DownloadTransfersView(initialJobID: queuedJobID, isSheet: true) }
    }
    private func search() { presentation.start(query: query, expected: expectedTracks) }
    private func size(_ bytes: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file) }
    private func availability(_ group: DownloadOfferGroup) -> String {
        let slot = group.freeUploadSlot.map { $0 ? "Slot livre" : "Sem slot livre" } ?? "Slot desconhecido"
        let queue = group.queueLength.map { "Fila: \($0)" } ?? "Fila desconhecida"
        let speed = group.uploadSpeedBytes.map { "\(size($0))/s" } ?? "Velocidade desconhecida"
        return "\(slot) · \(queue) · \(speed)"
    }
    private func quality(_ file: DownloadOfferFile) -> String {
        var parts = [file.format.uppercased(), size(file.sizeBytes)]
        parts.append(file.bitrateKbps.map { "\($0) kbps" } ?? "Bitrate desconhecido")
        parts.append(file.sampleRateHz.map { "\($0) Hz" } ?? "Frequência desconhecida")
        parts.append(file.bitDepth.map { "\($0) bits" } ?? "Profundidade desconhecida")
        parts.append(file.durationSeconds.map { "\($0 / 60):\(String(format: "%02d", $0 % 60))" } ?? "Duração desconhecida")
        return parts.joined(separator: " · ")
    }
}
extension DownloadExpectedTrack {
    static func reference(_ track: Track) -> DownloadExpectedTrack {
        DownloadExpectedTrack(title: track.title, disc: UInt32(max(track.discNumber, 1)), position: UInt32(max(track.trackNumber, 1)), durationSeconds: track.durationSeconds.isFinite && track.durationSeconds > 0 ? UInt64(track.durationSeconds) : nil)
    }
    static func references(_ entries: [CatalogEntry]) -> [DownloadExpectedTrack] {
        entries.compactMap { entry in
            guard let label = entry.versionLabel else { return nil }
            let position = label.split(separator: ".").compactMap { UInt32($0) }
            guard position.count == 2 else { return nil }
            return DownloadExpectedTrack(title: entry.title, disc: position[0], position: position[1], durationSeconds: entry.durationSeconds)
        }
    }
}
