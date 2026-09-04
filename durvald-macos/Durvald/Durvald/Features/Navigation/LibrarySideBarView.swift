import SwiftUI

struct LibrarySidebarView: View {
    @Environment(DurvaldCoreStore.self) private var store

    @Binding var section: SidebarSection
    @Binding var destination: LibraryDestination?
    let selectedPlaylistID: Int64?

    let onSelectAlbum: (Release) -> Void
    let onSelectArtist: (Artist) -> Void
    let onSelectPlaylist: (Playlist) -> Void

    @State private var isLocalSearchExpanded = false
    @State private var localSearchText = ""
    @State private var committedLocalQuery = ""

    private let albumGridColumns = [
        GridItem(.adaptive(minimum: 60, maximum: 60), spacing: 6, alignment: .top)
    ]

    var body: some View {
        selectedSectionContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Keep controls fixed while the scroll view extends behind them.
            // The system supplies the backdrop and scroll-edge treatment.
            .safeAreaBar(edge: .top, spacing: 0) {
                fixedControls
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
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

    private var fixedControls: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(spacing: 12) {
                SidebarSectionPicker(selection: $section)
                    .frame(maxWidth: .infinity)

                if section != .navigation {
                    SidebarSectionSearchField(
                        scope: section.title,
                        text: $localSearchText,
                        isExpanded: $isLocalSearchExpanded
                    )
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, section == .navigation ? 12 : 10)
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

                    SidebarNavigationButton(
                        item: .history,
                        selection: $destination,
                        accessibilityIdentifier: "sidebar.history"
                    )

                    navigationSectionHeader("Biblioteca")

                    ForEach([LibraryDestination.artists, .albums, .songs]) { item in
                        SidebarNavigationButton(
                            item: item,
                            selection: $destination,
                            accessibilityIdentifier: "sidebar.\(item.rawValue)"
                        )
                    }

                    navigationSectionHeader("Playlists")

                    SidebarNavigationButton(
                        item: .playlists,
                        selection: $destination,
                        accessibilityIdentifier: "sidebar.playlists",
                        allowsSelectionHighlight: selectedPlaylistID == nil
                    )

                    ForEach(store.playlists, id: \.id) { playlist in
                        SidebarPlaylistButton(
                            playlist: playlist,
                            isSelected: selectedPlaylistID == playlist.id,
                            action: { onSelectPlaylist(playlist) }
                        )
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10)
            }

        case .playlists:
            List(localPlaylists, id: \.id) { playlist in
                Button {
                    onSelectPlaylist(playlist)
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
                // At most three covers, but allow two in a narrow sidebar
                // instead of forcing the split column to expand on tab changes.
                .frame(maxWidth: 192, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }

        case .artists:
            List(localArtists, id: \.id) { artist in
                Button {
                    onSelectArtist(artist)
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

    private func navigationSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.top, 16)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
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
    var allowsSelectionHighlight = true

    private var isSelected: Bool { allowsSelectionHighlight && selection == item }

    private var foreground: Color {
        guard isSelected else {
            return item == .search ? .secondary : .primary
        }
        // Dim the user's accent in inactive windows without replacing its hue.
        return Color.accentColor.opacity(appearsActive ? 1 : 0.63)
    }

    private var selectionBackgroundOpacity: Double {
        if colorScheme == .dark {
            return appearsActive ? 0.08 : 0.10
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
                    // A semantic neutral lets the material retain the user's theme tint.
                    .fill(Color.primary.opacity(selectionBackgroundOpacity))
            }
        }
        .help(item.title)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(accessibilityIdentifier)
        .animation(.easeOut(duration: 0.15), value: appearsActive)
    }
}

private struct SidebarPlaylistButton: View {
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.colorScheme) private var colorScheme

    let playlist: Playlist
    let isSelected: Bool
    let action: () -> Void

    private var foreground: Color {
        isSelected ? Color.accentColor.opacity(appearsActive ? 1 : 0.63) : .primary
    }

    private var selectionBackgroundOpacity: Double {
        if colorScheme == .dark {
            return appearsActive ? 0.08 : 0.10
        }
        return appearsActive ? 0.10 : 0.06
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                PlaylistArtworkThumbnail(
                    playlistID: playlist.id,
                    artworkBase64: playlist.artworkId,
                    size: 24
                )

                Text(playlist.name)
                    .font(.body)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .foregroundStyle(foreground)
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(selectionBackgroundOpacity))
            }
        }
        .help(playlist.name)
        .accessibilityLabel(playlist.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("sidebar.playlist.\(playlist.id)")
        .animation(.easeOut(duration: 0.15), value: appearsActive)
    }
}



private struct SidebarSectionPicker: View {
    @Binding var selection: SidebarSection
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.self) private var environment

    private var selectedForeground: Color {
        guard appearsActive else { return .secondary }

        let accent = Color.accentColor.resolve(in: environment)
        let color = NSColor(
            srgbRed: CGFloat(accent.red),
            green: CGFloat(accent.green),
            blue: CGFloat(accent.blue),
            alpha: CGFloat(accent.opacity)
        )
        // Match yellow by hue, including its light and dark appearance variants.
        let isYellow = (0.12...0.20).contains(color.hueComponent)
            && color.saturationComponent > 0.35
        return isYellow ? .black : .white
    }

    var body: some View {
        // Read the column's allocated width without contributing a label-driven
        // ideal width to NavigationSplitView's sizing negotiations.
        GeometryReader { geometry in
            tabs(availableWidth: max(0, geometry.size.width - 6))
                .padding(3)
        }
        .frame(height: 30)
        .glassEffect(.regular, in: .capsule)
        .animation(.easeOut(duration: 0.15), value: appearsActive)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conteúdo da barra lateral")
        .accessibilityIdentifier("sidebar.sectionPicker")
    }

    private func tabs(availableWidth: CGFloat) -> some View {
        let otherTabsWidth = CGFloat(SidebarSection.allCases.count - 1) * (28 + 3)
        let selectedWidth = max(0, availableWidth - otherTabsWidth)

        return HStack(spacing: 3) {
            ForEach(SidebarSection.allCases) { item in
                Button {
                    selection = item
                } label: {
                    ViewThatFits(in: .horizontal) {
                        if item == selection {
                            // Every tab uses the same fitting threshold, based
                            // on the widest complete label in the current font.
                            ZStack {
                                ForEach(SidebarSection.allCases) { candidate in
                                    HStack(spacing: 5) {
                                        Image(systemName: candidate.icon)
                                        Text(candidate.title)
                                            .lineLimit(1)
                                    }
                                    .opacity(candidate == item ? 1 : 0)
                                    .accessibilityHidden(candidate != item)
                                }
                            }
                            .fixedSize(horizontal: true, vertical: false)
                        }

                        Image(systemName: item.icon)
                    }
                    .foregroundStyle(
                        item == selection
                            ? selectedForeground
                            : Color.secondary
                    )
                    .frame(height: 24)
                    .frame(width: item == selection ? selectedWidth : 28)
                    .contentShape(Rectangle())
                    .background {
                        if item == selection {
                            Capsule()
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
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("sidebar.sectionSearch.container")
                .glassEffect(.regular, in: .rect(cornerRadius: 7))
                .transition(.opacity)

            } else {
                Button {
                    isExpanded = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .regular))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Pesquisar em \(scope)")
                .accessibilityLabel("Pesquisar em \(scope)")
                .accessibilityIdentifier(
                    "sidebar.sectionSearch.toggle"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
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
