import SwiftUI

struct ClassificationSection: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(\.trackMenuNavigation) private var navigation
    let target: ClassificationTarget
    let itemID: Int64
    @State private var links: [ClassificationLink] = []
    @State private var editingKind: ClassificationKind?
    @State private var error: String?
    private var request: String { "\(target):\(itemID):\(store.libraryCatalogRevision):\(store.classificationRevision)" }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach([ClassificationKind.genre, .style], id: \.key) { kind in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(kind.title).font(.subheadline.weight(.medium))
                        if target != .artist {
                            Button("Editar \(kind.title.lowercased())") { editingKind = kind }
                                .buttonStyle(.borderless).accessibilityIdentifier("classification.edit.\(kind.key)")
                        }
                    }
                    let items = links.filter { $0.term.kind == kind }
                    if items.isEmpty { Text("Não informado").font(.caption).foregroundStyle(.secondary) }
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) { ForEach(items, id: \.term.selfIdentity) { link in
                            Button { navigation.classification(kind, link.term.id) } label: {
                                HStack(spacing: 4) {
                                    Text(link.term.name)
                                    if link.origin == "contains_tracks" { Image(systemName: "music.note") }
                                }.font(.caption).padding(.horizontal, 9).padding(.vertical, 5)
                                    .background(.quaternary, in: .capsule)
                            }.buttonStyle(.plain).help(origin(link.origin))
                                .accessibilityLabel("\(link.term.name), \(origin(link.origin))")
                                .accessibilityIdentifier("classification.link.\(kind.key).\(link.term.id)")
                        } }
                    }.scrollIndicators(.hidden)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            if target == .artist { Text("Resumo dos lançamentos na biblioteca.").font(.caption).foregroundStyle(.secondary) }
        }
        .task(id: request) {
            guard let core = store.core else { return }
            do {
                let value = try await core.classificationLinks(target: target, id: itemID)
                guard !Task.isCancelled else { return }
                links = value; error = nil
            } catch { if !Task.isCancelled { self.error = "Não foi possível carregar a classificação." } }
        }
        .sheet(isPresented: Binding(get: { editingKind != nil }, set: { if !$0 { editingKind = nil } })) {
            if let kind = editingKind { ClassificationEditor(target: target, itemID: itemID, kind: kind, links: links) }
        }
    }
    private func origin(_ value: String) -> String {
        switch value {
        case "manual": "Sua classificação"
        case "file": "Metadados do arquivo"
        case "metadata_edit": "Metadados editados"
        case "legacy_release": "Metadados do catálogo local"
        case "album": "Herdado do álbum"
        case "contains_tracks": "Contém faixas desta classificação"
        default: "Resumo do conteúdo da biblioteca"
        }
    }
}

struct ClassificationEditor: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let target: ClassificationTarget
    let itemID: Int64
    let kind: ClassificationKind
    let links: [ClassificationLink]
    @State private var text = ""
    @State private var error: String?
    @State private var busy = false
    @State private var suggestions: [ClassificationTerm] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Editar \(kind.title.lowercased())").font(.title2.bold())
            Text("Um nome por linha. Salvar substitui este campo apenas neste item. Deixar vazio mantém uma exclusão explícita, inclusive após atualizar os metadados.")
                .foregroundStyle(.secondary)
            TextEditor(text: $text).font(.body).frame(height: 130).border(.quaternary)
                .accessibilityIdentifier("classification.editor.names")
            if !suggestions.isEmpty {
                Text("Existentes na biblioteca").font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    HStack { ForEach(suggestions, id: \.selfIdentity) { term in
                        Button(term.name) { text += (text.isEmpty ? "" : "\n") + term.name }
                    } }
                }.frame(maxHeight: 32)
            }
            Text("As alterações ficam no aplicativo e não modificam os arquivos de áudio.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Usar metadados de origem") { save(nil) }.accessibilityIdentifier("classification.editor.reset")
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Salvar") { save(text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) }
                    .keyboardShortcut(.defaultAction).accessibilityIdentifier("classification.editor.save")
            }.disabled(busy)
        }.padding(24).frame(width: 560)
        .task {
            text = links.filter { $0.term.kind == kind && $0.origin != "contains_tracks" }.map(\.term.name).joined(separator: "\n")
            suggestions = ((try? await store.core?.classificationTerms()) ?? []).filter { $0.kind == kind }
        }
    }
    private func save(_ names: [String]?) {
        guard let core = store.core, !busy else { return }; busy = true
        Task {
            defer { busy = false }
            do {
                try await core.setClassification(target: target, id: itemID, kind: kind, names: names)
                store.classificationRevision &+= 1
                dismiss()
            } catch { self.error = "Não foi possível salvar. Use nomes de até 100 caracteres, sem repetições desnecessárias." }
        }
    }
}

struct StyleGenreEditor: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let style: ClassificationTerm
    @State private var genres: [ClassificationTerm] = []
    @State private var selected: Set<Int64> = []
    @State private var error: String?
    @State private var loading = true
    @State private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Gêneros relacionados a \(style.name)").font(.title2.bold())
            Text("Relação definida por você. Associar um estilo a um gênero não reclassifica seus álbuns ou músicas.").foregroundStyle(.secondary)
            if loading { ProgressView() }
            ScrollView {
                VStack(alignment: .leading) {
                    ForEach(genres, id: \.id) { genre in
                        Toggle(genre.name, isOn: Binding(get: { selected.contains(genre.id) }, set: { value in
                            if value { selected.insert(genre.id) } else { selected.remove(genre.id) }
                        })).accessibilityIdentifier("classification.relation.\(genre.id)")
                    }
                }
            }.frame(height: 180)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer(); Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Salvar") { save() }.disabled(loading || saving).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("classification.relations.save")
            }
        }.padding(24).frame(width: 520)
        .task {
            guard let core = store.core else { return }
            do {
                genres = try await core.classificationTerms().filter { $0.kind == .genre }
                let page = try await core.classificationPage(kind: .style, id: style.id, query: "", offset: 0, pageSize: 1)
                selected = Set(page.relatedTerms.map(\.id)); loading = false
            } catch { self.error = "Não foi possível carregar as relações." }
        }
    }
    private func save() {
        guard let core = store.core else { return }; saving = true
        Task {
            defer { saving = false }
            do {
                try await core.setStyleGenres(styleId: style.id, genreIds: selected.sorted())
                store.classificationRevision &+= 1; dismiss()
            } catch { self.error = "Não foi possível salvar as relações." }
        }
    }
}
