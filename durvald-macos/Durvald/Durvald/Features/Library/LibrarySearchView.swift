import SwiftUI

struct LibrarySearchView: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(\.trackMenuNavigation) private var navigation

    @Binding var searchText: String
    @Bindable var search = SearchPresentation<SearchResults>()
    private var committedQuery: String { search.committedQuery }
    private var searchResults: SearchResults? { search.value }
    var submissionRevision: UInt64 = 0
    private var request: SearchRequest {
        .init(query: normalizedSearchText, storeID: ObjectIdentifier(store), coreID: store.core.map(ObjectIdentifier.init),
              metadataRevision: store.metadataRevision, sourceRevision: submissionRevision, scope: "global")
    }

    var body: some View {
        resultsList(searchResults)
            .overlay {
                if normalizedSearchText.isEmpty {
                    ContentUnavailableView(
                        "Pesquisar na biblioteca",
                        systemImage: "magnifyingglass",
                        description: Text("Encontre músicas, álbuns, artistas e playlists.")
                    )
                }
            }
        .accessibilityIdentifier("search.page")
        .task(id: request) {
            let current = request
            await search.run(current, timing: SearchTiming(debounce: .zero, loadingDelay: .zero), isCurrent: { request == current }) {
                await store.searchLibrary(query: $0)
            }
        }
        .onDisappear { search.cancel() }
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resultsList(_ results: SearchResults?) -> some View {
        GeometryReader { visible in
            GeometryReader { canvas in
                let viewport = PageViewport(visibleFrame: visible.frame(in: .global),
                                            canvasFrame: canvas.frame(in: .global))
                ScrollView {
                    VStack(alignment: .leading, spacing: 36) {
                        if let results, !normalizedSearchText.isEmpty, !results.isEmpty || !search.isPending {
                            resultSections(results, viewport: viewport)
                        }
                    }
                    .padding(24)
                    .padding(.leading, viewport.leadingInset)
                    .padding(.trailing, viewport.trailingInset)
                    .frame(maxWidth: .infinity, minHeight: canvas.size.height, alignment: .topLeading)
                }
                .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
                .preservesLibraryScrollPosition(
                    isContentReady: normalizedSearchText.isEmpty
                        || (searchResults != nil && committedQuery == normalizedSearchText)
                )
            }
        }
    }

    @ViewBuilder
    private func resultSections(_ results: SearchResults, viewport: PageViewport) -> some View {
        let artworkSize = min(200, max(120, (viewport.visibleWidth - 112) / 4))
        let trackColumnWidth = min(560, max(280, (viewport.visibleWidth - 72) / 2))
        if !results.artists.isEmpty {
            SearchResultShelf(title: "Artistas", identifier: "artists", viewport: viewport,
                              itemWidth: artworkSize, itemCount: results.artists.count) {
                ForEach(Array(results.artists.enumerated()), id: \.element.id) { index, artist in
                    Button { navigation.artist(artist) } label: {
                        VStack(spacing: 10) {
                            ArtistPortraitView(
                                artist: artist,
                                fallbackArtworkID: results.releases.first {
                                    $0.artistId == artist.id && $0.artworkId != nil
                                }?.artworkId ?? store.releases.first {
                                    $0.artistId == artist.id && $0.artworkId != nil
                                }?.artworkId,
                                size: artworkSize
                            )
                            Text(artist.name)
                                .font(LibraryTypography.listingTitle)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                        }
                        .frame(width: artworkSize, alignment: .top)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Abrir artista \(artist.name)")
                    .accessibilityIdentifier("search.artist.\(artist.id)")
                    .id(SearchShelfBlockID(index: index))
                }
            }
            .id("artists:\(committedQuery)")
        } else {
            emptySection(title: "Artistas", identifier: "artists",
                         message: "Nenhum artista encontrado para esta pesquisa.")
        }

        if !results.releases.isEmpty {
            SearchResultShelf(title: "Álbuns", identifier: "albums", viewport: viewport,
                              itemWidth: artworkSize, itemCount: results.releases.count) {
                ForEach(Array(results.releases.enumerated()), id: \.element.id) { index, release in
                    AlbumCard(release: release, onSelectAlbum: navigation.album,
                              artworkSize: artworkSize)
                        .accessibilityIdentifier("search.release.\(release.id)")
                    .id(SearchShelfBlockID(index: index))
                }
            }
            .id("albums:\(committedQuery)")
        } else {
            emptySection(title: "Álbuns", identifier: "albums",
                         message: "Nenhum álbum encontrado para esta pesquisa.")
        }

        if !results.tracks.isEmpty {
            SearchResultShelf(title: "Faixas", identifier: "tracks", viewport: viewport,
                              itemWidth: trackColumnWidth, itemCount: (results.tracks.count + 2) / 3) {
                ForEach(Array(stride(from: 0, to: results.tracks.count, by: 3)), id: \.self) { start in
                    let end = min(start + 3, results.tracks.count)
                    VStack(spacing: 0) {
                        ForEach(start..<end, id: \.self) { index in
                            trackRow(results.tracks[index])
                                .frame(height: 58)
                                .overlay(alignment: .bottom) {
                                    if index < end - 1 { Divider() }
                                }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(width: trackColumnWidth, height: 174, alignment: .top)
                    .id(SearchShelfBlockID(index: start / 3))
                }
            }
            .id("tracks:\(committedQuery)")
        } else {
            emptySection(title: "Faixas", identifier: "tracks",
                         message: "Nenhuma faixa encontrada para esta pesquisa.")
        }

        if !results.playlists.isEmpty {
            SearchResultShelf(title: "Playlists", identifier: "playlists", viewport: viewport,
                              itemWidth: artworkSize, itemCount: results.playlists.count) {
                ForEach(Array(results.playlists.enumerated()), id: \.element.id) { index, playlist in
                    Button { navigation.playlist(playlist) } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            PlaylistArtworkThumbnail(playlistID: playlist.id,
                                                     artworkBase64: playlist.artworkId,
                                                     size: artworkSize)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(playlist.name)
                                    .font(LibraryTypography.listingTitle)
                                    .lineLimit(1)
                                Text("\(playlist.trackCount) músicas")
                                    .font(LibraryTypography.listingSecondary)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: artworkSize, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .playlistContextMenu(playlist: playlist)
                    .accessibilityLabel("Abrir playlist \(playlist.name)")
                    .accessibilityIdentifier("search.playlist.\(playlist.id)")
                    .id(SearchShelfBlockID(index: index))
                }
            }
            .id("playlists:\(committedQuery)")
        } else {
            emptySection(title: "Playlists", identifier: "playlists",
                         message: "Nenhuma playlist encontrada para esta pesquisa.")
        }
    }

    private func emptySection(title: String, identifier: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title)
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(LibraryTypography.listingSecondary)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("search.section.\(identifier)")
    }

    private func trackRow(_ track: Track) -> some View {
        let model = TrackRowModel(track)
        return HStack(spacing: 10) {
            ArtworkView(artworkID: model.artworkID, size: 42)

            TrackRowText(model: model, showsEmptySubtitle: true)
                .environment(\.playbackSourceContext, PlaybackSourceContext.search(committedQuery))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(model.accessibilityLabel)
            .accessibilityHint("Reproduz esta faixa agora")
            .accessibilityIdentifier("search.track.\(track.id)")

            Button {
                Task { await store.addToQueue(trackID: track.id) }
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(model.enqueueLabel)
            .accessibilityIdentifier("search.track.\(track.id).addToQueue")
        }
        .playTrackOnDoubleClick {
            Task { await TrackRowPlayback.track(track.id, sourceContext: PlaybackSourceContext.search(committedQuery)).perform(using: store) }
        }
        .trackContextMenu(track: track) {
            Task { await TrackRowPlayback.track(track.id, sourceContext: PlaybackSourceContext.search(committedQuery)).perform(using: store) }
        }
    }
}

private extension SearchResults {
    var isEmpty: Bool {
        tracks.isEmpty
            && releases.isEmpty
            && artists.isEmpty
            && playlists.isEmpty
    }
}

/// A distinct ID type keeps column destinations separate from nested track
/// indices and the collection IDs generated by ForEach.
private struct SearchShelfBlockID: Hashable {
    let index: Int
}

/// Keep the heading and controls in the visible column while cards scroll beneath
/// the navigation sidebar and queue, matching the artist page's shelves.
private struct SearchResultShelf<Content: View>: View {
    let title: String
    let identifier: String
    let viewport: PageViewport
    let itemWidth: CGFloat
    let itemCount: Int
    @ViewBuilder let content: () -> Content

    @State private var position = ScrollPosition(idType: SearchShelfBlockID.self)
    @State private var pendingIndex: Int?
    @State private var offset: CGFloat = 0
    @State private var isHovered = false

    private var paging: SearchShelfPaging {
        SearchShelfPaging(itemWidth: itemWidth, itemCount: itemCount, visibleWidth: viewport.visibleWidth)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title)
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: SearchShelfPaging.spacing, content: content)
                    .scrollTargetLayout()
            }
            .scrollPosition($position)
            .scrollIndicators(.hidden)
            .contentMargins(.leading, 24 + viewport.leadingInset, for: .scrollContent)
            .contentMargins(.trailing, 24 + viewport.trailingInset + paging.trailingSlack, for: .scrollContent)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                max(0, geometry.contentOffset.x + geometry.contentInsets.leading)
            } action: { _, newOffset in
                offset = newOffset
            }
            .onScrollPhaseChange { _, phase in
                // A gesture starts from the actual position; repeated button taps
                // continue from the requested block even while animation is running.
                if phase == .tracking || phase == .interacting || phase == .idle {
                    pendingIndex = nil
                }
            }
            .frame(width: viewport.expandedWidth, alignment: .leading)
            .padding(.leading, -24 - viewport.leadingInset)
            .padding(.trailing, -24 - viewport.trailingInset)
            .scrollClipDisabled()
            .overlay {
                HStack {
                    if paging.canScroll(forward: false, offset: offset, pendingIndex: pendingIndex) {
                        scrollButton(forward: false)
                    }
                    Spacer(minLength: 0)
                    if paging.canScroll(forward: true, offset: offset, pendingIndex: pendingIndex) {
                        scrollButton(forward: true)
                    }
                }
                .padding(.horizontal, 8)
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
                .accessibilityHidden(!isHovered)
                .animation(.easeInOut(duration: 0.12), value: isHovered)
            }
        }
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("search.section.\(identifier)")
    }

    private func scrollButton(forward: Bool) -> some View {
        Button {
            let currentIndex = pendingIndex ?? paging.index(at: offset)
            let destination = paging.destination(from: currentIndex, forward: forward)
            pendingIndex = destination
            withAnimation(.easeInOut(duration: 0.25)) {
                position.scrollTo(id: SearchShelfBlockID(index: destination), anchor: .leading)
            }
        } label: {
            Image(systemName: forward ? "chevron.right" : "chevron.left")
                .font(.title2.weight(.semibold))
                .frame(width: 36, height: 64)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel("\(forward ? "Avançar" : "Voltar") em \(title)")
        .accessibilityIdentifier("search.section.\(identifier).\(forward ? "next" : "previous")")
    }
}

/// Page by whole blocks, independent of canvas insets and animated offsets.
struct SearchShelfPaging {
    static let spacing: CGFloat = 24
    let itemWidth: CGFloat
    let itemCount: Int
    let visibleWidth: CGFloat

    var itemsPerPage: Int {
        max(1, Int((max(0, visibleWidth - 48) + Self.spacing) / (itemWidth + Self.spacing)))
    }

    var lastIndex: Int { max(0, itemCount - itemsPerPage) }

    // Let the last page align its first block without clamping between blocks.
    var trailingSlack: CGFloat {
        guard itemCount > itemsPerPage else { return 0 }
        let pageWidth = CGFloat(itemsPerPage) * (itemWidth + Self.spacing) - Self.spacing
        return max(0, visibleWidth - 48 - pageWidth)
    }

    func canScroll(forward: Bool, offset: CGFloat, pendingIndex: Int?) -> Bool {
        guard lastIndex > 0 else { return false }
        if let pendingIndex {
            return forward ? pendingIndex < lastIndex : pendingIndex > 0
        }
        let lastOffset = CGFloat(lastIndex) * (itemWidth + Self.spacing)
        return forward ? offset < lastOffset - 1 : offset > 1
    }

    func index(at offset: CGFloat) -> Int {
        min(lastIndex, max(0, Int((offset / (itemWidth + Self.spacing)).rounded())))
    }

    func destination(from index: Int, forward: Bool) -> Int {
        min(lastIndex, max(0, index + (forward ? itemsPerPage : -itemsPerPage)))
    }
}
