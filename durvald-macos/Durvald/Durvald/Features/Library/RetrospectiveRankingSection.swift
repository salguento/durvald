import AppKit
import SwiftUI

struct RetrospectiveRankingSection: View {
    let snapshot: RetrospectiveRankingSnapshot
    let viewport: PageViewport

    private var cardWidth: CGFloat { min(320, max(240, (viewport.visibleWidth - 120) / 3)) }
    private var sideInsets: EdgeInsets { viewport.sideInsets }

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            ForEach(RetrospectiveRankingSnapshot.Category.allCases) { category in
                rankingRow(category)
            }
            if snapshot.unresolvedListens > 0 {
                Label("\(snapshot.unresolvedListens.formatted()) reproduções sem metadados; seus artistas e álbuns não puderam ser identificados.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 32)
        .accessibilityIdentifier("retrospective.overview.rankings")
    }

    private func title(_ category: RetrospectiveRankingSnapshot.Category) -> String {
        switch category {
        case .artists: "Seus artistas mais ouvidos"
        case .albums: "Seus álbuns mais ouvidos"
        case .tracks: "Suas músicas mais ouvidas"
        }
    }

    private func rankingRow(_ category: RetrospectiveRankingSnapshot.Category) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title(category))
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            if snapshot[category].top.isEmpty {
                ContentUnavailableView("Sem reproduções neste período", systemImage: category.symbol)
                    .frame(maxWidth: .infinity)
            } else {
                ScrollView(.horizontal) {
                    if category == .tracks {
                        songColumns(snapshot[category].top)
                    } else {
                        LazyHStack(alignment: .top, spacing: 24) {
                            ForEach(Array(snapshot[category].top.enumerated()), id: \.element.id) { index, item in
                                if category == .albums {
                                    RetrospectiveAlbumCard(item: item, rank: index + 1,
                                        width: min(280, max(180, (viewport.visibleWidth - 152) / 4)))
                                } else {
                                    RetrospectiveRankingCard(item: item, category: category, rank: index + 1, width: cardWidth)
                                }
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .contentMargins(.leading, 24 + sideInsets.leading, for: .scrollContent)
                .contentMargins(.trailing, 24 + sideInsets.trailing, for: .scrollContent)
                .frame(width: viewport.expandedWidth, alignment: .leading)
                .padding(.leading, -24 - sideInsets.leading)
                .padding(.trailing, -24 - sideInsets.trailing)
                .scrollClipDisabled()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("retrospective.overview.ranking.\(category.rawValue)")
    }

    private func songColumns(_ items: [RetrospectiveRankingSnapshot.Item]) -> some View {
        LazyHStack(alignment: .top, spacing: PopularTrackRowMetrics.columnSpacing) {
            ForEach(Array(stride(from: 0, to: items.count, by: 4)), id: \.self) { start in
                VStack(spacing: 0) {
                    ForEach(start..<min(start + 4, items.count), id: \.self) { index in
                        RetrospectiveSongRow(item: items[index], rank: index + 1)
                            .overlay(alignment: .bottom) {
                                if index < min(start + 4, items.count) - 1 { Divider() }
                            }
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: min(620, max(320, (viewport.visibleWidth - 112) / 2)), height: PopularTrackRowMetrics.height * 4, alignment: .top)
            }
        }
    }
}

private struct RetrospectiveAlbumCard: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(\.trackMenuNavigation) private var navigation
    @State private var isArtworkHovered = false
    @State private var navigationTask: Task<Void, Never>?
    let item: RetrospectiveRankingSnapshot.Item
    let rank: Int
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .topLeading) {
                Button(action: openAlbum) {
                    ArtworkImageView(source: item.artworkID.map(ArtworkSource.managed), size: width,
                                     showsBorder: false, fallbackSymbol: "square.stack.fill")
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.12), lineWidth: 1) }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Abrir o álbum \(item.title)")
                if let releaseID = item.releaseID {
                    AlbumArtworkPlayOverlay(releaseID: releaseID, title: item.title,
                                            artworkSize: width, isHovered: isArtworkHovered)
                }
            }
            .frame(width: width, height: width)
            .contentShape(Rectangle())
            .onHover { isArtworkHovered = $0 }
            .padding(.bottom, 7)
            Text(rank.formatted()).font(.title2.bold()).monospacedDigit()
            RetrospectiveRankingNameLink(title: item.title, destination: item.releaseID.map { .album($0) })
                .font(LibraryTypography.listingTitle).lineLimit(1)
            if let artist = item.subtitle {
                RetrospectiveRankingNameLink(title: artist, destination: item.artistID.map { .artist($0) })
                    .font(LibraryTypography.listingSecondary).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(item.minutesLabel).font(LibraryTypography.listingSecondary).foregroundStyle(.secondary)
        }
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(rank)º lugar, \(item.title), \(item.minutesLabel)")
        .accessibilityIdentifier("retrospective.ranking.albums.\(item.id)")
        .onDisappear { navigationTask?.cancel(); navigationTask = nil; isArtworkHovered = false }
    }

    private func openAlbum() {
        guard let id = item.releaseID else { return }
        if let album = store.loadedRelease(id: id) { navigation.album(album); return }
        guard navigationTask == nil else { return }
        navigationTask = Task {
            defer { navigationTask = nil }
            do {
                guard let album = try await store.core?.release(releaseId: id), !Task.isCancelled else { return }
                navigation.album(album)
            } catch {
                if !Task.isCancelled { store.errorMessage = String(describing: error) }
            }
        }
    }
}

private struct RetrospectiveSongRow: View {
    let item: RetrospectiveRankingSnapshot.Item
    let rank: Int

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(artworkID: item.artworkID, size: 42)
            Text(rank.formatted())
                .font(.body).monospacedDigit()
                .frame(width: 24, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                RetrospectiveRankingNameLink(title: item.title, destination: item.releaseID.map { .album($0) })
                    .font(.body).lineLimit(1)
                Text("\(item.subtitle ?? "Artista desconhecido") · \(item.listens.formatted()) \(item.listens == 1 ? "reprodução" : "reproduções")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .frame(height: PopularTrackRowMetrics.height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(rank)º lugar, \(item.title), \(item.listens) reproduções")
        .accessibilityIdentifier("retrospective.ranking.tracks.\(item.id)")
    }
}

private struct RetrospectiveRankingCard: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(\.trackMenuNavigation) private var navigation
    @State private var isHovered = false
    let item: RetrospectiveRankingSnapshot.Item
    let category: RetrospectiveRankingSnapshot.Category
    let rank: Int
    let width: CGFloat
    @State private var artworkColor: NSColor?

    private var height: CGFloat { width * 4 / 3 }
    private var bottomColor: Color {
        Color(nsColor: (artworkColor ?? .windowBackgroundColor).blended(withFraction: 0.5, of: .black) ?? .black)
    }
    var body: some View {
        Button {
            if let id = item.artistID {
                navigation.artist(store.loadedArtist(id: id) ?? Artist(id: id, name: item.title))
            }
        } label: {
            cardContent
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .onDisappear { isHovered = false }
        .accessibilityLabel("\(rank)º lugar, \(item.title), \(item.minutesLabel)")
        .accessibilityHint("Abrir página do artista")
        .accessibilityIdentifier("retrospective.ranking.\(category.rawValue).\(item.id)")
    }

    private var cardContent: some View {
        ZStack(alignment: .bottom) {
            RetrospectiveRankingArtwork(item: item, category: category, width: width, height: height) { artworkColor = $0 }
            LinearGradient(stops: [.init(color: .clear, location: 0.35),
                                   .init(color: bottomColor.opacity(0.8), location: 0.75),
                                   .init(color: bottomColor, location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
            VStack(spacing: 6) {
                Text(item.title)
                    .font(LibraryTypography.listingTitle)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(item.minutesLabel)
                    .font(LibraryTypography.listingSecondary)
                    .monospacedDigit()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .overlay(alignment: .topLeading) {
            Text(rank.formatted())
                .font(.largeTitle.bold())
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
                .padding(20)
                .accessibilityHidden(true)
        }
        .frame(width: width, height: height)
        .overlay {
            Color.black.opacity(isHovered ? 0.10 : 0).allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .overlay {
            RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.12), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}

private struct RetrospectiveRankingArtwork: View {
    @Environment(DurvaldCoreStore.self) private var store
    let item: RetrospectiveRankingSnapshot.Item
    let category: RetrospectiveRankingSnapshot.Category
    let width: CGFloat
    let height: CGFloat
    let onColorLoaded: (NSColor?) -> Void
    @State private var portrait: String?
    @State private var loadedRequest: Request?

    private struct Request: Equatable {
        let artistID: Int64?
        let coreID: ObjectIdentifier?
    }

    var body: some View {
        let request = Request(artistID: category == .artists ? item.id : nil,
                              coreID: store.core.map(ObjectIdentifier.init))
        let artworkID = category == .artists ? (loadedRequest == request ? portrait ?? item.artworkID : item.artworkID) : item.artworkID
        ArtworkImageView(source: artworkID.map(ArtworkSource.managed), size: width,
                         aspectRatio: width / height, showsBorder: false,
                         fallbackSymbol: category.symbol, fallbackFont: .largeTitle,
                         onLowerRegionColorLoaded: onColorLoaded)
        .frame(width: width, height: height)
        .clipped()
        .onChange(of: artworkID) { _, _ in onColorLoaded(nil) }
        .task(id: request) {
            guard let artistID = request.artistID else { return }
            let path = await store.artistDetails(artistId: artistID,
                language: Locale.current.language.languageCode?.identifier ?? "en")?.portrait?.managedPath
            guard !Task.isCancelled else { return }
            portrait = path
            loadedRequest = request
        }
    }
}

private enum RetrospectiveRankingLinkDestination {
    case artist(Int64)
    case album(Int64)
}

private struct RetrospectiveRankingNameLink: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(\.trackMenuNavigation) private var navigation
    let title: String
    let destination: RetrospectiveRankingLinkDestination?
    @State private var hovered = false
    @State private var navigationTask: Task<Void, Never>?

    var body: some View {
        Group {
            if let destination {
                Button { open(destination) } label: {
                    Text(title).underline(hovered)
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 }
                .accessibilityRemoveTraits(.isButton)
                .accessibilityAddTraits(.isLink)
                .accessibilityHint(destinationHint(destination))
            } else {
                Text(title)
            }
        }
        .help(title)
        .onDisappear {
            hovered = false
            navigationTask?.cancel()
            navigationTask = nil
        }
    }

    private func destinationHint(_ destination: RetrospectiveRankingLinkDestination) -> String {
        switch destination {
        case .artist: "Abrir página do artista"
        case .album: "Abrir página do álbum"
        }
    }

    private func open(_ destination: RetrospectiveRankingLinkDestination) {
        switch destination {
        case .artist(let id):
            navigation.artist(store.loadedArtist(id: id) ?? Artist(id: id, name: title))
        case .album(let id):
            if let album = store.loadedRelease(id: id) {
                navigation.album(album)
                return
            }
            // History can reference an album outside the loaded catalog page.
            // Resolve only on click, never while rendering the ranking.
            guard navigationTask == nil else { return }
            navigationTask = Task {
                defer { navigationTask = nil }
                do {
                    guard let album = try await store.core?.release(releaseId: id),
                          !Task.isCancelled else { return }
                    navigation.album(album)
                } catch {
                    if !Task.isCancelled { store.errorMessage = String(describing: error) }
                }
            }
        }
    }
}
