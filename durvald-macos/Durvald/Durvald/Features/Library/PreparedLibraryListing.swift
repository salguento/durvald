import Foundation
import Observation

/// Only scalar revisions/preferences identify work. Arrays are worker payloads.
struct LibraryListingKey: Equatable {
    var storeID: ObjectIdentifier? = nil
    var catalogRevision: UInt64 = 0
    var tracksRevision: UInt64 = 0
    var releasesRevision: UInt64 = 0
    var artistsRevision: UInt64 = 0
    var playlistsRevision: UInt64 = 0
    var payloadRevision: UInt64 = 0
    var orderingRevision: UInt64 = 0
    var scope = ""
    var query = ""
    var order: CollectionListingOrder = .alphabetical
    var minimumRating = 0
    var ratingsEnabled = true
    var onlyLocal = false
    var newestFirst = true
}

@MainActor
@Observable
final class PreparedLibraryListing<Value> {
    private(set) var value: Value
    private(set) var revision: UInt64 = 0
    private(set) var isPreparing = false
    @ObservationIgnored private(set) var completedKey: LibraryListingKey?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var worker: Task<Value, Never>?

    init(_ initial: Value) { value = initial }

    // UniFFI records have value-only fields but do not declare Sendable. The
    // caller supplies an immutable value snapshot; only the worker reads it.
    private struct WorkerPayload<Payload>: @unchecked Sendable { let value: Payload }

    func prepare<Payload>(key: LibraryListingKey, payload: Payload,
                          build: @escaping @Sendable (Payload) async -> Value) async {
        let snapshot = WorkerPayload(value: payload)
        await prepare(key: key) { await build(snapshot.value) }
    }

    func prepare(key: LibraryListingKey, build: @escaping @Sendable () async -> Value) async {
        let requestGeneration = UUID()
        generation = requestGeneration
        worker?.cancel()
        worker = nil
        guard !Task.isCancelled, completedKey != key else { isPreparing = false; return }
        isPreparing = true
        let task = Task.detached(priority: .userInitiated) { await build() }
        worker = task
        let prepared = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard generation == requestGeneration else { return }
        worker = nil
        isPreparing = false
        guard !Task.isCancelled else { return }
        value = prepared
        completedKey = key
        revision &+= 1
    }
}

struct AlbumListingSnapshot {
    var items: [Release] = []
    var summary = ""

    static func build(releases: [Release], updates: [Release], tracks: [Track], sizes: [String: Int64],
                      key: LibraryListingKey, recency: [Int64: String]) -> Self {
        let updated = Dictionary(updates.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let filtered = releases.map { updated[$0.id] ?? $0 }.filter {
            (!key.ratingsEnabled || key.minimumRating == 0 || Int($0.rating ?? 0) >= key.minimumRating)
            && (key.query.isEmpty || $0.title.localizedCaseInsensitiveContains(key.query)
                || $0.artist.localizedCaseInsensitiveContains(key.query))
        }
        let ids = Set(filtered.map(\.id))
        let summary = MusicLibrarySummary(tracks: tracks.filter { ids.contains($0.releaseId) }, kind: .all, fileSizes: sizes)
        let hours = summary.durationSeconds / 3600
        let minutes = summary.durationSeconds / 60 % 60
        let duration = hours > 0
            ? "\(hours) \(hours == 1 ? "hora" : "horas"), \(minutes) \(minutes == 1 ? "minuto" : "minutos")"
            : "\(minutes) \(minutes == 1 ? "minuto" : "minutos")"
        let size = summary.totalBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
        let prefix = key.query.isEmpty ? "" : "Resultados para “\(key.query)” • "
        return Self(items: CollectionListingSorter.albums(filtered, order: key.order, lastPlayedByRelease: recency),
                    summary: "\(prefix)\(ids.count.formatted()) \(ids.count == 1 ? "item" : "itens"), \(duration), \(size)")
    }
}

struct ArtistListingSnapshot {
    var items: [Artist] = []
    var fallbackArtwork: [Int64: String] = [:]
    var summary = "Carregando…"

    static func build(artists: [Artist], releases: [Release], localIDs: Set<Int64>,
                      key: LibraryListingKey, recency: [Int64: String]) -> Self {
        let filtered = artists.filter {
            (!key.onlyLocal || localIDs.contains($0.id))
            && (key.query.isEmpty || $0.name.localizedCaseInsensitiveContains(key.query))
        }
        let artwork = firstRecordIndex(releases, key: { $0.artistId }).compactMapValues(\.artworkId)
        let localCount = filtered.filter { localIDs.contains($0.id) }.count
        let indexedCount = filtered.count - localCount
        let localText = "\(localCount.formatted()) \(localCount == 1 ? "artista local" : "artistas locais")"
        let indexedText = "\(indexedCount.formatted()) \(indexedCount == 1 ? "artista indexado" : "artistas indexados")"
        let prefix = key.query.isEmpty ? "" : "Resultados para “\(key.query)” • "
        return Self(items: CollectionListingSorter.artists(filtered, order: key.order, releases: releases, lastPlayedByRelease: recency),
                    fallbackArtwork: artwork, summary: "\(prefix)\(localText), \(indexedText)")
    }
}

struct HistoryListingSnapshot {
    var items: [PlaybackHistoryItem] = []
    var tracksByID: [Int64: Track] = [:]
    var summary = ""

    static func build(entries: [PlaybackHistoryItem], tracks: [Int64: Track], key: LibraryListingKey) -> Self {
        let filtered = entries.filter { item in
            guard !key.query.isEmpty else { return true }
            guard let track = tracks[item.trackId] else {
                return "Música #\(item.trackId)".localizedCaseInsensitiveContains(key.query)
            }
            return [track.title, track.artist, track.release].contains { $0.localizedCaseInsensitiveContains(key.query) }
        }
        let duration = filtered.reduce(UInt64.zero) { $0 + $1.durationSeconds }
        let time = duration >= 3600
            ? String(format: "%llu:%02llu:%02llu", duration / 3600, duration / 60 % 60, duration % 60)
            : String(format: "%llu:%02llu", duration / 60, duration % 60)
        let songs = Set(filtered.map(\.trackId)).count
        let prefix = key.query.isEmpty ? "" : "Resultados para “\(key.query)” • "
        let summary = "\(prefix)\(filtered.count.formatted()) \(filtered.count == 1 ? "reprodução" : "reproduções"), \(songs.formatted()) \(songs == 1 ? "música" : "músicas"), \(time) de reprodução"
        return Self(items: filtered.sorted { key.newestFirst ? $0.id > $1.id : $0.id < $1.id }, tracksByID: tracks, summary: summary)
    }
}

struct SidebarListingSnapshot {
    var artistFallbackArtwork: [Int64: String] = [:]
    var albums: [Release] = []
    var artists: [Artist] = []
    var playlists: [Playlist] = []

    static func build(albums: [Release], artists: [Artist], playlists: [Playlist],
                      tracks: [Int64: [Track]], recency: [Int64: String], key: LibraryListingKey) -> Self {
        switch key.scope {
        case "albums":
            let filtered = albums.filter { key.query.isEmpty || $0.title.localizedStandardContains(key.query) || $0.artist.localizedStandardContains(key.query) }
            return Self(albums: CollectionListingSorter.albums(filtered, order: key.order, lastPlayedByRelease: recency))
        case "artists":
            let filtered = artists.filter { key.query.isEmpty || $0.name.localizedStandardContains(key.query) }
            return Self(artistFallbackArtwork: firstRecordIndex(albums, key: { $0.artistId }).compactMapValues(\.artworkId),
                        artists: CollectionListingSorter.artists(filtered, order: key.order, releases: albums, lastPlayedByRelease: recency))
        case "playlists":
            let filtered = playlists.filter { key.query.isEmpty || $0.name.localizedStandardContains(key.query) }
            return Self(playlists: CollectionListingSorter.playlists(filtered, order: key.order, tracksByPlaylist: tracks, releases: albums))
        default: return Self()
        }
    }
}
