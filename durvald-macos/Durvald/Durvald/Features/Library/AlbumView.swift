import SwiftUI

struct AlbumView: View {
    private enum TrackOrder: String, CaseIterable, Identifiable {
        case album
        case title
        case artist
        case duration

        var id: Self { self }

        var title: String {
            switch self {
            case .album: "Ordem do álbum"
            case .title: "Título"
            case .artist: "Artista"
            case .duration: "Duração"
            }
        }
    }

    @Environment(DurvaldCoreStore.self) private var store

    private let album: Release?
    private let externalRelease: ExternalReleaseGroup?
    private let externalArtist: Artist?
    let onSelectArtist: (Artist) -> Void

    @State private var tracks: [Track] = []
    @State private var externalDetails: ExternalReleaseDetails?
    @State private var refreshedAlbum: Release?
    @State private var isLoading = true
    @State private var trackSearchText = ""
    @State private var trackOrder: TrackOrder = .album
    @FocusState private var isTrackSearchFocused: Bool

    private let artworkSize: CGFloat = 268

    init(album: Release, onSelectArtist: @escaping (Artist) -> Void) {
        self.album = album
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
        self.externalRelease = externalRelease
        externalArtist = artist
        self.onSelectArtist = onSelectArtist
    }

    private var currentAlbum: Release? {
        guard let album else { return nil }
        return store.releases.first(where: { $0.id == album.id })
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
        .accessibilityIdentifier("album.detail.\(detailID)")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(alignment: .top, spacing: 24) {
                ArtworkView(
                    artworkID: artworkID,
                    size: artworkSize
                )

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
                    }

                    if let externalRelease {
                        externalReleaseMetadata(externalRelease)
                            .padding(.top, 8)

                        Text("Este lançamento está disponível somente na discografia online.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: artworkSize, alignment: .topLeading)
            }

            if let album, let currentAlbum {
                localAlbumControls(album: album, currentAlbum: currentAlbum)
            } else if let externalRelease,
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
        HStack(spacing: 10) {
                CollectionPlaybackControls(
                    isEnabled: !isLoading && !tracks.isEmpty,
                    presentation: .groupedCompactShuffle,
                    isFavorite: currentAlbum.isFavorite,
                    onToggleFavorite: {
                        store.setReleaseFavorite(
                            releaseID: album.id,
                            favorite: !currentAlbum.isFavorite
                        )
                    },
                    onPlay: {
                        Task {
                            await store.playRelease(
                                releaseID: album.id,
                                shuffleEnabled: false
                            )
                        }
                    },
                    onShuffle: {
                        Task {
                            await store.playRelease(
                                releaseID: album.id,
                                shuffleEnabled: true
                            )
                        }
                    }
                )

                Spacer(minLength: 24)

                Menu {
                    Button(currentAlbum.isFavorite ? "Desfavoritar álbum" : "Favoritar álbum",
                           systemImage: currentAlbum.isFavorite ? "star.slash" : "star") {
                        store.setReleaseFavorite(
                            releaseID: album.id,
                            favorite: !currentAlbum.isFavorite
                        )
                    }
                    Button("Abrir artista", systemImage: "person") {
                        guard let artist = store.artists.first(where: { $0.id == album.artistId }) else {
                            return
                        }
                        onSelectArtist(artist)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 34, height: 34)
                }
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .background(Color.primary.opacity(0.08), in: .circle)
                .help("Opções")
                .accessibilityLabel("Opções")
                .accessibilityIdentifier("album.options")

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
                .accessibilityIdentifier("album.tracks.search")

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
                .accessibilityIdentifier("album.tracks.organize")
        }
    }

    private var selectedArtist: Artist? {
        if let externalArtist { return externalArtist }
        guard let album else { return nil }
        return store.artists.first(where: { $0.id == album.artistId })
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
            albumDurationText(album.durationSeconds),
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

    private func albumDurationText(_ durationSeconds: UInt64) -> String {
        let totalMinutes = Int(durationSeconds) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            return minutes > 0 ? "\(hours) h \(minutes) min" : "\(hours) h"
        }
        return "\(totalMinutes) min"
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
                ? albumDurationText($0.durationSeconds)
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
                ForEach(Array(externalDetails.tracks.enumerated()), id: \.offset) { index, track in
                    externalTrackRow(track, totalDiscs: externalDetails.totalDiscs)

                    if index < externalDetails.tracks.count - 1 {
                        Divider()
                    }
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
            ContentUnavailableView.search(text: trackSearchText)
                .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 0) {
                ForEach(visibleTracks, id: \.id) { track in
                    trackRow(track)

                    if track.id != visibleTracks.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private var visibleTracks: [Track] {
        let query = trackSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var visibleTracks = tracks

        if !query.isEmpty {
            visibleTracks = visibleTracks.filter {
                $0.title.localizedStandardContains(query)
                    || $0.artist.localizedStandardContains(query)
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

    private func trackRow(_ track: Track) -> some View {
        HStack(spacing: 12) {
            AlbumTrackPosition(trackID: track.id, number: trackNumber(for: track))

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .activeTrackTitle(trackID: track.id)
                    .lineLimit(1)

                if !track.artist.isEmpty && track.artist != artistName {
                    Text(track.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(durationText(track.durationSeconds))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Button {
                Task { await store.addToQueue(trackID: track.id) }
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Adicionar \(track.title) à fila")
        }
        .padding(.vertical, 9)
        .playTrackOnDoubleClick {
            guard let album else { return }
            Task { await store.playRelease(releaseID: album.id, startingAt: track.id) }
        }
        .trackContextMenu(track: track) {
            guard let album else { return }
            Task { await store.playRelease(releaseID: album.id, startingAt: track.id) }
        }
        .accessibilityElement(children: .contain)
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

            Text(track.durationSeconds.map { durationText(Double($0)) } ?? "—")
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

    private func durationText(_ duration: Double) -> String {
        let totalSeconds = max(0, Int(duration.rounded()))
        return String(
            format: "%d:%02d",
            totalSeconds / 60,
            totalSeconds % 60
        )
    }
}
