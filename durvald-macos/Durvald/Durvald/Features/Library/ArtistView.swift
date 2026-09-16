import SwiftUI

struct ArtistView: View {
    private enum TrackOrder: String, CaseIterable, Identifiable {
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

    @Environment(DurvaldCoreStore.self) private var store
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("followedArtistIDs") private var followedArtistIDs = ""
    @AppStorage("favoriteArtistIDs") private var favoriteArtistIDs = ""

    let artist: Artist
    let onSelectAlbum: (Release) -> Void
    let onSelectExternalRelease: (ExternalReleaseGroup) -> Void
    var onSelectArtist: ((Artist) -> Void)? = nil

    @State private var tracks: [Track] = []
    @State private var albums: [Release] = []
    @State private var details: ArtistDetails?
    @State private var identity: ArtistIdentity?
    @State private var identityCandidates: ArtistIdentityCandidates?
    @State private var discographyItems: [ExternalReleaseGroup] = []
    @State private var discographyPage: ArtistDiscographyPage?
    @State private var popularTracks: ArtistPopularTracks?
    @State private var catalogRefreshResults: [ArtistRefreshSectionResult] = []
    @State private var isRefreshingCatalog = false
    @State private var isLoadingMoreDiscography = false
    @State private var isIdentityPopoverPresented = false
    @State private var isIdentityPickerPresented = false
    @State private var isLoadingIdentityCandidates = false
    @State private var isSavingIdentity = false
    @State private var isClearIdentityConfirmationPresented = false
    @State private var selectedCandidateID: String?
    @State private var trackSearchText = ""
    @State private var trackOrder: TrackOrder = .album
    @FocusState private var isTrackSearchFocused: Bool
    @State private var isLoading = true
    @ScaledMetric(relativeTo: .largeTitle) private var artistNameFontSize =
        NSFont.preferredFont(forTextStyle: .largeTitle).pointSize * 1.275

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ArtworkView(
                        artworkID: ArtistPresentationPolicy.portraitArtworkID(
                            portrait: details?.portrait,
                            localArtworkIDs: albums.map(\.artworkId)
                                + discographyItems.map { $0.artwork?.image.managedPath }
                        ),
                        size: geometry.size.width,
                        aspectRatio: 16.0 / 9.0,
                        alignment: .top,
                        showsBorder: false
                    )
                    .backgroundExtensionEffect()
                    .overlay(alignment: .bottomLeading) {
                        HStack(alignment: .lastTextBaseline, spacing: 10) {
                            Text(artist.name)
                                .font(.system(size: artistNameFontSize, weight: .bold))
                                .accessibilityAddTraits(.isHeader)

                            if let identity {
                                Button {
                                    isIdentityPopoverPresented.toggle()
                                } label: {
                                    Image(systemName: identity.status == .resolved
                                          ? "checkmark.seal.fill"
                                          : "person.crop.circle.badge.questionmark")
                                        .font(.title2)
                                        .foregroundStyle(identity.status == .resolved ? Color.accentColor : Color.white)
                                        .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                                }
                                .buttonStyle(.plain)
                                .alignmentGuide(.lastTextBaseline) { dimensions in
                                    dimensions[.bottom]
                                }
                                .help("Ver identidade e conexões de metadados")
                                .accessibilityLabel("Ver identidade de \(artist.name)")
                                .accessibilityIdentifier("artist.identity.badge")
                                .popover(isPresented: $isIdentityPopoverPresented, arrowEdge: .bottom) {
                                    identityInformationPopover(identity)
                                }
                            }
                        }
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 4, y: 2)
                        .padding(24)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if let portrait = details?.portrait,
                           let sourceURL = URL(string: portrait.attribution.sourceUrl) {
                            Link("Foto: \(portraitSourceName(portrait.provider))", destination: sourceURL)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.black.opacity(0.55), in: Capsule())
                                .padding(24)
                        }
                    }
                    .accessibilityIdentifier("artist.header.\(artist.id)")

                    VStack(alignment: .leading, spacing: 24) {
                        collectionControls

                        artistHighlights(width: geometry.size.width)

                        discographySections(width: geometry.size.width)

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
                    .frame(maxWidth: .infinity, alignment: .leading)

                    artistFooter(width: geometry.size.width)
                }
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
            .preservesLibraryScrollPosition(isContentReady: !isLoading)
        }
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        .task(id: artist.id) {
            isLoading = true
            details = nil
            identity = nil
            identityCandidates = nil
            selectedCandidateID = nil
            discographyItems = []
            discographyPage = nil
            popularTracks = nil
            catalogRefreshResults = []
            async let loadedTracks = store.tracks(forArtistID: artist.id)
            async let loadedAlbums = store.releases(forArtistID: artist.id)
            async let loadedIdentity = store.artistIdentity(artistId: artist.id)
            async let loadedDetails = store.artistDetails(
                artistId: artist.id,
                language: enrichmentLanguage
            )
            async let loadedDiscography = store.artistDiscography(artistId: artist.id)
            async let loadedPopularTracks = store.artistPopularTracks(artistId: artist.id)
            let (resolvedTracks, resolvedAlbums, resolvedIdentity, resolvedDetails, resolvedDiscography, resolvedPopularTracks) = await (
                loadedTracks,
                loadedAlbums,
                loadedIdentity,
                loadedDetails,
                loadedDiscography,
                loadedPopularTracks
            )
            tracks = resolvedTracks.sorted {
                if $0.release != $1.release {
                    return $0.release.localizedStandardCompare($1.release) == .orderedAscending
                }
                if $0.discNumber != $1.discNumber { return $0.discNumber < $1.discNumber }
                if $0.trackNumber != $1.trackNumber { return $0.trackNumber < $1.trackNumber }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            albums = resolvedAlbums.sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            identity = resolvedIdentity
            popularTracks = resolvedPopularTracks
            details = resolvedDetails
            if let resolvedDiscography {
                applyDiscographyPage(resolvedDiscography, reset: true)
            }
            isLoading = false
            if let synchronizedAlbums = await store.syncArtistReleaseMetadata(artistId: artist.id) {
                albums = synchronizedAlbums.sorted {
                    $0.title.localizedStandardCompare($1.title) == .orderedAscending
                }
            }
        }
        .sheet(isPresented: $isIdentityPickerPresented) {
            identityPicker
        }
        .onChange(of: store.releases) { _, refreshedReleases in
            let refreshedByID = Dictionary(
                uniqueKeysWithValues: refreshedReleases.map { ($0.id, $0) }
            )
            albums = albums.map { refreshedByID[$0.id] ?? $0 }
        }
        .accessibilityIdentifier("artist.detail.\(artist.id)")
    }

    private func identityInformationPopover(_ identity: ArtistIdentity) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
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
                    identityInformationRow("Artista", value: artist.name)
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
        .frame(width: 500, height: 500)
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
        selectedCandidateID = nil
        if identity?.status != .resolved {
            identityCandidates = nil
        }
        isIdentityPickerPresented = true
    }

    private func loadIdentityCandidates() async {
        guard !isLoadingIdentityCandidates, !isSavingIdentity else { return }
        isLoadingIdentityCandidates = true
        defer { isLoadingIdentityCandidates = false }

        guard let result = await store.resolveArtistCandidates(artistId: artist.id) else {
            identityCandidates = nil
            return
        }
        identity = result.identity
        identityCandidates = result
        if let selectedCandidateID,
           !result.candidates.contains(where: { $0.musicbrainzId == selectedCandidateID }) {
            self.selectedCandidateID = nil
        }
    }

    private func confirmSelectedIdentity() async {
        guard let selectedCandidateID, !isSavingIdentity else { return }
        isSavingIdentity = true
        defer { isSavingIdentity = false }

        guard let confirmed = await store.confirmArtistIdentity(
            artistId: artist.id,
            musicbrainzId: selectedCandidateID
        ) else { return }

        identity = confirmed
        identityCandidates = nil
        self.selectedCandidateID = nil
        isIdentityPickerPresented = false
        await reloadCachedEnrichment()
        await refreshEnrichment()
    }

    private func clearIdentity() async {
        guard !isSavingIdentity else { return }
        isSavingIdentity = true

        guard let cleared = await store.clearArtistIdentity(artistId: artist.id) else {
            isSavingIdentity = false
            return
        }
        identity = cleared
        identityCandidates = nil
        selectedCandidateID = nil
        await reloadCachedEnrichment()
        isSavingIdentity = false

        if cleared.status != .resolved {
            await loadIdentityCandidates()
        }
    }

    private func reloadCachedEnrichment() async {
        async let cachedDetails = store.artistDetails(
            artistId: artist.id,
            language: enrichmentLanguage
        )
        async let cachedDiscography = store.artistDiscography(artistId: artist.id)
        let (newDetails, newDiscography) = await (cachedDetails, cachedDiscography)
        details = newDetails
        catalogRefreshResults = []
        if let newDiscography {
            applyDiscographyPage(newDiscography, reset: true)
        } else {
            discographyItems = []
            discographyPage = nil
        }
    }

    private func refreshEnrichment(force: Bool = false) async {
        guard !isRefreshingCatalog else { return }
        isRefreshingCatalog = true
        defer { isRefreshingCatalog = false }

        async let refreshedDetails = store.refreshArtistDetailsWithResult(
            artistId: artist.id,
            language: enrichmentLanguage,
            force: force
        )
        async let refreshedCatalog = store.refreshArtistCatalog(
            artistId: artist.id,
            language: enrichmentLanguage,
            force: force
        )
        let (detailsRefresh, catalogResult) = await (refreshedDetails, refreshedCatalog)
        if let newDetails = detailsRefresh.details {
            details = newDetails
        }
        catalogRefreshResults = mergeRefreshResults(
            detailsRefresh.result?.sections ?? [],
            catalogResult?.sections ?? []
        )
        if catalogResult != nil,
           let refreshedPage = await store.artistDiscography(artistId: artist.id) {
            applyDiscographyPage(refreshedPage, reset: true)
        }
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
    private func discographySections(width: CGFloat) -> some View {
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

                LazyVGrid(
                    columns: AlbumGridLayout.columns(for: width),
                    alignment: .leading,
                    spacing: AlbumGridLayout.spacing
                ) {
                    ForEach(albums, id: \.id) { album in
                        AlbumCard(
                            release: album,
                            onSelectAlbum: selectAlbum,
                            subtitle: releaseYear(for: album),
                            fallbackArtworkID: externalFallbackArtworkID(for: album)
                        )
                    }
                }
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
                    LazyVGrid(
                        columns: AlbumGridLayout.columns(for: width),
                        alignment: .leading,
                        spacing: AlbumGridLayout.spacing
                    ) {
                        ForEach(onlineOnlyReleases, id: \.musicbrainzId) { release in
                            ExternalReleaseCard(
                                release: release,
                                subtitle: externalReleaseSubtitle(release),
                                onSelectRelease: selectExternalRelease
                            )
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
                let left = $0.firstReleaseDate?.year ?? Int32.max
                let right = $1.firstReleaseDate?.year ?? Int32.max
                if left != right { return left < right }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
    }

    private func externalFallbackArtworkID(for album: Release) -> String? {
        guard album.artworkId == nil else { return nil }
        return discographyItems.first { $0.localReleaseId == album.id }?.artwork?.image.managedPath
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
        }
        return timestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    private func mergeRefreshResults(_ groups: [ArtistRefreshSectionResult]...) -> [ArtistRefreshSectionResult] {
        var merged: [ArtistRefreshSectionResult] = []
        for result in groups.flatMap({ $0 }) {
            if let index = merged.firstIndex(where: { $0.section == result.section }) {
                merged[index] = result
            } else {
                merged.append(result)
            }
        }
        return merged
    }

    private func mergeRefreshResults(_ incoming: [ArtistRefreshSectionResult]) {
        catalogRefreshResults = mergeRefreshResults(catalogRefreshResults, incoming)
    }

    private func retryEnrichmentSection(_ section: ArtistRefreshSection) async {
        guard !isRefreshingCatalog else { return }
        isRefreshingCatalog = true
        defer { isRefreshingCatalog = false }

        guard let result = await store.refreshArtistSections(
            artistId: artist.id,
            language: enrichmentLanguage,
            sections: [section]
        ) else { return }

        mergeRefreshResults(result.sections)
        switch section {
        case .profile, .portrait:
            details = await store.artistDetails(artistId: artist.id, language: enrichmentLanguage)
        case .discography, .covers:
            if let page = await store.artistDiscography(artistId: artist.id) {
                applyDiscographyPage(page, reset: true)
            }
        case .popularTracks:
            popularTracks = await store.artistPopularTracks(artistId: artist.id)
        }
    }

    private func applyDiscographyPage(_ page: ArtistDiscographyPage, reset: Bool) {
        if reset || discographyPage?.catalogGeneration != page.catalogGeneration {
            discographyItems = page.items
        } else {
            let known = Set(discographyItems.map(\.musicbrainzId))
            discographyItems.append(contentsOf: page.items.filter { !known.contains($0.musicbrainzId) })
        }
        discographyPage = page
    }

    private func loadMoreDiscography(from offset: UInt64) async {
        guard !isLoadingMoreDiscography else { return }
        isLoadingMoreDiscography = true
        defer { isLoadingMoreDiscography = false }
        if let page = await store.artistDiscography(artistId: artist.id, offset: offset) {
            applyDiscographyPage(page, reset: false)
        }
    }

    private func refreshCatalog() async {
        guard !isRefreshingCatalog else { return }
        isRefreshingCatalog = true
        defer { isRefreshingCatalog = false }
        let result = await store.refreshArtistCatalog(
            artistId: artist.id,
            language: enrichmentLanguage
        )
        if let result {
            mergeRefreshResults(result.sections)
        }
        if result != nil, let page = await store.artistDiscography(artistId: artist.id) {
            applyDiscographyPage(page, reset: true)
            albums = await store.releases(forArtistID: artist.id).sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }
    }

    private func artistHighlights(width: CGFloat) -> some View {
        // Two columns require twice the content column's 360 pt minimum width.
        let isStacked = width < 720
        let columnWidth = max(0, isStacked ? width - 48 : (width - 72) / 2)
        let layout = isStacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 28))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 24))
        let ranking = ArtistPresentationPolicy.popularRanking(
            lastFm: popularTracks,
            localTracks: mostPlayedLocalTracks
        )

        return layout {
            VStack(alignment: .leading, spacing: 16) {
                Text(ranking.title)
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)

                if !isLoading, case .empty = ranking {
                    Text("Nenhuma música disponível")
                        .foregroundStyle(.secondary)
                }

                LazyVStack(spacing: 0) {
                    switch ranking {
                    case let .lastFm(externalRanking):
                        ForEach(externalRanking, id: \.rank) { item in
                            popularTrackRow(item)
                            if item.rank != externalRanking.last?.rank { Divider() }
                        }
                    case let .library(localRanking):
                        ForEach(localRanking, id: \.id) { track in
                            trackRow(track)
                            if track.id != localRanking.last?.id { Divider() }
                        }
                    case .empty:
                        EmptyView()
                    }
                }
            }
            .frame(width: columnWidth, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Último lançamento")
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)

                    if let latestRelease {
                        Button {
                            selectAlbum(latestRelease)
                        } label: {
                            HStack(alignment: .center, spacing: 15) {
                                ArtworkView(
                                    artworkID: latestRelease.artworkId
                                        ?? externalFallbackArtworkID(for: latestRelease),
                                    size: 160
                                )

                                VStack(alignment: .leading, spacing: 2) {
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(latestRelease.title)
                                            .font(AlbumListingTypography.title)
                                            .lineLimit(2)
                                        Text(latestRelease.artist)
                                            .font(AlbumListingTypography.secondary)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Text(releaseYear(for: latestRelease))
                                        .font(AlbumListingTypography.secondary)
                                        .foregroundStyle(.secondary)
                                    Text("\(latestRelease.totalTracks) músicas")
                                        .font(AlbumListingTypography.secondary)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Abrir álbum \(latestRelease.title)")
                    } else if !isLoading {
                        Text("Nenhum lançamento disponível")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: columnWidth, alignment: .leading)

                VStack(alignment: .leading, spacing: 16) {
                    Text("Álbuns essenciais")
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)

                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 20) {
                            ForEach(essentialAlbums, id: \.id) { album in
                                Button {
                                    selectAlbum(album)
                                } label: {
                                    VStack(alignment: .leading, spacing: 7) {
                                        ArtworkView(
                                            artworkID: album.artworkId
                                                ?? externalFallbackArtworkID(for: album),
                                            size: 160
                                        )
                                        VStack(alignment: .leading, spacing: 0) {
                                            Text(album.title)
                                                .font(AlbumListingTypography.title)
                                                .lineLimit(2)
                                            Text(releaseYear(for: album))
                                                .font(AlbumListingTypography.secondary)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .frame(width: 160, alignment: .leading)
                                    .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Abrir álbum \(album.title)")
                            }
                        }
                        .padding(.leading, isStacked ? 0 : 24)
                    }
                    .scrollIndicators(.hidden)
                    // Extend into the column gap so the fade doesn't cover
                    // the first cover at its initial scroll position.
                    .mask {
                        HStack(spacing: 0) {
                            if !isStacked {
                                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                                    .frame(width: 24)
                            }
                            Rectangle()
                        }
                    }
                    .padding(.leading, isStacked ? 0 : -24)
                    .accessibilityIdentifier("artist.essentialAlbums")
                }
            }
            .frame(width: columnWidth + 24, alignment: .topLeading)
        }
        .padding(.trailing, -24)
    }

    private var latestRelease: Release? {
        albums.sorted {
            let leftDate = $0.releaseDate ?? ""
            let rightDate = $1.releaseDate ?? ""
            if leftDate != rightDate { return leftDate > rightDate }
            return $0.id < $1.id
        }.first
    }

    // Local ratings provide an interim order until editorial recommendations are available.
    private var essentialAlbums: [Release] {
        albums.sorted {
            if ($0.rating ?? 0) != ($1.rating ?? 0) {
                return ($0.rating ?? 0) > ($1.rating ?? 0)
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private var collectionControls: some View {
        HStack(spacing: 10) {
            CollectionPlaybackControls(
                isEnabled: !isLoading && !tracks.isEmpty,
                presentation: .groupedCompactShuffle,
                onPlay: {
                    Task { await store.playTracks(tracks, shuffleEnabled: false) }
                },
                onShuffle: {
                    Task { await store.playTracks(tracks, shuffleEnabled: true) }
                }
            )

            artistRelationshipControls

            Spacer(minLength: 24)

            Menu {
                Button("Adicionar músicas à fila", systemImage: "text.line.last.and.arrowtriangle.forward") {
                    Task {
                        for track in tracks {
                            await store.addToQueue(trackID: track.id)
                        }
                    }
                }
                .disabled(isLoading || tracks.isEmpty)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 34, height: 34)
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .background(Color.primary.opacity(0.08), in: .circle)
            .help("Opções")
            .accessibilityLabel("Opções")
            .accessibilityIdentifier("artist.options")

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Pesquisar", text: $trackSearchText)
                    .textFieldStyle(.plain)
                    .focused($isTrackSearchFocused)
                    .onExitCommand {
                        trackSearchText = ""
                        isTrackSearchFocused = false
                    }
            }
            .padding(.horizontal, 12)
            .frame(width: 147, height: 34)
            .background(Color.primary.opacity(0.08), in: .capsule)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("artist.tracks.search")

            Menu {
                Picker("Organizar", selection: $trackOrder) {
                    ForEach(TrackOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .frame(width: 34, height: 34)
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .background(Color.primary.opacity(0.08), in: .capsule)
            .help("Organizar ou filtrar faixas")
            .accessibilityLabel("Organizar ou filtrar faixas")
            .accessibilityIdentifier("artist.tracks.organize")
        }
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

    private var artistRelationshipControls: some View {
        HStack(spacing: 10) {
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
                                    .foregroundStyle(.background, Color.accentColor)
                                    .offset(x: 5, y: 2)
                            }
                    } else {
                        Image(systemName: "person.badge.plus")
                    }
                }
                .frame(width: 34, height: 34)
                .background(relationshipBackground, in: .circle)
                .contentShape(.circle)
            }
            .help(isFollowing ? "Deixar de seguir artista" : "Seguir artista")
            .accessibilityLabel(isFollowing ? "Deixar de seguir artista" : "Seguir artista")
            .accessibilityValue(isFollowing ? "Seguindo" : "Não seguindo")
            .accessibilityIdentifier("artist.follow")

            Button {
                favoriteArtistIDs = togglingArtist(in: favoriteArtistIDs)
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .frame(width: 34, height: 34)
                    .background(relationshipBackground, in: .circle)
                    .contentShape(.circle)
            }
            .help(isFavorite ? "Desfavoritar artista" : "Favoritar artista")
            .accessibilityLabel(isFavorite ? "Desfavoritar artista" : "Favoritar artista")
            .accessibilityValue(isFavorite ? "Favorito" : "Não favorito")
            .accessibilityIdentifier("artist.favorite")
        }
        .buttonStyle(.plain)
        .font(.body.weight(.medium))
        .foregroundStyle(Color.accentColor.opacity(appearsActive ? 1 : 0.63))
    }

    private var relationshipBackground: Color {
        Color.primary.opacity(
            colorScheme == .dark
                ? (appearsActive ? 0.08 : 0.10)
                : (appearsActive ? 0.10 : 0.06)
        )
    }

    private var visibleTracks: [Track] {
        let query = trackSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var visibleTracks = tracks

        if !query.isEmpty {
            visibleTracks = visibleTracks.filter {
                $0.title.localizedStandardContains(query)
                    || $0.artist.localizedStandardContains(query)
                    || $0.release.localizedStandardContains(query)
            }
        }

        switch trackOrder {
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
            Task { await store.play(trackID: track.id) }
        }
        .trackContextMenu(track: track) {
            Task { await store.play(trackID: track.id) }
        }
        .accessibilityIdentifier("artist.track.\(track.id)")
    }

    @ViewBuilder
    private func popularTrackRow(_ item: ArtistPopularTrack) -> some View {
        if let localTrackID = item.localTrackId,
           let localTrack = tracks.first(where: { $0.id == localTrackID }) {
            trackRow(localTrack)
        } else {
            HStack(spacing: 12) {
                ArtworkView(artworkID: nil, size: 36)

                VStack(alignment: .leading, spacing: 3) {
                    if let url = URL(string: item.lastfmUrl) {
                        Link(item.title, destination: url)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(item.title)
                            .foregroundStyle(.secondary)
                    }
                    Text("\(item.listeners.formatted()) ouvintes · não disponível na biblioteca")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

                Text("#\(item.rank)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(item.title), posição \(item.rank), não disponível na biblioteca")
            .accessibilityIdentifier("artist.popular.external.\(item.rank)")
        }
    }

    private func artistFooter(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 36) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Sobre \(artist.name)")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)

                VStack(alignment: .leading, spacing: 12) {
                    if let factsSummary {
                        Text(factsSummary)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                    }
                    if let biography = biographyText {
                        Text(biography)
                        if biographyOverride == nil,
                           let biographySource,
                           let sourceURL = URL(string: biographySource.profile.attribution.sourceUrl) {
                            Link("Fonte: \(biographySourceName)", destination: sourceURL)
                                .font(.caption)
                        }
                    } else {
                        Text("Informações biográficas ainda não disponíveis.")
                            .italic()
                    }
                }
                .font(.body)
                .foregroundStyle(.secondary)
                .lineSpacing(4)
                .frame(maxWidth: 800, alignment: .leading)
            }
            .padding(.horizontal, 24)

            VStack(alignment: .leading, spacing: 16) {
                Text("Artistas similares")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, 24)

                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 20) {
                        ForEach(similarArtists, id: \.id) { similar in
                            Button {
                                selectArtist(similar)
                            } label: {
                                VStack(spacing: 10) {
                                    similarArtistAvatar(for: similar)

                                    Text(similar.name)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.center)
                                        .frame(width: 104)
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Abrir artista \(similar.name)")
                        }
                    }
                    .padding(.horizontal, 24)
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(.top, 36)
        .padding(.bottom, 180)
        .frame(width: width, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            Rectangle()
                .fill(.quaternary)
                .backgroundExtensionEffect()
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

    private func portraitSourceName(_ provider: EnrichmentProvider) -> String {
        provider == .lastFm ? "Last.fm" : "Wikimedia Commons"
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

    private var factsSummary: String? {
        let profile = details?.sources.first(where: { $0.provider == .wikidata })?.profile
        let hasManualFacts = details?.overrides.contains { $0.field != .biography } == true
        guard profile != nil || hasManualFacts else {
            return nil
        }
        var facts: [String] = []
        if let date = overriddenDate(.birthDate, fallback: profile?.birthDate) {
            facts.append("Nascimento: \(formatted(date))")
        } else if let date = overriddenDate(.formationDate, fallback: profile?.formationDate) {
            facts.append("Formação: \(formatted(date))")
        }
        let place = overriddenText(.birthPlace, fallback: profile?.birthPlace)
            ?? overriddenText(.formationPlace, fallback: profile?.formationPlace)
            ?? overriddenText(.originPlace, fallback: profile?.originPlace)
        if let place {
            facts.append(place)
        }
        return facts.isEmpty ? nil : facts.joined(separator: " · ")
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

    private var similarArtists: [Artist] {
        let candidates = store.artists.filter { $0.id != artist.id }
        if !candidates.isEmpty {
            return Array(candidates.prefix(10))
        }
        return [
            Artist(id: -1, name: "Artista Similar 1"),
            Artist(id: -2, name: "Artista Similar 2"),
            Artist(id: -3, name: "Artista Similar 3"),
            Artist(id: -4, name: "Artista Similar 4"),
            Artist(id: -5, name: "Artista Similar 5")
        ]
    }

    private func similarArtistAvatar(for similar: Artist) -> some View {
        let artID = artworkID(for: similar)
        return Group {
            if let artID {
                ArtworkView(artworkID: artID, size: 104, showsBorder: false)
                    .scaledToFill()
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

    private func artworkID(for similar: Artist) -> String? {
        store.releases.first(where: {
            $0.artist.localizedCaseInsensitiveCompare(similar.name) == .orderedSame
        })?.artworkId
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

private struct ExternalReleaseCard: View {
    let release: ExternalReleaseGroup
    let subtitle: String
    let onSelectRelease: (ExternalReleaseGroup) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                onSelectRelease(release)
            } label: {
                VStack(alignment: .leading, spacing: 7) {
                    ZStack(alignment: .topTrailing) {
                        ArtworkView(
                            artworkID: release.artwork?.image.managedPath,
                            size: AlbumGridLayout.cardWidth
                        )

                        Text("Somente online")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.68), in: .capsule)
                            .padding(7)
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        Text(release.title)
                            .font(AlbumListingTypography.title)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(AlbumListingTypography.secondary)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(width: AlbumGridLayout.cardWidth, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Abrir \(release.title), \(subtitle), somente online")
            .accessibilityIdentifier("artist.discography.remote.\(release.musicbrainzId)")

            if let source = URL(string: release.attribution.sourceUrl) {
                Link("MusicBrainz", destination: source)
                    .font(.caption2)
            }
        }
        .frame(width: AlbumGridLayout.cardWidth, alignment: .leading)
    }
}
