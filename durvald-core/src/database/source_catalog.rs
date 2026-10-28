//! Stage 7: source-owned media and catalog rows without required local files.
use rusqlite::Connection;

fn rebuild(
    conn: &Connection,
    table: &str,
    replacement: &str,
    projection: &str,
) -> rusqlite::Result<()> {
    let schema: String = conn.query_row(
        "SELECT sql FROM sqlite_master WHERE type='table' AND name=?1",
        [table],
        |r| r.get(0),
    )?;
    let objects = conn.prepare("SELECT sql FROM sqlite_master WHERE tbl_name=?1 AND type IN ('index','trigger') AND sql IS NOT NULL ORDER BY type,name")?
        .query_map([table], |r|r.get::<_,String>(0))?.collect::<Result<Vec<_>,_>>()?;
    let sequence: Option<i64> = if table == "track_sources" {
        conn.query_row(
            "SELECT seq FROM sqlite_sequence WHERE name=?1",
            [table],
            |r| r.get(0),
        )
        .ok()
    } else {
        None
    };
    let temporary = format!("{table}_stage7");
    let ddl = if replacement.is_empty() {
        schema.replacen(table, &temporary, 1).replace(
            "file_path TEXT NOT NULL",
            "file_path TEXT CHECK(file_path IS NULL OR length(file_path)>0)",
        )
    } else {
        replacement.replace(
            "CREATE TABLE track_sources",
            &format!("CREATE TABLE {temporary}"),
        )
    };
    conn.execute_batch(&ddl)?;
    conn.execute_batch(&format!("INSERT INTO {temporary} {projection}; DROP TABLE {table}; ALTER TABLE {temporary} RENAME TO {table};"))?;
    if let Some(sequence) = sequence {
        conn.execute("INSERT INTO sqlite_sequence(name,seq) SELECT ?1,?2 WHERE NOT EXISTS(SELECT 1 FROM sqlite_sequence WHERE name=?1)",rusqlite::params![table,sequence])?;
        conn.execute(
            "UPDATE sqlite_sequence SET seq=MAX(seq,?2) WHERE name=?1",
            rusqlite::params![table, sequence],
        )?;
    }
    for sql in objects {
        conn.execute_batch(&sql)?;
    }
    Ok(())
}

pub(crate) fn migrate(conn: &Connection) -> rusqlite::Result<()> {
    // Rebuilding uses the documented SQLite sequence with FK enforcement disabled
    // by the migration owner, and checks every relationship before committing.
    for name in [
        "songs_insert_local_source",
        "songs_update_local_source",
        "songs_update_source_quality",
        "songs_archive_local_sources",
        "sources_insert_state",
        "sources_path_changed",
        "sources_check_primary_insert",
        "sources_check_primary_update",
        "sources_check_primary_delete",
    ] {
        conn.execute_batch(&format!("DROP TRIGGER IF EXISTS {name}"))?;
    }
    rebuild(conn, "songs", "", "SELECT * FROM songs")?;
    rebuild(
        conn,
        "track_metadata_changes",
        "",
        "SELECT * FROM track_metadata_changes",
    )?;
    rebuild(
        conn,
        "track_sources",
        SOURCES,
        "(source_id,song_id,provider,local_path,local_path_key,is_primary_local,enabled,priority,association_origin,created_at,updated_at) SELECT source_id,song_id,provider,local_path,local_path_key,is_primary_local,enabled,priority,association_origin,created_at,updated_at FROM track_sources",
    )?;
    conn.execute_batch(TRIGGERS)
}

const SOURCES: &str = r#"
CREATE TABLE track_sources (
 source_id INTEGER PRIMARY KEY AUTOINCREMENT,
 song_id INTEGER NOT NULL REFERENCES songs(song_id) ON DELETE CASCADE,
 provider TEXT NOT NULL DEFAULT 'local',
 local_path TEXT,
 local_path_key TEXT UNIQUE,
 is_primary_local INTEGER NOT NULL DEFAULT 0 CHECK(is_primary_local IN (0,1)),
 enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0,1)),
 priority INTEGER NOT NULL DEFAULT 0,
 association_origin TEXT NOT NULL,
 created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
 updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
 external_id TEXT, canonical_url TEXT,
 UNIQUE(source_id,song_id),
 CHECK((provider='local' AND local_path IS NOT NULL AND local_path_key IS NOT NULL
     AND local_path_key=durvald_local_path_key(local_path) AND external_id IS NULL AND canonical_url IS NULL)
    OR (provider!='local' AND length(provider)>0 AND external_id IS NOT NULL AND length(external_id)>0 AND canonical_url IS NOT NULL
     AND (canonical_url LIKE 'https://%' OR canonical_url LIKE 'http://%')
     AND local_path IS NULL AND local_path_key IS NULL AND is_primary_local=0))
);
"#;

const TRIGGERS: &str = r#"
CREATE UNIQUE INDEX idx_track_sources_external ON track_sources(provider,external_id) WHERE external_id IS NOT NULL;
CREATE TABLE catalog_track_references (
 provider TEXT NOT NULL, entity_kind TEXT NOT NULL, external_id TEXT NOT NULL,
 song_id INTEGER NOT NULL REFERENCES songs(song_id) ON DELETE CASCADE,
 PRIMARY KEY(provider,entity_kind,external_id)
);
CREATE INDEX idx_catalog_track_reference_song ON catalog_track_references(song_id);
CREATE VIEW local_track_paths AS
 SELECT song_id,source_id,local_path,is_primary_local,priority FROM track_sources WHERE provider='local';

CREATE TRIGGER songs_insert_local_source AFTER INSERT ON songs WHEN NEW.file_path IS NOT NULL BEGIN
 INSERT INTO track_sources(song_id,provider,local_path,local_path_key,is_primary_local,association_origin)
 VALUES(NEW.song_id,'local',NEW.file_path,durvald_local_path_key(NEW.file_path),1,'local_import');
END;
CREATE TRIGGER songs_update_local_source AFTER UPDATE OF file_path ON songs
WHEN NEW.file_path IS NOT OLD.file_path AND NEW.file_path IS NOT
 (SELECT local_path FROM local_track_paths WHERE song_id=NEW.song_id ORDER BY is_primary_local DESC,priority DESC,source_id LIMIT 1) BEGIN
 UPDATE track_sources SET local_path=NEW.file_path,local_path_key=durvald_local_path_key(NEW.file_path),updated_at=CURRENT_TIMESTAMP
 WHERE NEW.file_path IS NOT NULL AND source_id=(SELECT source_id FROM local_track_paths WHERE song_id=NEW.song_id ORDER BY is_primary_local DESC,priority DESC,source_id LIMIT 1);
 INSERT INTO track_sources(song_id,provider,local_path,local_path_key,is_primary_local,association_origin)
 SELECT NEW.song_id,'local',NEW.file_path,durvald_local_path_key(NEW.file_path),1,'local_import'
 WHERE NEW.file_path IS NOT NULL AND NOT EXISTS(SELECT 1 FROM local_track_paths WHERE song_id=NEW.song_id);
 DELETE FROM track_sources WHERE song_id=NEW.song_id AND provider='local' AND NEW.file_path IS NULL;
END;
CREATE TRIGGER sources_insert_state AFTER INSERT ON track_sources BEGIN
 INSERT INTO track_source_state(source_id) VALUES(NEW.source_id);
 INSERT INTO track_source_metadata(source_id,bitrate,sample_rate,bit_depth)
 SELECT NEW.source_id,bitrate,sample_rate,bit_depth FROM songs WHERE song_id=NEW.song_id;
 UPDATE songs SET file_path=(SELECT local_path FROM local_track_paths WHERE song_id=NEW.song_id ORDER BY is_primary_local DESC,priority DESC,source_id LIMIT 1) WHERE song_id=NEW.song_id;
END;
CREATE TRIGGER sources_sync_path AFTER UPDATE OF local_path,song_id,is_primary_local,priority ON track_sources BEGIN
 UPDATE songs SET file_path=(SELECT local_path FROM local_track_paths WHERE song_id=OLD.song_id ORDER BY is_primary_local DESC,priority DESC,source_id LIMIT 1) WHERE song_id=OLD.song_id;
 UPDATE songs SET file_path=(SELECT local_path FROM local_track_paths WHERE song_id=NEW.song_id ORDER BY is_primary_local DESC,priority DESC,source_id LIMIT 1) WHERE song_id=NEW.song_id;
END;
CREATE TRIGGER sources_delete_path AFTER DELETE ON track_sources BEGIN
 DELETE FROM track_file_identity WHERE song_id=OLD.song_id AND OLD.provider='local';
 UPDATE songs SET file_path=(SELECT local_path FROM local_track_paths WHERE song_id=OLD.song_id ORDER BY is_primary_local DESC,priority DESC,source_id LIMIT 1) WHERE song_id=OLD.song_id;
END;
CREATE TRIGGER sources_path_changed AFTER UPDATE OF local_path ON track_sources WHEN NEW.local_path IS NOT OLD.local_path BEGIN
 DELETE FROM track_file_identity WHERE song_id=OLD.song_id;
 UPDATE track_source_state SET availability='unknown',last_checked_at=NULL,last_success_at=NULL,last_failure_at=NULL,retry_after=NULL WHERE source_id=NEW.source_id;
END;
CREATE TRIGGER songs_update_source_quality AFTER UPDATE OF bitrate,sample_rate,bit_depth ON songs BEGIN
 UPDATE track_source_metadata SET bitrate=NEW.bitrate,sample_rate=NEW.sample_rate,bit_depth=NEW.bit_depth WHERE source_id IN
 (SELECT source_id FROM local_track_paths WHERE song_id=NEW.song_id ORDER BY is_primary_local DESC,priority DESC,source_id LIMIT 1);
END;
CREATE TRIGGER songs_archive_local_sources BEFORE DELETE ON songs BEGIN
 INSERT OR REPLACE INTO missing_track_sources
 SELECT s.source_id,m.missing_id,s.local_path,s.enabled,s.priority,s.created_at,
 json_object('bitrate',md.bitrate,'sample_rate',md.sample_rate,'bit_depth',md.bit_depth,'metadata',md.metadata)
 FROM track_sources s JOIN track_source_metadata md USING(source_id)
 JOIN missing_tracks m ON m.original_song_id=OLD.song_id AND m.file_path=OLD.file_path
 WHERE s.song_id=OLD.song_id AND s.provider='local';
END;
"#;

/// A disappearing local file cannot delete personal data owned by a track that
/// still has any other source, including a disabled/offline remote source.
pub(crate) fn remove_missing_files_with_surviving_sources(
    conn: &Connection,
    root: &str,
    scan: &str,
) -> rusqlite::Result<()> {
    conn.execute("DELETE FROM track_sources WHERE source_id IN (
        SELECT gone.source_id FROM track_sources gone WHERE gone.provider='local'
        AND substr(gone.local_path,1,length(?1))=?1
        AND NOT EXISTS(SELECT 1 FROM scan_discovered_paths d WHERE d.scan_id=?2 AND d.file_path=gone.local_path)
        AND EXISTS(SELECT 1 FROM track_sources keep WHERE keep.song_id=gone.song_id AND (
            keep.provider!='local' OR substr(keep.local_path,1,length(?1))!=?1 OR
            EXISTS(SELECT 1 FROM scan_discovered_paths d WHERE d.scan_id=?2 AND d.file_path=keep.local_path))))",rusqlite::params![root,scan])?;
    Ok(())
}

pub(crate) fn save_remote(
    conn: &mut Connection,
    entry: &crate::api::CatalogEntry,
) -> rusqlite::Result<i64> {
    let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
    let id = save_remote_inner(&tx, entry, true)?;
    tx.commit()?;
    Ok(id)
}
pub(crate) fn save_remote_inner(
    conn: &Connection,
    entry: &crate::api::CatalogEntry,
    include_source: bool,
) -> rusqlite::Result<i64> {
    use rusqlite::{OptionalExtension, params};
    let kind = serde_json::to_string(&entry.reference.kind)
        .map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(e)))?;
    if let Some(id)=conn.query_row("SELECT song_id FROM catalog_track_references WHERE provider=?1 AND entity_kind=?2 AND external_id=?3",params![entry.reference.provider,kind,entry.reference.id],|r|r.get::<_,i64>(0)).optional()? { return Ok(id); }
    // A recording is a catalog identity, not proof of playable audio.
    let artist = entry
        .artist_credit
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or("Artista desconhecido");
    // A display credit cannot establish artist identity. Keep it provisional
    // rather than attaching this track to an unrelated homonym by name.
    conn.execute("INSERT INTO artists(name) VALUES(?1)", [artist])?;
    let artist_id = conn.last_insert_rowid();
    conn.execute("INSERT INTO artist_enrichment_state(artist_id,identity_origin) VALUES(?1,'remote_track_credit')",[artist_id])?;
    conn.execute("INSERT INTO releases(title,artist_id,artist_name,total_tracks,total_discs,duration) VALUES(?1,?2,?3,1,1,?4)",params![entry.title,artist_id,artist,entry.duration_seconds.unwrap_or(0)])?;
    let release = conn.last_insert_rowid();
    conn.execute("INSERT INTO songs(title,artist_id,artist_name,release_id,release_title,track_number,disc_number,duration,file_path) VALUES(?1,?2,?3,?4,?1,1,1,?5,NULL)",params![entry.title,artist_id,artist,release,entry.duration_seconds.unwrap_or(0)])?;
    let id = conn.last_insert_rowid();
    conn.execute(
        "INSERT INTO song_artists(song_id,artist_id,position) VALUES(?1,?2,0)",
        params![id, artist_id],
    )?;
    conn.execute("INSERT INTO catalog_track_references(provider,entity_kind,external_id,song_id) VALUES(?1,?2,?3,?4)",params![entry.reference.provider,kind,entry.reference.id,id])?;
    if include_source
        && matches!(
            entry.reference.kind,
            crate::api::CatalogItemKind::AudioTrack | crate::api::CatalogItemKind::Video
        )
    {
        if let Some(url) = &entry.canonical_url {
            conn.execute("INSERT INTO track_sources(song_id,provider,external_id,canonical_url,association_origin) VALUES(?1,?2,?3,?4,'explicit_catalog_save')",params![id,entry.reference.provider,entry.reference.id,url])?;
        }
    }
    Ok(id)
}

pub(crate) fn cache_scan_time(
    conn: &Connection,
    path: &str,
    mtime: i64,
    version: i64,
) -> rusqlite::Result<()> {
    conn.execute("UPDATE track_source_metadata SET metadata=json_set(metadata,'$.scan_mtime',?2,'$.scan_version',?3) WHERE source_id IN (SELECT source_id FROM track_sources WHERE provider='local' AND local_path_key=durvald_local_path_key(?1))",rusqlite::params![path,mtime,version])?;
    Ok(())
}

pub(crate) fn cache_scanned_source(
    conn: &Connection,
    md: &crate::metadata::AudioMetadata,
    mtime: i64,
    version: i64,
) -> rusqlite::Result<()> {
    let metadata = serde_json::to_string(&crate::metadata_edit::from_extracted(md))
        .map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(e)))?;
    conn.execute("UPDATE track_source_metadata SET bitrate=?2,sample_rate=?3,bit_depth=?4,metadata=json_set(metadata,'$.file_metadata',json(?5)) WHERE source_id IN (SELECT source_id FROM track_sources WHERE provider='local' AND local_path_key=durvald_local_path_key(?1))",rusqlite::params![md.file_path,md.bitrate,md.sample_rate,md.bit_depth,metadata])?;
    cache_scan_time(conn, &md.file_path, mtime, version)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::database::{migrations, operations};
    use rusqlite::{params, types::Value};
    fn stage6() -> Connection {
        let mut c = Connection::open_in_memory().unwrap();
        c.execute_batch("PRAGMA foreign_keys=ON").unwrap();
        operations::create_tables(&c).unwrap();
        migrations::migrate_stage6(&mut c).unwrap();
        c
    }
    fn song(c: &Connection, id: i64, path: &str) {
        c.execute("INSERT INTO songs(song_id,title,artist_id,artist_name,release_id,release_title,track_number,duration,file_path,rating_half_steps,is_favorite) VALUES(?1,'Track',1,'Artist',1,'Album',1,180,?2,7,1)",params![id,path]).unwrap();
    }
    fn rows(c: &Connection, table: &str) -> Vec<Vec<Value>> {
        let mut s = c
            .prepare(&format!("SELECT * FROM {table} ORDER BY rowid"))
            .unwrap();
        let n = s.column_count();
        s.query_map([], |r| (0..n).map(|i| r.get(i)).collect())
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    }
    #[test]
    fn rebuild_preserves_every_relationship_index_and_trigger_and_reopens() {
        let mut c = stage6();
        song(&c, 42, "/offline/a.flac");
        c.execute_batch("INSERT INTO playlists(id,name) VALUES(8,'Ordered'); INSERT INTO playlist_songs(playlist_id,song_id,position) VALUES(8,42,0),(8,42,1);
            INSERT INTO play_history(song_id,played_at,play_duration) VALUES(42,'2026-01-01',90);
            INSERT INTO playback_source_preferences SELECT 42,source_id FROM track_sources;
            CREATE INDEX custom_song_index ON songs(title);
            CREATE TABLE migration_audit(song_id);
            CREATE TRIGGER custom_song_trigger AFTER UPDATE OF title ON songs BEGIN INSERT INTO migration_audit VALUES(NEW.song_id); END;").unwrap();
        let tables = [
            "songs",
            "playlist_songs",
            "play_history",
            "track_sources",
            "track_source_state",
            "track_source_metadata",
            "playback_source_preferences",
        ];
        let before: Vec<_> = tables.iter().map(|t| rows(&c, t)).collect();
        let objects:Vec<String>=c.prepare("SELECT name FROM sqlite_master WHERE tbl_name='songs' AND type IN ('index','trigger') ORDER BY name").unwrap().query_map([],|r|r.get(0)).unwrap().collect::<Result<_,_>>().unwrap();
        migrations::migrate_enrichment(&mut c).unwrap();
        for (i, t) in tables.iter().enumerate() {
            let after = rows(&c, t);
            if *t == "track_sources" {
                assert_eq!(before[i][0], after[0][..11]);
            } else {
                assert_eq!(before[i], after, "{t}");
            }
        }
        for name in objects {
            assert!(
                c.query_row(
                    "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name=?1)",
                    [name],
                    |r| r.get::<_, bool>(0)
                )
                .unwrap()
            );
        }
        c.execute("UPDATE songs SET title='Updated' WHERE song_id=42", [])
            .unwrap();
        assert_eq!(rows(&c, "migration_audit").len(), 1);
        migrations::migrate_enrichment(&mut c).unwrap();
        assert_eq!(
            c.query_row("PRAGMA foreign_keys", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            1
        );
        assert!(
            !c.prepare("PRAGMA foreign_key_check")
                .unwrap()
                .exists([])
                .unwrap()
        );
    }
    #[test]
    fn source_deletion_preserves_track_preferences_and_null_is_not_an_empty_path() {
        let mut c = stage6();
        song(&c, 1, "/music/local.flac");
        migrations::migrate_enrichment(&mut c).unwrap();
        c.execute("INSERT INTO track_sources(song_id,provider,external_id,canonical_url,association_origin) VALUES(1,'test','audio-1','https://example.org/audio/1','test')",[]).unwrap();
        c.execute("DELETE FROM track_sources WHERE provider='local'", [])
            .unwrap();
        assert_eq!(
            c.query_row("SELECT file_path FROM songs WHERE song_id=1", [], |r| {
                r.get::<_, Option<String>>(0)
            })
            .unwrap(),
            None
        );
        assert_eq!(
            c.query_row(
                "SELECT rating_half_steps FROM songs WHERE song_id=1",
                [],
                |r| r.get::<_, i64>(0)
            )
            .unwrap(),
            7
        );
        assert!(
            c.execute("UPDATE songs SET file_path='' WHERE song_id=1", [])
                .is_err()
        );
        assert!(c.execute("INSERT INTO track_sources(song_id,provider,canonical_url,association_origin) VALUES(1,'test','https://example.org/invalid','test')",[]).is_err());
        c.execute("DELETE FROM songs WHERE song_id=1", []).unwrap();
        assert!(rows(&c, "track_sources").is_empty());
        assert!(rows(&c, "track_source_state").is_empty());
    }
    #[test]
    fn missing_local_file_with_remote_source_is_not_archived_as_missing_track() {
        let mut c = stage6();
        song(&c, 1, "/music/gone.flac");
        migrations::migrate_enrichment(&mut c).unwrap();
        c.execute("INSERT INTO track_sources(song_id,provider,external_id,canonical_url,association_origin,enabled) VALUES(1,'test','audio-1','https://example.org/audio/1','test',0)",[]).unwrap();
        c.execute_batch("CREATE TEMP TABLE scan_discovered_paths(scan_id,file_path)")
            .unwrap();
        remove_missing_files_with_surviving_sources(&c, "/music/", "scan").unwrap();
        assert_eq!(rows(&c, "songs").len(), 1);
        assert!(rows(&c, "missing_tracks").is_empty());
        assert_eq!(
            c.query_row("SELECT availability FROM track_source_state", [], |r| {
                r.get::<_, String>(0)
            })
            .unwrap(),
            "unknown"
        );
    }
    #[test]
    fn removing_primary_file_uses_remaining_origin_without_changing_track_identity() {
        let mut c = stage6();
        song(&c, 1, "/gone/primary.flac");
        migrations::migrate_enrichment(&mut c).unwrap();
        c.execute("INSERT INTO track_sources(song_id,local_path,local_path_key,association_origin) VALUES(1,'/kept/secondary.flac','/kept/secondary.flac','test')",[]).unwrap();
        c.execute_batch("CREATE TEMP TABLE scan_discovered_paths(scan_id,file_path)")
            .unwrap();
        remove_missing_files_with_surviving_sources(&c, "/gone/", "scan").unwrap();
        assert_eq!(
            c.query_row("SELECT file_path FROM songs WHERE song_id=1", [], |r| {
                r.get::<_, String>(0)
            })
            .unwrap(),
            "/kept/secondary.flac"
        );
        assert_eq!(
            c.query_row(
                "SELECT rating_half_steps FROM songs WHERE song_id=1",
                [],
                |r| r.get::<_, i64>(0)
            )
            .unwrap(),
            7
        );
        assert_eq!(rows(&c, "track_sources").len(), 1);
    }

    #[test]
    fn existing_stage6_library_gets_a_separate_backup_before_nullable_files() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("library.sqlite");
        let mut c = stage6();
        song(&c, 1, "/offline/track.flac");
        crate::database::local_sources::backup_before_migration(&c, path.to_str().unwrap())
            .unwrap();
        let backup_path = format!("{}.pre-optional-local-files.sqlite", path.display());
        let backup = Connection::open(&backup_path).unwrap();
        assert_eq!(
            backup
                .query_row("SELECT MAX(version) FROM enrichment_migrations", [], |r| {
                    r.get::<_, i64>(0)
                })
                .unwrap(),
            21
        );
        migrations::migrate_enrichment(&mut c).unwrap();
        assert_eq!(
            backup
                .query_row("SELECT COUNT(*) FROM songs", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            1
        );
        assert_eq!(
            backup
                .query_row("SELECT MAX(version) FROM enrichment_migrations", [], |r| {
                    r.get::<_, i64>(0)
                })
                .unwrap(),
            21
        );
    }

    #[test]
    fn failed_rebuild_rolls_back_schema_version_and_foreign_key_mode() {
        let mut c = stage6();
        song(&c, 1, "/music/a.flac");
        let before = rows(&c, "songs");
        // Deliberate collision with the new table name, after both table rebuilds.
        c.execute("CREATE TABLE catalog_track_references(occupied)", [])
            .unwrap();
        assert!(migrations::migrate_enrichment(&mut c).is_err());
        assert_eq!(before, rows(&c, "songs"));
        assert_eq!(
            c.query_row("SELECT MAX(version) FROM enrichment_migrations", [], |r| {
                r.get::<_, i64>(0)
            })
            .unwrap(),
            21
        );
        assert!(
            c.execute("UPDATE songs SET file_path=NULL WHERE song_id=1", [])
                .is_err()
        );
        assert_eq!(
            c.query_row("PRAGMA foreign_keys", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            1
        );
    }
}
