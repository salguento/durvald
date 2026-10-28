import SwiftUI

struct CatalogDetailsView: View {
    @Environment(DurvaldCoreStore.self) private var store
    let seed: CatalogEntry
    @State private var presentation = CatalogDetailPresentation()
    @State private var showingSources = false
    private var entry: CatalogEntry { presentation.entry ?? seed }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 24) {
                    if let bytes = presentation.blocks[.cover]?.page?.image, let image = NSImage(data: bytes) {
                        Image(nsImage: image).resizable().scaledToFit().frame(width: 180, height: 180)
                    } else {
                        Image(systemName: entry.reference.kind == .artist ? "person.crop.circle" : "music.note")
                            .font(.system(size: 56)).foregroundStyle(.secondary).frame(width: 180, height: 180)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text(entry.title).font(.largeTitle.bold())
                        if let credit = entry.artistCredit { Text(credit).font(.title3).foregroundStyle(.secondary) }
                        if let version = entry.versionLabel { Text(version).foregroundStyle(.secondary) }
                        Text(entry.reference.provider == "musicbrainz" ? "MusicBrainz" : entry.reference.provider).font(.caption).foregroundStyle(.secondary)
                        actions
                    }
                }
                if let error = presentation.actionError { Text(error).foregroundStyle(.secondary) }
                if entry.reference.provider != "musicbrainz" {
                    Text("Você pode salvar este item. Detalhes adicionais ainda não estão disponíveis para este serviço.").foregroundStyle(.secondary)
                }
                ForEach(entry.detailSections, id: \.self) { section in block(section) }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(entry.title)
        .accessibilityIdentifier("catalog.details")
        .task(id: seed.entryKey) {
            guard let loader = store.makeCatalogDetailLoader() else { return }
            await presentation.run(entry: seed, language: Locale.current.language.languageCode?.identifier ?? "und", loader: loader)
        }
        .sheet(isPresented: $showingSources) { SourceManagementView(entry: entry) }
        .onDisappear { presentation.cancel() }
    }
    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(presentation.selection == nil ? "Salvar" : "Salvo") { Task { await presentation.save() } }
                    .disabled(presentation.saving || presentation.selection != nil)
                    .accessibilityIdentifier("catalog.details.save")
                if entry.reference.kind == .artist {
                    Button(presentation.followed ? "Deixar de seguir" : "Seguir") { Task { await presentation.toggleFollow() } }.disabled(presentation.saving)
                }
                if entry.reference.provider == "musicbrainz", entry.reference.kind == .releaseGroup {
                    Button(presentation.inListenList ? "Em Ouvir depois" : "Ouvir depois") { Task { await presentation.listen() } }
                        .disabled(presentation.saving || presentation.inListenList || presentation.primaryArtist == nil)
                }
                if presentation.saving { ProgressView().controlSize(.small) }
            }
            HStack {
                Button("Onde ouvir / origens") { showingSources = true }.disabled(!entry.supportsSources)
                Button("Onde baixar") {}.disabled(true)
            }.help(entry.supportsSources ? "Buscar links e gerenciar origens para esta faixa. Downloads serão implementados em outra etapa." : "Selecione uma faixa individual para buscar origens.")
            if let value = entry.canonicalUrl, let url = URL(string: value) { Link("Abrir no serviço", destination: url) }
        }
    }
    @ViewBuilder
    private func block(_ section: CatalogDetailSection) -> some View {
        let state = presentation.blocks[section] ?? CatalogDetailBlock()
        if !(section == .basic && state.page?.items.count == 1 && !state.loading && state.error == nil) && !(section == .cover && state.page?.image == nil && !state.loading && state.error == nil) {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(section.title).font(.title2.bold())
                if state.loading { ProgressView().controlSize(.small) }
            }
            if let error = state.error {
                Text(error).foregroundStyle(.secondary)
                Button("Tentar novamente") { Task { await presentation.retry(section) } }.disabled(state.loading)
            }
            if let page = state.page {
                if let profile = page.profile {
                    if let biography = profile.biography { Text(biography).textSelection(.enabled) }
                    if let place = profile.birthPlace { Text("Nascimento: \(place)") }
                    if let place = profile.formationPlace { Text("Formação: \(place)") }
                    if let place = profile.originPlace { Text("Origem: \(place)") }
                    if profile.attribution.sourceUrl != page.attribution?.sourceUrl,
                       let url = URL(string: profile.attribution.sourceUrl) { Link("Fonte dos dados do perfil", destination: url).font(.caption) }
                }
                ForEach(section == .basic ? Array(page.items.dropFirst()) : page.items, id: \.entryKey) { related in
                    NavigationLink { CatalogDetailsView(seed: related) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(related.title)
                            if let version = related.versionLabel { Text(version).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .disabled(related.reference.kind == .releaseTrack)
                }
                if section != .basic, section != .cover, page.items.isEmpty, page.profile?.biography == nil, !state.loading {
                    Text("Nenhuma informação disponível para esta parte.").foregroundStyle(.secondary)
                }
                if let attribution = page.attribution, let url = URL(string: attribution.sourceUrl) {
                    HStack {
                        Link("Fonte", destination: url)
                        if let author = attribution.author { Text(author).foregroundStyle(.secondary) }
                        if let license = attribution.licenseName {
                            if let link = attribution.licenseUrl, let url = URL(string: link) { Link(license, destination: url) }
                            else { Text(license).foregroundStyle(.secondary) }
                        }
                    }.font(.caption)
                }
                if page.nextCursor != nil { Button("Carregar mais") { Task { await presentation.more(section) } }.disabled(state.loading) }
            }
        }
        }
    }
}
private extension CatalogDetailSection {
    var title: String { switch self {
    case .basic: "Identidade"
    case .cover: "Imagem"
    case .profile: "Perfil"
    case .editions: "Edições"
    case .tracklist: "Faixas da edição"
    case .discography: "Discografia"
    case .similar: "Artistas similares"
    } }
}
struct CatalogDetailDestination: Identifiable { let entry: CatalogEntry; var id: String { entry.entryKey } }

struct CatalogSavedView: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var selections: [CatalogSelection] = []
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(.secondary) }
                if selections.isEmpty, error == nil { Text("Os itens que você salvar aparecerão aqui.").foregroundStyle(.secondary) }
                ForEach(selections, id: \.entry.entryKey) { saved in
                    NavigationLink { CatalogDetailsView(seed: saved.entry) } label: {
                        VStack(alignment: .leading) {
                            Text(saved.entry.title)
                            Text(saved.entry.reference.provider).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Itens salvos")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() } } }
            .task {
                guard let core = store.core else { return }
                do { selections = try await core.catalogSelections() }
                catch { self.error = "Não foi possível carregar os itens salvos." }
            }
        }
    }
}
