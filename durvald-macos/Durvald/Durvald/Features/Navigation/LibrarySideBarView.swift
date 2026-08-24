import SwiftUI

struct LibrarySidebarView: View {
    @EnvironmentObject private var store: DurvaldCoreStore

    @Binding var section: SidebarSection
    @Binding var searchText: String
    @Binding var destination: LibraryDestination?

    var body: some View {
        VStack(spacing: 0) {
            Picker("Conteúdo da barra lateral", selection: $section) {
                ForEach(SidebarSection.allCases) { item in
                    Label(item.title, systemImage: item.icon)
                        .labelStyle(.iconOnly)
                        .tag(item)
                        .help(item.title)
                        .accessibilityIdentifier("sidebar.section.\(item.rawValue)")
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .accessibilityLabel("Conteúdo da barra lateral")
            .accessibilityIdentifier("sidebar.sectionPicker")

            SidebarSearchField(text: $searchText)
                .padding(.horizontal, 10)
                .padding(.top, 12)
                .padding(.bottom, 10)

            Divider()

            Group {
                if normalizedQuery.isEmpty {
                    selectedSectionContent
                } else {
                    searchResults
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var selectedSectionContent: some View {
        switch section {
        case .navigation:
            List(LibraryDestination.allCases, selection: $destination) { item in
                Label(item.title, systemImage: item.icon)
                    .tag(item)
                    .accessibilityIdentifier("sidebar.\(item.rawValue)")
            }
            .listStyle(.sidebar)

        case .playlists:
            List(store.playlists, id: \.id) { playlist in
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
            List(store.releases, id: \.id) { album in
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
            List(store.artists, id: \.id) { artist in
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

    @ViewBuilder
    private var searchResults: some View {
        if filteredTracks.isEmpty,
           filteredAlbums.isEmpty,
           filteredArtists.isEmpty,
           filteredPlaylists.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Nenhum resultado")
                    .font(.headline)
                Text("Não encontramos “\(normalizedQuery)”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            List {
                if !filteredTracks.isEmpty {
                    Section("Músicas") {
                        ForEach(filteredTracks, id: \.id) { track in
                            Button {
                                destination = .songs
                                Task { await store.play(trackID: track.id) }
                            } label: {
                                SidebarItemLabel(
                                    title: track.title,
                                    subtitle: track.artist,
                                    systemImage: "music.note"
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !filteredAlbums.isEmpty {
                    Section("Álbuns") {
                        ForEach(filteredAlbums, id: \.id) { album in
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
                    }
                }

                if !filteredArtists.isEmpty {
                    Section("Artistas") {
                        ForEach(filteredArtists, id: \.id) { artist in
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
                    }
                }

                if !filteredPlaylists.isEmpty {
                    Section("Playlists") {
                        ForEach(filteredPlaylists, id: \.id) { playlist in
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
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var normalizedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredTracks: [Track] {
        store.tracks.filter {
            matches([$0.title, $0.artist, $0.release])
        }
    }

    private var filteredAlbums: [Release] {
        store.releases.filter {
            matches([$0.title, $0.artist])
        }
    }

    private var filteredArtists: [Artist] {
        store.artists.filter {
            matches([$0.name])
        }
    }

    private var filteredPlaylists: [Playlist] {
        store.playlists.filter {
            matches([$0.name])
        }
    }

    private func matches(_ values: [String]) -> Bool {
        values.contains {
            $0.localizedCaseInsensitiveContains(normalizedQuery)
        }
    }
}

private struct SidebarSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Pesquisa", text: $text)
                .textFieldStyle(.plain)
                .accessibilityLabel("Pesquisar em toda a biblioteca")
                .accessibilityIdentifier("sidebar.search")

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Limpar pesquisa")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct SidebarItemLabel: View {
    let title: String
    let subtitle: String?
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .frame(width: 16)
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
