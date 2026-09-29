import SwiftUI

struct SmartPlaylistSheet: View {
    private struct RuleDraft: Identifiable {
        let id = UUID()
        var field: Field
        var comparison: Comparison
        var value: String
    }

    private enum Field: String, CaseIterable, Identifiable {
        case rating, favorite, genre, year, playCount = "play_count"
        case lastPlayed = "last_played", dateAdded = "date_added"
        var id: Self { self }
        var title: String {
            switch self {
            case .rating: "Nota"
            case .favorite: "Favorita"
            case .genre: "Gênero"
            case .year: "Ano"
            case .playCount: "Reproduções"
            case .lastPlayed: "Última reprodução"
            case .dateAdded: "Data de inclusão"
            }
        }
        var isDate: Bool { self == .lastPlayed || self == .dateAdded }
        var isNumber: Bool { self == .rating || self == .year || self == .playCount }
    }

    private enum Comparison: String, CaseIterable, Identifiable {
        case equals, notEquals = "not_equals", greater, greaterOrEqual = "greater_or_equal"
        case less, lessOrEqual = "less_or_equal", contains, before, after
        case isEmpty = "is_empty", isNotEmpty = "is_not_empty"
        var id: Self { self }
        var title: String {
            switch self {
            case .equals: "é"
            case .notEquals: "não é"
            case .greater: "maior que"
            case .greaterOrEqual: "maior ou igual"
            case .less: "menor que"
            case .lessOrEqual: "menor ou igual"
            case .contains: "contém"
            case .before: "antes de"
            case .after: "depois de"
            case .isEmpty: "não está definida"
            case .isNotEmpty: "está definida"
            }
        }
        var needsValue: Bool { self != .isEmpty && self != .isNotEmpty }
    }

    private enum SortField: String, CaseIterable, Identifiable {
        case title, artist, album, rating, playCount = "play_count"
        case lastPlayed = "last_played", dateAdded = "date_added", year
        var id: Self { self }
        var title: String {
            switch self {
            case .title: "Título"
            case .artist: "Artista"
            case .album: "Álbum"
            case .rating: "Nota"
            case .playCount: "Reproduções"
            case .lastPlayed: "Última reprodução"
            case .dateAdded: "Data de inclusão"
            case .year: "Ano"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var description: String
    @State private var matchAll: Bool
    @State private var rules: [RuleDraft]
    @State private var hasLimit: Bool
    @State private var limit: Int
    @State private var sortField: SortField
    @State private var descending: Bool
    @State private var isSaving = false

    private let playlist: Playlist?
    let onSave: (String, String, SmartPlaylistDefinition) async -> Bool

    init(
        playlist: Playlist? = nil,
        onSave: @escaping (String, String, SmartPlaylistDefinition) async -> Bool
    ) {
        self.playlist = playlist
        self.onSave = onSave
        let definition = playlist?.smartDefinition
        _name = State(initialValue: playlist?.name ?? "")
        _description = State(initialValue: playlist?.description ?? "")
        _matchAll = State(initialValue: definition?.matchAll ?? true)
        _rules = State(initialValue: definition?.rules.compactMap { rule in
            guard let field = Field(rawValue: rule.field),
                  let comparison = Comparison(rawValue: rule.comparison) else { return nil }
            return RuleDraft(field: field, comparison: comparison, value: rule.value)
        } ?? [RuleDraft(field: .rating, comparison: .greaterOrEqual, value: "4")])
        _hasLimit = State(initialValue: definition?.limit != nil)
        _limit = State(initialValue: Int(definition?.limit ?? 100))
        _sortField = State(initialValue: SortField(rawValue: definition?.sortBy ?? "title") ?? .title)
        _descending = State(initialValue: definition?.descending ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(playlist == nil ? "Nova smart playlist" : "Editar smart playlist")
                .font(.title2.weight(.semibold))

            Form {
                TextField("Nome", text: $name)
                TextField("Descrição (opcional)", text: $description)

                Section("Correspondência") {
                    Picker("Incluir quando", selection: $matchAll) {
                        Text("todas as regras coincidirem").tag(true)
                        Text("qualquer regra coincidir").tag(false)
                    }
                    ForEach($rules) { $rule in
                        HStack {
                            Picker("Campo", selection: $rule.field) {
                                ForEach(Field.allCases) { Text($0.title).tag($0) }
                            }
                            .onChange(of: rule.field) { _, field in
                                rule.comparison = comparisons(for: field).first ?? .equals
                                rule.value = field == .favorite ? "true" : ""
                            }
                            Picker("Comparação", selection: $rule.comparison) {
                                ForEach(comparisons(for: rule.field)) { Text($0.title).tag($0) }
                            }
                            if rule.comparison.needsValue {
                                if rule.field == .favorite {
                                    Picker("Valor", selection: $rule.value) {
                                        Text("Sim").tag("true")
                                        Text("Não").tag("false")
                                    }.frame(width: 90)
                                } else {
                                    TextField(valuePlaceholder(for: rule.field), text: $rule.value)
                                        .frame(width: 130)
                                }
                            }
                            Button(role: .destructive) { rules.removeAll { $0.id == rule.id } } label: {
                                Image(systemName: "minus.circle")
                            }.buttonStyle(.borderless)
                        }
                    }
                    Button("Adicionar regra", systemImage: "plus") {
                        rules.append(.init(field: .rating, comparison: .greaterOrEqual, value: "4"))
                    }
                }

                Section("Resultado") {
                    Picker("Ordenar por", selection: $sortField) {
                        ForEach(SortField.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Ordem decrescente", isOn: $descending)
                    Toggle("Limitar quantidade", isOn: $hasLimit)
                    if hasLimit { Stepper("Máximo: \(limit)", value: $limit, in: 1...10_000) }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancelar", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Salvar") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave || isSaving)
            }
        }
        .padding(24)
        .frame(width: 720, height: 620)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !rules.isEmpty
            && rules.allSatisfy { !$0.comparison.needsValue || !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func comparisons(for field: Field) -> [Comparison] {
        if field == .genre { return [.contains, .equals, .notEquals, .isEmpty, .isNotEmpty] }
        if field == .favorite { return [.equals, .notEquals] }
        if field.isDate { return [.before, .after, .isEmpty, .isNotEmpty] }
        return [.equals, .notEquals, .greater, .greaterOrEqual, .less, .lessOrEqual, .isEmpty, .isNotEmpty]
    }

    private func valuePlaceholder(for field: Field) -> String {
        field.isDate ? "AAAA-MM-DD" : (field.isNumber ? "Número" : "Valor")
    }

    private func save() {
        isSaving = true
        let definition = SmartPlaylistDefinition(
            matchAll: matchAll,
            rules: rules.map { SmartPlaylistRule(field: $0.field.rawValue, comparison: $0.comparison.rawValue, value: $0.value) },
            limit: hasLimit ? UInt32(limit) : nil,
            sortBy: sortField.rawValue,
            descending: descending
        )
        Task {
            let saved = await onSave(name, description, definition)
            isSaving = false
            if saved { dismiss() }
        }
    }
}
