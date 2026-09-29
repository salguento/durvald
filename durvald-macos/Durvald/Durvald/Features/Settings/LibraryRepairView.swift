import SwiftUI

struct LibraryRepairView: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var analysis: LibraryRepairAnalysis?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var pendingMerge: MergeRequest?

    private struct MergeRequest: Identifiable {
        let id = UUID()
        let sourceID: Int64
        let targetID: Int64
        let sourceIsMissing: Bool
        let description: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Reparo da biblioteca").font(.title2.weight(.semibold))
                Spacer()
                Button("Analisar novamente") { Task { await load() } }.disabled(isLoading)
            }
            Text("O Durvald sugere correspondências, mas só mescla registros após sua confirmação.")
                .foregroundStyle(.secondary)

            if isLoading && analysis == nil {
                ProgressView("Calculando hashes e verificando caminhos…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let analysis {
                List {
                    Section("Caminhos quebrados (\(analysis.brokenFiles.count))") {
                        if analysis.brokenFiles.isEmpty { Text("Nenhum caminho quebrado.").foregroundStyle(.secondary) }
                        ForEach(analysis.brokenFiles, id: \.self) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title).fontWeight(.medium)
                                Text(item.filePath).font(.caption.monospaced()).foregroundStyle(.secondary)
                                ForEach(suggestions(for: item), id: \.self) { suggestion in
                                    HStack {
                                        Text("\(Int(suggestion.confidence * 100))% — \(suggestion.reason)")
                                            .font(.caption)
                                        Spacer()
                                        Button("Relink") {
                                            pendingMerge = .init(
                                                sourceID: suggestion.missingId,
                                                targetID: suggestion.candidateTrackId,
                                                sourceIsMissing: true,
                                                description: "\(item.title) → faixa #\(suggestion.candidateTrackId)"
                                            )
                                        }
                                    }
                                }
                            }.padding(.vertical, 3)
                        }
                    }
                    Section("Duplicatas (\(analysis.duplicateGroups.count) grupos)") {
                        if analysis.duplicateGroups.isEmpty { Text("Nenhuma duplicata por hash.").foregroundStyle(.secondary) }
                        ForEach(Array(analysis.duplicateGroups.enumerated()), id: \.offset) { _, group in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(group.reason).font(.headline)
                                ForEach(group.tracks, id: \.id) { item in
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text(item.title)
                                            Text(item.filePath).font(.caption.monospaced()).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if item.id != group.tracks.first?.id, let target = group.tracks.first {
                                            Button("Mesclar no primeiro") {
                                                pendingMerge = .init(
                                                    sourceID: item.id, targetID: target.id,
                                                    sourceIsMissing: false,
                                                    description: "\(item.filePath) → \(target.filePath)"
                                                )
                                            }
                                        }
                                    }
                                }
                            }.padding(.vertical, 4)
                        }
                    }
                }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
            HStack { Spacer(); Button("Fechar") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(24).frame(width: 760, height: 650)
        .task { await load() }
        .confirmationDialog("Confirmar mesclagem?", isPresented: Binding(
            get: { pendingMerge != nil }, set: { if !$0 { pendingMerge = nil } }
        ), titleVisibility: .visible, presenting: pendingMerge) { request in
            Button("Mesclar registros", role: .destructive) { Task { await merge(request) } }
            Button("Cancelar", role: .cancel) { pendingMerge = nil }
        } message: { request in
            Text("\(request.description)\n\nPlaylists, histórico, favoritos, contadores e a maior nota serão preservados. O arquivo não será apagado.")
        }
    }

    private func suggestions(for item: LibraryRepairTrack) -> [LibraryRepairSuggestion] {
        guard item.isMissing, let analysis else { return [] }
        return analysis.relinkSuggestions.filter { $0.missingId == item.id }
    }

    private func load() async {
        guard let core = store.core else { errorMessage = "A biblioteca ainda está abrindo."; return }
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do { analysis = try await core.analyzeLibraryRepairs() }
        catch { errorMessage = error.localizedDescription }
    }

    private func merge(_ request: MergeRequest) async {
        guard let core = store.core else { return }
        pendingMerge = nil; isLoading = true; errorMessage = nil
        do {
            try await core.mergeLibraryRecords(
                sourceId: request.sourceID, targetId: request.targetID,
                sourceIsMissing: request.sourceIsMissing
            )
            await store.refreshLibraryCatalog()
            analysis = try await core.analyzeLibraryRepairs()
        } catch { errorMessage = error.localizedDescription }
        isLoading = false
    }
}
