import SwiftUI

struct PersonalTagSection: View {
    @Environment(DurvaldCoreStore.self) private var store
    let selection: PersonalTagSelection
    @State private var isEditing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tags pessoais").font(.subheadline.weight(.medium))
                Button("Editar tags", systemImage: "tag") { isEditing = true }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("personalTags.edit")
            }
            if store.tags(for: selection).isEmpty {
                Text("Nenhuma tag").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(store.tags(for: selection), id: \.id) { tag in
                            Text(tag.name).font(.caption).padding(.horizontal, 9).padding(.vertical, 5)
                                .background(.quaternary, in: .capsule)
                                .accessibilityIdentifier("personalTags.chip.\(tag.id)")
                        }
                    }
                }
            }
        }
        .task(id: store.personalTagsRequest) { await store.refreshPersonalTags() }
        .sheet(isPresented: $isEditing) { PersonalTagEditor(selection: selection) }
    }
}

struct PersonalTagEditor: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let selection: PersonalTagSelection
    @State private var query = ""
    @State private var isManaging = false
    private var suggestions: [UserTag] {
        store.personalTags.tags.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }
    private var normalizedQuery: String { query.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tags pessoais").font(.title2.bold())
            Text(selection.count == 1 ? "Categorias livres para este item." : "Aplicar ou remover tags nos \(selection.count) itens selecionados.")
                .foregroundStyle(.secondary)
            TextField("Buscar ou criar uma tag", text: $query)
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("personalTags.input")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(suggestions, id: \.id) { tag in
                        let count = store.associationCount(tag, in: selection)
                        HStack {
                            Toggle(tag.name, isOn: Binding(get: { count == selection.count }, set: { attached in
                                Task { await store.attachPersonalTag(tag, to: selection, attached: attached) }
                            }))
                            .accessibilityIdentifier("personalTags.toggle.\(tag.id)")
                            Spacer()
                            if count > 0 && count < selection.count {
                                Text("\(count) de \(selection.count)").font(.caption).foregroundStyle(.secondary)
                                Button("Remover da seleção") {
                                    Task { await store.attachPersonalTag(tag, to: selection, attached: false) }
                                }.buttonStyle(.borderless)
                            }
                        }
                    }
                    if !normalizedQuery.isEmpty {
                        Button("Usar tag “\(normalizedQuery)”", systemImage: "plus") {
                            Task { if await store.createPersonalTag(normalizedQuery, selection: selection) { query = "" } }
                        }.accessibilityIdentifier("personalTags.create")
                    }
                    if suggestions.isEmpty && normalizedQuery.isEmpty {
                        Text("Crie sua primeira tag para organizar a biblioteca.").foregroundStyle(.secondary)
                    }
                }.padding(2)
            }.frame(minHeight: 140, maxHeight: 280)
            PersonalTagError()
            HStack {
                Button("Gerenciar tags…") { isManaging = true }
                Spacer()
                if store.isUpdatingPersonalTags { ProgressView().controlSize(.small) }
                Button("Concluir") { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("personalTags.done")
            }
        }
        .padding(24).frame(width: 520)
        .disabled(store.isUpdatingPersonalTags)
        .task(id: store.personalTagsRequest) { await store.refreshPersonalTags() }
        .sheet(isPresented: $isManaging) { PersonalTagManager() }
    }
}

struct PersonalTagManager: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var deleting: UserTag?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Gerenciar tags pessoais").font(.title2.bold())
            Text("Renomear atualiza todos os usos. Excluir remove a tag de toda a biblioteca.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("Nova tag", text: $newName).textFieldStyle(.roundedBorder)
                Button("Criar") { Task { if await store.createPersonalTag(newName) { newName = "" } } }
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            ScrollView {
                LazyVStack {
                    ForEach(store.personalTags.tags, id: \.id) { tag in
                        PersonalTagNameRow(tag: tag, onDelete: { deleting = tag })
                    }
                }
            }.frame(height: 260)
            PersonalTagError()
            HStack { Spacer(); Button("Concluir") { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("personalTags.managerDone") }
        }
        .padding(24).frame(width: 560)
        .disabled(store.isUpdatingPersonalTags)
        .task(id: store.personalTagsRequest) { await store.refreshPersonalTags() }
        .alert("Excluir tag de todos os itens?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { tag in
            Button("Cancelar", role: .cancel) {}
            Button("Excluir de todos", role: .destructive) {
                Task { _ = await store.changePersonalTags { try await $0.deleteUserTag(tagId: tag.id) } }
            }
        } message: { tag in Text("“\(tag.name)” será removida de todas as faixas e lançamentos. Os arquivos de áudio serão preservados.") }
    }
}

private struct PersonalTagNameRow: View {
    @Environment(DurvaldCoreStore.self) private var store
    let tag: UserTag
    let onDelete: () -> Void
    @State private var name = ""
    var body: some View {
        HStack {
            TextField("Nome da tag", text: $name).textFieldStyle(.roundedBorder).accessibilityIdentifier("personalTags.name.\(tag.id)")
            Button("Renomear") {
                Task { _ = await store.changePersonalTags { _ = try await $0.renameUserTag(tagId: tag.id, name: name) } }
            }.accessibilityIdentifier("personalTags.rename.\(tag.id)").disabled(name == tag.name || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Excluir", systemImage: "trash", role: .destructive, action: onDelete).labelStyle(.iconOnly).accessibilityIdentifier("personalTags.delete.\(tag.id)")
        }
        .onAppear { name = tag.name }
        .onChange(of: tag.name) { _, value in name = value }
    }
}

private struct PersonalTagError: View {
    @Environment(DurvaldCoreStore.self) private var store
    var body: some View {
        if let message = store.personalTagsError { Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
    }
}

struct PersonalTagFilterBar: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Binding var filter: PersonalTagFilter
    var selection: PersonalTagSelection? = nil
    @State private var isManaging = false
    var body: some View {
        HStack(spacing: 12) {
            Menu {
                Picker("Combinar tags", selection: $filter.matchAll) {
                    Text("Todas as tags").tag(true)
                    Text("Qualquer tag").tag(false)
                }
                Divider()
                ForEach(store.personalTags.tags, id: \.id) { tag in
                    Toggle(tag.name, isOn: Binding(get: { filter.ids.contains(tag.id) }, set: { on in
                        if on { filter.ids.insert(tag.id) } else { filter.ids.remove(tag.id) }
                    }))
                }
                Divider()
                Button("Gerenciar tags…") { isManaging = true }
            } label: { Label(filter.ids.isEmpty ? "Tags pessoais" : "Tags pessoais (\(filter.ids.count))", systemImage: "tag") }
            .fixedSize().accessibilityIdentifier("personalTags.filter")
            if !filter.ids.isEmpty {
                Text(filter.matchAll ? "Todas as tags selecionadas" : "Qualquer tag selecionada")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Limpar") { filter.ids.removeAll() }.buttonStyle(.borderless)
            }
            Spacer()
            if let selection, selection.count > 0 {
                Button(selection.count == 1 ? "Editar tags de 1 item" : "Editar tags de \(selection.count) itens") { store.personalTagEditor = selection }
                    .buttonStyle(.borderless)
                    .disabled(selection.count > 10_000)
                    .accessibilityIdentifier("personalTags.editBatch")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .task(id: store.personalTagsRequest) { await store.refreshPersonalTags() }
        .onChange(of: store.personalTags.tags.map(\.id)) { _, ids in filter.ids.formIntersection(ids) }
        .sheet(isPresented: $isManaging) { PersonalTagManager() }
    }
}
