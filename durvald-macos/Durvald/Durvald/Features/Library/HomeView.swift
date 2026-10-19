import SwiftUI

struct HomeView: View {
    @Environment(DurvaldCoreStore.self) private var store

    @Environment(\.trackMenuNavigation) private var navigation

    let onNavigate: (LibraryDestination) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 12)
    ]

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
        .task(id: store.libraryCatalogRevision) {
            guard let core = store.core else { return }
            let revision = store.libraryCatalogRevision
            while !Task.isCancelled {
                await store.homeRepository.refresh(core: core, catalogRevision: revision)
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
            }
        }
    }

    private var libraryShortcuts: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sua biblioteca").font(.title2.bold())
                Text("Acesse rapidamente todo o conteúdo local.").foregroundStyle(.secondary)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
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
