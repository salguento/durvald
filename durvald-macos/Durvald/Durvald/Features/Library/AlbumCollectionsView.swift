import SwiftUI

struct AlbumCollectionsView: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(AlbumCollectionsState.self) private var state
    let collectionID: Int64?
    let onOpen: (Int64) -> Void
    let onEdit: (AlbumCollection) -> Void
    let onCreate: () -> Void
    let onDeleted: () -> Void
    @State private var adding = false
    @State private var deleting = false
    private var page: AlbumCollectionPage? { state.page?.collection.id == collectionID ? state.page : nil }
    private var request: String {
        "\(collectionID ?? 0):\(store.core.map(ObjectIdentifier.init).map(String.init(describing:)) ?? "none"):\(store.libraryCatalogRevision):\(store.metadataRevision):\(store.classificationRevision):\(store.personalTagsRevision):\(store.releasesRevision):\(store.historyRepository.revision)"
    }
    private var items: [AlbumCollectionItem] {
        let query = collectionID.flatMap { state.detailQueries[$0] } ?? ""
        return (page?.items ?? []).filter { query.isEmpty || $0.title.localizedStandardContains(query) || $0.artist.localizedStandardContains(query) }
    }

    var body: some View {
        Group {
            if collectionID == nil && state.visibleCollections.isEmpty && !state.loading && state.error == nil {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                collectionContent
            }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("albumCollections.page")
        .task(id: request) { await state.load(id: collectionID, using: store) }
        .sheet(isPresented: $adding) {
            if let page { AlbumCollectionAlbumPicker(collection: page.collection) }
        }
        .alert("Excluir coleção?", isPresented: $deleting) {
            Button("Cancelar", role: .cancel) {}
            Button("Excluir coleção", role: .destructive) {
                guard let collectionID else { return }
                Task { if await state.change(using: store, operation: { try await $0.deleteAlbumCollection(collectionId: collectionID) }) { onDeleted() } }
            }
        } message: { Text("Os álbuns continuarão na sua biblioteca.") }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nenhuma coleção encontrada", systemImage: "rectangle.stack")
        } description: { Text("Crie uma coleção para organizar e reproduzir álbuns completos.") }
        actions: { Button("Nova coleção", action: onCreate).accessibilityIdentifier("albumCollections.empty.create") }
        .padding(24)
    }

    private var collectionContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let error = state.error {
                    HStack { Text(error).foregroundStyle(.red); Button("Tentar novamente") { Task { await state.load(id: collectionID, using: store) } } }
                }
                if let page {
                    detailHeader(page)
                    if items.isEmpty {
                        ContentUnavailableView("Nenhum álbum nesta seleção", systemImage: "rectangle.stack",
                            description: Text(page.collection.definition == nil ? "Adicione álbuns da biblioteca à coleção." : "Nenhum álbum disponível corresponde às regras."))
                    }
                    LazyVStack(spacing: 14) {
                        ForEach(items, id: \.id) { item in albumRow(item, page: page) }
                    }
                } else if collectionID == nil {
                    Text("Organize álbuns inteiros em coleções manuais ou inteligentes.")
                        .foregroundStyle(.secondary)
                    if state.visibleCollections.isEmpty && !state.loading {
                        emptyState
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 270), spacing: 24)], spacing: 24) {
                        ForEach(state.visibleCollections, id: \.id) { collection in
                            Button { onOpen(collection.id) } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    ArtworkView(artworkID: collection.artworkId, size: 150)
                                    Text(collection.name).font(.headline).foregroundStyle(.primary)
                                    Text("\(collection.albumCount) álbuns · \(collection.definition == nil ? "Manual" : "Inteligente")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                                    .background(.quaternary, in: .rect(cornerRadius: 12)).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("albumCollection.\(collection.id)")
                        }
                    }
                }
                if state.loading { ProgressView("Carregando coleções…") }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .preservesLibraryScrollPosition(isContentReady: !state.loading)
    }

    private func detailHeader(_ page: AlbumCollectionPage) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if !page.collection.description.isEmpty { Text(page.collection.description).textSelection(.enabled) }
            Text(page.collection.definition == nil ? "Coleção manual · álbuns na ordem escolhida por você." : "Coleção inteligente · álbuns selecionados pelas regras.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Reproduzir", systemImage: "play.fill") { play(.ordered) }.accessibilityIdentifier("albumCollection.play")
                Menu("Aleatório", systemImage: "shuffle") {
                    Button("Embaralhar álbuns") { play(.albums) }
                    Button("Embaralhar músicas") { play(.tracks) }
                }.accessibilityIdentifier("albumCollection.shuffle")
                Spacer()
                if page.collection.definition == nil {
                    Button("Adicionar álbuns", systemImage: "plus") { adding = true }.accessibilityIdentifier("albumCollection.add")
                }
                Button("Editar", systemImage: "pencil") { onEdit(page.collection) }.accessibilityIdentifier("albumCollection.edit")
                Button("Excluir", systemImage: "trash", role: .destructive) { deleting = true }.accessibilityIdentifier("albumCollection.delete")
            }.disabled(state.changing || state.preparingPlayback || store.isChangingTrack)
        }
    }
    private func play(_ mode: AlbumCollectionPlaybackMode, releaseID: Int64? = nil) {
        guard let collectionID else { return }
        Task { await state.play(id: collectionID, mode: mode, startingAt: releaseID, using: store) }
    }

    private func albumRow(_ item: AlbumCollectionItem, page: AlbumCollectionPage) -> some View {
        let index = page.items.firstIndex(where: { $0.id == item.id }) ?? 0
        let active = store.activeSourceContext == "albumCollection:\(page.collection.id)" && item.release.map { release in
            store.activeTrackID.flatMap { store.loadedTrack(id: $0) }?.releaseId == release.id
        } == true
        return HStack(spacing: 16) {
            ArtworkView(artworkID: item.artworkId, size: 80)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title).font(.headline)
                Text(item.artist).foregroundStyle(.secondary)
                if item.release == nil { Text("Álbum indisponível").font(.caption).foregroundStyle(.secondary) }
                else if active { Label("Reproduzindo nesta coleção", systemImage: "speaker.wave.2.fill").font(.caption).foregroundStyle(Color.accentColor) }
            }
            Spacer()
            if let release = item.release {
                Button("Reproduzir a partir deste álbum", systemImage: "play.fill") { play(.ordered, releaseID: release.id) }
                    .labelStyle(.iconOnly).disabled(state.preparingPlayback || store.isChangingTrack)
                Button("Abrir álbum", systemImage: "arrow.up.forward") {
                    openAlbum(release)
                }.labelStyle(.iconOnly).albumContextMenu(album: release)
            }
            if page.collection.definition == nil {
                Button("Mover para cima", systemImage: "chevron.up") { move(item, delta: -1) }
                    .labelStyle(.iconOnly).disabled(index == 0 || state.changing)
                    .accessibilityIdentifier("albumCollection.up.\(item.id)")
                Button("Mover para baixo", systemImage: "chevron.down") { move(item, delta: 1) }
                    .labelStyle(.iconOnly).disabled(index + 1 == page.items.count || state.changing)
                    .accessibilityIdentifier("albumCollection.down.\(item.id)")
                Button("Remover da coleção", systemImage: "minus.circle") {
                    Task { await state.change(id: page.collection.id, using: store) { try await $0.removeAlbumFromCollection(collectionId: page.collection.id, itemId: item.id) } }
                }.labelStyle(.iconOnly).disabled(state.changing).accessibilityIdentifier("albumCollection.remove.\(item.id)")
            }
        }.padding(14).background(active ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04), in: .rect(cornerRadius: 12))
            .accessibilityElement(children: .contain).accessibilityIdentifier("albumCollection.item.\(item.id)")
    }
    @Environment(\.trackMenuNavigation) private var navigation
    private func openAlbum(_ release: Release) { navigation.album(release) }
    private func move(_ item: AlbumCollectionItem, delta: Int) {
        guard let page, let index = page.items.firstIndex(where: { $0.id == item.id }) else { return }
        var ids = page.items.map(\.id)
        let destination = index + delta
        guard ids.indices.contains(destination) else { return }
        ids.swapAt(index, destination)
        Task { await state.change(id: page.collection.id, using: store) { try await $0.reorderAlbumCollection(collectionId: page.collection.id, itemIds: ids) } }
    }
}

struct AlbumCollectionsToolbarOptions: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Bindable var state: AlbumCollectionsState
    let collectionID: Int64?
    let onCreate: () -> Void
    let onEdit: (AlbumCollection) -> Void
    var body: some View {
        ToolbarOptionsButton(title: "Opções de coleções") {
            Button("Nova coleção", systemImage: "plus", action: onCreate)
            if let id = collectionID, let page = state.page, page.collection.id == id {
                Button(page.collection.definition == nil ? "Editar coleção…" : "Editar regras…") { onEdit(page.collection) }
                if page.collection.definition == nil {
                    Divider()
                    Button("Ordenar por título") { sort(artist: false) }
                    Button("Ordenar por artista") { sort(artist: true) }
                }
            } else {
                Divider()
                Picker("Ordenar coleções por", selection: $state.byCount) {
                    Text("Nome").tag(false); Text("Quantidade de álbuns").tag(true)
                }.pickerStyle(.inline)
            }
        }.accessibilityIdentifier("albumCollections.options")
    }
    private func sort(artist: Bool) {
        guard let page = state.page else { return }
        let ids = page.items.sorted {
            if artist {
                let order = $0.artist.localizedStandardCompare($1.artist)
                if order != .orderedSame { return order == .orderedAscending }
            }
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }.map(\.id)
        Task { await state.change(id: page.collection.id, using: store) { try await $0.reorderAlbumCollection(collectionId: page.collection.id, itemIds: ids) } }
    }
}

struct AlbumCollectionAlbumPicker: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(AlbumCollectionsState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let collection: AlbumCollection
    @State private var releases: [Release] = []
    @State private var selected = Set<Int64>()
    @State private var query = ""
    @State private var loading = true
    @State private var failed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Adicionar álbuns a \(collection.name)").font(.title2.bold())
            TextField("Pesquisar álbuns", text: $query).textFieldStyle(.roundedBorder).accessibilityIdentifier("albumCollection.picker.search")
            if loading { ProgressView() }
            if failed { Text("Não foi possível carregar os álbuns.").foregroundStyle(.red) }
            List(releases.filter { query.isEmpty || $0.title.localizedStandardContains(query) || $0.artist.localizedStandardContains(query) }, id: \.id) { release in
                Toggle(isOn: Binding(get: { selected.contains(release.id) }, set: { on in if on { selected.insert(release.id) } else { selected.remove(release.id) } })) {
                    Text("\(release.title) — \(release.artist)")
                }.toggleStyle(.checkbox).accessibilityIdentifier("albumCollection.pick.\(release.id)")
            }
            if let error = state.error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Adicionar \(selected.count) álbuns") {
                    let ids = releases.filter { selected.contains($0.id) }.map(\.id)
                    Task {
                        if await state.change(id: collection.id, using: store, operation: { core in
                            for id in ids { try await core.addAlbumToCollection(collectionId: collection.id, releaseId: id) }
                        }) { dismiss() }
                    }
                }.disabled(selected.isEmpty || state.changing || loading).keyboardShortcut(.defaultAction).accessibilityIdentifier("albumCollection.picker.add")
            }
        }.padding(24).frame(width: 570, height: 500).interactiveDismissDisabled(state.changing)
            .task {
                do { releases = try await store.completeCatalogReleases().filter { !$0.isHidden }; loading = false }
                catch { loading = false; failed = true }
            }
    }
}

struct AlbumCollectionAddSheet: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(AlbumCollectionsState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let release: Release
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Adicionar álbum a uma coleção").font(.title2.bold())
            Text("\(release.title) — \(release.artist)").foregroundStyle(.secondary)
            List(state.collections.filter { $0.definition == nil }, id: \.id) { collection in
                Button(collection.name) { add(to: collection) }.buttonStyle(.plain)
                    .accessibilityIdentifier("albumCollection.destination.\(collection.id)")
            }
            HStack {
                TextField("Nome da nova coleção", text: $name).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("albumCollection.quick.name")
                Button("Criar e adicionar") {
                    Task {
                        if await state.change(using: store, operation: { core in
                            let collection = try await core.saveAlbumCollection(collectionId: nil, name: name, description: "", definition: nil)
                            try await core.addAlbumToCollection(collectionId: collection.id, releaseId: release.id)
                        }) { dismiss() }
                    }
                }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("albumCollection.quick.create")
            }
            if let error = state.error { Text(error).foregroundStyle(.red) }
            HStack { Spacer(); Button("Concluir") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 520, height: 400).disabled(state.changing)
            .task { await state.load(using: store) }
    }
    private func add(to collection: AlbumCollection) {
        Task { if await state.change(using: store, operation: { try await $0.addAlbumToCollection(collectionId: collection.id, releaseId: release.id) }) { dismiss() } }
    }
}
