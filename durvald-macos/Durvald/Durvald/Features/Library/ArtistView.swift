import SwiftUI

@Observable
final class ArtistToolbarState {
    var searchText = ""
    var order: ArtistTrackOrder = .album
    var tracks: [Track] = []
    var isLoading = true
}

enum ArtistTrackOrder: String, CaseIterable, Identifiable {
    case album
    case title
    case artist
    case duration

    var id: Self { self }

    var title: String {
        switch self {
        case .album: "Álbum"
        case .title: "Título"
        case .artist: "Artista"
        case .duration: "Duração"
        }
    }
}

struct ArtistView: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("followedArtistIDs") private var followedArtistIDs = ""
    @AppStorage("favoriteArtistIDs") private var favoriteArtistIDs = ""

    let artist: Artist
    let onSelectAlbum: (Release) -> Void
    let onSelectExternalRelease: (ExternalReleaseGroup) -> Void
    var onSelectArtist: ((Artist) -> Void)? = nil
    var informationOnly = false
    @Bindable var toolbarState = ArtistToolbarState()

    @State private var presentation = ArtistPresentation()

    private var lookupRevision: UInt64 {
        get { presentation.lookupRevision }
        nonmutating set { presentation.lookupRevision = newValue }
    }
    private var lookups: PreparedLibraryListing<ArtistLookupSnapshot> {
        get { presentation.lookups }
        nonmutating set { presentation.lookups = newValue }
    }
    private var tracks: [Track] {
        get { presentation.tracks }
        nonmutating set { presentation.tracks = newValue }
    }
    private var albums: [Release] {
        get { presentation.albums }
        nonmutating set { presentation.albums = newValue }
    }
    private var details: ArtistDetails? {
        get { presentation.details }
        nonmutating set { presentation.details = newValue }
    }
    private var identity: ArtistIdentity? {
        get { presentation.identity }
        nonmutating set { presentation.identity = newValue }
    }
    private var identityCandidates: ArtistIdentityCandidates? {
        get { presentation.identityCandidates }
        nonmutating set { presentation.identityCandidates = newValue }
    }
    private var discographyItems: [ExternalReleaseGroup] {
        get { presentation.discographyItems }
        nonmutating set { presentation.discographyItems = newValue }
    }
    private var latestRelease: ExternalReleaseGroup? {
        get { presentation.latestRelease }
        nonmutating set { presentation.latestRelease = newValue }
    }
    private var discographyPageRevision: UInt64 {
        get { presentation.discographyPageRevision }
        nonmutating set { presentation.discographyPageRevision = newValue }
    }
    private var discographyPage: ArtistDiscographyPage? {
        get { presentation.discographyPage }
        nonmutating set { presentation.discographyPage = newValue }
    }
    private var popularTracks: ArtistPopularTracks? {
        get { presentation.popularTracks }
        nonmutating set { presentation.popularTracks = newValue }
    }
    private var popularTrackArtworkIDs: [String: String] {
        get { presentation.popularTrackArtworkIDs }
        nonmutating set { presentation.popularTrackArtworkIDs = newValue }
    }
    private var popularTrackReleaseGroupIDs: [String: String] {
        get { presentation.popularTrackReleaseGroupIDs }
        nonmutating set { presentation.popularTrackReleaseGroupIDs = newValue }
    }
    private var releaseDetailsByGroupID: [String: ExternalReleaseDetails] {
        get { presentation.releaseDetailsByGroupID }
        nonmutating set { presentation.releaseDetailsByGroupID = newValue }
    }
    private var isCachingReleaseTracks: Bool {
        get { presentation.isCachingReleaseTracks }
        nonmutating set { presentation.isCachingReleaseTracks = newValue }
    }
    private var similarArtistArtworkIDs: [Int64: String] {
        get { presentation.similarArtistArtworkIDs }
        nonmutating set { presentation.similarArtistArtworkIDs = newValue }
    }
    private var catalogRefreshResults: [ArtistRefreshSectionResult] {
        get { presentation.catalogRefreshResults }
        nonmutating set { presentation.catalogRefreshResults = newValue }
    }
    private var isRefreshingCatalog: Bool {
        get { presentation.isRefreshingCatalog }
        nonmutating set { presentation.isRefreshingCatalog = newValue }
    }
    private var isLoadingMoreDiscography: Bool {
        get { presentation.isLoadingMoreDiscography }
        nonmutating set { presentation.isLoadingMoreDiscography = newValue }
    }
    private var isIdentityPickerPresented: Bool {
        get { presentation.isIdentityPickerPresented }
        nonmutating set { presentation.isIdentityPickerPresented = newValue }
    }
    private var isLoadingIdentityCandidates: Bool {
        get { presentation.isLoadingIdentityCandidates }
        nonmutating set { presentation.isLoadingIdentityCandidates = newValue }
    }
    private var isSavingIdentity: Bool {
        get { presentation.isSavingIdentity }
        nonmutating set { presentation.isSavingIdentity = newValue }
    }
    private var selectedCandidateID: String? {
        get { presentation.selectedCandidateID }
        nonmutating set { presentation.selectedCandidateID = newValue }
    }
    private var isLoading: Bool {
        get { presentation.isLoading }
        nonmutating set { presentation.isLoading = newValue }
    }

    @State private var isClearIdentityConfirmationPresented = false
    @State private var identitySheetHeight: CGFloat = 500
    @State private var isIdentityPopoverPresented = false
    @State private var isTopbarHovered = false
    @State private var isArtistScrolled = false
    @State private var artworkAverageColor: NSColor?
    @ScaledMetric(relativeTo: .largeTitle) private var artistNameFontSize =
        NSFont.preferredFont(forTextStyle: .largeTitle).pointSize * 1.275 * 1.35
    private let headerActionSize: CGFloat = 48
    private let headerPlaySize: CGFloat = 72

    private var artistRequest: ArtistPresentation.Request {
        .init(artistID: artist.id, coreID: store.core.map(ObjectIdentifier.init), language: enrichmentLanguage)
    }

    private var lookupKey: LibraryListingKey {
        LibraryListingKey(storeID: ObjectIdentifier(store), payloadRevision: lookupRevision, scope: String(artist.id))
    }

    private var artistArtworkID: String? {
        ArtistPresentationPolicy.portraitArtworkID(
            portrait: details?.portrait,
            localArtworkIDs: albums.map(\.artworkId)
                + discographyItems.map { $0.artwork?.image.managedPath }
        )
    }

    private var pageBackgroundColor: Color {
        let baseColor = NSColor.windowBackgroundColor
        guard let artworkAverageColor else { return Color(nsColor: baseColor) }

        // Keep enough of the system background to preserve contrast while
        // tinting the page with the portrait's own palette.
        let tintAmount = colorScheme == .dark ? 0.52 : 0.28
        return Color(
            nsColor: baseColor.blended(
                withFraction: tintAmount,
                of: artworkAverageColor
            ) ?? baseColor
        )
    }

    var body: some View {
        if informationOnly {
            Group {
                if let identity {
                    identityInformationPopover(identity)
                } else {
                    ContentUnavailableView("Informações do artista indisponíveis", systemImage: "person.crop.rectangle")
                }
            }
            .task(id: artistRequest) {
                await presentation.load(artistID: artist.id, using: store,
                                        language: enrichmentLanguage, informationOnly: true)
            }
            .sheet(isPresented: $presentation.isIdentityPickerPresented) { identityPicker }
        } else {
            artistPage
        }
    }

    private var pageChrome: PageChromePolicy {
        PageChromePolicy(kind: .artist, queuePresented: false,
                         scrolled: isArtistScrolled, hovered: isTopbarHovered)
    }

    private var artistPage: some View {
        GeometryReader { chrome in
            artistPage(topbarInset: chrome.safeAreaInsets.top)
        }
    }

    private func artistPage(topbarInset: CGFloat) -> some View {
        GeometryReader { visible in
            GeometryReader { geometry in
                let viewport = PageViewport(visibleFrame: visible.frame(in: .global),
                                            canvasFrame: geometry.frame(in: .global))
                let sideInsets = viewport.sideInsets
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        artistHeaderArtwork(width: viewport.visibleWidth)
                        .backgroundExtensionEffect()
                        .overlay {
                            GeometryReader { header in
                                VStack(spacing: 20) {
                                    Text(artist.name)
                                        .font(.system(size: artistNameFontSize, weight: .bold))
                                        .multilineTextAlignment(.center)
                                        .foregroundStyle(.white)
                                        .accessibilityAddTraits(.isHeader)

                                    collectionControls(availableWidth: max(1, visible.size.width - 48))
                                }
                                .frame(width: max(1, visible.size.width - 48))
                                .padding(.bottom, max(24, header.size.height * 0.06))
                                .frame(width: visible.size.width, height: header.size.height,
                                       alignment: .bottom)
                            }
                        }
                        .padding(.trailing, sideInsets.trailing)
                        .accessibilityIdentifier("artist.header.\(artist.id)")

                        VStack(alignment: .leading, spacing: 24) {
                            artistHighlights(viewport: viewport)

                            discographySections(viewport: viewport)

                            if isLoading {
                                ProgressView("Carregando artista…")
                                    .frame(maxWidth: .infinity, alignment: .center)
                            } else if albums.isEmpty && tracks.isEmpty && onlineOnlyReleases.isEmpty {
                                ContentUnavailableView(
                                    "Nenhuma música disponível",
                                    systemImage: "music.mic",
                                    description: Text("Este artista ainda não possui músicas na biblioteca.")
                                )
                            }
                        }
                        .padding(24)
                        .padding(.leading, sideInsets.leading)
                        .padding(.trailing, sideInsets.trailing)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        artistFooter(viewport: viewport)
                            .padding(.leading, sideInsets.leading)
                            .padding(.trailing, sideInsets.trailing)
                    }
                    .frame(minHeight: geometry.size.height, alignment: .top)
                    .background(pageBackgroundColor)
                }
                // Measure before extending the page under the titlebar. Only the
                // indicator is inset; the portrait and scroll offsets stay intact.
                .contentMargins(.top, topbarInset, for: .scrollIndicators)
                .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
                .scrollEdgeEffectHidden(pageChrome.hidesTopScrollEdge, for: .top)
                .onScrollGeometryChange(for: Bool.self) {
                    PageChromePolicy.isScrolled(offset: $0.contentOffset.y + $0.contentInsets.top)
                } action: { _, scrolled in
                    isArtistScrolled = scrolled
                }
                .preservesLibraryScrollPosition(isContentReady: !isLoading)
            }
            // Preserve both sidebars' safe areas. Only the header's reflected
            // background extends beneath them; the portrait stays in the visible column.
            .ignoresSafeArea(.container, edges: pageChrome.canvasSafeAreaEdges)
        }
        .ignoresSafeArea(.container, edges: pageChrome.visibleSafeAreaEdges)
        .background {
            TopbarHoverObserver(isHovered: $isTopbarHovered)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .preference(
            key: PageToolbarBackgroundPreferenceKey.self,
            value: pageChrome.toolbarVisibility
        )
        .onChange(of: tracks, initial: true) { _, value in
            toolbarState.tracks = value
        }
        .onChange(of: isLoading, initial: true) { _, value in
            toolbarState.isLoading = value
        }
        .task(id: lookupKey) {
            await presentation.prepareLookups()
        }
        .task(id: store.metadataRevision) {
            guard store.metadataRevision > 0 else { return }
            await presentation.refreshLocalLibrary(using: store, artistID: artist.id)
        }
        .task(id: artistRequest) {
            artworkAverageColor = nil
            await presentation.load(artistID: artist.id, using: store, language: enrichmentLanguage)
        }
        .task(id: discographyPageRevision) {
            await presentation.loadLatestRelease()
        }
        .sheet(isPresented: $presentation.isIdentityPickerPresented) {
            identityPicker
        }
        .sheet(isPresented: $isIdentityPopoverPresented) {
            if let identity {
                identityInformationPopover(identity)
                    .frame(width: 500, height: identitySheetHeight)
            }
        }
        .onChange(of: store.releasesRevision) { _, _ in
            presentation.reconcileReleases(using: store)
        }
        .onChange(of: store.isUpdatingLibraryMetadata) { wasUpdating, isUpdating in
            guard wasUpdating, !isUpdating else { return }
            Task {
                await reloadCachedEnrichment()
                await cacheReleaseTracksAndResolvePopularArtwork()
            }
        }
        .accessibilityIdentifier("artist.detail.\(artist.id)")
    }

    private func artistHeaderArtwork(width: CGFloat) -> some View {
        ZStack {
            colorSamplingHeaderArtwork(width: width)

            // Blur only the lower portion of the portrait. The mask starts near
            // the artist title so the sharp image dissolves gradually instead
            // of switching to a uniformly blurred layer.
            headerArtwork(width: width)
                .blur(radius: 30, opaque: true)
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.48),
                            .init(color: .black.opacity(0.35), location: 0.62),
                            .init(color: .black, location: 0.82)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }

            // Finish with the exact page background color, keeping the join
            // below the header seamless in both light and dark appearances.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.50),
                    .init(color: pageBackgroundColor.opacity(0.18), location: 0.63),
                    .init(color: pageBackgroundColor.opacity(0.72), location: 0.84),
                    .init(color: pageBackgroundColor, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .frame(width: width, height: width / 1.4)
        .clipped()
    }

    private func headerArtwork(width: CGFloat) -> some View {
        ArtworkView(
            artworkID: artistArtworkID,
            size: width,
            aspectRatio: 1.4,
            alignment: .top,
            showsBorder: false
        )
    }

    private func colorSamplingHeaderArtwork(width: CGFloat) -> some View {
        ArtworkView(
            artworkID: artistArtworkID,
            size: width,
            aspectRatio: 1.4,
            alignment: .top,
            showsBorder: false,
            onLowerRegionColorLoaded: { color in
                captureBackgroundColor(color)
            }
        )
    }

    private func captureBackgroundColor(_ averageColor: NSColor?) {
        withAnimation(.easeInOut(duration: 0.45)) {
            artworkAverageColor = averageColor
        }
    }

    private func identityInformationPopover(_ identity: ArtistIdentity) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ZStack(alignment: .bottomLeading) {
                    ArtworkView(
                        artworkID: artistArtworkID,
                        size: 500,
                        aspectRatio: 1,
                        alignment: .top,
                        showsBorder: false
                    )

                    LinearGradient(
                        colors: [.clear, .black.opacity(0.72)],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                    .allowsHitTesting(false)

                    Text(artist.name)
                        .font(.largeTitle.bold())
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 500, height: 500)
                .clipped()
                .padding(.horizontal, -20)
                .padding(.top, -20)

                HStack(alignment: .top, spacing: 24) {
                    artistInformationColumn(
                        title: "Origem",
                        value: artistOriginInformation
                    )
                    artistInformationColumn(
                        title: "Nascimento",
                        value: artistBirthInformation
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                artistInformationColumn(
                    title: "Gêneros",
                    value: artistGenresInformation
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Sobre")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                        .accessibilityAddTraits(.isHeader)

                    if let biography = biographyText {
                        Text(biography)
                            .foregroundStyle(.white)

                        if biographyOverride == nil,
                           let biographySource,
                           let sourceURL = URL(string: biographySource.profile.attribution.sourceUrl) {
                            Link("Fonte: \(biographySourceName)", destination: sourceURL)
                                .font(.caption)
                        }
                    } else {
                        Text("Informações biográficas ainda não disponíveis.")
                            .foregroundStyle(.white.opacity(0.8))
                            .italic()
                    }
                }

                Divider()

                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: identity.status == .resolved
                          ? "checkmark.seal.fill"
                          : "person.crop.circle.badge.questionmark")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(identityCalloutTitle(for: identity))
                            .font(.headline)
                        Text(identityCalloutDescription(for: identity))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    identityInformationRow(
                        "MusicBrainz ID",
                        value: identity.musicbrainzId ?? identity.confirmedMusicbrainzId ?? "Não vinculado",
                        monospaced: true
                    )
                    identityInformationRow("Origem", value: identityOriginLabel(identity.origin))
                    identityInformationRow("Geração", value: String(identity.generation))
                }

                if identity.conflictingTags {
                    Label(
                        "As faixas possuem identificadores MusicBrainz conflitantes.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                }

                if identity.status == .resolved {
                    HStack(spacing: 12) {
                        Button {
                            Task { await refreshEnrichment(force: true) }
                        } label: {
                            if isRefreshingCatalog {
                                HStack(spacing: 7) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Atualizando…")
                                }
                            } else {
                                Label("Atualizar metadados", systemImage: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isRefreshingCatalog || isSavingIdentity)
                        .accessibilityIdentifier("artist.enrichment.refresh")

                        Button("Remover vínculo…", role: .destructive) {
                            isClearIdentityConfirmationPresented = true
                        }
                        .disabled(isSavingIdentity || isRefreshingCatalog)
                    }
                } else {
                    Button("Escolher identidade…") {
                        isIdentityPopoverPresented = false
                        Task { @MainActor in
                            await Task.yield()
                            presentIdentityPicker()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }

                if !catalogRefreshResults.isEmpty || isRefreshingCatalog {
                    Divider()
                    enrichmentDiagnostics
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
        .overlay(alignment: .topTrailing) {
            Button {
                if informationOnly { dismiss() }
                else { isIdentityPopoverPresented = false }
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 28, height: 28)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .background(.regularMaterial, in: .circle)
            .padding(12)
            .accessibilityLabel("Fechar informações")
        }
        .confirmationDialog(
            "Remover a identidade de \(artist.name)?",
            isPresented: $isClearIdentityConfirmationPresented
        ) {
            Button("Remover vínculo", role: .destructive) {
                Task { await clearIdentity() }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Os dados enriquecidos associados serão ocultados até que outra identidade seja confirmada.")
        }
        .accessibilityIdentifier("artist.identity.information")
    }

    private var artistFactsProfile: ArtistProfile? {
        details?.sources.first(where: { $0.provider == .wikidata })?.profile
    }

    private var artistOriginInformation: String {
        overriddenText(.birthPlace, fallback: artistFactsProfile?.birthPlace)
            ?? overriddenText(.formationPlace, fallback: artistFactsProfile?.formationPlace)
            ?? overriddenText(.originPlace, fallback: artistFactsProfile?.originPlace)
            ?? "Não disponível"
    }

    private var artistBirthInformation: String {
        guard let date = overriddenDate(.birthDate, fallback: artistFactsProfile?.birthDate) else {
            return "Não disponível"
        }
        return formatted(date)
    }

    private var artistGenresInformation: String {
        var knownGenres = Set<String>()
        let genres = albums.flatMap(\.genres).compactMap { genre -> String? in
            let normalized = genre.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty,
                  knownGenres.insert(normalized.lowercased()).inserted else {
                return nil
            }
            return normalized
        }
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        return genres.isEmpty ? "Não disponível" : genres.joined(separator: ", ")
    }

    private func artistInformationColumn(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Color.secondary.opacity(0.7))
            Text(value)
                .font(.body)
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func identityInformationRow(
        _ title: String,
        value: String,
        monospaced: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .body)
                .textSelection(.enabled)
        }
    }

    private var identityPicker: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Escolha o resultado do MusicBrainz que representa \(artist.name). A confirmação define qual perfil, discografia e capas serão usados.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if identity?.status == .resolved, let musicbrainzID = identity?.musicbrainzId {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Identidade confirmada", systemImage: "checkmark.seal.fill")
                            .font(.headline)
                            .foregroundStyle(Color.accentColor)
                        Text(musicbrainzID)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Button("Remover vínculo…", role: .destructive) {
                            isClearIdentityConfirmationPresented = true
                        }
                        .disabled(isSavingIdentity)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(.quaternary, in: .rect(cornerRadius: 10))
                } else if isLoadingIdentityCandidates {
                    Spacer()
                    ProgressView("Buscando candidatos no MusicBrainz…")
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else if let identityCandidates {
                    if let message = identityLookupMessage(identityCandidates) {
                        Label(message, systemImage: identityLookupIcon(identityCandidates.lookupStatus))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if identityCandidates.candidates.isEmpty {
                        ContentUnavailableView(
                            "Nenhum candidato disponível",
                            systemImage: "person.crop.circle.badge.xmark",
                            description: Text(emptyCandidatesDescription(identityCandidates))
                        )
                        .frame(maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(identityCandidates.candidates, id: \.musicbrainzId) { candidate in
                                    candidateRow(candidate)
                                }
                            }
                        }

                        if identityCandidates.truncated {
                            Text("A lista foi limitada aos resultados mais relevantes.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Spacer()
                    ContentUnavailableView(
                        "Não foi possível carregar os candidatos",
                        systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90"
                    )
                    .frame(maxWidth: .infinity)
                    Spacer()
                }
            }
            .padding(20)
            .navigationTitle("Selecionar identidade")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") {
                        isIdentityPickerPresented = false
                    }
                    .disabled(isSavingIdentity)
                }

                if identity?.status != .resolved {
                    ToolbarItem {
                        Button("Buscar novamente") {
                            Task { await loadIdentityCandidates() }
                        }
                        .disabled(isLoadingIdentityCandidates || isSavingIdentity)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Confirmar") {
                            Task { await confirmSelectedIdentity() }
                        }
                        .disabled(selectedCandidateID == nil || isSavingIdentity)
                    }
                }
            }
            .overlay {
                if isSavingIdentity {
                    ZStack {
                        Color.black.opacity(0.08)
                        ProgressView("Salvando identidade…")
                            .padding(18)
                            .background(.regularMaterial, in: .rect(cornerRadius: 12))
                    }
                    .ignoresSafeArea()
                }
            }
            .confirmationDialog(
                "Remover a identidade de \(artist.name)?",
                isPresented: $isClearIdentityConfirmationPresented
            ) {
                Button("Remover vínculo", role: .destructive) {
                    Task { await clearIdentity() }
                }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Os dados enriquecidos associados serão ocultados até que outra identidade seja confirmada.")
            }
        }
        .frame(minWidth: 620, minHeight: 520)
        .task {
            if identity?.status != .resolved, identityCandidates == nil {
                await loadIdentityCandidates()
            }
        }
        .accessibilityIdentifier("artist.identity.picker")
    }

    private func candidateRow(_ candidate: ArtistIdentityCandidate) -> some View {
        Button {
            selectedCandidateID = candidate.musicbrainzId
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selectedCandidateID == candidate.musicbrainzId ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selectedCandidateID == candidate.musicbrainzId ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(candidate.name)
                            .font(.headline)
                        Text(entityKindLabel(candidate.entityKind))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !candidate.disambiguation.isEmpty {
                        Text(candidate.disambiguation)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if !candidate.aliases.isEmpty {
                        Text("Também conhecido como: \(candidate.aliases.prefix(3).joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !candidate.evidence.isEmpty {
                        Text(candidate.evidence.map(evidenceLabel).joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Text(candidate.musicbrainzId)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .contentShape(.rect)
            .background(
                selectedCandidateID == candidate.musicbrainzId
                    ? Color.accentColor.opacity(0.12)
                    : Color.primary.opacity(0.04),
                in: .rect(cornerRadius: 10)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        selectedCandidateID == candidate.musicbrainzId
                            ? Color.accentColor.opacity(0.55)
                            : Color.clear
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(candidate.name), \(entityKindLabel(candidate.entityKind))")
        .accessibilityValue(selectedCandidateID == candidate.musicbrainzId ? "Selecionado" : "Não selecionado")
        .accessibilityIdentifier("artist.identity.candidate.\(candidate.musicbrainzId)")
    }

    private func presentIdentityPicker() {
        presentation.presentIdentityPicker()
    }

    private func loadIdentityCandidates() async {
        await presentation.loadIdentityCandidates()
    }

    private func confirmSelectedIdentity() async {
        await presentation.confirmSelectedIdentity()
    }

    private func clearIdentity() async {
        await presentation.clearIdentity()
    }

    private func reloadCachedEnrichment() async {
        await presentation.reloadCachedEnrichment()
    }

    private func refreshEnrichment(force: Bool = false) async {
        await presentation.refreshEnrichment(force: force)
    }

    private func identityCalloutTitle(for identity: ArtistIdentity) -> String {
        if identity.conflictingTags { return "Identificadores conflitantes nos arquivos" }
        switch identity.status {
        case .resolved: return "Identidade MusicBrainz confirmada"
        case .ambiguous: return "Mais de um artista encontrado"
        case .notFound: return "Artista não identificado"
        case .unresolved: return "Identidade do artista pendente"
        }
    }

    private func identityCalloutDescription(for identity: ArtistIdentity) -> String {
        if identity.conflictingTags {
            return "As músicas possuem MusicBrainz IDs diferentes. Revise as tags para liberar o enriquecimento."
        }
        switch identity.status {
        case .resolved:
            return "Perfil, discografia e capas usam o vínculo confirmado."
        case .ambiguous:
            return "Selecione o candidato correto para carregar perfil, discografia e capas."
        case .notFound:
            return "Tente uma nova busca ou mantenha apenas os metadados locais."
        case .unresolved:
            return "Confirme um candidato antes de buscar perfil, discografia e capas."
        }
    }

    private func identityOriginLabel(_ origin: ArtistIdentityOrigin?) -> String {
        switch origin {
        case .tag: "Tags dos arquivos"
        case .manual: "Confirmação manual"
        case nil: "Não definida"
        }
    }

    private func identityLookupMessage(_ result: ArtistIdentityCandidates) -> String? {
        switch result.lookupStatus {
        case .updated:
            return result.candidates.isEmpty ? nil : "\(result.candidates.count) candidato(s) encontrado(s)."
        case .disabled:
            return "O enriquecimento remoto está desativado nos Ajustes."
        case .offline:
            return "Modo offline: mostrando apenas candidatos já armazenados."
        case .unavailable:
            return "O MusicBrainz não está disponível agora. Os candidatos armazenados foram preservados."
        case .rateLimited:
            if let seconds = result.retryAfterSeconds {
                return "Limite do MusicBrainz atingido. Tente novamente em \(seconds) segundos."
            }
            return "Limite do MusicBrainz atingido. Tente novamente mais tarde."
        case .superseded:
            return "A identidade mudou durante a busca. Atualize a lista antes de confirmar."
        }
    }

    private func identityLookupIcon(_ status: ArtistIdentityLookupStatus) -> String {
        switch status {
        case .updated: "checkmark.circle"
        case .disabled: "slash.circle"
        case .offline: "network.slash"
        case .unavailable: "exclamationmark.triangle"
        case .rateLimited: "clock.badge.exclamationmark"
        case .superseded: "arrow.trianglehead.2.clockwise.rotate.90"
        }
    }

    private func emptyCandidatesDescription(_ result: ArtistIdentityCandidates) -> String {
        if result.identity.conflictingTags {
            return "Corrija os MusicBrainz IDs conflitantes nas tags das músicas e faça uma nova varredura."
        }
        return identityLookupMessage(result)
            ?? "Nenhum resultado corresponde ao nome deste artista."
    }

    private func entityKindLabel(_ kind: ArtistEntityKind) -> String {
        switch kind {
        case .person: "Pessoa"
        case .group: "Grupo"
        case .other: "Outro"
        case .unknown: "Tipo desconhecido"
        }
    }

    private func evidenceLabel(_ evidence: String) -> String {
        switch evidence {
        case "musicbrainz_search_candidate": return "resultado do MusicBrainz"
        case "exact_name": return "nome exato"
        case "exact_alias": return "alias exato"
        default:
            if evidence.hasPrefix("local_release_title:") {
                return "álbum local: \(evidence.dropFirst("local_release_title:".count))"
            }
            return evidence.replacingOccurrences(of: "_", with: " ")
        }
    }

    @ViewBuilder
    private func discographySections(viewport: PageViewport) -> some View {
        let sideInsets = viewport.sideInsets
        let scrollableWidth = viewport.expandedWidth

        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Na biblioteca")
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text("\(albums.count) reproduzíveis")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: AlbumGridLayout.spacing) {
                        ForEach(localReleasesNewestFirst, id: \.id) { album in
                            AlbumCard(
                                release: album,
                                onSelectAlbum: selectAlbum,
                                subtitle: releaseYear(for: album),
                                fallbackArtworkID: externalFallbackArtworkID(for: album),
                                artworkSize: AlbumGridLayout.cardWidth
                            )
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .contentMargins(.leading, 24 + sideInsets.leading, for: .scrollContent)
                .contentMargins(.trailing, 24 + sideInsets.trailing, for: .scrollContent)
                .frame(width: scrollableWidth, alignment: .leading)
                .padding(.leading, -24 - sideInsets.leading)
                .padding(.trailing, -24 - sideInsets.trailing)
                .scrollClipDisabled()
            }
            .accessibilityIdentifier("artist.discography.local")
        }

        if discographyPage != nil || isRefreshingCatalog || !catalogRefreshResults.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Discografia online")
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    if !onlineOnlyReleases.isEmpty {
                        Text("\(onlineOnlyReleases.count) somente online")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if discographyPage?.stale == true {
                        Text("Cache antigo")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: .capsule)
                    }
                    Spacer()
                    if isRefreshingCatalog || isLoadingMoreDiscography {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Atualizando discografia")
                    }
                }

                if onlineOnlyReleases.isEmpty {
                    Text("Nenhum lançamento exclusivamente online no cache local.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 32) {
                        ForEach(ArtistDiscographyCategory.allCases) { category in
                            let releases = onlineOnlyReleases.filter {
                                ArtistDiscographyCategory.category(for: $0, artistMBID: identity?.musicbrainzId) == category
                            }
                            if !releases.isEmpty {
                                VStack(alignment: .leading, spacing: 16) {
                                    Text(category.title)
                                        .font(.title3.bold())
                                        .accessibilityAddTraits(.isHeader)

                                    ScrollView(.horizontal) {
                                        LazyHStack(alignment: .top, spacing: AlbumGridLayout.spacing) {
                                            ForEach(releases, id: \.musicbrainzId) { release in
                                                ExternalReleaseCard(
                                                    release: release,
                                                    subtitle: externalReleaseSubtitle(release),
                                                    onSelectRelease: selectExternalRelease,
                                                    artworkSize: AlbumGridLayout.cardWidth
                                                )
                                            }
                                        }
                                    }
                                    .scrollIndicators(.hidden)
                                    .contentMargins(.leading, 24 + sideInsets.leading, for: .scrollContent)
                                    .contentMargins(.trailing, 24 + sideInsets.trailing, for: .scrollContent)
                                    .frame(width: scrollableWidth, alignment: .leading)
                                    .padding(.leading, -24 - sideInsets.leading)
                                    .padding(.trailing, -24 - sideInsets.trailing)
                                    .scrollClipDisabled()
                                }
                                .accessibilityIdentifier("artist.discography.online.\(category.rawValue)")
                            }
                        }
                    }
                }

                if let progress = coverQueueProgress {
                    Text("Capas: \(progress.completed) concluídas · \(progress.pending) pendentes · \(progress.absent) ausentes · \(progress.temporarilyBlocked) bloqueadas temporariamente")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("artist.covers.progress")
                }

                HStack(spacing: 10) {
                    if let nextOffset = discographyPage?.nextOffset {
                        Button("Mostrar mais", systemImage: "chevron.down") {
                            Task { await loadMoreDiscography(from: nextOffset) }
                        }
                        .disabled(isRefreshingCatalog || isLoadingMoreDiscography)
                    } else if catalogNeedsContinuation {
                        Button("Continuar catálogo", systemImage: "arrow.clockwise") {
                            Task { await refreshCatalog() }
                        }
                        .disabled(isRefreshingCatalog || isLoadingMoreDiscography)
                        .accessibilityIdentifier("artist.discography.continue")
                    }

                    if let total = discographyPage?.remoteTotal {
                        Text("\(discographyItems.count) de \(total) itens armazenados")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityIdentifier("artist.discography.online")
        }
    }

    private var onlineOnlyReleases: [ExternalReleaseGroup] {
        discographyItems
            .filter { $0.localReleaseId == nil }
            .sorted {
                let left = externalReleaseDateKey($0.firstReleaseDate)
                let right = externalReleaseDateKey($1.firstReleaseDate)
                if left != right { return left > right }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
    }

    private var localReleasesNewestFirst: [Release] {
        albums.sorted {
            let left = localReleaseDateKey($0.releaseDate)
            let right = localReleaseDateKey($1.releaseDate)
            if left != right { return left > right }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private func externalReleaseDateKey(_ date: ArtistPartialDate?) -> Int {
        guard let date else { return Int.min }
        return Int(date.year) * 10_000 + Int(date.month ?? 0) * 100 + Int(date.day ?? 0)
    }

    private func localReleaseDateKey(_ date: String?) -> Int {
        guard let date else { return Int.min }
        let components = date.split { !$0.isNumber }.compactMap { Int($0) }
        guard let year = components.first else { return Int.min }
        let month = components.count > 1 ? components[1] : 0
        let day = components.count > 2 ? components[2] : 0
        return year * 10_000 + month * 100 + day
    }

    private func externalFallbackArtworkID(for album: Release) -> String? {
        guard album.artworkId == nil else { return nil }
        return lookups.value.externalByLocalReleaseID[album.id]?.artwork?.image.managedPath
    }

    private func externalReleaseSubtitle(_ release: ExternalReleaseGroup) -> String {
        let kind = release.primaryType ?? "Lançamento"
        guard let year = release.firstReleaseDate?.year else { return kind }
        return "\(kind) · \(year)"
    }

    private var catalogNeedsContinuation: Bool {
        if catalogRefreshResults.contains(where: { $0.status == .partial }) {
            return true
        }
        return catalogRefreshResults.isEmpty && discographyPage?.remoteExhausted == false
    }

    private var coverQueueProgress: CoverRefreshProgress? {
        catalogRefreshResults
            .first { $0.section == .covers }?
            .coverProgress
    }

    @ViewBuilder
    private var enrichmentDiagnostics: some View {
        if !catalogRefreshResults.isEmpty || isRefreshingCatalog {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Atualização de metadados")
                        .font(.headline)
                    Spacer()
                    if isRefreshingCatalog {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Atualizando metadados")
                    }
                }

                ForEach(ArtistEnrichmentDiagnostics.orderedSections, id: \.self) { section in
                    if let result = catalogRefreshResults.first(where: { $0.section == section }) {
                        enrichmentDiagnosticRow(result)
                    }
                }
            }
            .padding(14)
            .background(.quaternary, in: .rect(cornerRadius: 12))
            .accessibilityIdentifier("artist.enrichment.diagnostics")
        }
    }

    private func enrichmentDiagnosticRow(_ result: ArtistRefreshSectionResult) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: diagnosticIcon(result.status))
                .foregroundStyle(diagnosticColor(result.status))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(ArtistEnrichmentDiagnostics.title(for: result.section))
                    .font(.subheadline.weight(.semibold))
                Text(ArtistEnrichmentDiagnostics.message(
                    for: result,
                    hasCachedContent: hasCachedContent(for: result.section)
                ))
                .font(.caption)
                .foregroundStyle(.secondary)

                if let lastSuccess = lastSuccess(for: result.section) {
                    Text("Último sucesso: \(lastSuccess.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if result.section == .covers, let progress = result.coverProgress {
                    Text("\(progress.completed) concluídas · \(progress.pending) pendentes · \(progress.absent) ausentes · \(progress.temporarilyBlocked) bloqueadas")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 12)

            if ArtistEnrichmentDiagnostics.isRetryable(result) {
                Button("Tentar novamente") {
                    Task { await retryEnrichmentSection(result.section) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isRefreshingCatalog)
                .accessibilityIdentifier("artist.enrichment.retry.\(String(describing: result.section))")
            }
        }
    }

    private func diagnosticIcon(_ status: ArtistRefreshStatus) -> String {
        switch status {
        case .updated, .unchanged: "checkmark.circle.fill"
        case .partial: "clock.arrow.circlepath"
        case .notFound: "minus.circle"
        case .needsIdentity: "person.crop.circle.badge.questionmark"
        case .rateLimited: "hourglass.circle"
        case .disabled, .offline: "icloud.slash"
        case .superseded: "arrow.trianglehead.2.clockwise.rotate.90"
        case .unavailable: "exclamationmark.triangle.fill"
        }
    }

    private func diagnosticColor(_ status: ArtistRefreshStatus) -> Color {
        switch status {
        case .updated, .unchanged: .green
        case .unavailable, .rateLimited: .orange
        default: .secondary
        }
    }

    private func hasCachedContent(for section: ArtistRefreshSection) -> Bool {
        switch section {
        case .profile:
            return !(details?.sources.isEmpty ?? true)
        case .portrait:
            return details?.portrait != nil
        case .discography:
            return discographyPage?.catalogGeneration ?? 0 > 0 || !discographyItems.isEmpty
        case .covers:
            return discographyItems.contains { $0.artwork != nil }
        case .popularTracks:
            return popularTracks != nil
        case .similarArtists:
            return details?.similarArtistsFetchedAt != nil
        }
    }

    private func lastSuccess(for section: ArtistRefreshSection) -> Date? {
        let timestamp: Int64?
        switch section {
        case .profile:
            timestamp = details?.sources.map(\.fetchedAt).max()
        case .portrait:
            timestamp = details?.portrait?.fetchedAt
        case .discography:
            timestamp = discographyPage?.lastSuccessAt
        case .covers:
            timestamp = discographyItems.compactMap { $0.artwork?.image.fetchedAt }.max()
        case .popularTracks:
            timestamp = popularTracks?.fetchedAt
        case .similarArtists:
            timestamp = details?.similarArtistsFetchedAt
        }
        return timestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    private func retryEnrichmentSection(_ section: ArtistRefreshSection) async {
        await presentation.retryEnrichmentSection(section)
    }

    private func loadMoreDiscography(from offset: UInt64) async {
        await presentation.loadMoreDiscography(from: offset)
    }

    private func refreshCatalog() async {
        await presentation.refreshCatalog()
    }

    private func artistHighlights(viewport: PageViewport) -> some View {
        let width = viewport.visibleWidth
        let sideInsets = viewport.sideInsets
        let highlightArtworkSize: CGFloat = 160
        let popularTrackRowHeight = PopularTrackRowMetrics.height
        let latestReleaseTitleFont = Font.system(
            size: (NSFont.preferredFont(forTextStyle: .subheadline).pointSize + 1) * 1.25
        )
        let latestReleaseMetadataFont = Font.system(
            size: NSFont.preferredFont(forTextStyle: .caption1).pointSize + 2
        )
        let contentWidth = viewport.expandedWidth
        // Size the blocks and scroll viewport from the visible content column.
        let initialVisibleWidth = max(0, width - 48)
        let latestReleaseBlockWidth = min(420, max(360, initialVisibleWidth * 0.40))
        let popularColumnWidth = min(440, max(360, initialVisibleWidth * 0.45))
        let ranking = ArtistPresentationPolicy.popularRanking(
            lastFm: popularTracks,
            localTracks: mostPlayedLocalTracks
        )

        return ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 16) {
                Text("Último lançamento")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)

                if let latestRelease {
                    let localRelease = latestRelease.localReleaseId.flatMap { lookups.value.albumsByID[$0] }
                    Button {
                        if let local = localRelease {
                            selectAlbum(local)
                        } else {
                            onSelectExternalRelease(latestRelease)
                        }
                    } label: {
                        HStack(alignment: .center, spacing: 15) {
                            ArtworkView(
                                artworkID: localRelease?.artworkId
                                    ?? latestRelease.artwork?.image.managedPath,
                                size: highlightArtworkSize
                            )

                            VStack(alignment: .leading, spacing: 2) {
                                if let releaseDate = latestRelease.firstReleaseDate {
                                    Text(formattedReleaseDate(releaseDate))
                                        .font(latestReleaseMetadataFont.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .textCase(.uppercase)
                                }

                                AlbumTitleLabel(
                                    title: latestRelease.title,
                                    isFavorite: localRelease?.isFavorite == true,
                                    font: latestReleaseTitleFont
                                )
                                    .lineLimit(2)
                                if let count = releaseDetailsByGroupID[latestRelease.musicbrainzId]?.tracks.count {
                                    Text("\(count) músicas")
                                        .font(latestReleaseMetadataFont)
                                        .foregroundStyle(.secondary)
                                } else if let kind = latestRelease.primaryType {
                                    Text(kind)
                                        .font(latestReleaseMetadataFont)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Abrir lançamento \(latestRelease.title)")
                    .albumContextMenu(album: localRelease)
                    .accessibilityIdentifier("artist.latestRelease.\(latestRelease.musicbrainzId)")
                    if discographyPage?.remoteExhausted == false {
                        Text("Mais recente no catálogo disponível. Continue a atualização da discografia para consultar os demais lançamentos.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if !isLoading {
                    Text("Nenhum lançamento disponível")
                        .foregroundStyle(.secondary)
                }
                }
                .frame(width: latestReleaseBlockWidth, alignment: .leading)

                VStack(alignment: .leading, spacing: 16) {
                    Text(ranking.title)
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                        .visualEffect { content, geometry in
                            content.offset(
                                x: max(
                                    0,
                                    -geometry.frame(
                                        in: .scrollView(axis: .horizontal)
                                    ).minX
                                )
                            )
                        }
                        .zIndex(1)

                    if !isLoading, case .empty = ranking {
                        Text("Nenhuma música disponível")
                            .foregroundStyle(.secondary)
                    }

                    LazyHStack(alignment: .top, spacing: PopularTrackRowMetrics.columnSpacing) {
                        switch ranking {
                        case let .lastFm(externalRanking):
                            let visibleRanking = externalRanking.count >= 12
                                ? Array(externalRanking.prefix(12))
                                : Array(externalRanking.prefix(9))
                            ForEach(Array(stride(from: 0, to: visibleRanking.count, by: 3)), id: \.self) { start in
                                VStack(spacing: 0) {
                                    let end = min(start + 3, visibleRanking.count)
                                    ForEach(start..<end, id: \.self) { index in
                                        popularTrackRow(visibleRanking[index])
                                            .frame(
                                                maxWidth: .infinity,
                                                minHeight: popularTrackRowHeight,
                                                maxHeight: popularTrackRowHeight,
                                                alignment: .leading
                                            )
                                            .overlay(alignment: .bottom) {
                                                if index < end - 1 { Divider() }
                                            }
                                    }
                                }
                                .frame(
                                    width: popularColumnWidth,
                                    height: highlightArtworkSize,
                                    alignment: .topLeading
                                )
                            }
                        case let .library(localRanking):
                            ForEach(Array(stride(from: 0, to: localRanking.count, by: 3)), id: \.self) { start in
                                VStack(spacing: 0) {
                                    let end = min(start + 3, localRanking.count)
                                    ForEach(start..<end, id: \.self) { index in
                                        popularLocalTrackRow(localRanking[index], rank: index + 1)
                                            .frame(
                                                maxWidth: .infinity,
                                                minHeight: popularTrackRowHeight,
                                                maxHeight: popularTrackRowHeight,
                                                alignment: .leading
                                            )
                                            .overlay(alignment: .bottom) {
                                                if index < end - 1 { Divider() }
                                            }
                                    }
                                }
                                .frame(
                                    width: popularColumnWidth,
                                    height: highlightArtworkSize,
                                    alignment: .topLeading
                                )
                            }
                        case .empty:
                            EmptyView()
                        }
                    }
                }
                .frame(minWidth: popularColumnWidth, alignment: .leading)
            }
        }
        .scrollIndicators(.hidden)
        .contentMargins(.leading, 24 + sideInsets.leading, for: .scrollContent)
        .contentMargins(.trailing, 24 + sideInsets.trailing, for: .scrollContent)
        .frame(width: contentWidth, alignment: .leading)
        .padding(.leading, -24 - sideInsets.leading)
        .padding(.trailing, -24 - sideInsets.trailing)
        .scrollClipDisabled()
    }

    private func collectionControls(availableWidth: CGFloat) -> some View {
        // Reference proportions: four 48 pt actions around a 72 pt play button.
        let spacing = min(24, max(8, (availableWidth - headerActionSize * 4 - headerPlaySize) / 4))
        return HStack(spacing: spacing) {
            artistFollowButton
            artistInformationButton
            artistPlayButton
            artistShuffleButton
            artistFavoriteButton
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("artist.header.actions")
    }

    private var canPlayArtist: Bool { !isLoading && !tracks.isEmpty }

    private func playArtist(_ action: PlaybackCollection.Action) {
        guard canPlayArtist else { return }
        Task { await PlaybackCollection.tracks(tracks).perform(action, using: store) }
    }

    private var artistPlayButton: some View {
        Button { playArtist(.play) } label: {
            Image(systemName: "play.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.black.opacity(0.85))
                .offset(x: 2)
                .frame(width: headerPlaySize, height: headerPlaySize)
                .background(.white, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(!canPlayArtist)
        .help("Reproduzir")
        .accessibilityLabel("Reproduzir")
        .accessibilityIdentifier("collection.play")
    }

    private var artistShuffleButton: some View {
        Button { playArtist(.shuffle) } label: {
            Image(systemName: "shuffle")
        }
        .buttonStyle(ArtistHeaderActionButtonStyle(size: headerActionSize))
        .disabled(!canPlayArtist)
        .help("Reproduzir aleatoriamente")
        .accessibilityLabel("Reproduzir aleatoriamente")
        .accessibilityIdentifier("collection.shuffle")
    }

    private var isFollowing: Bool {
        followedArtistIDs.split(separator: ",").contains(Substring(String(artist.id)))
    }

    private var isFavorite: Bool {
        favoriteArtistIDs.split(separator: ",").contains(Substring(String(artist.id)))
    }

    private func togglingArtist(in storedIDs: String) -> String {
        var ids = Set(storedIDs.split(separator: ",").map(String.init))
        let id = String(artist.id)
        if ids.contains(id) {
            ids.remove(id)
        } else {
            ids.insert(id)
        }
        return ids.sorted().joined(separator: ",")
    }

    private var artistFollowButton: some View {
        Button {
            followedArtistIDs = togglingArtist(in: followedArtistIDs)
        } label: {
            Group {
                if isFollowing {
                    Image(systemName: "person.fill")
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 9, weight: .bold))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.black, Color.accentColor)
                                .offset(x: 5, y: 2)
                        }
                } else {
                    Image(systemName: "person.badge.plus")
                }
            }
            .foregroundStyle(isFollowing ? Color.accentColor : .white.opacity(0.85))
        }
        .buttonStyle(ArtistHeaderActionButtonStyle(size: headerActionSize))
        .help(isFollowing ? "Deixar de seguir artista" : "Seguir artista")
        .accessibilityLabel(isFollowing ? "Deixar de seguir artista" : "Seguir artista")
        .accessibilityValue(isFollowing ? "Seguindo" : "Não seguindo")
        .accessibilityAddTraits(isFollowing ? .isSelected : [])
        .accessibilityIdentifier("artist.follow")
    }

    private var artistInformationButton: some View {
        Button {
            let window = NSApp.keyWindow ?? NSApp.mainWindow
            let windowHeight = window?.contentView?.bounds.height ?? 628
            identitySheetHeight = max(1, windowHeight - 64 - 64)
            isIdentityPopoverPresented = true
        } label: {
            Image(systemName: "info")
        }
        .buttonStyle(ArtistHeaderActionButtonStyle(size: headerActionSize))
        .disabled(identity == nil)
        .help("Ver informações e conexões de metadados")
        .accessibilityLabel("Ver informações de \(artist.name)")
        .accessibilityIdentifier("artist.identity.badge")
    }

    private var artistFavoriteButton: some View {
        Button {
            favoriteArtistIDs = togglingArtist(in: favoriteArtistIDs)
        } label: {
            Image(systemName: "star.fill")
                .foregroundStyle(isFavorite ? Color.accentColor : .white.opacity(0.45))
        }
        .buttonStyle(ArtistHeaderActionButtonStyle(size: headerActionSize))
        .help(isFavorite ? "Desfavoritar artista" : "Favoritar artista")
        .accessibilityLabel(isFavorite ? "Desfavoritar artista" : "Favoritar artista")
        .accessibilityValue(isFavorite ? "Favorito" : "Não favorito")
        .accessibilityAddTraits(isFavorite ? .isSelected : [])
        .accessibilityIdentifier("artist.favorite")
    }

    private var visibleTracks: [Track] {
        let query = toolbarState.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var visibleTracks = tracks

        if !query.isEmpty {
            visibleTracks = visibleTracks.filter {
                $0.title.localizedStandardContains(query)
                    || $0.artist.localizedStandardContains(query)
                    || $0.release.localizedStandardContains(query)
            }
        }

        switch toolbarState.order {
        case .album:
            break
        case .title:
            visibleTracks.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .artist:
            visibleTracks.sort { $0.artist.localizedStandardCompare($1.artist) == .orderedAscending }
        case .duration:
            visibleTracks.sort { $0.durationSeconds < $1.durationSeconds }
        }

        return visibleTracks
    }

    private var mostPlayedLocalTracks: [Track] {
        Array(tracks.sorted {
            if $0.playCount != $1.playCount { return $0.playCount > $1.playCount }
            let titleOrder = $0.title.localizedStandardCompare($1.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return $0.id < $1.id
        }.prefix(10))
    }

    private func releaseYear(for album: Release) -> String {
        guard let date = album.releaseDate?.trimmingCharacters(in: .whitespacesAndNewlines),
              date.count >= 4,
              let year = Int(date.prefix(4)),
              year > 0 else {
            return "Ano desconhecido"
        }
        return String(year)
    }

    private func trackRow(_ track: Track) -> some View {
        HStack(spacing: 12) {
            ArtworkView(artworkID: track.artworkId, size: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .activeTrackTitle(trackID: track.id)
                Text(track.release)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Reproduzir \(track.title)")

            Button {
                Task { await store.addToQueue(trackID: track.id) }
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Adicionar \(track.title) à fila")
        }
        .padding(.vertical, 8)
        .playTrackOnDoubleClick {
            Task { await TrackRowPlayback.track(track.id).perform(using: store) }
        }
        .trackContextMenu(track: track) {
            Task { await TrackRowPlayback.track(track.id).perform(using: store) }
        }
        .accessibilityIdentifier("artist.track.\(track.id)")
    }

    @ViewBuilder
    private func popularTrackRow(_ item: ArtistPopularTrack) -> some View {
        if let localTrackID = item.localTrackId,
           let localTrack = lookups.value.tracksByID[localTrackID] {
            popularLocalTrackRow(localTrack, rank: Int(item.rank))
        } else {
            let matchedRelease = popularExternalRelease(for: item.title)
            PopularTrackListRow(
                rank: Int(item.rank),
                track: nil,
                trackID: nil,
                title: item.title,
                subtitle: item.listeners.formatted(),
                artworkID: popularTrackValue(for: item.title, in: popularTrackArtworkIDs),
                durationSeconds: popularTrackDuration(
                    for: item.title,
                    release: matchedRelease
                ),
                isFavorite: false,
                onToggleFavorite: nil,
                onPlay: nil,
                onAddToQueue: nil,
                onSelectArtwork: matchedRelease.map { release in
                    { selectExternalRelease(release) }
                },
                externalURL: URL(string: item.lastfmUrl)
            )
            .accessibilityLabel("\(item.title), posição \(item.rank)")
            .accessibilityIdentifier("artist.popular.external.\(item.rank)")
        }
    }

    private func popularLocalTrackRow(_ track: Track, rank: Int) -> some View {
        let currentTrack = store.loadedTrack(id: track.id) ?? track
        let release = lookups.value.albumsByID[track.releaseId]
        let playRanking: () -> Void = {
            _ = Task {
                await store.playTracks(
                    popularPlaybackTracks,
                    startingAt: track.id,
                    shuffleEnabled: false
                )
            }
        }
        return PopularTrackListRow(
            rank: rank,
            track: currentTrack,
            trackID: track.id,
            title: track.title,
            subtitle: track.release,
            artworkID: track.artworkId,
            durationSeconds: track.durationSeconds,
            isFavorite: currentTrack.isFavorite,
            onToggleFavorite: {
                Task {
                    await store.setTrackFavorite(
                        trackID: track.id,
                        favorite: !currentTrack.isFavorite,
                        fallbackTrack: currentTrack
                    )
                }
            },
            onPlay: playRanking,
            onAddToQueue: { Task { await store.addToQueue(trackID: track.id) } },
            onSelectArtwork: release.map { album in
                { selectAlbum(album) }
            },
            externalURL: nil
        )
        .playTrackOnDoubleClick(playRanking)
        .trackContextMenu(track: currentTrack, onPlay: playRanking)
        .accessibilityIdentifier("artist.popular.local.\(track.id)")
    }

    private var popularPlaybackTracks: [Track] {
        if let items = popularTracks?.items, !items.isEmpty {
            return items.compactMap { item in
                item.localTrackId.flatMap { trackID in
                    lookups.value.tracksByID[trackID]
                }
            }
        }
        return mostPlayedLocalTracks
    }

    private func artistFooter(viewport: PageViewport) -> some View {
        let width = viewport.visibleWidth
        let sideInsets = viewport.sideInsets
        let scrollableWidth = viewport.expandedWidth

        return VStack(alignment: .leading, spacing: 36) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Artistas similares")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, 24)

                if similarArtists.isEmpty {
                    Text("Nenhum artista similar disponível.")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 24)
                }

                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 20) {
                        ForEach(similarArtists, id: \.artistId) { similar in
                            VStack(spacing: 6) {
                                Button {
                                    selectArtist(Artist(id: similar.artistId, name: similar.name))
                                } label: {
                                    similarArtistCard(similar)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Abrir artista \(similar.name)")

                                if let url = URL(string: similar.lastfmUrl) {
                                    Link(destination: url) {
                                        Label("Last.fm", systemImage: "arrow.up.right.square")
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("Abrir fonte de \(similar.name) no Last.fm")
                                }
                            }
                            .task(id: similar.artistId) {
                                await loadSimilarArtistPortrait(similar)
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .contentMargins(.leading, 24 + sideInsets.leading, for: .scrollContent)
                .contentMargins(.trailing, 24 + sideInsets.trailing, for: .scrollContent)
                .frame(width: scrollableWidth, alignment: .leading)
                .padding(.leading, -sideInsets.leading)
                .padding(.trailing, -sideInsets.trailing)
                .scrollClipDisabled()
            }
        }
        .padding(.top, 36)
        .padding(.bottom, 180)
        .frame(width: width, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            Rectangle()
                .fill(pageBackgroundColor)
                .ignoresSafeArea(.container, edges: .bottom)
                .padding(.bottom, -1000)
        }
        .accessibilityIdentifier("artist.footer")
    }

    private var enrichmentLanguage: String {
        store.enrichmentSettings?.preferredLanguage
            ?? Locale.current.language.languageCode?.identifier
            ?? "pt"
    }

    private var biographySource: ArtistProfileSource? {
        biographySelection?.source
    }

    private var biographySourceName: String {
        biographySource?.provider == .lastFm ? "Last.fm" : "Wikipedia"
    }

    private var biographyOverride: ArtistFieldOverride? {
        details?.overrides.first { $0.field == .biography }
    }

    private var biographyText: String? {
        biographySelection?.text
    }

    private var biographySelection: ArtistBiographySelection? {
        ArtistPresentationPolicy.biography(
            overrides: details?.overrides ?? [],
            sources: details?.sources ?? []
        )
    }

    private func formatted(_ date: ArtistPartialDate) -> String {
        if let month = date.month, let day = date.day {
            return String(format: "%02d/%02d/%04d", day, month, date.year)
        }
        if let month = date.month {
            return String(format: "%02d/%04d", month, date.year)
        }
        return String(date.year)
    }

    private func formattedReleaseDate(_ date: ArtistPartialDate) -> String {
        guard let month = date.month, let day = date.day else {
            return formatted(date)
        }

        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.year = Int(date.year)
        components.month = Int(month)
        components.day = Int(day)

        guard let value = components.date else { return formatted(date) }
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "dd MMM yyyy"
        return formatter.string(from: value).replacingOccurrences(of: ".", with: "")
    }

    private func override(for field: ArtistProfileField) -> ArtistFieldOverride? {
        details?.overrides.first { $0.field == field }
    }

    private func overriddenText(_ field: ArtistProfileField, fallback: String?) -> String? {
        guard let value = override(for: field) else { return fallback }
        return value.value
    }

    private func overriddenDate(
        _ field: ArtistProfileField,
        fallback: ArtistPartialDate?
    ) -> ArtistPartialDate? {
        guard let value = override(for: field) else { return fallback }
        return value.value.flatMap(parseDate)
    }

    private func parseDate(_ value: String) -> ArtistPartialDate? {
        let fields = value.split(separator: "-")
        guard let year = fields.first.flatMap({ Int32($0) }) else { return nil }
        let month = fields.count > 1 ? UInt8(fields[1]) : nil
        let day = fields.count > 2 ? UInt8(fields[2]) : nil
        return ArtistPartialDate(year: year, month: month, day: day)
    }

    private func similarArtistCard(_ similar: SimilarArtist) -> some View {
        VStack(spacing: 10) {
            similarArtistAvatar(for: similar)
            Text(similar.name)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 104)
            if !similar.hasPlayableSources {
                Label("Fora da biblioteca", systemImage: "icloud")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: 120)
        .contentShape(.rect)
    }

    private var similarArtists: [SimilarArtist] {
        details?.similarArtists ?? []
    }

    private func similarArtistAvatar(for similar: SimilarArtist) -> some View {
        let artID = similarArtistArtworkIDs[similar.artistId] ?? similar.portrait?.managedPath
        return Group {
            if let artID {
                ArtworkView(
                    artworkID: artID,
                    size: 104,
                    aspectRatio: 1,
                    alignment: .center,
                    showsBorder: false
                )
            } else {
                ZStack {
                    Circle()
                        .fill(.tertiary)
                    Image(systemName: "person.fill")
                        .font(.system(size: 38))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 104, height: 104)
        .clipShape(Circle())
        .overlay {
            Circle()
                .strokeBorder(.separator, lineWidth: 0.5)
        }
    }

    @MainActor
    private func loadSimilarArtistPortrait(_ similar: SimilarArtist) async {
        await presentation.loadSimilarArtistPortrait(similar)
    }

    @MainActor
    private func cacheReleaseTracksAndResolvePopularArtwork() async {
        await presentation.cacheReleaseTracksAndResolvePopularArtwork()
    }

    private func popularExternalRelease(for title: String) -> ExternalReleaseGroup? {
        guard let groupID = popularTrackValue(for: title, in: popularTrackReleaseGroupIDs) else {
            return nil
        }
        return lookups.value.externalByGroupID[groupID]
    }

    private func popularTrackDuration(
        for title: String,
        release: ExternalReleaseGroup?
    ) -> Double? {
        guard let release else { return nil }
        return lookups.value.duration(for: title, release: release)
    }

    private func popularTrackValue<Value>(for title: String, in values: [String: Value]) -> Value? {
        for key in PopularTrackTitle.keys(title) {
            if let value = values[key] {
                return value
            }
        }
        return nil
    }

    private func selectAlbum(_ album: Release) {
        onSelectAlbum(album)
    }

    private func selectExternalRelease(_ release: ExternalReleaseGroup) {
        onSelectExternalRelease(release)
    }

    private func selectArtist(_ artist: Artist) {
        onSelectArtist?(artist)
    }
}

private struct PopularTrackListRow: View {
    let rank: Int
    let track: Track?
    let trackID: Int64?
    let title: String
    let subtitle: String
    let artworkID: String?
    let durationSeconds: Double?
    let isFavorite: Bool
    let onToggleFavorite: (() -> Void)?
    let onPlay: (() -> Void)?
    let onAddToQueue: (() -> Void)?
    let onSelectArtwork: (() -> Void)?
    let externalURL: URL?

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)

            if let onSelectArtwork {
                Button(action: onSelectArtwork) {
                    ArtworkView(artworkID: artworkID, size: 44)
                }
                .buttonStyle(.plain)
                .help("Abrir álbum")
                .accessibilityLabel("Abrir álbum de \(title)")
            } else {
                ArtworkView(artworkID: artworkID, size: 44)
            }

            TrackRowText(
                model: TrackRowModel(trackID: trackID, title: title, artworkID: artworkID,
                                     durationSeconds: durationSeconds, isFavorite: isFavorite),
                subtitle: subtitle, showsEmptySubtitle: true, titleURL: externalURL, spacing: 3
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            HStack(spacing: 8) {
                Button {
                    onToggleFavorite?()
                } label: {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .foregroundStyle(isFavorite ? Color.accentColor : .secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(onToggleFavorite == nil)
                .opacity(isFavorite || isHovered ? 1 : 0)
                .allowsHitTesting(isFavorite || isHovered)
                .accessibilityHidden(!isFavorite && !isHovered)
                .help(TrackRowModel.favoriteLabel(isFavorite))

                Text(durationText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)

                Menu {
                    if let onPlay {
                        Button("Reproduzir", systemImage: "play.fill", action: onPlay)
                    }
                    if let onAddToQueue {
                        Button("Adicionar à fila", systemImage: "text.badge.plus", action: onAddToQueue)
                    }
                    if let onToggleFavorite {
                        Button(
                            TrackRowModel.favoriteLabel(isFavorite),
                            systemImage: isFavorite ? "star.slash" : "star",
                            action: onToggleFavorite
                        )
                    }
                    if let externalURL {
                        Link("Abrir no Last.fm", destination: externalURL)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(.rect)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
                .accessibilityHidden(!isHovered)
                .help("Opções da faixa")
                .trackOptionsMenu(track: track, onPlay: onPlay ?? {})
            }
            .frame(width: 116, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .onHover { isHovered = $0 }
    }

    private var durationText: String {
        TrackRowModel(trackID: trackID, title: title, durationSeconds: durationSeconds)
            .durationText(unknown: "—")
    }
}

private struct ExternalReleaseCard: View {
    let release: ExternalReleaseGroup
    let subtitle: String
    let onSelectRelease: (ExternalReleaseGroup) -> Void

    var artworkSize: CGFloat = AlbumGridLayout.cardWidth

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                onSelectRelease(release)
            } label: {
                VStack(alignment: .leading, spacing: 7) {
                    ZStack(alignment: .topTrailing) {
                        ArtworkView(
                            artworkID: release.artwork?.image.managedPath,
                            size: artworkSize
                        )

                        Image(systemName: "cloud.fill")
                            .font(.caption.weight(.semibold))
                            .accessibilityLabel("Somente online")
                            .help("Somente online")
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.68), in: .capsule)
                            .padding(7)
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        Text(release.title)
                            .font(LibraryTypography.listingTitle)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(LibraryTypography.listingSecondary)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(width: artworkSize, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Abrir \(release.title), \(subtitle), somente online")
            .accessibilityIdentifier("artist.discography.remote.\(release.musicbrainzId)")
        }
        .frame(width: artworkSize, alignment: .leading)
    }
}

struct ArtistDetailToolbarControls: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Bindable var state: ArtistToolbarState
    let searchWidth: CGFloat
    let prefersCompact: Bool
    @Binding var isSearchExpanded: Bool

    var body: some View {
        HStack(spacing: ToolbarControlMetrics.spacing) {
            LibraryToolbarSearchField(
                searchText: $state.searchText,
                placeholder: "Pesquisar faixas",
                identifier: "artist.tracks.search",
                prefersCompact: prefersCompact,
                expandedWidth: searchWidth,
                isExpanded: $isSearchExpanded
            )

            ToolbarOptionsButton(title: "Organizar ou filtrar faixas") {
                Picker("Organizar", selection: $state.order) {
                    ForEach(ArtistTrackOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }
            }
            .accessibilityIdentifier("artist.tracks.organize")

            ToolbarOptionsButton(title: "Opções", systemImage: "ellipsis") {
                Button("Adicionar músicas à fila", systemImage: "text.line.last.and.arrowtriangle.forward") {
                    Task {
                        for track in state.tracks {
                            await store.addToQueue(trackID: track.id)
                        }
                    }
                }
                .disabled(state.isLoading || state.tracks.isEmpty)
            }
            .accessibilityIdentifier("artist.options")
        }
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

}

private struct ArtistHeaderActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    let size: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .frame(width: size, height: size)
            .contentShape(.circle)
            .background(.black.opacity(0.3), in: .circle)
            .glassEffect(.regular.tint(.black.opacity(0.2)).interactive(), in: .circle)
            .overlay { Circle().strokeBorder(.white.opacity(0.08), lineWidth: 1) }
            .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.65 : 1)
    }
}
