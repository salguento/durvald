import SwiftUI

struct ListenListSaveButton: View {
    @Environment(DurvaldCoreStore.self) private var store
    var releaseID: Int64?
    var externalRelease: ExternalReleaseGroup? = nil
    var artist: Artist? = nil
    private var entry: ListenListEntry? {
        store.listenListEntry(releaseID: releaseID, externalID: externalRelease?.musicbrainzId)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                Task {
                    if let entry { await store.removeFromListenList(entry) }
                    else if let releaseID { await store.saveToListenList(releaseID: releaseID) }
                    else if let externalRelease, let artist { await store.saveToListenList(release: externalRelease, artist: artist) }
                }
            } label: {
                Image(systemName: "bookmark.fill")
                    .foregroundStyle(entry != nil ? Color.accentColor : .white.opacity(0.45))
            }
            .buttonStyle(CollectionHeaderActionButtonStyle(size: 40))
            .disabled(store.core == nil || store.isChangingListenList)
            .help(entry == nil ? "Adicionar a Ouvir depois" : "Remover de Ouvir depois")
            .accessibilityLabel(entry == nil ? "Adicionar a Ouvir depois" : "Remover de Ouvir depois")
            .accessibilityValue(entry == nil ? "Fora de Ouvir depois" : "Em Ouvir depois")
            .accessibilityAddTraits(entry == nil ? [] : .isSelected)
            .accessibilityIdentifier("listenList.save")
            if let error = store.listenListError { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .task(id: store.listenListRequest) { await store.refreshListenList() }
    }
}

enum ListenListStatus: String, CaseIterable, Identifiable {
    case pending, heard, all
    var id: Self { self }
    var title: String {
        switch self { case .pending: "Ouvir depois"; case .heard: "Ouvidos"; case .all: "Todos" }
    }
}
enum ListenListOrder: String, CaseIterable, Identifiable {
    case newest, oldest, title, artist
    var id: Self { self }
    var title: String {
        switch self { case .newest: "Adicionados recentemente"; case .oldest: "Adicionados há mais tempo"; case .title: "Título"; case .artist: "Artista" }
    }
}

enum ListenListPresentation {
    static func items(_ entries: [ListenListEntry], status: ListenListStatus, order: ListenListOrder, query: String) -> [ListenListEntry] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter {
            (status == .all || ($0.heardAt == nil) == (status == .pending))
                && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.artist.localizedCaseInsensitiveContains(query))
        }.sorted { a, b in
            switch order {
            case .newest: return a.addedAt == b.addedAt ? a.id > b.id : a.addedAt > b.addedAt
            case .oldest: return a.addedAt == b.addedAt ? a.id < b.id : a.addedAt < b.addedAt
            case .title:
                let comparison = a.title.localizedStandardCompare(b.title)
                return comparison == .orderedSame ? a.id < b.id : comparison == .orderedAscending
            case .artist:
                let comparison = a.artist.localizedStandardCompare(b.artist)
                return comparison == .orderedSame ? a.id < b.id : comparison == .orderedAscending
            }
        }
    }
}

struct ListenListView: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Binding var searchText: String
    @State private var status: ListenListStatus = .pending
    @State private var order: ListenListOrder = .newest

    private var items: [ListenListEntry] {
        ListenListPresentation.items(store.listenListEntries, status: status, order: order, query: searchText)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Picker("Mostrar", selection: $status) { ForEach(ListenListStatus.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).frame(maxWidth: 320).accessibilityIdentifier("listenList.status")
                Spacer()
                Picker("Ordenar", selection: $order) { ForEach(ListenListOrder.allCases) { Text($0.title).tag($0) } }
                    .fixedSize().accessibilityIdentifier("listenList.order")
            }
            Text("Salve lançamentos para ouvir depois. Marcar como ouvido mantém o item na lista.")
                .font(.callout).foregroundStyle(.secondary)
            if let error = store.listenListError {
                HStack {
                    Text(error).foregroundStyle(.red)
                    Button("Tentar novamente") { Task { await store.refreshListenList() } }
                }
            }
            if store.isLoadingListenList && store.listenListEntries.isEmpty {
                ProgressView("Carregando Ouvir depois…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                ContentUnavailableView(searchText.isEmpty ? (status == .heard ? "Nenhum lançamento marcado como ouvido" : "Sua lista está vazia") : "Nenhum resultado",
                    systemImage: "bookmark", description: Text("Use “Adicionar a Ouvir depois” na página ou no menu de um álbum ou lançamento."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) { ForEach(items, id: \.id) { entry in ListenListRow(entry: entry) } }
                }
            }
        }
        .padding(24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("listenList.page")
        .task(id: store.listenListRequest) { await store.refreshListenList() }
    }
}

private struct ListenListRow: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(\.trackMenuNavigation) private var navigation
    let entry: ListenListEntry
    private var canOpen: Bool { entry.localReleaseId != nil || entry.externalRelease != nil && entry.externalArtist != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: open) {
                HStack(spacing: 16) {
                    ArtworkView(artworkID: entry.artworkId, size: 80)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.title).font(.headline).foregroundStyle(.primary)
                        Text(entry.artist).foregroundStyle(.secondary)
                        Text(entry.heardAt == nil ? "Ouvir depois" : "Ouvido").font(.caption).foregroundStyle(.secondary)
                        if entry.localReleaseId == nil { Text(entry.externalRelease == nil ? "Arquivos indisponíveis" : "Somente on-line").font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(!canOpen).accessibilityIdentifier("listenList.open.\(entry.id)")
            HStack {
            if let releaseID = entry.localReleaseId {
                Button("Reproduzir", systemImage: "play.fill") {
                    Task { await PlaybackCollection.release(releaseID).perform(.play, using: store) }
                }.labelStyle(.iconOnly).disabled(store.isChangingTrack)
            }
            Button(entry.heardAt == nil ? "Marcar como ouvido" : "Marcar como não ouvido",
                   systemImage: entry.heardAt == nil ? "checkmark.circle" : "arrow.uturn.backward") {
                Task { await store.markListenListEntry(entry, heard: entry.heardAt == nil) }
            }
            .disabled(store.isChangingListenList).accessibilityIdentifier("listenList.heard.\(entry.id)")
            Spacer()
            Button("Remover de Ouvir depois", systemImage: "bookmark.slash", role: .destructive) {
                Task { await store.removeFromListenList(entry) }
            }.labelStyle(.iconOnly).disabled(store.isChangingListenList).accessibilityIdentifier("listenList.remove.\(entry.id)")
            }
        }
        .padding(12).background(.quaternary, in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .contain).accessibilityIdentifier("listenList.entry.\(entry.id)")
    }
    private func open() {
        Task {
            if let id = entry.localReleaseId {
                if let release = store.loadedRelease(id: id) { navigation.album(release) }
                else if let release = try? await store.core?.release(releaseId: id) { navigation.album(release) }
            } else if let release = entry.externalRelease, let artist = entry.externalArtist { navigation.externalAlbum(release, artist) }
        }
    }
}
