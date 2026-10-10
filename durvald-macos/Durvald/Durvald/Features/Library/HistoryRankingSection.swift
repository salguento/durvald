import AppKit
import SwiftUI

struct HistoryRankingSection: View {
    let snapshot: HistoryRankingSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(HistoryRankingSnapshot.Category.allCases) { category in
                        card(category).frame(minWidth: 240, maxWidth: .infinity)
                    }
                }
                VStack(spacing: 16) {
                    ForEach(HistoryRankingSnapshot.Category.allCases) { category in
                        card(category).frame(maxWidth: .infinity)
                    }
                }
            }
            if snapshot.unresolvedListens > 0 {
                Label("\(snapshot.unresolvedListens.formatted()) reproduções sem metadados; seus artistas e álbuns não puderam ser identificados.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .accessibilityIdentifier("history.overview.rankings")
    }

    private func card(_ category: HistoryRankingSnapshot.Category) -> some View {
        HistoryRankingCard(category: category, ranking: snapshot[category])
    }
}

private struct HistoryRankingCard: View {
    let category: HistoryRankingSnapshot.Category
    let ranking: HistoryRankingSnapshot.Ranking

    @State private var artworkColor: NSColor?

    private var featuredForeground: Color {
        guard let color = artworkColor?.usingColorSpace(.sRGB) else { return .primary }
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(color.redComponent)
            + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
        return luminance > 0.179 ? .black : .white
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                header
                if let top = ranking.top.first {
                    featured(top)
                    VStack(spacing: 0) {
                        ForEach(Array(ranking.top.dropFirst().enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Divider() }
                            rankRow(item)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 176, alignment: .top)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                } else {
                    ContentUnavailableView("Sem reproduções nesta semana", systemImage: category.symbol,
                                           description: Text("Seu top 5 aparecerá aqui quando houver histórico disponível."))
                        .frame(maxWidth: .infinity, minHeight: 416)
                }
            }
        }
        .groupBoxStyle(HistoryRankingGroupBoxStyle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("history.overview.ranking.\(category.rawValue)")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(category.title, systemImage: category.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(ranking.distinctCount.formatted())
                .font(.largeTitle.weight(.bold))
                .monospacedDigit()
                .accessibilityLabel("\(ranking.distinctCount.formatted()) \(category.title.lowercased()) distintos ouvidos nesta semana")
            Label {
                if let change = ranking.percentageChange {
                    Text("\(abs(change).formatted(.number.precision(.fractionLength(0...1))))% vs semana passada")
                } else {
                    Text("Sem base na semana passada")
                }
            } icon: {
                Image(systemName: ranking.trendIcon)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
        .padding(12)
    }

    private func featured(_ item: HistoryRankingSnapshot.Item) -> some View {
        VStack(spacing: 0) {
            HistoryRankingArtwork(item: item, category: category) { artworkColor = $0 }
            VStack(alignment: .leading, spacing: 6) {
                Text(category.topLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(featuredForeground.opacity(0.75))
                nameLink(item)
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.tail)
                Text("\(item.listens.formatted()) \(item.listens == 1 ? "reprodução" : "reproduções")")
                    .font(.caption)
                    .monospacedDigit()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(featuredForeground)
            .containerShape(Rectangle())
            .background {
                if let artworkColor {
                    Rectangle().fill(Color(nsColor: artworkColor))
                } else {
                    Rectangle().fill(Color(nsColor: .windowBackgroundColor))
                }
            }
            .clipShape(Rectangle())
        }
        .artworkGlassBorder(size: 240)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(fullDescription(item))
    }

    private func rankRow(_ item: HistoryRankingSnapshot.Item) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                nameLink(item).font(.subheadline).lineLimit(1).truncationMode(.tail)
                if category == .albums, let subtitle = item.subtitle {
                    HistoryRankingNameLink(title: subtitle, destination: item.artistID.map { .artist($0) })
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(item.listens.formatted())
                .font(.subheadline)
                .monospacedDigit()
                .fixedSize()
        }
        .frame(minHeight: 44)
        .help(fullDescription(item))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(fullDescription(item))
    }

    private func nameLink(_ item: HistoryRankingSnapshot.Item) -> HistoryRankingNameLink {
        let destination: HistoryRankingLinkDestination? = category == .artists
            ? item.artistID.map { .artist($0) }
            : item.releaseID.map { .album($0) }
        return HistoryRankingNameLink(title: item.title, destination: destination)
    }

    private func fullDescription(_ item: HistoryRankingSnapshot.Item) -> String {
        let subtitle = category == .tracks ? "" : item.subtitle.map { " · \($0)" } ?? ""
        return "\(item.title)\(subtitle) · \(item.listens.formatted()) \(item.listens == 1 ? "reprodução" : "reproduções")"
    }
}

private struct HistoryRankingArtwork: View {
    @Environment(DurvaldCoreStore.self) private var store
    let item: HistoryRankingSnapshot.Item
    let category: HistoryRankingSnapshot.Category
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
        let artworkID = category == .artists ? (loadedRequest == request ? portrait : nil) : item.artworkID
        GeometryReader { geometry in
            ArtworkImageView(source: artworkID.map(ArtworkSource.managed), size: geometry.size.width,
                             aspectRatio: max(geometry.size.width, 1) / 240, showsBorder: false,
                             fallbackSymbol: category.symbol, fallbackFont: .largeTitle,
                             onLowerRegionColorLoaded: onColorLoaded)
        }
        .frame(height: 240)
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

/// Keep the accessible group without a surrounding panel or default inset.
private struct HistoryRankingGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.content
    }
}

private enum HistoryRankingLinkDestination {
    case artist(Int64)
    case album(Int64)
}

private struct HistoryRankingNameLink: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(\.trackMenuNavigation) private var navigation
    let title: String
    let destination: HistoryRankingLinkDestination?
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

    private func destinationHint(_ destination: HistoryRankingLinkDestination) -> String {
        switch destination {
        case .artist: "Abrir página do artista"
        case .album: "Abrir página do álbum"
        }
    }

    private func open(_ destination: HistoryRankingLinkDestination) {
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
