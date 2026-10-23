import Observation
import SwiftUI

extension ClassificationKind {
    var title: String { self == .genre ? "Gêneros" : "Estilos" }
    var singular: String { self == .genre ? "Gênero" : "Estilo" }
    var key: String { self == .genre ? "genre" : "style" }
}

enum ClassificationTab: String, CaseIterable { case albums = "Álbuns", artists = "Artistas", tracks = "Músicas" }
enum ClassificationFilter: String, CaseIterable { case all = "Todos", genres = "Gêneros", styles = "Estilos" }

@MainActor @Observable
final class ClassificationBrowserState {
    var query = ""
    var tab = ClassificationTab.albums
    var filter = ClassificationFilter.all
    var byCount = false
    var terms: [ClassificationTerm] = []
    var page: ClassificationPage?
    var releases: [Release] = []
    var artists: [Artist] = []
    var tracks: [Track] = []
    var offset: UInt64 = 0
    var error: String?
    var loading = false
    var hasLoaded = false
    var generation: UInt64 = 0
    var loadedRequest: String?

    var visibleTerms: [ClassificationTerm] {
        terms.filter {
            (filter == .all || (filter == .genres ? $0.kind == .genre : $0.kind == .style))
                && (query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.name.localizedStandardContains(query.trimmingCharacters(in: .whitespacesAndNewlines)))
        }.sorted {
            if byCount && $0.releaseCount != $1.releaseCount { return $0.releaseCount > $1.releaseCount }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    func load(core: DurvaldCore, kind: ClassificationKind?, id: Int64?, more: Bool = false) async {
        generation &+= 1
        let request = generation
        loading = true
        defer { if generation == request { loading = false } }
        do {
            if let kind, let id {
                let next = more ? offset + 100 : 0
                let result = try await core.classificationPage(kind: kind, id: id, query: query, offset: next, pageSize: 100)
                guard !Task.isCancelled, generation == request else { return }
                page = result
                releases = more ? releases + result.releases : result.releases
                artists = more ? artists + result.artists : result.artists
                tracks = more ? tracks + result.tracks : result.tracks
                offset = next
            } else {
                let result = try await core.classificationTerms()
                guard !Task.isCancelled, generation == request else { return }
                terms = result
            }
            hasLoaded = true
            error = nil
        } catch {
            guard !Task.isCancelled, generation == request else { return }
            self.error = "Não foi possível carregar gêneros e estilos. Tente novamente."
        }
    }
}

struct ClassificationBrowser: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(\.trackMenuNavigation) private var navigation
    let kind: ClassificationKind?
    let termID: Int64?
    @Bindable var state: ClassificationBrowserState
    @State private var isEditingRelations = false
    @State private var isPreparingPlayback = false
    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 24)]
    private var request: String { "\(kind?.key ?? "all"):\(termID ?? -1):\(store.libraryCatalogRevision):\(store.classificationRevision):\(kind == nil ? "" : state.query)" }
    private var canLoadMore: Bool {
        guard let page = state.page else { return false }
        switch state.tab {
        case .albums: return state.releases.count < page.totalReleases
        case .artists: return state.artists.count < page.totalArtists
        case .tracks: return state.tracks.count < page.totalTracks
        }
    }
    private var context: String { "\(kind?.key ?? "genre"):\(termID ?? 0):\(state.query)" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let kind, let page = state.page {
                    detailHeader(kind, page)
                } else if kind == nil {
                    Text("Gêneros e estilos").font(.largeTitle.bold())
                    Text("Explore a classificação disponível na sua biblioteca.").foregroundStyle(.secondary)
                }
                HStack {
                    TextField("Pesquisar \(kind == nil ? "gêneros e estilos" : "neste conteúdo")", text: $state.query)
                        .textFieldStyle(.roundedBorder).accessibilityIdentifier("classification.search")
                    if kind == nil {
                        Picker("Ordenar", selection: $state.byCount) {
                            Text("Nome").tag(false)
                            Text("Álbuns na biblioteca").tag(true)
                        }.frame(maxWidth: 220).accessibilityIdentifier("classification.order")
                    }
                }
                if let error = state.error {
                    HStack { Text(error).foregroundStyle(.red); Button("Tentar novamente") { reload() } }
                }
                if state.loading && !state.hasLoaded { ProgressView("Carregando…") }
                if kind == nil { overview }
                else if let page = state.page { detailContent(page) }
                if canLoadMore {
                    Button("Carregar mais") { if let core = store.core { Task { await state.load(core: core, kind: kind, id: termID, more: true) } } }
                        .disabled(state.loading).accessibilityIdentifier("classification.more")
                }
            }
            .padding(24).frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .preservesLibraryScrollPosition(isContentReady: state.hasLoaded)
        .accessibilityElement(children: .contain).accessibilityIdentifier("classification.page")
        .task(id: request) {
            guard state.loadedRequest != request else { return }
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard let core = store.core else { return }
            await state.load(core: core, kind: kind, id: termID)
            if !Task.isCancelled && state.error == nil { state.loadedRequest = request }
        }
        .sheet(isPresented: $isEditingRelations) {
            if let term = state.page?.term { StyleGenreEditor(style: term) }
        }
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 24) {
            Picker("Classificação", selection: $state.filter) {
                ForEach(ClassificationFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).frame(maxWidth: 360).accessibilityIdentifier("classification.filter")
            Button("Sem gênero", systemImage: "questionmark.folder") { navigation.classification(.genre, 0) }
                .accessibilityIdentifier("classification.unclassified")
            if state.hasLoaded && state.visibleTerms.isEmpty {
                ContentUnavailableView("Nenhuma classificação encontrada", systemImage: "square.grid.2x2",
                    description: Text("Os gêneros dos arquivos e metadados locais aparecem aqui. Você também pode editar gêneros e estilos na página de um álbum."))
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                ForEach(state.visibleTerms, id: \.selfIdentity) { term in
                    Button { navigation.classification(term.kind, term.id) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            ArtworkView(artworkID: term.artworkId, size: 112)
                            Text(term.name).font(.title3.bold()).foregroundStyle(.primary)
                            Text(term.kind.singular).font(.caption).foregroundStyle(Color.accentColor)
                            Text(term.albumTrackSummary).font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                            .background(.quaternary, in: .rect(cornerRadius: 12)).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("classification.term.\(term.kind.key).\(term.id)")
                }
            }
        }
    }
    private func detailHeader(_ kind: ClassificationKind, _ page: ClassificationPage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(kind.singular).font(.subheadline).foregroundStyle(.secondary)
            Text(page.term.name).font(.largeTitle.bold()).accessibilityIdentifier("classification.title")
            Text(page.term.contentSummary)
                .foregroundStyle(.secondary).accessibilityIdentifier("classification.counts")
            if let description = page.term.description, !description.isEmpty { Text(description) }
            Text("Álbuns podem aparecer por conter faixas desta classificação. Artistas são agrupados pelo conteúdo da biblioteca.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Reproduzir", systemImage: "play.fill") { play() }.accessibilityIdentifier("classification.play").disabled(page.totalTracks == 0)
                Button("Aleatório", systemImage: "shuffle") { play(shuffle: true) }.accessibilityIdentifier("classification.shuffle").disabled(page.totalTracks == 0)
                if kind == .style && page.term.id != 0 {
                    Button("Relacionar gêneros", systemImage: "link") { isEditingRelations = true }
                        .accessibilityIdentifier("classification.relations")
                }
            }.disabled(isPreparingPlayback || store.isChangingTrack || state.loading)
            if !page.relatedTerms.isEmpty {
                Text(kind == .genre ? "Estilos relacionados" : "Gêneros relacionados").font(.headline)
                ScrollView(.horizontal) {
                    HStack { ForEach(page.relatedTerms, id: \.selfIdentity) { term in
                        Button(term.name) { navigation.classification(term.kind, term.id) }
                            .accessibilityIdentifier("classification.related.\(term.kind.key).\(term.id)")
                    } }
                }
            }
        }
    }
    private func detailContent(_ page: ClassificationPage) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Picker("Conteúdo", selection: $state.tab) {
                ForEach(ClassificationTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }.pickerStyle(.segmented).frame(maxWidth: 360).accessibilityIdentifier("classification.tabs")
            switch state.tab {
            case .albums:
                if !page.wellRated.isEmpty && state.query.isEmpty {
                    Text("Bem avaliados na sua biblioteca").font(.title2.bold())
                    Text("Suas avaliações de álbum a partir de 4 estrelas.").font(.caption).foregroundStyle(.secondary)
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 24) {
                            ForEach(page.wellRated, id: \.id) { AlbumCard(release: $0, onSelectAlbum: navigation.album, artworkSize: 160) }
                        }
                    }.accessibilityIdentifier("classification.wellRated")
                }
                Text("Álbuns (\(page.totalReleases))").font(.title2.bold())
                if state.releases.isEmpty { empty }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                    ForEach(state.releases, id: \.id) { release in
                        VStack(alignment: .leading, spacing: 6) {
                            AlbumCard(release: release, onSelectAlbum: navigation.album, artworkSize: 160)
                            if page.containsTracksReleaseIds.contains(release.id) { Text("Contém faixas").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            case .artists:
                Text("Artistas (\(page.totalArtists))").font(.title2.bold())
                if state.artists.isEmpty { empty }
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(state.artists, id: \.id) { artist in
                        Button { navigation.artist(artist) } label: { Label(artist.name, systemImage: "music.mic") }
                            .buttonStyle(.plain).accessibilityIdentifier("classification.artist.\(artist.id)")
                    }
                }
            case .tracks:
                Text("Músicas (\(page.totalTracks))").font(.title2.bold())
                if state.tracks.isEmpty { empty }
                LazyVStack(spacing: 8) {
                    ForEach(state.tracks, id: \.id) { track in
                        CollectionTrackRow(track: track, number: String(track.trackNumber),
                            activeOverride: store.activeSourceContext == context && store.activeTrackID == track.id,
                            onPlay: { play(startingAt: track.id) })
                    }
                }
            }
        }
    }
    private var empty: some View { Text("Nenhum resultado nesta seleção.").foregroundStyle(.secondary).padding(.vertical, 24) }
    private func reload() { if let core = store.core { Task { await state.load(core: core, kind: kind, id: termID) } } }
    private func play(shuffle: Bool = false, startingAt: Int64? = nil) {
        guard let core = store.core, let kind, let termID, !isPreparingPlayback else { return }
        isPreparingPlayback = true
        let query = state.query
        let sourceContext = context
        Task {
            defer { isPreparingPlayback = false }
            do {
                let tracks = try await core.classificationTracks(kind: kind, id: termID, query: query)
                guard !Task.isCancelled, store.core === core else { return }
                if let startingAt, !tracks.contains(where: { $0.id == startingAt }) { return }
                await store.playTracks(tracks, startingAt: startingAt, shuffleEnabled: shuffle, sourceContext: sourceContext)
            } catch { state.error = "Não foi possível preparar a reprodução. Tente novamente." }
        }
    }
}

extension ClassificationTerm {
    var selfIdentity: String { "\(kind.key):\(id)" }
    private func count(_ value: UInt64, _ singular: String, _ plural: String) -> String {
        "\(value) \(value == 1 ? singular : plural)"
    }
    var albumTrackSummary: String {
        "\(count(releaseCount, "álbum", "álbuns")) · \(count(trackCount, "música", "músicas"))"
    }
    var contentSummary: String {
        "\(count(releaseCount, "álbum", "álbuns")) · \(count(artistCount, "artista", "artistas")) · \(count(trackCount, "música", "músicas"))"
    }
}
