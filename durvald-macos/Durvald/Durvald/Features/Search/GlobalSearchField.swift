import AppKit
import SwiftUI

/// Persist only submitted terms, newest first, independently of preview requests.
enum RecentSearchHistory {
    static let storageKey = "search.recentQueries"
    static let limit = 10

    static func terms(in json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return normalized(values)
    }

    static func record(_ term: String, in json: String) -> String {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return json }
        let values = normalized([term] + terms(in: json))
        guard let data = try? JSONEncoder().encode(values) else { return json }
        return String(decoding: data, as: UTF8.self)
    }

    private static func normalized(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        return Array(terms.compactMap { term -> String? in
            let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = term.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard !term.isEmpty, seen.insert(key).inserted else { return nil }
            return term
        }.prefix(limit))
    }
}

struct SearchPreviewItem: Identifiable {
    enum Destination {
        case recentQuery(String), query(String), artist(Artist), album(Release), track(Track), playlist(Playlist)
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

/// Insets leave the selection clear of the panel edge and row separators.
private enum SearchPreviewStyle {
    static let outerInset: CGFloat = 5
    static let contentInset: CGFloat = 11
    static let contentSpacing: CGFloat = 8
    static let artworkSize: CGFloat = 46
    static let queryHeight: CGFloat = 24
    static let resultHeight: CGFloat = 52
    static let resultInset: CGFloat = 5
    static let sectionGap: CGFloat = 5
    static let cornerRadius: CGFloat = 12
}

/// Typing loads suggestions; only an explicit submission updates the results page.
struct GlobalSearchField: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Binding var text: String
    @Binding var isFocused: Bool
    @Binding var focusRequest: Int
    @Bindable var search: SearchPresentation<SearchResults>
    var isExecutingSearch = false
    var recentQueries: [String] = []
    let onSubmit: () -> Void
    let navigation: TrackMenuNavigation
    @State private var dismissedQuery: String?
    @State private var selectedIndex: Int?
    @State private var showsRecentSearches = false
    @State private var selectionFocusRequest: Int?

    private var query: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isShowingHistory: Bool {
        (query.isEmpty || showsRecentSearches) && !recentQueries.isEmpty
    }
    private var items: [SearchPreviewItem] {
        if isShowingHistory {
            return recentQueries.map {
                SearchPreviewItem(id: "recent:\($0)", title: $0, subtitle: nil, destination: .recentQuery($0))
            }
        }
        guard search.committedQuery == query, let results = search.value else { return [] }
        return SearchPreviewItem.build(query: query, results: results)
    }
    private var isPresented: Bool {
        isFocused && !items.isEmpty && (isShowingHistory || !search.isPending) && dismissedQuery != query
    }

    private var request: SearchRequest {
        .init(query: query, storeID: ObjectIdentifier(store), coreID: store.core.map(ObjectIdentifier.init),
              metadataRevision: store.metadataRevision, scope: "global.preview")
    }

    private var previewHeight: CGFloat {
        let rows = items.reduce(2 * SearchPreviewStyle.outerInset) { height, item in
            height + (item.subtitle == nil ? SearchPreviewStyle.queryHeight
                : SearchPreviewStyle.resultHeight + 2 * SearchPreviewStyle.resultInset)
        }
        let separators = zip(items, items.dropFirst()).reduce(CGFloat.zero) { height, pair in
            guard pair.0.subtitle != nil || pair.1.subtitle != nil else { return height }
            return height + 1 + (pair.0.subtitle == nil ? SearchPreviewStyle.sectionGap : 0)
        }
        return rows + separators + (isShowingHistory ? 28 : 0)
    }

    var body: some View {
        ToolbarSearchField(text: $text, isFocused: $isFocused, focusRequest: $focusRequest,
                           placeholder: "Pesquisar músicas", identifier: "search",
                           accessibilityLabel: "Pesquisar músicas",
                           accessory: .reservedClear, focusColor: .accentColor,
                           isLoading: search.isPending || isExecutingSearch, onSubmit: submit,
                           clearsOnEscape: true)
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
            .onChange(of: text) { _, _ in
                selectedIndex = nil
                showsRecentSearches = query.isEmpty
            }
            .onChange(of: search.revision) { _, _ in selectedIndex = nil }
            .onChange(of: focusRequest) { _, request in
                if request == selectionFocusRequest {
                    selectionFocusRequest = nil
                    return
                }
                dismissedQuery = nil
                showsRecentSearches = true
                selectedIndex = nil
            }
            .onChange(of: isFocused) { _, focused in
                if focused { dismissedQuery = nil; showsRecentSearches = true }
                else { selectedIndex = nil }
            }
    }

    private var preview: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    if isShowingHistory {
                        Text("Pesquisas recentes")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, SearchPreviewStyle.contentInset)
                            .frame(height: 28)
                    }
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        let isSelected = selectedIndex == index
                        Button { select(item) } label: {
                            HStack(spacing: SearchPreviewStyle.contentSpacing) {
                                previewArtwork(item, isSelected: isSelected)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).font(LibraryTypography.listingTitle)
                                    if let subtitle = item.subtitle {
                                        Text(subtitle).font(LibraryTypography.listingSecondary)
                                            .foregroundStyle(isSelected ? Color.white : Color.secondary)
                                    }
                                }
                                .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, SearchPreviewStyle.contentInset)
                            .frame(height: item.subtitle == nil ? SearchPreviewStyle.queryHeight : SearchPreviewStyle.resultHeight)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                            .background(isSelected ? Color.accentColor : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .padding(.vertical, item.subtitle == nil ? 0 : SearchPreviewStyle.resultInset)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("search.preview.\(item.id)")
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                        .id(item.id)
                        .onHover { hovered in if hovered { selectedIndex = index } }
                        if index < items.count - 1, item.subtitle != nil || items[index + 1].subtitle != nil {
                            Divider()
                                .padding(.horizontal, SearchPreviewStyle.contentInset)
                                .padding(.top, item.subtitle == nil ? SearchPreviewStyle.sectionGap : 0)
                        }
                    }
                }
                .padding(SearchPreviewStyle.outerInset)
            }
            .onChange(of: selectedIndex) { _, index in
                if let index, items.indices.contains(index) { proxy.scrollTo(items[index].id) }
            }
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: SearchPreviewStyle.cornerRadius))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("search.preview")
    }

    @ViewBuilder
    private func previewArtwork(_ item: SearchPreviewItem, isSelected: Bool) -> some View {
        switch item.destination {
        case .recentQuery:
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(isSelected ? Color.white : Color.secondary).frame(width: 14)
        case .query:
            Image(systemName: "magnifyingglass")
                .foregroundStyle(isSelected ? Color.white : Color.secondary).frame(width: 14)
        case .artist(let artist):
            ArtistPortraitView(artist: artist,
                               fallbackArtworkID: store.releases.first { $0.artistId == artist.id }?.artworkId,
                               size: SearchPreviewStyle.artworkSize)
        case .album(let album): ArtworkView(artworkID: album.artworkId, size: SearchPreviewStyle.artworkSize)
        case .track(let track): ArtworkView(artworkID: track.artworkId, size: SearchPreviewStyle.artworkSize)
        case .playlist(let playlist):
            PlaylistArtworkThumbnail(playlistID: playlist.id, artworkBase64: playlist.artworkId, size: SearchPreviewStyle.artworkSize)
        }
    }

    private func dismiss() { dismissedQuery = query; selectedIndex = nil }

    private func select(_ item: SearchPreviewItem) {
        switch item.destination {
        case .recentQuery(let term):
            replaceQuery(term)
            dismissedQuery = term
            selectedIndex = nil
            onSubmit()
        case .query(let term):
            replaceQuery(term)
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

    private func replaceQuery(_ term: String) {
        text = term
        showsRecentSearches = false
        // An explicit edit also updates AppKit's active field editor. Keep
        // this request from reopening history immediately after a selection.
        focusRequest &+= 1
        selectionFocusRequest = focusRequest
    }

    private func submit() {
        dismiss()
        onSubmit()
    }

    private func handleKey(_ key: UInt16) -> Bool {
        switch key {
        // Let the native editor clear first and resign focus only when empty.
        case 53: return false
        case 125, 126:
            guard !items.isEmpty else { return true }
            let first = key == 125 ? 0 : items.count - 1
            selectedIndex = selectedIndex.map { min(items.count - 1, max(0, $0 + (key == 125 ? 1 : -1))) } ?? first
            return true
        case 36, 76:
            if let index = selectedIndex, items.indices.contains(index) {
                let item = items[index]
                select(item)
                if case .query = item.destination { onSubmit() }
            } else { submit() }
            return true
        default: return false
        }
    }
}
