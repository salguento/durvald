import AppKit
import SwiftUI

struct SearchPreviewItem: Identifiable {
    enum Destination {
        case query(String), artist(Artist), album(Release), track(Track), playlist(Playlist)
    }
    let id: String
    let title: String
    let subtitle: String?
    let destination: Destination

    static func build(query: String, results: SearchResults) -> [Self] {
        guard !results.artists.isEmpty || !results.releases.isEmpty
            || !results.tracks.isEmpty || !results.playlists.isEmpty else { return [] }
        let names = results.artists.map(\.name) + results.releases.map(\.title)
            + results.tracks.map(\.title) + results.playlists.map(\.name)
        let terms = suggestedTerms(query: query, names: names)
        return terms.map { Self(id: "query:\($0)", title: $0, subtitle: nil, destination: .query($0)) }
            + results.artists.prefix(3).map { Self(id: "artist:\($0.id)", title: $0.name, subtitle: "Artista", destination: .artist($0)) }
            + results.releases.prefix(1).map { Self(id: "album:\($0.id)", title: $0.title, subtitle: "Álbum · \($0.artist)", destination: .album($0)) }
            + results.tracks.prefix(3).map { Self(id: "track:\($0.id)", title: $0.title, subtitle: "Faixa · \($0.artist)", destination: .track($0)) }
            + results.playlists.prefix(1).map { Self(id: "playlist:\($0.id)", title: $0.name, subtitle: "Playlist · \($0.trackCount) músicas", destination: .playlist($0)) }
    }

    static func suggestedTerms(query: String, names: [String]) -> [String] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        func key(_ value: String) -> String {
            value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        }
        let queryKey = key(query)
        var seen: Set<String> = [queryKey]
        var terms: [String] = []
        for name in names {
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = key(name)
            if normalized.contains(queryKey), seen.insert(normalized).inserted {
                terms.append(name)
                if terms.count == 2 { break }
            }
        }
        return terms + [query]
    }
}

/// Typing loads suggestions; only an explicit submission updates the results page.
struct GlobalSearchField: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Binding var text: String
    @Binding var isFocused: Bool
    @Binding var focusRequest: Int
    @Bindable var search: SearchPresentation<SearchResults>
    var isExecutingSearch = false
    let onSubmit: () -> Void
    let navigation: TrackMenuNavigation
    @State private var dismissedQuery: String?
    @State private var selectedIndex: Int?

    private var query: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var items: [SearchPreviewItem] {
        guard search.committedQuery == query, let results = search.value else { return [] }
        return SearchPreviewItem.build(query: query, results: results)
    }
    private var isPresented: Bool {
        isFocused && !query.isEmpty && !items.isEmpty && !search.isPending && dismissedQuery != query
    }

    private var request: SearchRequest {
        .init(query: query, storeID: ObjectIdentifier(store), coreID: store.core.map(ObjectIdentifier.init),
              metadataRevision: store.metadataRevision, scope: "global.preview")
    }

    private var previewHeight: CGFloat {
        let rows = items.reduce(CGFloat(12)) { $0 + ($1.subtitle == nil ? 34 : 66) }
        let dividers = zip(items, items.dropFirst()).filter { $0.subtitle != nil || $1.subtitle != nil }.count
        return rows + CGFloat(dividers)
    }

    var body: some View {
        ToolbarSearchField(text: $text, isFocused: $isFocused, focusRequest: $focusRequest,
                           placeholder: "Biblioteca", identifier: "search",
                           accessibilityLabel: "Pesquisar na biblioteca",
                           accessory: .reservedClear, focusColor: .accentColor,
                           isLoading: search.isPending || isExecutingSearch, onSubmit: submit)
            .background {
                SearchPreviewAnchor(isPresented: isPresented, contentHeight: previewHeight,
                                    onDismiss: dismiss, onKey: handleKey) {
                    preview.environment(store)
                }
            }
            .task(id: request) {
                let current = request
                await search.run(current, timing: .suggestions, isCurrent: { request == current }) {
                    await store.searchLibrary(query: $0)
                }
            }
            .onDisappear { search.cancel() }
            .onChange(of: text) { _, _ in selectedIndex = nil }
            .onChange(of: search.revision) { _, _ in selectedIndex = nil }
            .onChange(of: focusRequest) { _, _ in dismissedQuery = nil }
            .onChange(of: isFocused) { _, focused in
                if focused { dismissedQuery = nil }
                else { selectedIndex = nil }
            }
    }

    private var preview: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        Button { select(item) } label: {
                            HStack(spacing: 12) {
                                previewArtwork(item)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).font(LibraryTypography.listingTitle)
                                    if let subtitle = item.subtitle {
                                        Text(subtitle).font(LibraryTypography.listingSecondary)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14)
                            .frame(height: item.subtitle == nil ? 34 : 66)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                            .background(selectedIndex == index ? Color.accentColor.opacity(0.18) : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("search.preview.\(item.id)")
                        .id(item.id)
                        .onHover { hovered in if hovered { selectedIndex = index } }
                        if index < items.count - 1, item.subtitle != nil || items[index + 1].subtitle != nil {
                            Divider().padding(.horizontal, 14)
                        }
                    }
                }
                .padding(6)
            }
            .onChange(of: selectedIndex) { _, index in
                if let index, items.indices.contains(index) { proxy.scrollTo(items[index].id) }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.separator, lineWidth: 0.5) }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("search.preview")
    }

    @ViewBuilder
    private func previewArtwork(_ item: SearchPreviewItem) -> some View {
        switch item.destination {
        case .query:
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).frame(width: 20)
        case .artist(let artist):
            ArtistPortraitView(artist: artist,
                               fallbackArtworkID: store.releases.first { $0.artistId == artist.id }?.artworkId,
                               size: 46)
        case .album(let album): ArtworkView(artworkID: album.artworkId, size: 46)
        case .track(let track): ArtworkView(artworkID: track.artworkId, size: 46)
        case .playlist(let playlist):
            PlaylistArtworkThumbnail(playlistID: playlist.id, artworkBase64: playlist.artworkId, size: 46)
        }
    }

    private func dismiss() { dismissedQuery = query; selectedIndex = nil }

    private func select(_ item: SearchPreviewItem) {
        switch item.destination {
        case .query(let term):
            text = term
            dismissedQuery = term
            selectedIndex = nil
        case .artist(let artist): dismiss(); navigation.artist(artist)
        case .album(let album): dismiss(); navigation.album(album)
        case .playlist(let playlist): dismiss(); navigation.playlist(playlist)
        case .track(let track):
            dismiss()
            Task { await TrackRowPlayback.track(track.id).perform(using: store) }
        }
    }

    private func submit() {
        dismiss()
        onSubmit()
    }

    private func handleKey(_ key: UInt16) -> Bool {
        switch key {
        case 53: dismiss(); return true
        case 125, 126:
            guard !items.isEmpty else { return true }
            let first = key == 125 ? 0 : items.count - 1
            selectedIndex = selectedIndex.map { min(items.count - 1, max(0, $0 + (key == 125 ? 1 : -1))) } ?? first
            return true
        case 36, 76:
            if let index = selectedIndex, items.indices.contains(index) {
                select(items[index])
                if case .query = items[index].destination { onSubmit() }
            } else { submit() }
            return true
        default: return false
        }
    }
}
