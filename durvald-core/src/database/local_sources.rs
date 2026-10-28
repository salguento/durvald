//! Additive local-source storage. Readers keep using songs.file_path until stage 7.
use rusqlite::{Connection, functions::FunctionFlags};
use std::{
    collections::HashMap,
    path::{Component, Path},
    time::Duration,
};

/// Preserve case, Unicode and `..`: resolving parent segments could cross symlinks.
/// This deliberately does not touch the filesystem (volumes may be disconnected).
fn path_key(value: &str) -> rusqlite::Result<String> {
    if !value.starts_with('/') || value.contains('\0') || value.ends_with('/') {
        return Err(rusqlite::Error::InvalidParameterName(
            "Invalid local media path".into(),
        ));
    }
    let parts: Vec<_> = Path::new(value)
        .components()
        .filter_map(|part| match part {
            Component::RootDir | Component::CurDir => None,
            _ => Some(part.as_os_str().to_string_lossy().into_owned()),
        })
        .collect();
    if parts.is_empty() {
        return Err(rusqlite::Error::InvalidParameterName(
            "Invalid local media path".into(),
        ));
    }
    Ok(format!("/{}", parts.join("/")))
}

pub(crate) fn register(conn: &Connection) -> rusqlite::Result<()> {
    conn.create_scalar_function(
        "durvald_local_path_key",
        1,
        FunctionFlags::SQLITE_UTF8
            | FunctionFlags::SQLITE_DETERMINISTIC
            | FunctionFlags::SQLITE_INNOCUOUS,
        |ctx| path_key(&ctx.get::<String>(0)?),
    )
}

/// Run before any DDL/backfill; do not silently merge identities on collision.
pub(crate) fn preflight(conn: &Connection) -> rusqlite::Result<()> {
    let mut paths = HashMap::new();
    let mut stmt = conn.prepare("SELECT song_id, file_path FROM songs ORDER BY song_id")?;
    for row in stmt.query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)))? {
        let (id, path) = row?;
        let key = path_key(&path).map_err(|_| {
            rusqlite::Error::InvalidParameterName(format!(
                "Local-source migration: invalid path for song {id}"
            ))
        })?;
        if let Some(previous) = paths.insert(key, id) {
            return Err(rusqlite::Error::InvalidParameterName(format!(
                "Local-source migration: path collision between songs {previous} and {id}; repair the legacy library before retrying"
            )));
        }
    }
    Ok(())
}

pub(crate) const SCHEMA: &str = r#"
CREATE TABLE track_sources (
    source_id INTEGER PRIMARY KEY AUTOINCREMENT,
    song_id INTEGER NOT NULL REFERENCES songs(song_id) ON DELETE CASCADE,
    provider TEXT NOT NULL DEFAULT 'local' CHECK(provider = 'local'),
    local_path TEXT NOT NULL,
    local_path_key TEXT NOT NULL UNIQUE CHECK(local_path_key = durvald_local_path_key(local_path)),
    is_primary_local INTEGER NOT NULL DEFAULT 0 CHECK(is_primary_local IN (0,1)),
    enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0,1)),
    priority INTEGER NOT NULL DEFAULT 0,
    association_origin TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(source_id, song_id)
);
CREATE UNIQUE INDEX idx_track_sources_primary ON track_sources(song_id) WHERE is_primary_local = 1;
CREATE INDEX idx_track_sources_song ON track_sources(song_id);
CREATE TABLE track_source_state (
    source_id INTEGER PRIMARY KEY REFERENCES track_sources(source_id) ON DELETE CASCADE,
    availability TEXT NOT NULL DEFAULT 'unknown' CHECK(availability IN ('unknown','available','unavailable')),
    last_checked_at TEXT, last_success_at TEXT, last_failure_at TEXT, retry_after TEXT
);
CREATE TABLE track_source_metadata (
    source_id INTEGER PRIMARY KEY REFERENCES track_sources(source_id) ON DELETE CASCADE,
    bitrate INTEGER, sample_rate INTEGER, bit_depth INTEGER,
    metadata TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(metadata))
);
CREATE TABLE playback_source_preferences (
    song_id INTEGER PRIMARY KEY REFERENCES songs(song_id) ON DELETE CASCADE,
    source_id INTEGER NOT NULL,
    FOREIGN KEY(source_id,song_id) REFERENCES track_sources(source_id,song_id) ON DELETE CASCADE
);
INSERT INTO track_sources(song_id,local_path,local_path_key,is_primary_local,association_origin)
    SELECT song_id,file_path,durvald_local_path_key(file_path),1,'legacy_migration' FROM songs ORDER BY song_id;
INSERT INTO track_source_state(source_id) SELECT source_id FROM track_sources;
INSERT INTO track_source_metadata(source_id,bitrate,sample_rate,bit_depth)
    SELECT source_id,bitrate,sample_rate,bit_depth FROM track_sources JOIN songs USING(song_id);

-- Missing-file reconciliation archives every source before removing the song.
CREATE TABLE missing_track_sources (
    source_id INTEGER PRIMARY KEY,
    missing_id INTEGER NOT NULL REFERENCES missing_tracks(missing_id) ON DELETE CASCADE,
    local_path TEXT NOT NULL,
    enabled INTEGER NOT NULL,
    priority INTEGER NOT NULL,
    created_at TEXT NOT NULL,
    payload TEXT NOT NULL CHECK(json_valid(payload))
);
CREATE TRIGGER songs_archive_local_sources BEFORE DELETE ON songs BEGIN
    INSERT OR REPLACE INTO missing_track_sources
        SELECT s.source_id,m.missing_id,s.local_path,s.enabled,s.priority,s.created_at,
            json_object('availability',st.availability,'last_checked_at',st.last_checked_at,
                'last_success_at',st.last_success_at,'last_failure_at',st.last_failure_at,
                'retry_after',st.retry_after,'bitrate',md.bitrate,'sample_rate',md.sample_rate,
                'bit_depth',md.bit_depth,'metadata',md.metadata)
        FROM track_sources s JOIN track_source_state st USING(source_id)
        JOIN track_source_metadata md USING(source_id)
        JOIN missing_tracks m ON m.original_song_id=OLD.song_id AND m.file_path=OLD.file_path
        WHERE s.song_id=OLD.song_id;
END;
CREATE TRIGGER songs_insert_local_source AFTER INSERT ON songs BEGIN
    INSERT INTO track_sources(song_id,local_path,local_path_key,is_primary_local,association_origin)
        VALUES(NEW.song_id,NEW.file_path,durvald_local_path_key(NEW.file_path),1,'local_import');
END;
CREATE TRIGGER sources_insert_state AFTER INSERT ON track_sources BEGIN
    INSERT INTO track_source_state(source_id) VALUES(NEW.source_id);
    INSERT INTO track_source_metadata(source_id,bitrate,sample_rate,bit_depth)
        SELECT NEW.source_id,bitrate,sample_rate,bit_depth FROM songs WHERE song_id=NEW.song_id;
END;
CREATE TRIGGER songs_update_local_source AFTER UPDATE OF file_path ON songs
WHEN NEW.file_path != OLD.file_path BEGIN
    UPDATE track_sources SET local_path=NEW.file_path,local_path_key=durvald_local_path_key(NEW.file_path),
        updated_at=CURRENT_TIMESTAMP WHERE song_id=NEW.song_id AND is_primary_local=1;
END;
CREATE TRIGGER songs_update_source_quality AFTER UPDATE OF bitrate,sample_rate,bit_depth ON songs BEGIN
    UPDATE track_source_metadata SET bitrate=NEW.bitrate,sample_rate=NEW.sample_rate,bit_depth=NEW.bit_depth
        WHERE source_id IN (SELECT source_id FROM track_sources WHERE song_id=NEW.song_id AND is_primary_local=1);
END;
CREATE TRIGGER sources_path_changed AFTER UPDATE OF local_path ON track_sources
WHEN NEW.local_path != OLD.local_path BEGIN
    UPDATE track_source_state SET availability='unknown',last_checked_at=NULL,last_success_at=NULL,
        last_failure_at=NULL,retry_after=NULL WHERE source_id=NEW.source_id;
END;
CREATE TRIGGER sources_check_primary_insert BEFORE INSERT ON track_sources
WHEN NEW.is_primary_local=1 AND NOT EXISTS(SELECT 1 FROM songs WHERE song_id=NEW.song_id AND file_path=NEW.local_path) BEGIN
    SELECT RAISE(ABORT,'Primary local source must match songs.file_path');
END;
CREATE TRIGGER sources_check_primary_update BEFORE UPDATE ON track_sources
WHEN NEW.is_primary_local=1 AND NOT EXISTS(SELECT 1 FROM songs WHERE song_id=NEW.song_id AND file_path=NEW.local_path) BEGIN
    SELECT RAISE(ABORT,'Update the primary local path through songs.file_path');
END;
CREATE TRIGGER sources_check_primary_delete BEFORE DELETE ON track_sources
WHEN OLD.is_primary_local=1 AND EXISTS(SELECT 1 FROM songs WHERE song_id=OLD.song_id) BEGIN
    SELECT RAISE(ABORT,'Delete the song to remove its primary local source');
END;
"#;

fn verify_backup(path: &str) -> rusqlite::Result<()> {
    let snapshot = Connection::open_with_flags(path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    register(&snapshot)?;
    let check: String = snapshot.query_row("PRAGMA integrity_check", [], |r| r.get(0))?;
    if check != "ok" || !snapshot.table_exists(None, "songs")? {
        return Err(rusqlite::Error::InvalidParameterName(
            "Invalid pre-migration library backup".into(),
        ));
    }
    Ok(())
}

/// SQLite backup includes committed WAL pages. Never overwrite the original snapshot.
pub(crate) fn backup_before_migration(
    conn: &Connection,
    database_path: &str,
) -> rusqlite::Result<()> {
    if !conn.table_exists(None, "songs")? {
        return Ok(());
    }
    let version = if conn.table_exists(None, "enrichment_migrations")? {
        conn.query_row(
            "SELECT COALESCE(MAX(version),0) FROM enrichment_migrations",
            [],
            |r| r.get::<_, i64>(0),
        )?
    } else {
        0
    };
    if version >= 22 {
        return Ok(());
    }
    let suffix = if version < 21 {
        "pre-local-sources"
    } else {
        "pre-optional-local-files"
    };
    let backup_path = format!("{database_path}.{suffix}.sqlite");
    if Path::new(&backup_path).exists() {
        return verify_backup(&backup_path);
    }
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(e)))?
        .as_nanos();
    let temporary = format!("{backup_path}.{}.{}.tmp", std::process::id(), stamp);
    let io_error = |e: std::io::Error| rusqlite::Error::ToSqlConversionFailure(Box::new(e));
    let result = (|| {
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        options.open(&temporary).map_err(io_error)?;
        let mut destination = Connection::open(&temporary)?;
        register(&destination)?;
        rusqlite::backup::Backup::new(conn, &mut destination)?.run_to_completion(
            128,
            Duration::from_millis(10),
            None,
        )?;
        let check: String = destination.query_row("PRAGMA integrity_check", [], |r| r.get(0))?;
        if check != "ok" {
            return Err(rusqlite::Error::InvalidQuery);
        }
        destination.close().map_err(|(_, err)| err)?;
        std::fs::File::open(&temporary)
            .map_err(io_error)?
            .sync_all()
            .map_err(io_error)?;
        match std::fs::hard_link(&temporary, &backup_path) {
            Ok(()) => Ok(()),
            Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => {
                verify_backup(&backup_path)
            }
            Err(err) => Err(io_error(err)),
        }
    })();
    let _ = std::fs::remove_file(&temporary);
    result
}

/// The donor disappears, but its files remain associated with the surviving song.
pub(crate) fn merge(conn: &Connection, donor: i64, target: i64) -> rusqlite::Result<()> {
    if !conn.table_exists(None, "track_sources")? {
        return Ok(());
    }
    conn.execute(
        "DELETE FROM playback_source_preferences WHERE song_id=?1",
        [donor],
    )?;
    conn.execute("UPDATE track_sources SET song_id=?2,is_primary_local=0,association_origin='library_repair',updated_at=CURRENT_TIMESTAMP WHERE song_id=?1", [donor,target])?;
    Ok(())
}

/// Missing files remain secondary candidates; their availability must be rechecked.
pub(crate) fn restore_missing(
    conn: &Connection,
    missing: i64,
    target: i64,
) -> rusqlite::Result<()> {
    if !conn.table_exists(None, "missing_track_sources")? {
        return Ok(());
    }
    let collision: bool = conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM missing_track_sources a JOIN track_sources s
         ON s.local_path_key=durvald_local_path_key(a.local_path)
         WHERE a.missing_id=?1 AND s.song_id!=?2)",
        [missing, target],
        |r| r.get(0),
    )?;
    if collision {
        return Err(rusqlite::Error::InvalidParameterName(
            "Archived source path is already owned by another song".into(),
        ));
    }
    conn.execute(
        "INSERT INTO track_sources(source_id,song_id,local_path,local_path_key,enabled,priority,association_origin,created_at)
         SELECT a.source_id,?2,a.local_path,durvald_local_path_key(a.local_path),a.enabled,a.priority,'library_repair',a.created_at
         FROM missing_track_sources a WHERE missing_id=?1 AND NOT EXISTS(
             SELECT 1 FROM track_sources s WHERE s.local_path_key=durvald_local_path_key(a.local_path))",
        [missing,target])?;
    conn.execute(
        "UPDATE track_source_metadata SET
             bitrate=json_extract(a.payload,'$.bitrate'),sample_rate=json_extract(a.payload,'$.sample_rate'),
             bit_depth=json_extract(a.payload,'$.bit_depth'),metadata=json_extract(a.payload,'$.metadata')
         FROM missing_track_sources a WHERE track_source_metadata.source_id=a.source_id AND a.missing_id=?1",
        [missing])?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::database::{
        migrations::migrate_stage6 as migrate_enrichment, operations::create_tables,
    };
    use rusqlite::{params, types::Value};

    fn legacy() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("PRAGMA foreign_keys=ON").unwrap();
        create_tables(&conn).unwrap();
        conn
    }

    fn song(conn: &Connection, id: i64, path: &str) {
        conn.execute("INSERT INTO songs(song_id,title,artist_id,artist_name,release_id,release_title,track_number,duration,file_path,rating_half_steps,is_favorite,play_count,bitrate)
            VALUES(?1,'Track',1,'Artist',1,'Album',1,180,?2,7,1,12,320)", params![id,path]).unwrap();
    }

    fn rows(conn: &Connection, table: &str) -> Vec<Vec<Value>> {
        let mut stmt = conn
            .prepare(&format!("SELECT * FROM {table} ORDER BY rowid"))
            .unwrap();
        let width = stmt.column_count();
        stmt.query_map([], |r| (0..width).map(|i| r.get(i)).collect())
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    }

    #[test]
    fn migration_preserves_personal_data_and_duplicate_playlist_positions() {
        let mut conn = legacy();
        song(&conn, 42, "/Volumes/Música/track.flac");
        song(&conn, 99, "/Volumes/Música/other.flac");
        conn.execute_batch("INSERT INTO playlists(id,name) VALUES(8,'Ordered');
            INSERT INTO playlist_songs(playlist_id,song_id,position) VALUES(8,42,0),(8,99,1),(8,42,2);
            INSERT INTO play_history(history_id,song_id,played_at,play_duration) VALUES(5,42,'2026-01-01',90);").unwrap();
        let tables = ["songs", "playlists", "playlist_songs", "play_history"];
        let before: Vec<_> = tables.iter().map(|t| rows(&conn, t)).collect();
        migrate_enrichment(&mut conn).unwrap();
        let sources = rows(&conn, "track_sources");
        migrate_enrichment(&mut conn).unwrap();
        assert_eq!(sources, rows(&conn, "track_sources"));
        for (index, table) in tables.iter().enumerate() {
            assert_eq!(before[index], rows(&conn, table), "{table}");
        }
        assert_eq!(
            conn.query_row(
                "SELECT COUNT(*) FROM track_source_state WHERE availability='unknown'",
                [],
                |r| r.get::<_, i64>(0)
            )
            .unwrap(),
            2
        );
        assert_eq!(
            conn.query_row(
                "SELECT bitrate FROM track_source_metadata LIMIT 1",
                [],
                |r| r.get::<_, i64>(0)
            )
            .unwrap(),
            320
        );
        assert!(rows(&conn, "playback_source_preferences").is_empty());
        assert!(
            !conn
                .prepare("PRAGMA foreign_key_check")
                .unwrap()
                .exists([])
                .unwrap()
        );
    }

    #[test]
    fn collision_aborts_all_schema_changes_without_merging_songs() {
        let mut conn = legacy();
        song(&conn, 1, "/music/a.flac");
        song(&conn, 2, "/music//./a.flac");
        let before = rows(&conn, "songs");
        let error = migrate_enrichment(&mut conn).unwrap_err().to_string();
        assert!(error.contains("collision between songs 1 and 2"), "{error}");
        assert_eq!(before, rows(&conn, "songs"));
        assert!(!conn.table_exists(None, "track_sources").unwrap());
        assert!(!conn.table_exists(None, "enrichment_migrations").unwrap());
        conn.execute(
            "UPDATE songs SET file_path='/music/b.flac' WHERE song_id=2",
            [],
        )
        .unwrap();
        migrate_enrichment(&mut conn).unwrap();
        assert_eq!(rows(&conn, "track_sources").len(), 2);
    }

    #[test]
    fn writes_relinks_and_deletes_are_atomic_and_preferences_are_owned() {
        let mut conn = legacy();
        migrate_enrichment(&mut conn).unwrap();
        song(&conn, 1, "/music/a.flac");
        song(&conn, 2, "/music/b.flac");
        let source: i64 = conn
            .query_row(
                "SELECT source_id FROM track_sources WHERE song_id=1",
                [],
                |r| r.get(0),
            )
            .unwrap();
        conn.execute(
            "INSERT INTO playback_source_preferences VALUES(1,?1)",
            [source],
        )
        .unwrap();
        assert!(
            conn.execute(
                "INSERT INTO playback_source_preferences VALUES(2,?1)",
                [source]
            )
            .is_err()
        );
        assert!(
            conn.execute(
                "UPDATE songs SET file_path='/music//b.flac' WHERE song_id=1",
                []
            )
            .is_err()
        );
        assert_eq!(
            conn.query_row("SELECT file_path FROM songs WHERE song_id=1", [], |r| {
                r.get::<_, String>(0)
            })
            .unwrap(),
            "/music/a.flac"
        );
        conn.execute("UPDATE track_source_state SET availability='available',last_success_at='2026-01-01' WHERE source_id=?1",[source]).unwrap();
        conn.execute(
            "UPDATE songs SET file_path='/new/a.flac',bitrate=256 WHERE song_id=1",
            [],
        )
        .unwrap();
        assert_eq!(
            conn.query_row(
                "SELECT local_path FROM track_sources WHERE source_id=?1",
                [source],
                |r| r.get::<_, String>(0)
            )
            .unwrap(),
            "/new/a.flac"
        );
        assert_eq!(
            conn.query_row(
                "SELECT availability FROM track_source_state WHERE source_id=?1",
                [source],
                |r| r.get::<_, String>(0)
            )
            .unwrap(),
            "unknown"
        );
        assert!(
            conn.execute("DELETE FROM track_sources WHERE source_id=?1", [source])
                .is_err()
        );
        conn.execute("DELETE FROM songs WHERE song_id=1", [])
            .unwrap();
        assert!(rows(&conn, "playback_source_preferences").is_empty());
        assert_eq!(rows(&conn, "track_sources").len(), 1);
        assert_eq!(rows(&conn, "track_source_state").len(), 1);
        assert_eq!(rows(&conn, "track_source_metadata").len(), 1);
        song(&conn, 3, "/new/c.flac");
        assert!(
            conn.query_row(
                "SELECT source_id FROM track_sources WHERE song_id=3",
                [],
                |r| r.get::<_, i64>(0)
            )
            .unwrap()
                > source
        );
    }

    #[test]
    fn repair_preserves_donor_sources_and_archived_missing_sources() {
        let mut conn = legacy();
        migrate_enrichment(&mut conn).unwrap();
        song(&conn, 1, "/music/target.flac");
        song(&conn, 2, "/music/donor.flac");
        crate::library_repair::merge(&conn, 2, 1, false).unwrap();
        assert_eq!(rows(&conn, "track_sources").len(), 2);
        assert_eq!(
            conn.query_row(
                "SELECT COUNT(*) FROM track_sources WHERE song_id=1",
                [],
                |r| r.get::<_, i64>(0)
            )
            .unwrap(),
            2
        );
        conn.execute("INSERT INTO missing_tracks(missing_id,original_song_id,title,artist_name,release_title,track_number,disc_number,duration,file_path,play_count,is_favorite,is_hidden,suggest_less)
            VALUES(9,1,'Track','Artist','Album',1,1,180,'/music/target.flac',0,0,0,0)",[]).unwrap();
        let before = rows(&conn, "track_sources");
        conn.execute("DELETE FROM songs WHERE song_id=1", [])
            .unwrap();
        assert_eq!(rows(&conn, "missing_track_sources").len(), 2);
        song(&conn, 3, "/music/restored.flac");
        crate::library_repair::merge(&conn, 9, 3, true).unwrap();
        assert_eq!(rows(&conn, "track_sources").len(), 3);
        assert!(rows(&conn, "missing_track_sources").is_empty());
        for row in before {
            assert!(
                rows(&conn, "track_sources")
                    .iter()
                    .any(|new| new[0] == row[0] && new[3] == row[3])
            );
        }
        assert!(
            !conn
                .prepare("PRAGMA foreign_key_check")
                .unwrap()
                .exists([])
                .unwrap()
        );
    }

    #[test]
    fn backup_includes_wal_and_is_not_overwritten_on_retry() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("library.sqlite");
        let mut conn = Connection::open(&path).unwrap();
        conn.execute_batch("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;")
            .unwrap();
        create_tables(&conn).unwrap();
        song(&conn, 42, "/offline/track.flac");
        backup_before_migration(&conn, path.to_str().unwrap()).unwrap();
        let backup_path = format!("{}.pre-local-sources.sqlite", path.display());
        let bytes = std::fs::read(&backup_path).unwrap();
        backup_before_migration(&conn, path.to_str().unwrap()).unwrap();
        assert_eq!(bytes, std::fs::read(&backup_path).unwrap());
        let mut backup = Connection::open(&backup_path).unwrap();
        assert_eq!(rows(&conn, "songs"), rows(&backup, "songs"));
        assert!(!backup.table_exists(None, "track_sources").unwrap());
        // A pre-migration backup can be restored and upgraded independently.
        migrate_enrichment(&mut backup).unwrap();
        migrate_enrichment(&mut conn).unwrap();
        // Independent upgrades have different association timestamps.
        let restored_sources = rows(&backup, "track_sources");
        let live_sources = rows(&conn, "track_sources");
        assert_eq!(live_sources.len(), restored_sources.len());
        for (live, restored) in live_sources.iter().zip(&restored_sources) {
            assert_eq!(live[..9], restored[..9]);
        }
        // Use a separate snapshot for the no-overwrite assertion (backup was upgraded above).
        let saved = std::fs::read(&backup_path).unwrap();
        backup_before_migration(&conn, path.to_str().unwrap()).unwrap();
        assert_eq!(saved, std::fs::read(&backup_path).unwrap());
        assert!(!bytes.is_empty());
    }

    #[test]
    fn invalid_existing_backup_blocks_upgrade_without_overwriting_it() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("library.sqlite");
        let conn = Connection::open(&path).unwrap();
        create_tables(&conn).unwrap();
        song(&conn, 1, "/music/track.flac");
        let backup_path = format!("{}.pre-local-sources.sqlite", path.display());
        std::fs::write(&backup_path, b"invalid snapshot").unwrap();
        assert!(backup_before_migration(&conn, path.to_str().unwrap()).is_err());
        assert_eq!(std::fs::read(&backup_path).unwrap(), b"invalid snapshot");
        assert!(!conn.table_exists(None, "track_sources").unwrap());
    }

    #[test]
    fn normalization_preserves_platform_and_symlink_distinctions() {
        assert_eq!(path_key("//music/./a.flac").unwrap(), "/music/a.flac");
        assert_ne!(
            path_key("/Music/a.flac").unwrap(),
            path_key("/music/a.flac").unwrap()
        );
        assert_ne!(
            path_key("/link/../a.flac").unwrap(),
            path_key("/a.flac").unwrap()
        );
        assert!(path_key("relative.flac").is_err());
        let mut conn = legacy();
        song(&conn, 1, "relative.flac");
        assert!(
            migrate_enrichment(&mut conn)
                .unwrap_err()
                .to_string()
                .contains("invalid path for song 1")
        );
    }
}
