import SwiftUI

struct LibrarySidebarView: View {
    @EnvironmentObject private var store: DurvaldCoreStore

    @Binding var section: SidebarSection
    @Binding var destination: LibraryDestination?

    let onSelectAlbum: (Release) -> Void

    @State private var isLocalSearchExpanded = false
    @State private var localSearchText = ""
    @State private var committedLocalQuery = ""

    private let albumGridColumnCount = 3

    private var albumGridColumns: [GridItem] {
        Array(
            repeating: GridItem(
                .fixed(60),
                spacing: 6,
                alignment: .top
            ),
            count: albumGridColumnCount
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            SidebarSectionPicker(selection: $section)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10)

            if section != .navigation {
                SidebarSectionSearchField(
                    scope: section.title,
                    text: $localSearchText,
                    isExpanded: $isLocalSearchExpanded
                )
                .padding(.horizontal, 10)
                .padding(.top, 12)
                .padding(.bottom, 10)
            }

            selectedSectionContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: localSearchText) {
            let normalized = localSearchText.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

            guard !normalized.isEmpty else {
                committedLocalQuery = ""
                return
            }

            do {
                try await Task.sleep(for: .milliseconds(180))
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            committedLocalQuery = normalized
        }
        .onChange(of: section) { _, _ in
            localSearchText = ""
            committedLocalQuery = ""
            isLocalSearchExpanded = false
        }
    }

    @ViewBuilder
    private var selectedSectionContent: some View {
        switch section {
        case .navigation:
            ScrollView {
                LazyVStack(spacing: 2) {
                    SidebarNavigationButton(
                        item: .search,
                        selection: $destination,
                        accessibilityIdentifier: "sidebar.search.open"
                    )

                    SidebarNavigationButton(
                        item: .home,
                        selection: $destination,
                        accessibilityIdentifier: "sidebar.home"
                    )

                    ForEach(LibraryDestination.navigationItems) { item in
                        SidebarNavigationButton(
                            item: item,
                            selection: $destination,
                            accessibilityIdentifier: "sidebar.\(item.rawValue)"
                        )
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10)
            }
            .clipped()
            .padding(.top, 12)

        case .playlists:
            List(localPlaylists, id: \.id) { playlist in
                Button {
                    destination = .playlists
                } label: {
                    SidebarItemLabel(
                        title: playlist.name,
                        subtitle: "\(playlist.trackCount) músicas",
                        systemImage: "music.note.list"
                    )
                }
                .buttonStyle(.plain)
            }
            .listStyle(.sidebar)

        case .albums:
            ScrollView {
                LazyVGrid(
                    columns: albumGridColumns,
                    alignment: .leading,
                    spacing: 6
                ) {
                    ForEach(localAlbums, id: \.id) { album in
                        Button {
                            destination = .albums
                            onSelectAlbum(album)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                ArtworkView(
                                    artworkID: album.artworkId,
                                    size: 60
                                )

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(album.title)
                                        .font(.caption)
                                        .lineLimit(1)

                                    Text(album.artist)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(width: 60, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("\(album.title) — \(album.artist)")
                        .accessibilityLabel(
                            album.artist.isEmpty
                                ? album.title
                                : "\(album.title), \(album.artist)"
                        )
                        .accessibilityIdentifier("sidebar.album.\(album.id)")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }

        case .artists:
            List(localArtists, id: \.id) { artist in
                Button {
                    destination = .artists
                } label: {
                    SidebarItemLabel(
                        title: artist.name,
                        subtitle: nil,
                        systemImage: "music.mic"
                    )
                }
                .buttonStyle(.plain)
            }
            .listStyle(.sidebar)
        }
    }

    private var localPlaylists: [Playlist] {
        guard !committedLocalQuery.isEmpty else { return store.playlists }
        return store.playlists.filter {
            $0.name.localizedStandardContains(committedLocalQuery)
        }
    }

    private var localAlbums: [Release] {
        guard !committedLocalQuery.isEmpty else { return store.releases }
        return store.releases.filter {
            $0.title.localizedStandardContains(committedLocalQuery)
                || $0.artist.localizedStandardContains(committedLocalQuery)
        }
    }

    private var localArtists: [Artist] {
        guard !committedLocalQuery.isEmpty else { return store.artists }
        return store.artists.filter {
            $0.name.localizedStandardContains(committedLocalQuery)
        }
    }

}

private struct SidebarNavigationButton: View {
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.colorScheme) private var colorScheme

    let item: LibraryDestination
    @Binding var selection: LibraryDestination?
    let accessibilityIdentifier: String

    private var isSelected: Bool { selection == item }

    private var foreground: Color {
        guard isSelected else {
            return item == .search ? .secondary : .primary
        }
        // Dim the user's accent in inactive windows without replacing its hue.
        return Color.accentColor.opacity(appearsActive ? 1 : 0.63)
    }

    private var selectionBackgroundColor: Color {
        guard colorScheme == .dark else { return .black }

        // Active: #2A2B33. Inactive: #2F3138. The sidebar material remains visible.
        return appearsActive
            ? Color(.sRGB, red: 42.0 / 255, green: 43.0 / 255, blue: 51.0 / 255)
            : Color(.sRGB, red: 47.0 / 255, green: 49.0 / 255, blue: 56.0 / 255)
    }

    private var selectionBackgroundOpacity: Double {
        if colorScheme == .dark {
            return 0.80
        }

        return appearsActive ? 0.10 : 0.06
    }

    var body: some View {
        Button {
            selection = item
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.icon)
                    .font(.system(size: 16, weight: .regular))
                    .symbolRenderingMode(.monochrome)
                    .frame(width: 20)

                Text(item.title)
                    .font(.body)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .frame(
                maxWidth: .infinity,
                minHeight: 32,
                maxHeight: 32,
                alignment: .leading
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selectionBackgroundColor.opacity(selectionBackgroundOpacity))
            }
        }
        .help(item.title)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(accessibilityIdentifier)
        .animation(.easeOut(duration: 0.15), value: appearsActive)
    }
}



private struct SidebarSectionPicker: View {
    @Binding var selection: SidebarSection
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        HStack(spacing: 3) {
            ForEach(SidebarSection.allCases) { item in
                Button {
                    selection = item
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: item.icon)

                        if item == selection {
                            Text(item.title)
                                .lineLimit(1)
                        }
                    }
                    .foregroundStyle(
                        item == selection
                            ? (appearsActive ? Color.white : Color.secondary)
                            : Color.secondary
                    )
                    .frame(height: 24)
                    .frame(
                        minWidth: item == selection ? 76 : 28,
                        maxWidth: item == selection ? .infinity : 28
                    )
                    .contentShape(Rectangle())
                    .background {
                        if item == selection {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(
                                    appearsActive
                                        ? Color.accentColor
                                        : Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
                                )
                                .shadow(
                                    color: appearsActive
                                        ? Color.accentColor.opacity(0.20)
                                        : .clear,
                                    radius: 1,
                                    y: 1
                                )
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(item.title)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(
                    item == selection ? .isSelected : []
                )
                .accessibilityIdentifier(
                    "sidebar.section.\(item.rawValue)"
                )
            }
        }
        .padding(3)
        .background(
            .quaternary,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .animation(.easeOut(duration: 0.15), value: appearsActive)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conteúdo da barra lateral")
        .accessibilityIdentifier("sidebar.sectionPicker")
    }
}

private struct SidebarSectionSearchField: View {
    let scope: String

    @Binding var text: String
    @Binding var isExpanded: Bool

    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if isExpanded {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .regular))
                        .symbolRenderingMode(.monochrome)
                        .frame(width: 20)
                        .foregroundStyle(.secondary)

                    TextField("Pesquisar em \(scope)", text: $text)
                        .textFieldStyle(.plain)
                        .focused($isFocused)
                        .onExitCommand {
                            if text.isEmpty {
                                isFocused = false
                                isExpanded = false
                            } else {
                                text = ""
                            }
                        }
                        .task {
                            await Task.yield()
                            isFocused = true
                        }
                        .accessibilityIdentifier(
                            "sidebar.sectionSearch.field"
                        )

                    Button {
                        text = ""
                        Task { @MainActor in
                            await Task.yield()
                            isFocused = true
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .opacity(text.isEmpty ? 0 : 1)
                    .allowsHitTesting(!text.isEmpty)
                    .accessibilityHidden(text.isEmpty)
                    .accessibilityLabel("Limpar pesquisa")
                    .accessibilityIdentifier("sidebar.sectionSearch.clear")
                }
                .padding(.horizontal, 8)
                .frame(
                    maxWidth: .infinity,
                    minHeight: 32,
                    alignment: .leading
                )
                .accessibilityIdentifier("sidebar.sectionSearch.container")
                .background(
                    .quaternary,
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .transition(.opacity)

            } else {
                Button {
                    isExpanded = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 16, weight: .regular))
                            .symbolRenderingMode(.monochrome)
                            .frame(width: 20)
                            .foregroundStyle(.secondary)

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: 32,
                        alignment: .leading
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .help("Pesquisar em \(scope)")
                .accessibilityLabel("Pesquisar em \(scope)")
                .accessibilityIdentifier(
                    "sidebar.sectionSearch.toggle"
                )
            }
        }
        .onChange(of: isFocused) { _, focused in
            if !focused {
                isExpanded = false
            }
        }
    }
}

private struct SidebarItemLabel: View {
    let title: String
    let subtitle: String?
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .frame(width: 18)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .lineLimit(1)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}
