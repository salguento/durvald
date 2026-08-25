import SwiftUI

struct LibrarySidebarView: View {
    @EnvironmentObject private var store: DurvaldCoreStore

    @Binding var section: SidebarSection
    @Binding var destination: LibraryDestination?

    @State private var isLocalSearchExpanded = false
    @State private var localSearchText = ""
    @State private var committedLocalQuery = ""

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
                .padding(.top, 12)
            }

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
            List(localAlbums, id: \.id) { album in
                Button {
                    destination = .albums
                } label: {
                    SidebarItemLabel(
                        title: album.title,
                        subtitle: album.artist,
                        systemImage: "square.stack"
                    )
                }
                .buttonStyle(.plain)
            }
            .listStyle(.sidebar)

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
    let item: LibraryDestination

    @Binding var selection: LibraryDestination?

    let accessibilityIdentifier: String

    @State private var isHovered = false

    private var isSelected: Bool {
        selection == item
    }

    private var backgroundColor: Color {
        if isSelected {
            return .accentColor
        }

        return isHovered
            ? Color.primary.opacity(0.08)
            : .clear
    }

    var body: some View {
        Button {
            selection = item
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.icon)
                    .frame(width: 18)

                Text(item.title)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .foregroundStyle(
                isSelected ? Color.white : Color.primary
            )
            .padding(.horizontal, 8)
            .frame(
                maxWidth: .infinity,
                minHeight: 30,
                alignment: .leading
            )
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(backgroundColor)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .help(item.title)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(
            isSelected ? .isSelected : []
        )
        .accessibilityIdentifier(accessibilityIdentifier)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

private struct SidebarSectionPicker: View {
    @Binding var selection: SidebarSection

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
                            ? Color.white
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
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.accentColor)
                                .shadow(
                                    color: Color.accentColor.opacity(0.24),
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
            in: RoundedRectangle(cornerRadius: 8)
        )
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
                        .frame(width: 18)
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
                    minHeight: 30,
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
                            .frame(width: 18)
                            .foregroundStyle(.secondary)

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: 30,
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
