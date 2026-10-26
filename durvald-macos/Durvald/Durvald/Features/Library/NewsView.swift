import SwiftUI

struct NewsToolbarOptions: View {
    @Bindable var state: ArtistNewsRepository
    var body: some View {
        ToolbarOptionsButton(title: "Opções de Novidades") {
            Toggle("Apenas não vistas", isOn: $state.unseenOnly)
            Picker("Mostrar", selection: $state.kind) {
                Text("Todas as novidades").tag(ArtistNewsKind?.none)
                Text("Lançamentos recentes").tag(ArtistNewsKind?.some(.recent))
                Text("Próximos lançamentos").tag(ArtistNewsKind?.some(.upcoming))
                Text("Data parcial").tag(ArtistNewsKind?.some(.partialDate))
            }
            Divider()
            Picker("Ordenar por", selection: $state.sortBy) {
                Text("Data de lançamento").tag("date")
                Text("Artista").tag("artist")
            }
            Toggle("Ordem decrescente", isOn: $state.descending)
        }.accessibilityIdentifier("news.options")
    }
}

struct NewsView: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(\.trackMenuNavigation) private var navigation
    @Environment(\.openSettings) private var openSettings
    @AppStorage("followedArtistIDs") private var legacyFollowedArtistIDs = ""
    var onSelectArtists: () -> Void
    @State private var showingArtists = false
    private var state: ArtistNewsRepository { store.artistNews }
    private var canRefresh: Bool { store.enrichmentSettings?.enabled == true && store.enrichmentSettings?.offline == false }
    private var request: String { "\(store.core.map(ObjectIdentifier.init).debugDescription)|\(state.request)|\(state.initialized)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Lançamentos dos artistas que você segue.").font(.headline)
                    Text("MusicBrainz · Últimos 90 dias e próximos 12 meses. A cobertura e as datas dependem da fonte.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if state.updating {
                    Button("Cancelar", systemImage: "xmark") { state.cancelRefresh() }
                } else {
                    Button("Atualizar", systemImage: "arrow.clockwise") {
                        if let core = store.core { state.refresh(core: core, force: true) }
                    }.disabled(!canRefresh || state.followed.isEmpty || !state.initialized)
                        .accessibilityIdentifier("news.refresh")
                }
            }
            if !canRefresh {
                HStack {
                    Text(store.enrichmentSettings?.offline == true ? "Modo offline: mostrando novidades salvas." : "Ative os dados on-line nos Ajustes para buscar novidades.")
                    Spacer()
                    Button("Ajustes") { openSettings() }
                }.font(.callout).foregroundStyle(.secondary)
            }
            if let artist = state.currentArtist {
                HStack { ProgressView().controlSize(.small); Text("Atualizando \(artist)…").font(.callout) }
            }
            if let error = state.error {
                HStack {
                    Text(error).foregroundStyle(.red)
                    Button("Tentar novamente") { Task { if let core = store.core {
                        await state.initialize(core: core, legacyIDs: legacyFollowedArtistIDs)
                        await state.load(core: core)
                    } } }
                }.font(.callout)
            }
            DisclosureGroup("Artistas seguidos (\(state.followed.count))", isExpanded: $showingArtists) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(state.followed, id: \.artist.id) { artist in
                            HStack {
                                Button(artist.artist.name) { navigation.artist(artist.artist) }.buttonStyle(.plain)
                                Text(status(artist)).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Deixar de seguir", systemImage: "person.badge.minus") {
                                    Task { if let core = store.core { await state.setFollow(artist.artist.id, followed: false, core: core) } }
                                }.disabled(state.pending.contains(artist.artist.id))
                            }
                        }
                    }.padding(.top, 8)
                }.frame(maxHeight: 180)
            }.accessibilityIdentifier("news.followed")
            if state.loading && state.items.isEmpty {
                ProgressView("Carregando novidades…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.items.isEmpty {
                ContentUnavailableView {
                    Label(state.followed.isEmpty ? "Siga artistas para acompanhar novidades" : "Nenhuma novidade encontrada", systemImage: "bell")
                } description: {
                    Text(state.followed.isEmpty ? "Use o botão Seguir na página de um artista." : "Atualize os artistas seguidos ou ajuste a pesquisa e os filtros. Lançamentos sem data e catálogos incompletos podem não aparecer.")
                } actions: {
                    if state.followed.isEmpty { Button("Ver artistas", action: onSelectArtists) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(state.items, id: \.id) { item in NewsRow(item: item) }
                        if state.nextOffset != nil {
                            Button("Carregar mais") { Task { if let core = store.core { await state.load(core: core, more: true) } } }
                                .disabled(state.loading)
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("news.page")
        .task(id: request) {
            guard let core = store.core else { return }
            if !state.initialized { await state.initialize(core: core, legacyIDs: legacyFollowedArtistIDs) }
            await state.load(core: core)
        }
        .task(id: "\(state.initialized)|\(canRefresh)") {
            if canRefresh, let core = store.core { state.refresh(core: core) }
            else { state.cancelRefresh() }
        }
        .onDisappear { state.cancelRefresh() }
    }

    private func status(_ followed: FollowedArtist) -> String {
        if followed.identity.conflictingTags { return "Revise a identificação do artista" }
        if followed.identity.status != .resolved { return "Identifique no MusicBrainz para buscar novidades" }
        let message: String
        switch followed.status {
        case .some(.notFound): message = "Artista não encontrado na fonte"
        case .some(.rateLimited): message = "Aguardando limite da fonte"
        case .some(.unavailable), .some(.partial): message = "Atualização incompleta"
        case .some(.offline): message = "Offline"
        case .some(.disabled): message = "Dados on-line desativados"
        default: message = followed.catalogComplete ? "Catálogo consultado" : "Catálogo incompleto"
        }
        if let updated = followed.lastSuccessAt {
            return "\(message) · \(Date(timeIntervalSince1970: TimeInterval(updated)).formatted(date: .abbreviated, time: .shortened))"
        }
        return message
    }
}

private struct NewsRow: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(\.trackMenuNavigation) private var navigation
    let item: ArtistNewsItem
    private var date: String {
        guard let date = item.release.firstReleaseDate else { return "Data não informada" }
        if let month = date.month {
            if let day = date.day { return String(format: "%02d/%02d/%04d", day, month, date.year) }
            return String(format: "%02d/%04d", month, date.year)
        }
        return String(date.year)
    }
    var body: some View {
        HStack(spacing: 16) {
            Button(action: open) {
                HStack(spacing: 16) {
                    ArtworkView(artworkID: item.release.artwork?.image.managedPath, size: 88)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(item.release.title).font(.headline)
                            if !item.seen { Circle().fill(Color.accentColor).frame(width: 6, height: 6).accessibilityLabel("Não vista") }
                        }
                        Text(item.artist.name).foregroundStyle(.secondary)
                        Text("\(date) · \(kindTitle)").font(.callout).foregroundStyle(.secondary)
                        if let type = item.release.primaryType { Text(type).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("news.open.\(item.id)")
            VStack(alignment: .trailing, spacing: 8) {
                ListenListSaveButton(releaseID: item.release.localReleaseId, externalRelease: item.release, artist: item.artist)
                Button(item.seen ? "Marcar como não vista" : "Marcar como vista", systemImage: item.seen ? "envelope.badge" : "checkmark.circle") {
                    Task { if let core = store.core { await store.artistNews.setSeen(item, seen: !item.seen, core: core) } }
                }.labelStyle(.iconOnly).accessibilityIdentifier("news.seen.\(item.id)")
                if let url = URL(string: "https://musicbrainz.org/release-group/\(item.id)") {
                    Link("MusicBrainz", destination: url).font(.caption)
                }
                Text("Consultado \(Date(timeIntervalSince1970: TimeInterval(item.sourceUpdatedAt)).formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(14).background(.quaternary, in: .rect(cornerRadius: 10))
            .accessibilityElement(children: .contain).accessibilityIdentifier("news.item.\(item.id)")
    }
    private var kindTitle: String {
        switch item.kind { case .recent: "Lançamento recente"; case .upcoming: "Próximo lançamento"; case .partialDate: "Data parcial" }
    }
    private func open() {
        Task {
            guard let core = store.core else { return }
            await store.artistNews.setSeen(item, seen: true, core: core)
            if let id = item.release.localReleaseId, let release = try? await core.release(releaseId: id) {
                navigation.album(release)
            } else { navigation.externalAlbum(item.release, item.artist) }
        }
    }
}
