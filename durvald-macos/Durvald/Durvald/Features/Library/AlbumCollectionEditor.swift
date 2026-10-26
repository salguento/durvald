import SwiftUI

struct AlbumCollectionEditorRequest: Identifiable {
    let id = UUID()
    var collection: AlbumCollection?
}

enum AlbumRuleField: String, CaseIterable {
    case artist, genre, style, albumTag, trackTag, yearFrom, yearTo, rating, played
    var title: String {
        switch self {
        case .artist: "Artista contém"
        case .genre: "Gênero do álbum"
        case .style: "Estilo do álbum"
        case .albumTag: "Álbum possui a tag"
        case .trackTag: "Contém faixa com a tag"
        case .yearFrom: "Ano a partir de"
        case .yearTo: "Ano até"
        case .rating: "Avaliação do álbum a partir de"
        case .played: "Histórico de reprodução"
        }
    }
    var key: String {
        switch self { case .albumTag: "album_tag"; case .trackTag: "track_tag"; case .yearFrom, .yearTo: "year"; default: rawValue }
    }
    var comparison: String {
        switch self { case .artist: "contains"; case .yearFrom, .rating: "at_least"; case .yearTo: "at_most"; default: "equals" }
    }
}

struct AlbumRuleDraft: Identifiable {
    let id = UUID()
    var field: AlbumRuleField = .artist
    var value = ""
    var rule: SmartPlaylistRule { SmartPlaylistRule(field: field.key, comparison: field.comparison, value: value) }
    var valid: Bool {
        switch field {
        case .artist: !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .yearFrom, .yearTo: Int(value).map { (1000...3000).contains($0) } ?? false
        case .rating: Int(value).map { (0...10).contains($0) } ?? false
        case .played: value == "true" || value == "false"
        default: Int64(value).map { $0 > 0 } ?? false
        }
    }
    init() {}
    init(_ rule: SmartPlaylistRule) {
        field = AlbumRuleField.allCases.first(where: { $0.key == rule.field && $0.comparison == rule.comparison }) ?? .artist
        value = rule.value
    }
}

struct AlbumCollectionEditor: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(AlbumCollectionsState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let collection: AlbumCollection?
    let onSaved: (AlbumCollection) -> Void
    @State private var name: String
    @State private var description: String
    @State private var smart: Bool
    @State private var matchAll: Bool
    @State private var rules: [AlbumRuleDraft]
    @State private var order: String
    @State private var descending: Bool
    @State private var terms: [ClassificationTerm] = []
    @State private var tags: [UserTag] = []
    @State private var loadingError: String?
    init(collection: AlbumCollection?, onSaved: @escaping (AlbumCollection) -> Void) {
        self.collection = collection; self.onSaved = onSaved
        _name = State(initialValue: collection?.name ?? "")
        _description = State(initialValue: collection?.description ?? "")
        _smart = State(initialValue: collection?.definition != nil)
        _matchAll = State(initialValue: collection?.definition?.matchAll ?? true)
        _rules = State(initialValue: collection?.definition?.rules.map(AlbumRuleDraft.init) ?? [AlbumRuleDraft()])
        _order = State(initialValue: collection?.definition?.sortBy ?? "title")
        _descending = State(initialValue: collection?.definition?.descending ?? false)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(collection == nil ? "Nova coleção" : "Editar coleção").font(.title2.bold())
            TextField("Nome", text: $name).textFieldStyle(.roundedBorder).accessibilityIdentifier("albumCollection.editor.name")
            TextField("Descrição", text: $description, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
            if collection == nil {
                Picker("Tipo", selection: $smart) { Text("Manual").tag(false); Text("Inteligente").tag(true) }
                    .pickerStyle(.segmented).accessibilityIdentifier("albumCollection.editor.kind")
            }
            if smart {
                Picker("Combinar", selection: $matchAll) { Text("Todas as regras").tag(true); Text("Qualquer regra").tag(false) }
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach($rules) { $rule in
                            HStack {
                                Picker("Campo", selection: $rule.field) {
                                    ForEach(AlbumRuleField.allCases, id: \.self) { Text($0.title).tag($0) }
                                }.labelsHidden().frame(width: 215)
                                    .onChange(of: rule.field) { _, field in rule.value = initialValue(field) }
                                ruleValue($rule)
                                Button("Remover regra", systemImage: "minus.circle") { rules.removeAll { $0.id == rule.id } }
                                    .labelStyle(.iconOnly).disabled(rules.count == 1)
                            }
                        }
                    }
                }.frame(minHeight: 70, maxHeight: 230)
                Button("Adicionar regra", systemImage: "plus") { rules.append(AlbumRuleDraft()) }.disabled(rules.count >= 20)
                    .accessibilityIdentifier("albumCollection.editor.addRule")
                HStack {
                    Picker("Ordenar álbuns por", selection: $order) {
                        Text("Título").tag("title"); Text("Artista").tag("artist"); Text("Ano").tag("year"); Text("Avaliação do álbum").tag("rating")
                    }
                    Toggle("Decrescente", isOn: $descending)
                }
                Text("As regras selecionam álbuns completos. A avaliação é a nota pessoal do álbum; “já reproduzido” exige ao menos um registro no histórico.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Adicione álbuns e escolha a ordem na página da coleção.").foregroundStyle(.secondary)
            }
            if let error = loadingError ?? state.error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if state.changing { ProgressView().controlSize(.small) }
                Button("Salvar") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 120 || description.count > 2000 || (smart && !rules.allSatisfy(\.valid)))
                    .accessibilityIdentifier("albumCollection.editor.save")
            }
        }.padding(24).frame(width: 660).disabled(state.changing).interactiveDismissDisabled(state.changing)
            .task {
                guard let core = store.core else { return }
                do {
                    terms = try await core.classificationTerms()
                    tags = try await core.userTagLibrary().tags
                } catch { loadingError = "Não foi possível carregar os gêneros e tags. Você ainda pode usar filtros de texto." }
            }
    }
    @ViewBuilder private func ruleValue(_ rule: Binding<AlbumRuleDraft>) -> some View {
        switch rule.wrappedValue.field {
        case .genre, .style:
            let choices = terms.filter { $0.kind == (rule.wrappedValue.field == .genre ? .genre : .style) }
            Picker("Classificação", selection: rule.value) {
                Text("Selecione…").tag("")
                if !rule.wrappedValue.value.isEmpty && !choices.contains(where: { String($0.id) == rule.wrappedValue.value }) { Text("Classificação indisponível").tag(rule.wrappedValue.value) }
                ForEach(choices, id: \.id) { Text($0.name).tag(String($0.id)) }
            }.labelsHidden()
        case .albumTag, .trackTag:
            Picker("Tag", selection: rule.value) {
                Text("Selecione…").tag("")
                if !rule.wrappedValue.value.isEmpty && !tags.contains(where: { String($0.id) == rule.wrappedValue.value }) { Text("Tag removida").tag(rule.wrappedValue.value) }
                ForEach(tags, id: \.id) { Text($0.name).tag(String($0.id)) }
            }.labelsHidden()
        case .rating:
            Picker("Nota", selection: rule.value) { ForEach(0...10, id: \.self) { Text("\(RatingValues.number($0)) estrelas").tag(String($0)) } }.labelsHidden()
        case .played:
            Picker("Histórico", selection: rule.value) { Text("Já reproduzido").tag("true"); Text("Nunca reproduzido").tag("false") }.labelsHidden()
        default:
            TextField(rule.wrappedValue.field == .artist ? "Nome do artista" : "Ano", text: rule.value)
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("albumCollection.editor.ruleValue")
        }
    }
    private func initialValue(_ field: AlbumRuleField) -> String {
        switch field { case .rating: "8"; case .played: "true"; case .yearFrom, .yearTo: "2000"; default: "" }
    }
    private func save() {
        let def = smart ? AlbumCollectionDefinition(matchAll: matchAll, rules: rules.map(\.rule), sortBy: order, descending: descending) : nil
        Task {
            var saved: AlbumCollection?
            if await state.change(id: collection?.id, using: store, operation: { core in
                saved = try await core.saveAlbumCollection(collectionId: collection?.id, name: name, description: description, definition: def)
            }), let saved { onSaved(saved); dismiss() }
        }
    }
}
