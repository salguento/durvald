import SwiftUI

enum CollectionListingMode: String, CaseIterable, Identifiable {
    case compact, standard, compactGrid, standardGrid

    var id: Self { self }
    var isGrid: Bool { self == .compactGrid || self == .standardGrid }
    var title: String {
        switch self {
        case .compact: "Compacta"
        case .standard: "Default"
        case .compactGrid: "Grid compacto"
        case .standardGrid: "Grid default"
        }
    }
    var icon: String {
        switch self {
        case .compact: "text.justify"
        case .standard: "list.bullet"
        case .compactGrid: "square.grid.3x3"
        case .standardGrid: "square.grid.2x2"
        }
    }
}

enum CollectionListingOrder: String, CaseIterable, Identifiable {
    case recent
    case recentlyAdded
    case alphabetical
    case artist
    case releaseDate

    var id: Self { self }

    var title: String {
        switch self {
        case .recent: "Recentes"
        case .recentlyAdded: "Adicionados recentemente"
        case .alphabetical: "Alfabética"
        case .artist: "Artista"
        case .releaseDate: "Lançamento"
        }
    }

}

enum CollectionListingSorter {
    static func albums(
        _ albums: [Release],
        order: CollectionListingOrder,
        lastPlayedByRelease: [Int64: String]
    ) -> [Release] {
        return albums.sorted { lhs, rhs in
            switch order {
            case .recent:
                let left = lastPlayedByRelease[lhs.id]
                let right = lastPlayedByRelease[rhs.id]
                if left != right { return (left ?? "") > (right ?? "") }
            case .recentlyAdded:
                if lhs.id != rhs.id { return lhs.id > rhs.id }
            case .alphabetical:
                let comparison = lhs.title.localizedStandardCompare(rhs.title)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            case .artist:
                let comparison = lhs.artist.localizedStandardCompare(rhs.artist)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            case .releaseDate:
                if lhs.releaseDate != rhs.releaseDate {
                    return (lhs.releaseDate ?? "") > (rhs.releaseDate ?? "")
                }
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    static func artists(
        _ artists: [Artist],
        order: CollectionListingOrder,
        releases: [Release],
        lastPlayedByRelease: [Int64: String]
    ) -> [Artist] {
        let releasesByArtist = Dictionary(grouping: releases, by: \.artistId)
        return artists.sorted { lhs, rhs in
            let leftReleases = releasesByArtist[lhs.id] ?? []
            let rightReleases = releasesByArtist[rhs.id] ?? []
            switch order {
            case .recent:
                let left = leftReleases.compactMap { lastPlayedByRelease[$0.id] }.max()
                let right = rightReleases.compactMap { lastPlayedByRelease[$0.id] }.max()
                if left != right { return (left ?? "") > (right ?? "") }
            case .recentlyAdded:
                let left = leftReleases.map(\.id).max() ?? lhs.id
                let right = rightReleases.map(\.id).max() ?? rhs.id
                if left != right { return left > right }
            case .releaseDate:
                let left = leftReleases.compactMap(\.releaseDate).max()
                let right = rightReleases.compactMap(\.releaseDate).max()
                if left != right { return (left ?? "") > (right ?? "") }
            case .alphabetical, .artist:
                break
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static func playlists(
        _ playlists: [Playlist],
        order: CollectionListingOrder,
        tracksByPlaylist: [Int64: [Track]],
        releases: [Release]
    ) -> [Playlist] {
        let releaseDates = Dictionary(uniqueKeysWithValues: releases.map { ($0.id, $0.releaseDate) })
        return playlists.sorted { lhs, rhs in
            switch order {
            case .recent:
                let left = latestPlayback(in: tracksByPlaylist[lhs.id] ?? [])
                let right = latestPlayback(in: tracksByPlaylist[rhs.id] ?? [])
                if left != right { return (left ?? "") > (right ?? "") }
            case .recentlyAdded:
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            case .alphabetical:
                break
            case .artist:
                let left = firstArtist(in: tracksByPlaylist[lhs.id] ?? [])
                let right = firstArtist(in: tracksByPlaylist[rhs.id] ?? [])
                if left != right {
                    guard let left else { return false }
                    guard let right else { return true }
                    return left.localizedStandardCompare(right) == .orderedAscending
                }
            case .releaseDate:
                let left = latestReleaseDate(
                    in: tracksByPlaylist[lhs.id] ?? [],
                    releaseDates: releaseDates
                )
                let right = latestReleaseDate(
                    in: tracksByPlaylist[rhs.id] ?? [],
                    releaseDates: releaseDates
                )
                if left != right { return (left ?? "") > (right ?? "") }
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private static func latestPlayback(in tracks: [Track]) -> String? {
        tracks.compactMap(\.lastPlayed).max()
    }

    private static func firstArtist(in tracks: [Track]) -> String? {
        tracks.map(\.artist).min { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func latestReleaseDate(
        in tracks: [Track],
        releaseDates: [Int64: String?]
    ) -> String? {
        tracks.compactMap { releaseDates[$0.releaseId] ?? nil }.max()
    }
}

struct CollectionListingMenu: View {
    @Binding var mode: CollectionListingMode
    @Binding var order: CollectionListingOrder
    var controlSize: CGFloat = 32
    var controlWidth: CGFloat? = nil
    var usesGlassEffect = true
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            ZStack {
                Color.clear
                Image(systemName: "line.3.horizontal.decrease")
            }
            .frame(width: controlWidth ?? controlSize, height: controlSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: controlWidth ?? controlSize, height: controlSize)
        .contentShape(Capsule())
        .modifier(CollectionListingGlassEffect(enabled: usesGlassEffect))
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Ordenar")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(CollectionListingOrder.allCases) { option in
                    Button {
                        order = option
                        isPresented = false
                    } label: {
                        HStack(spacing: 8) {
                            Text(option.title)
                            Spacer(minLength: 16)
                            Image(systemName: "checkmark")
                                .opacity(order == option ? 1 : 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Divider()

                Text("Visualização")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 0) {
                    ForEach(CollectionListingMode.allCases) { option in
                        Button {
                            mode = option
                            isPresented = false
                        } label: {
                            Image(systemName: option.icon)
                                .frame(maxWidth: .infinity, minHeight: 26)
                                .foregroundStyle(
                                    mode == option
                                        ? Color(nsColor: .selectedMenuItemTextColor)
                                        : Color.primary
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                        .background {
                            if mode == option {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.accentColor)
                            }
                        }
                        .help(option.title)
                        .accessibilityLabel(option.title)
                        .accessibilityAddTraits(mode == option ? .isSelected : [])
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(12)
            .frame(width: 238)
        }
        .help("Organizar listagem")
        .accessibilityLabel("Organizar listagem")
        .accessibilityValue("\(order.title), \(mode.title)")
    }
}

private struct CollectionListingGlassEffect: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content
        }
    }
}

struct CollectionListingLayout<Content: View>: View {
    static var mainGridMinimumCardWidth: CGFloat { 120 }
    static var mainListArtworkSize: CGFloat { 42 }

    let mode: CollectionListingMode
    var isSidebar = false
    var mainGridMinimumCardWidth = Self.mainGridMinimumCardWidth
    var mainListArtworkSize = Self.mainListArtworkSize
    @ViewBuilder let content: (CGFloat) -> Content

    var body: some View {
        GeometryReader { geometry in
            let padding: CGFloat = isSidebar ? 10 : 24
            let spacing: CGFloat = switch mode {
            case .compactGrid: isSidebar ? 6 : 16
            case .standardGrid: isSidebar ? 12 : 24
            case .compact, .standard: isSidebar ? 6 : 16
            }
            let width = max(1, geometry.size.width - padding * 2)
            let target: CGFloat = mode.isGrid
                ? (isSidebar ? 66 : mainGridMinimumCardWidth)
                : (isSidebar ? 110 : 192)
            // Both grid modes keep the same column count. The standard grid
            // spends part of each column on gaps instead of growing the art.
            let count = AlbumGridLayout.columnCount(
                for: width,
                minimumCardWidth: target,
                padding: 0,
                gap: mode.isGrid ? 0 : spacing
            )
            let size = max(1, (width - CGFloat(count - 1) * spacing) / CGFloat(count))
            ScrollView {
                Group {
                    if mode.isGrid {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: spacing, alignment: .top), count: count), alignment: .leading, spacing: spacing) {
                            content(size)
                        }
                    } else {
                        LazyVStack(alignment: .leading, spacing: isSidebar ? 2 : 4) {
                            content(isSidebar ? 32 : mainListArtworkSize)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, padding)
                .padding(.vertical, isSidebar ? 4 : 24)
            }
            .preservesLibraryScrollPosition()
        }
    }
}

struct CollectionListingItem<Artwork: View>: View {
    let title: String
    var subtitle: String? = nil
    var isFavorite = false
    let mode: CollectionListingMode
    let artworkSize: CGFloat
    var isSelected = false
    var centersGridText = false
    let action: () -> Void
    @ViewBuilder let artwork: () -> Artwork
    @State private var isHovered = false
    @State private var showsTooltip = false

    private var usesCenteredGridText: Bool {
        centersGridText && mode == .standardGrid
    }

    var body: some View {
        Button(action: action) {
            Group {
                if mode.isGrid {
                    VStack(alignment: usesCenteredGridText ? .center : .leading, spacing: 7) {
                        artwork()
                        if mode == .standardGrid {
                            textDetails
                        }
                    }
                    .frame(width: artworkSize, alignment: .leading)
                } else {
                    HStack(spacing: 10) {
                        if mode == .standard { artwork() }
                        if mode == .compact {
                            HStack(spacing: 4) {
                                if isFavorite {
                                    Image(systemName: "star.fill")
                                        .font(.body)
                                }
                                Text("\(title)\(Text(subtitle.map { " · \($0)" } ?? "").foregroundColor(.secondary))")
                                    .lineLimit(1)
                            }
                        } else {
                            textDetails
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, mode == .compact ? 7 : 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.1))
            }
        }
        .accessibilityLabel(subtitle.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { isHovered = $0 }
        .task(id: isHovered) {
            guard isHovered, mode == .compactGrid else { showsTooltip = false; return }
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            guard !Task.isCancelled else { return }
            showsTooltip = true
        }
        .onChange(of: mode) { _, _ in showsTooltip = false }
        .popover(isPresented: $showsTooltip, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).foregroundStyle(.white)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: 260, alignment: .leading)
            .preferredColorScheme(.dark)
        }
    }

    private var textDetails: some View {
        VStack(alignment: .leading, spacing: 1) {
            AlbumTitleLabel(
                title: title,
                isFavorite: isFavorite,
                font: AlbumListingTypography.title
            )
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: usesCenteredGridText ? .center : .leading)
            if let subtitle {
                Text(subtitle)
                    .font(AlbumListingTypography.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: usesCenteredGridText ? .center : .leading)
            }
        }
        .multilineTextAlignment(usesCenteredGridText ? .center : .leading)
    }
}

struct AlbumTitleLabel: View {
    let title: String
    let isFavorite: Bool
    let font: Font
    var weight: Font.Weight? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if isFavorite {
                Image(systemName: "star.fill")
            }
            Text(title)
        }
        .font(font)
        .fontWeight(weight)
    }
}
