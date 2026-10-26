import SwiftUI

struct HomeView: View {
    @Environment(DurvaldCoreStore.self) private var store

    @Environment(\.trackMenuNavigation) private var navigation

    let onNavigate: (LibraryDestination) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 12)
    ]
    private var recommendationSignals: String {
        "\(store.libraryCatalogRevision):\(store.metadataRevision):\(store.releasesRevision):\(store.tracksRevision):\(store.classificationRevision):\(store.personalTagsRevision)"
    }
    private var homeRequest: String {
        "\(store.core.map(ObjectIdentifier.init).map(String.init(describing:)) ?? "none"):\(recommendationSignals)"
    }

    var body: some View {
        GeometryReader { visible in
            GeometryReader { canvas in
                let viewport = PageViewport(visibleFrame: visible.frame(in: .global),
                                            canvasFrame: canvas.frame(in: .global))
                ScrollView {
                    VStack(alignment: .leading, spacing: 36) {
                        libraryShortcuts
                        if store.homeRepository.isLoading && !store.homeRepository.hasLoaded {
                            ProgressView("Carregando sua biblioteca…")
                                .frame(maxWidth: .infinity)
                        } else {
                            shelf(title: "Escutas recentes", releases: store.homeRepository.snapshot.recentlyPlayed,
                                  empty: "Os álbuns que você ouvir aparecerão aqui.", id: "recentlyPlayed", viewport: viewport)
                            shelf(title: "Adicionados recentemente", releases: store.homeRepository.snapshot.recentlyAdded,
                                  empty: "Importe músicas para ver seus álbuns aqui.", id: "recentlyAdded", viewport: viewport)
                        }
                        recommendations(viewport: viewport)
                        if let error = store.homeRepository.errorMessage {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .padding(24)
                    .padding(.leading, viewport.leadingInset)
                    .padding(.trailing, viewport.trailingInset)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
                .preservesLibraryScrollPosition(isContentReady: store.homeRepository.hasLoaded)
            }
        }
        .accessibilityIdentifier("home.page")
        .task(id: store.listenListRequest) { await store.refreshListenList() }
        .task(id: homeRequest) {
            guard let core = store.core else { return }
            let revision = store.libraryCatalogRevision
            while !Task.isCancelled {
                await store.homeRepository.refresh(core: core, catalogRevision: revision)
                await store.homeRecommendations.refresh(core: core, signals: recommendationSignals)
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
            }
        }
    }

    private func recommendations(viewport: PageViewport) -> some View {
        let repository = store.homeRecommendations
        let snapshot = repository.snapshot
        return VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(snapshot.exploration ? "Explore sua biblioteca" : "Recomendações para você")
                    .font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("home.recommendations.title")
                Spacer()
                Menu("Opções de sugestões", systemImage: "ellipsis") {
                    Button("Atualizar sugestões") {
                        guard let core = store.core else { return }
                        Task { await repository.refresh(core: core, signals: recommendationSignals, force: true) }
                    }
                    Button("Restaurar sugestões dispensadas") {
                        guard let core = store.core else { return }
                        Task { await repository.restore(core: core, signals: recommendationSignals) }
                    }
                }.labelStyle(.iconOnly).menuIndicator(.hidden).fixedSize().help("Opções de sugestões")
                    .disabled(repository.changing || repository.loading)
                    .accessibilityIdentifier("home.recommendations.options")
            }
            Text(snapshot.exploration ? "Álbuns locais para descobrir. Seus favoritos e avaliações ajudam a escolher." : "Sugestões da sua biblioteca com base nas suas escutas e preferências.")
                .font(.callout).foregroundStyle(.secondary)
            if let error = repository.error {
                HStack {
                    Text(error).foregroundStyle(.secondary)
                    Button("Tentar novamente") {
                        guard let core = store.core else { return }
                        Task { await repository.refresh(core: core, signals: recommendationSignals, force: true) }
                    }
                }
            }
            if repository.loading { ProgressView("Preparando sugestões…") }
            else if snapshot.items.isEmpty && repository.error == nil {
                Text("Nenhuma sugestão disponível agora. Continue explorando sua biblioteca ou restaure as sugestões dispensadas.")
                    .foregroundStyle(.secondary).padding(.vertical, 24)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 24) {
                        ForEach(snapshot.items, id: \.release.id) { item in
                            VStack(alignment: .leading, spacing: 10) {
                                AlbumCard(release: item.release, onSelectAlbum: { release in
                                    if let core = store.core { Task { await repository.record(.opened, releaseID: release.id, core: core) } }
                                    navigation.album(release)
                                }, artworkSize: min(220, max(160, (viewport.visibleWidth - 120) / 4)))
                                HStack(alignment: .top, spacing: 8) {
                                    Text(item.reason).font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                    Button("Dispensar sugestão", systemImage: "xmark") {
                                        guard let core = store.core else { return }
                                        Task { await repository.dismiss(releaseID: item.release.id, core: core, signals: recommendationSignals) }
                                    }.labelStyle(.iconOnly).buttonStyle(.borderless).disabled(repository.changing)
                                        .help("Ocultar esta sugestão por 30 dias")
                                        .accessibilityIdentifier("home.recommendation.dismiss.\(item.release.id)")
                                }
                            }.frame(width: min(220, max(160, (viewport.visibleWidth - 120) / 4)), alignment: .leading)
                                .accessibilityElement(children: .contain)
                                .accessibilityIdentifier("home.recommendation.\(item.release.id)")
                                .onScrollVisibilityChange(threshold: 0.5) { visible in
                                    guard visible, let core = store.core else { return }
                                    Task { await repository.record(.shown, releaseID: item.release.id, core: core) }
                                }
                        }
                    }
                }.scrollIndicators(.hidden)
                    .contentMargins(.leading, 24 + viewport.leadingInset, for: .scrollContent)
                    .contentMargins(.trailing, 24 + viewport.trailingInset, for: .scrollContent)
                    .frame(width: viewport.expandedWidth, alignment: .leading)
                    .padding(.leading, -24 - viewport.leadingInset)
                    .padding(.trailing, -24 - viewport.trailingInset)
                    .scrollClipDisabled()
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("home.recommendations")
    }

    private var libraryShortcuts: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sua biblioteca").font(.title2.bold())
                Text("Acesse rapidamente todo o conteúdo local.").foregroundStyle(.secondary)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                HomeLibraryCard(title: "Ouvir depois", count: store.pendingListenListCount, systemImage: "bookmark",
                                destination: .listenList, onNavigate: onNavigate)
                HomeLibraryCard(title: "Músicas", count: store.tracks.count, systemImage: "music.note",
                                destination: .songs, onNavigate: onNavigate)
                HomeLibraryCard(title: "Álbuns", count: store.releases.count, systemImage: "square.stack",
                                destination: .albums, onNavigate: onNavigate)
                HomeLibraryCard(title: "Artistas", count: store.artists.count, systemImage: "music.mic",
                                destination: .artists, onNavigate: onNavigate)
                HomeLibraryCard(title: "Playlists", count: store.playlists.count, systemImage: "music.note.list",
                                destination: .playlists, onNavigate: onNavigate)
            }
        }
    }

    private func shelf(title: String, releases: [Release], empty: String, id: String,
                       viewport: PageViewport) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                if id == "recentlyPlayed" {
                    Button("Ver histórico", systemImage: "clock.arrow.circlepath") { onNavigate(.retrospective) }
                        .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                        .accessibilityIdentifier("home.history")
                }
            }
            if releases.isEmpty {
                Text(empty).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 24)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 24) {
                        ForEach(releases, id: \.id) { release in
                            AlbumCard(release: release, onSelectAlbum: navigation.album,
                                      artworkSize: min(220, max(160, (viewport.visibleWidth - 120) / 4)))
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .contentMargins(.leading, 24 + viewport.leadingInset, for: .scrollContent)
                .contentMargins(.trailing, 24 + viewport.trailingInset, for: .scrollContent)
                .frame(width: viewport.expandedWidth, alignment: .leading)
                .padding(.leading, -24 - viewport.leadingInset)
                .padding(.trailing, -24 - viewport.trailingInset)
                .scrollClipDisabled()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.\(id)")
    }

}

private struct HomeLibraryCard: View {
    @Environment(\.appearsActive) private var appearsActive
    @State private var isHovered = false

    let title: String
    let count: Int
    let systemImage: String
    let destination: LibraryDestination
    let onNavigate: (LibraryDestination) -> Void

    var body: some View {
        Button {
            onNavigate(destination)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)

                    Text("\(count) itens")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
            .padding(14)
            .contentShape(Rectangle())
            .background(
                .quaternary,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        Color.black.opacity(
                            isHovered ? (appearsActive ? 0.055 : 0.025) : 0
                        )
                    )
                    .allowsHitTesting(false)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .animation(.easeOut(duration: 0.15), value: appearsActive)
        .accessibilityLabel("\(title), \(count) itens")
        .accessibilityHint("Abre \(title.lowercased())")
        .accessibilityIdentifier("home.\(destination.rawValue)")
    }
}

#Preview {
    HomeView(onNavigate: { _ in })
        .environment(DurvaldCoreStore())
}
