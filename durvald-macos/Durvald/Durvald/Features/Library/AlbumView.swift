import SwiftUI

@Observable
final class AlbumToolbarState {
    var searchText = ""
    var order: AlbumTrackOrder = .album
    var minimumTrackRating: UInt8 = 0
}

enum AlbumTrackOrder: String, CaseIterable, Identifiable {
    case album
    case title
    case artist
    case duration
    case rating

    var id: Self { self }

    var title: String {
        switch self {
        case .album: "Ordem do álbum"
        case .title: "Título"
        case .artist: "Artista"
        case .duration: "Duração"
        case .rating: "Avaliação"
        }
    }
}

struct AlbumView: View {
    @Environment(DurvaldCoreStore.self) private var store

    private let album: Release?
    private let externalRelease: ExternalReleaseGroup?
    private let externalArtist: Artist?
    let onSelectArtist: (Artist) -> Void

    @State private var tracks: [Track] = []
    @State private var externalDetails: ExternalReleaseDetails?
    @State private var refreshedAlbum: Release?
    @State private var isLoading = true
    @Bindable var toolbarState: AlbumToolbarState
    @AppStorage(RatingPreferences.enabledKey) private var ratingsEnabled = true

    private let artworkSize: CGFloat = 268

    init(
        album: Release,
        toolbarState: AlbumToolbarState = AlbumToolbarState(),
        onSelectArtist: @escaping (Artist) -> Void
    ) {
        self.album = album
        self.toolbarState = toolbarState
        externalRelease = nil
        externalArtist = nil
        self.onSelectArtist = onSelectArtist
    }

    init(
        externalRelease: ExternalReleaseGroup,
        artist: Artist,
        onSelectArtist: @escaping (Artist) -> Void
    ) {
        album = nil
        toolbarState = AlbumToolbarState()
        self.externalRelease = externalRelease
        externalArtist = artist
        self.onSelectArtist = onSelectArtist
    }

    private var currentAlbum: Release? {
        guard let album else { return nil }
        return store.loadedRelease(id: album.id)
            ?? refreshedAlbum
            ?? album
    }

    private var title: String {
        album?.title ?? externalDetails?.title ?? externalRelease?.title ?? "Álbum"
    }

    private var artistName: String {
        if let album { return album.artist }
        if let artist = externalDetails?.artist.trimmingCharacters(in: .whitespacesAndNewlines),
           !artist.isEmpty {
            return artist
        }
        return externalArtist?.name ?? ""
    }

    private var artworkID: String? {
        album?.artworkId ?? externalRelease?.artwork?.image.managedPath
    }

    private var detailID: String {
        if let album { return "local.\(album.id)" }
        return "remote.\(externalRelease?.musicbrainzId ?? "unknown")"
    }

    private var accessibilityDetailID: String {
        if let album { return "album.detail.\(album.id)" }
        return "album.detail.remote.\(externalRelease?.musicbrainzId ?? "unknown")"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                trackList
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .preservesLibraryScrollPosition(isContentReady: !isLoading)
        .task(id: detailID) {
            isLoading = true
            refreshedAlbum = nil
            externalDetails = nil
            if let album {
                tracks = await store.tracks(forReleaseID: album.id)
            } else if let externalRelease, let externalArtist {
                tracks = []
                externalDetails = await store.externalReleaseDetails(
                    artistId: externalArtist.id,
                    releaseGroupMbid: externalRelease.musicbrainzId
                )
            } else {
                tracks = []
            }
            isLoading = false
            if let album {
                refreshedAlbum = await store.syncReleaseMetadata(
                    artistId: album.artistId,
                    releaseId: album.id
                )
            }
        }
        .accessibilityIdentifier(accessibilityDetailID)
        .task(id: store.metadataRevision) {
            guard store.metadataRevision > 0, let album else { return }
            tracks = await store.tracks(forReleaseID: album.id)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(alignment: .top, spacing: 24) {
                ArtworkView(
                    artworkID: artworkID,
                    size: artworkSize
                )
                .albumContextMenu(album: currentAlbum)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Capa de \(title)")
                .accessibilityIdentifier("album.header.artwork")

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .multilineTextAlignment(.leading)
                        .padding(.top, 24)

                    Button {
                        guard let artist = selectedArtist else { return }
                        onSelectArtist(artist)
                    } label: {
                        Text(artistName)
                            .font(.title)
                            .foregroundStyle(Color.accentColor)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    .help("Abrir artista \(artistName)")
                    .accessibilityLabel("Abrir artista \(artistName)")
                    .accessibilityIdentifier("album.artist")

                    if let currentAlbum {
                        localReleaseMetadata(currentAlbum)
                            .padding(.top, 8)
                        if ratingsEnabled {
                            RatingControl(
                                rating: currentAlbum.ratingHalfSteps,
                                isEditable: true,
                                identity: .release(currentAlbum.id),
                                onCommit: { rating in
                                    await store.setReleaseRating(releaseID: currentAlbum.id, rating: rating,
                                                                 fallbackRelease: currentAlbum)
                                }
                            )
                            .padding(.top, 6)
                            .accessibilityIdentifier("album.rating")
                        }
                    }

                    if let externalRelease {
                        externalReleaseMetadata(externalRelease)
                            .padding(.top, 8)

                        Text("Este lançamento está disponível somente na discografia online.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }

                    if let album, let currentAlbum {
                        Spacer(minLength: 20)
                        localAlbumControls(album: album, currentAlbum: currentAlbum)
                            .padding(.bottom, 24)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: artworkSize, alignment: .topLeading)
            }

            if let externalRelease,
                      let source = URL(
                        string: externalDetails?.attribution.sourceUrl
                            ?? externalRelease.attribution.sourceUrl
                      ) {
                Link("Ver no MusicBrainz", destination: source)
                    .accessibilityIdentifier("album.external.musicbrainz")
            }
        }
    }

    private func localAlbumControls(album: Release, currentAlbum: Release) -> some View {
        HStack(spacing: 16) {
            Button { playAlbum(.play, album: album) } label: {
                CollectionHeaderPlayLabel(size: 60)
            }
            .buttonStyle(.plain)
            .disabled(isLoading || tracks.isEmpty)
            .help("Reproduzir")
            .accessibilityLabel("Reproduzir")
            .accessibilityIdentifier("collection.play")

            Button { playAlbum(.shuffle, album: album) } label: {
                Image(systemName: "shuffle")
            }
            .buttonStyle(CollectionHeaderActionButtonStyle(size: 40))
            .disabled(isLoading || tracks.isEmpty)
            .help("Reproduzir aleatoriamente")
            .accessibilityLabel("Reproduzir aleatoriamente")
            .accessibilityIdentifier("collection.shuffle")

            Button {
                store.setReleaseFavorite(releaseID: album.id, favorite: !currentAlbum.isFavorite)
            } label: {
                Image(systemName: "star.fill")
                    .foregroundStyle(currentAlbum.isFavorite ? Color.accentColor : .white.opacity(0.45))
            }
            .buttonStyle(CollectionHeaderActionButtonStyle(size: 40))
            .help(currentAlbum.isFavorite ? "Desfavoritar álbum" : "Favoritar álbum")
            .accessibilityLabel(currentAlbum.isFavorite ? "Desfavoritar álbum" : "Favoritar álbum")
            .accessibilityValue(currentAlbum.isFavorite ? "Favorito" : "Não favorito")
            .accessibilityAddTraits(currentAlbum.isFavorite ? .isSelected : [])
            .accessibilityIdentifier("collection.favorite")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("album.header.actions")
    }

    private func playAlbum(_ action: PlaybackCollection.Action, album: Release) {
        guard !isLoading, !tracks.isEmpty else { return }
        Task { await PlaybackCollection.release(album.id).perform(action, using: store) }
    }

    private var selectedArtist: Artist? {
        if let externalArtist { return externalArtist }
        guard let album else { return nil }
        return store.loadedArtist(id: album.artistId)
    }

    @ViewBuilder
    private func localReleaseMetadata(_ album: Release) -> some View {
        let metadata = releaseMetadataText(album)

        Text(metadata)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help(metadata)
            .textSelection(.enabled)
            .accessibilityIdentifier("album.metadata")
    }

    private func releaseMetadataText(_ album: Release) -> String {
        let genre = album.genres
            .lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? "Gênero desconhecido"
        let year = releaseYear(album.releaseDate) ?? "Ano desconhecido"
        let trackCount = album.totalTracks > 0 ? Int(album.totalTracks) : tracks.count
        let trackLabel = trackCount == 1 ? "1 faixa" : "\(trackCount) faixas"

        return [
            genre,
            year,
            trackLabel,
            DurationFormatter.text(seconds: album.durationSeconds, context: .albumHeader),
            fileQualityText
        ].joined(separator: " • ")
    }

    private func releaseYear(_ releaseDate: String?) -> String? {
        guard let releaseDate else { return nil }
        let candidate = releaseDate
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "-", maxSplits: 1)
            .first
            .map(String.init)
        guard let candidate,
              candidate.count == 4,
              candidate.allSatisfy(\.isNumber) else {
            return nil
        }
        return candidate
    }


    private var fileQualityText: String {
        let tracksByFormat = Dictionary(grouping: tracks) { track -> String in
            let fileExtension = URL(fileURLWithPath: track.filePath).pathExtension
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return fileExtension.uppercased()
        }

        let descriptions = tracksByFormat.keys
            .filter { !$0.isEmpty }
            .sorted()
            .compactMap { format -> String? in
                guard let formatTracks = tracksByFormat[format] else { return nil }

                switch format {
                case "MP3", "OGG", "OGA":
                    let bitrates = Set(formatTracks.compactMap(\.bitrate)).sorted()
                    guard let value = rangeText(bitrates, suffix: "kbps") else {
                        return format
                    }
                    return "\(format) (\(value))"

                case "FLAC", "WAV":
                    var properties: [String] = []
                    let sampleRates = Set(formatTracks.compactMap(\.sampleRate)).sorted()
                    if let first = sampleRates.first, let last = sampleRates.last {
                        properties.append(
                            first == last
                                ? sampleRateText(first)
                                : "\(sampleRateText(first))–\(sampleRateText(last))"
                        )
                    }
                    let bitDepths = Set(formatTracks.compactMap(\.bitDepth)).sorted()
                    if let value = rangeText(bitDepths, suffix: "bit") {
                        properties.append(value)
                    }
                    return properties.isEmpty
                        ? format
                        : "\(format) (\(properties.joined(separator: ", ")))"

                default:
                    return format
                }
            }

        return descriptions.isEmpty ? "Qualidade indisponível" : descriptions.joined(separator: " / ")
    }

    private func rangeText<T: BinaryInteger>(_ values: [T], suffix: String) -> String? {
        guard let first = values.first, let last = values.last else { return nil }
        return first == last ? "\(first) \(suffix)" : "\(first)–\(last) \(suffix)"
    }

    private func sampleRateText(_ sampleRate: UInt32) -> String {
        if sampleRate.isMultiple(of: 1_000) {
            return "\(sampleRate / 1_000) kHz"
        }
        return String(format: "%.1f kHz", locale: Locale(identifier: "en_US_POSIX"), Double(sampleRate) / 1_000)
    }

    @ViewBuilder
    private func externalReleaseMetadata(_ release: ExternalReleaseGroup) -> some View {
        let metadata = externalReleaseMetadataText(release)
        Text(metadata)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help(metadata)
            .textSelection(.enabled)
            .accessibilityIdentifier("album.metadata")
    }

    private func externalReleaseMetadataText(_ release: ExternalReleaseGroup) -> String {
        let genre = externalDetails?.genres
            .lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
            ?? release.primaryType
            ?? "Gênero desconhecido"
        let date = externalDetails?.releaseDate ?? release.firstReleaseDate
        let year = date.map { String($0.year) } ?? "Ano desconhecido"
        let count = externalDetails?.tracks.count ?? 0
        let trackLabel = count == 1 ? "1 faixa" : "\(count) faixas"
        let duration = externalDetails.map {
            $0.durationSeconds > 0
                ? DurationFormatter.text(seconds: $0.durationSeconds, context: .albumHeader)
                : "Duração indisponível"
        } ?? "Duração indisponível"
        return [genre, year, trackLabel, duration, "MusicBrainz"].joined(separator: " • ")
    }

    @ViewBuilder
    private var trackList: some View {
        if isLoading {
            ProgressView("Carregando faixas…")
                .frame(maxWidth: .infinity, alignment: .center)
        } else if let externalDetails, !externalDetails.tracks.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(externalDetails.tracks.enumerated()), id: \.offset) { _, track in
                    externalTrackRow(track, totalDiscs: externalDetails.totalDiscs)
                }
            }
        } else if externalRelease != nil {
            ContentUnavailableView(
                "Faixas não disponíveis",
                systemImage: "music.note.list",
                description: Text("Não foi possível carregar a listagem informativa do MusicBrainz.")
            )
            .frame(maxWidth: .infinity)
        } else if tracks.isEmpty {
            ContentUnavailableView(
                "Nenhuma faixa",
                systemImage: "music.note",
                description: Text("Este álbum não possui faixas disponíveis.")
            )
            .frame(maxWidth: .infinity)
        } else if visibleTracks.isEmpty {
            ContentUnavailableView.search(text: toolbarState.searchText)
                .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 0) {
                ForEach(visibleTracks, id: \.id) { track in
                    trackRow(track)
                }
            }
        }
    }

    private var visibleTracks: [Track] {
        let query = toolbarState.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var visibleTracks = tracks

        if !query.isEmpty {
            visibleTracks = visibleTracks.filter {
                $0.title.localizedStandardContains(query)
                    || $0.artist.localizedStandardContains(query)
            }
        }
        if ratingsEnabled, toolbarState.minimumTrackRating > 0 {
            visibleTracks = visibleTracks.filter { ($0.ratingHalfSteps ?? 0) >= toolbarState.minimumTrackRating }
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
        case .rating:
            visibleTracks.sort { ($0.ratingHalfSteps ?? 0) > ($1.ratingHalfSteps ?? 0) }
        }

        return visibleTracks
    }

    private func trackRow(_ track: Track) -> some View {
        CollectionTrackRow(track: track, number: trackNumber(for: track), showsArtwork: false, showsAlbum: false) {
            guard let album else { return }
            Task { await TrackRowPlayback.release(album.id, startingAt: track.id).perform(using: store) }
        }
        .accessibilityIdentifier("album.track.\(track.id)")
    }

    private func externalTrackRow(_ track: ExternalReleaseTrack, totalDiscs: UInt32) -> some View {
        HStack(spacing: 12) {
            Text(totalDiscs > 1
                 ? "\(track.discNumber).\(track.trackNumber)"
                 : "\(track.trackNumber)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 32, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if !track.artist.isEmpty && track.artist != artistName {
                    Text(track.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(track.durationSeconds.map { DurationFormatter.text(Double($0)) } ?? "—")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("album.externalTrack.\(track.discNumber).\(track.trackNumber)")
    }

    private func trackNumber(for track: Track) -> String {
        guard let album, album.totalDiscs > 1 else {
            return "\(track.trackNumber)"
        }

        return "\(track.discNumber).\(track.trackNumber)"
    }
}

struct AlbumDetailToolbarControls: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(\.trackMenuNavigation) private var navigation
    @AppStorage(RatingPreferences.enabledKey) private var ratingsEnabled = true
    let album: Release
    @Bindable var state: AlbumToolbarState
    let searchWidth: CGFloat
    let prefersCompact: Bool
    @Binding var isSearchExpanded: Bool

    var body: some View {
        HStack(spacing: ToolbarControlMetrics.spacing) {
            LibraryToolbarSearchField(
                searchText: $state.searchText,
                placeholder: "Pesquisar faixas",
                identifier: "album.tracks.search",
                prefersCompact: prefersCompact,
                expandedWidth: searchWidth,
                isExpanded: $isSearchExpanded
            )

            ToolbarOptionsButton(title: "Opções", systemImage: "ellipsis") {
                Button(album.isFavorite ? "Desfavoritar álbum" : "Favoritar álbum",
                       systemImage: album.isFavorite ? "star.slash" : "star") {
                    store.setReleaseFavorite(
                        releaseID: album.id,
                        favorite: !album.isFavorite
                    )
                }
                Button("Abrir artista", systemImage: "person") {
                    guard let artist = store.loadedArtist(id: album.artistId) else {
                        return
                    }
                    navigation.artist(artist)
                }
                if ratingsEnabled {
                    Divider()
                    ratingMenu(releaseID: album.id, rating: album.ratingHalfSteps)
                }
            }
            .accessibilityIdentifier("album.options")
            .albumOptionsMenu(album: album)

            ToolbarOptionsButton(title: "Organizar ou filtrar faixas") {
                Picker("Organizar", selection: $state.order) {
                    ForEach(AlbumTrackOrder.allCases.filter { ratingsEnabled || $0 != .rating }) { order in
                        Text(order.title).tag(order)
                    }
                }
                if ratingsEnabled {
                    Picker("Nota mínima", selection: $state.minimumTrackRating) {
                        Text("Todas").tag(UInt8(0))
                        ForEach(1...10, id: \.self) { value in
                            Text("\(RatingValues.number(value))+ estrelas").tag(UInt8(value))
                        }
                    }
                }
            }
            .accessibilityIdentifier("album.tracks.organize")
        }
    }

    private func ratingMenu(releaseID: Int64, rating: UInt8?) -> some View {
        Menu("Avaliação") {
            Button("Sem avaliação") {
                Task { await store.setReleaseRating(releaseID: releaseID, rating: nil, fallbackRelease: album) }
            }
            Divider()
            ForEach(RatingValues.options(store.ratingGranularity), id: \.self) { value in
                Button {
                    Task { await store.setReleaseRating(releaseID: releaseID, rating: UInt8(value), fallbackRelease: album) }
                } label: {
                    Label(
                        PersonalValueLabels.rating(UInt8(value)),
                        systemImage: rating == UInt8(value) ? "checkmark" : "star"
                    )
                }
            }
        }
        .disabled(store.isChangingRatingScale)
    }
}
