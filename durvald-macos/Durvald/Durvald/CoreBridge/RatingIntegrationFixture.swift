#if DEBUG
import Foundation
import SQLite3

/// Isolated, real-core fixture shared by hosted integration and UI tests.
/// It never scans audio, starts playback, or opens the user's library database.
enum RatingIntegrationFixture {
    static func config(directory: URL) -> CoreConfig {
        CoreConfig(databasePath: directory.appendingPathComponent("ratings.db3").path,
            appSupportDir: directory.path, coversDir: directory.appendingPathComponent("covers").path,
            keychainService: "com.durvald.tests.ratings.\(directory.lastPathComponent)")
    }

    static func openCore(directory: URL, count: Int = 7) async throws -> DurvaldCore {
        let config = config(directory: directory)
        let core = try await open(config: config)
        try withDatabase(config.databasePath) { database in
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try check(sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM songs", -1, &statement, nil), database)
            guard sqlite3_step(statement) == SQLITE_ROW else { throw failure(database) }
            guard sqlite3_column_int(statement, 0) == 0 else { return }
            let ratings = ["NULL", "0", "1", "7", "8", "9", "10"]
            var sql = "BEGIN IMMEDIATE; INSERT INTO artists(artist_id,name) VALUES(1,'Rating fixture');"
            for id in 1...max(1, count) {
                let rating = ratings[(id - 1) % ratings.count]
                sql += """
                    INSERT INTO releases(release_id,title,artist_id,artist_name,duration,rating_half_steps)
                    VALUES(\(id),'Rating album \(id)',1,'Rating fixture',180,\(rating));
                    INSERT INTO songs(song_id,title,artist_id,artist_name,release_id,release_title,
                        track_number,disc_number,duration,file_path,rating_half_steps)
                    VALUES(\(id),'Rating track \(String(format: "%03d", id))',1,'Rating fixture',\(id),
                        'Rating album \(id)',1,1,180,'/rating-fixture/\(id).flac',\(rating));
                    """
            }
            sql += "COMMIT;"
            try execute(sql, database: database)
        }
        return core
    }

    static func onlineListenRelease() -> ExternalReleaseGroup {
        ExternalReleaseGroup(primaryArtistMbid: nil,
            musicbrainzId: "12345678-1234-1234-1234-123456789abc", title: "Online listening fixture",
            primaryType: "Album", secondaryTypes: [], firstReleaseDate: nil, localReleaseId: nil, artwork: nil,
            attribution: EnrichmentAttribution(sourceUrl: "https://musicbrainz.org/release-group/12345678-1234-1234-1234-123456789abc",
                author: nil, licenseName: nil, licenseUrl: nil, revision: nil))
    }

    @MainActor
    static func makeStore(directory: URL) async throws -> DurvaldCoreStore {
        let core = try await openCore(directory: directory)
        if ProcessInfo.processInfo.arguments.contains("--collection-track-fixture"), try await core.playlists().isEmpty {
            let playlist = try await core.createPlaylist(name: "Collection row fixture", description: "", artworkBase64: nil)
            for (index, id) in [Int64(1), 4, 5].enumerated() {
                _ = try await core.addTrackToPlaylist(playlistId: playlist.id, trackId: id, position: UInt64(index))
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--listen-list-external-fixture") {
            _ = try await core.addExternalToListenList(artistId: 1, release: onlineListenRelease())
        }
        if ProcessInfo.processInfo.arguments.contains("--classification-fixture"), try await core.classificationTerms().isEmpty {
            try await core.setClassification(target: .release, id: 1, kind: .genre, names: ["Electronic"])
            try await core.setClassification(target: .release, id: 5, kind: .genre, names: ["Electronic"])
            try await core.setClassification(target: .release, id: 2, kind: .genre, names: ["Rock"])
            try await core.setClassification(target: .release, id: 1, kind: .style, names: ["Ambient"])
            let terms = try await core.classificationTerms()
            if let style = terms.first(where: { $0.kind == .style }), let genre = terms.first(where: { $0.name == "Electronic" }) {
                try await core.setStyleGenres(styleId: style.id, genreIds: [genre.id])
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--album-metadata-fixture") {
            try withDatabase(config(directory: directory).databasePath) { database in
                try execute("UPDATE songs SET release_id=1,release_title='Rating album 1',track_number=2 WHERE song_id=2; UPDATE releases SET total_tracks=2 WHERE release_id=1;", database: database)
            }
        }
        let tracks = try await core.tracksPage(pageSize: 100, offset: 0).items
        let releases = try await core.releasesPage(pageSize: 100, offset: 0).items
        let store = DurvaldCoreStore(core: core, tracks: tracks, releases: releases)
        await store.refreshRatingPreferences()
        try await store.reloadPlaylists()
        return store
    }

    static func withDatabase<T>(_ path: String, body: (OpaquePointer) throws -> T) throws -> T {
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw NSError(domain: "RatingFixture.SQLite", code: 1)
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 5_000)
        return try body(database)
    }

    static func execute(_ sql: String, database: OpaquePointer) throws {
        try check(sqlite3_exec(database, sql, nil, nil, nil), database)
    }

    private static func check(_ code: Int32, _ database: OpaquePointer) throws {
        guard code == SQLITE_OK else { throw failure(database) }
    }

    private static func failure(_ database: OpaquePointer) -> NSError {
        NSError(domain: "RatingFixture.SQLite", code: Int(sqlite3_errcode(database)),
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))])
    }
}
#endif
