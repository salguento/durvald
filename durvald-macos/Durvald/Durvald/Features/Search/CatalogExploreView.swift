import SwiftUI

struct CatalogExploreView: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(\.trackMenuNavigation) private var navigation
    let query: String
    let filter: CatalogFilter
    let submissionRevision: UInt64
    @State private var presentation = CatalogSearchPresentation()
    @State private var providerRevision: UInt64 = 0
    @State private var configurationError: String?
    @State private var showSavedCatalog = false
    @State private var showSoundCloudLink = false
    @State private var showSoulseek = false
    @State private var showServiceImport = false
    @State private var detailDestination: CatalogDetailDestination?

    private var request: SearchRequest {
        SearchRequest(query: query, coreID: store.core.map(ObjectIdentifier.init),
                      sourceRevision: submissionRevision &+ providerRevision, scope: "catalog.\(filter)")
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                HStack { Button("Ouvir link SoundCloud…") { showSoundCloudLink = true }; Spacer(); Button("Itens salvos") { showSavedCatalog = true } }
                HStack { Button("Buscar opções de download…") { showSoulseek = true }; Button("Importar link ou coleção…") { showServiceImport = true } }
                providerSection(.library, title: "Sua biblioteca")
                providerSection(.musicBrainz, title: "MusicBrainz")
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("catalog.explore")
        .task(id: request) {
            guard let loader = store.makeCatalogSearchLoader() else { return }
            await presentation.run(query: query, filter: filter,
                                   language: Locale.current.language.languageCode?.identifier ?? "und",
                                   loader: loader)
        }
        .onDisappear { presentation.cancel() }
        .sheet(isPresented: $showServiceImport) { ServiceCollectionsView(isSheet: true) }
        .sheet(isPresented: $showSoulseek) { SoulseekSearchView(initialQuery: query) }
        .sheet(isPresented: $showSoundCloudLink) { SoundCloudLinkView() }
        .sheet(isPresented: $showSavedCatalog) { CatalogSavedView().frame(width: 760, height: 560) }
        .sheet(item: $detailDestination) { destination in
            NavigationStack { CatalogDetailsView(seed: destination.entry)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fechar") { detailDestination = nil } } }
            }.frame(width: 760, height: 560)
        }
    }

    private func providerSection(_ provider: CatalogProvider, title: String) -> some View {
        let page = presentation.page(for: provider)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                if page.isLoading { ProgressView().controlSize(.small) }
                if page.fromCache { Text("Em cache").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if provider == .musicBrainz, page.failure != .disabled {
                    Button("Desativar") { setProviderEnabled(false) }.buttonStyle(.borderless)
                }
            }
            if let message = failureMessage(page) {
                Text(message).foregroundStyle(.secondary)
                if page.failure == .disabled {
                    Button("Ativar MusicBrainz") { setProviderEnabled(true) }
                } else {
                    Button("Tentar novamente") { Task { await presentation.retry(provider) } }
                        .disabled(page.isLoading)
                }
            }
            if provider == .musicBrainz, let configurationError {
                Text(configurationError).foregroundStyle(.secondary)
            }
            ForEach(page.items, id: \.catalogKey) { item in
                result(item)
            }
            if page.items.isEmpty, !page.isLoading, page.failure == nil, page.errorMessage == nil {
                Text("Nenhum resultado para esta pesquisa.").foregroundStyle(.secondary)
            }
            if page.nextCursor != nil {
                Button("Carregar mais") { Task { await presentation.loadMore(provider) } }
                    .disabled(page.isLoading)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(provider == .library ? "catalog.provider.library" : "catalog.provider.musicbrainz")
    }

    private func result(_ item: CatalogItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.kind == .artist ? "person.crop.circle" : "music.note")
                .frame(width: 30)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.headline)
                if let credit = item.artistCredit, !credit.isEmpty { Text(credit).foregroundStyle(.secondary) }
                if let version = item.versionLabel, !version.isEmpty { Text(version).font(.caption).foregroundStyle(.secondary) }
                Text(item.provider == .library ? "\(item.kindLabel) · Na biblioteca" : "\(item.kindLabel) · MusicBrainz")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let id = item.localId {
                Button("Abrir") { openLocal(item, id: id) }.buttonStyle(.borderless)
            } else {
                Button("Ver detalhes") { detailDestination = CatalogDetailDestination(entry: item.detailEntry) }.buttonStyle(.borderless)
                if let value = item.canonicalUrl, let url = URL(string: value) { Link("Abrir no MusicBrainz", destination: url).buttonStyle(.borderless) }
            }
        }
        .padding(.vertical, 6)
        .accessibilityIdentifier("catalog.result.\(item.catalogKey)")
    }

    private func openLocal(_ item: CatalogItem, id: Int64) {
        guard let core = store.core else { return }
        switch item.kind {
        case .artist: navigation.artist(Artist(id: id, name: item.title))
        case .releaseGroup, .releaseEdition:
            Task { if let release = try? await core.release(releaseId: id) { navigation.album(release) } }
        case .playlist:
            Task { if let playlist = try? await core.playlist(playlistId: id) { navigation.playlist(playlist) } }
        case .recording, .track:
            Task { await store.play(trackID: id, sourceContext: PlaybackSourceContext.search(query)) }
        default: break
        }
    }

    private func setProviderEnabled(_ enabled: Bool) {
        guard let core = store.core else { return }
        Task {
            do {
                _ = try await core.setCatalogProviderEnabled(enabled: enabled)
                configurationError = nil
                providerRevision &+= 1
            } catch {
                configurationError = "Não foi possível alterar o MusicBrainz. Tente novamente."
            }
        }
    }

    private func failureMessage(_ page: CatalogProviderPage) -> String? {
        if let error = page.errorMessage { return error }
        switch page.failure {
        case .disabled: return "O MusicBrainz está desativado. A busca local continua disponível."
        case .invalidQuery: return "Verifique a pesquisa ou o endereço do MusicBrainz."
        case .rateLimited:
            return page.retryAfterSeconds.map { "O serviço está ocupado. Tente novamente em \($0) segundos." }
                ?? "O serviço está ocupado. Tente novamente mais tarde."
        case .timedOut: return "A consulta demorou mais que o esperado. Tente novamente."
        case .unavailable: return "O provedor está indisponível. Os demais resultados continuam disponíveis."
        case .cancelled, nil: return nil
        }
    }
}
