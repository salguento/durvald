//! Version only the new enrichment schema; legacy initialization stays intact.

use rusqlite::{Connection, TransactionBehavior};

const FOUNDATION: &str = r#"
CREATE TABLE enrichment_settings (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    enabled INTEGER NOT NULL CHECK (enabled IN (0, 1)),
    offline INTEGER NOT NULL CHECK (offline IN (0, 1)),
    preferred_language TEXT NOT NULL,
    policy_version INTEGER NOT NULL DEFAULT 1
);
INSERT INTO enrichment_settings (id, enabled, offline, preferred_language)
VALUES (1, 0, 0, 'pt');

CREATE TABLE artist_enrichment_state (
    artist_id INTEGER PRIMARY KEY REFERENCES artists(artist_id) ON DELETE CASCADE,
    generation INTEGER NOT NULL DEFAULT 0 CHECK (generation >= 0),
    identity_status TEXT NOT NULL DEFAULT 'unresolved'
        CHECK (identity_status IN ('unresolved', 'ambiguous', 'resolved', 'not_found')),
    musicbrainz_id TEXT,
    CHECK ((identity_status = 'resolved' AND musicbrainz_id IS NOT NULL)
        OR (identity_status != 'resolved' AND musicbrainz_id IS NULL))
);

CREATE TABLE artist_profile_sources (
    artist_id INTEGER NOT NULL REFERENCES artist_enrichment_state(artist_id) ON DELETE CASCADE,
    provider TEXT NOT NULL,
    language TEXT NOT NULL,
    generation INTEGER NOT NULL CHECK (generation >= 0),
    payload_version INTEGER NOT NULL,
    payload TEXT NOT NULL CHECK (json_valid(payload)),
    fetched_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL CHECK (expires_at >= fetched_at),
    etag TEXT,
    last_modified TEXT,
    PRIMARY KEY (artist_id, provider, language)
);
"#;

const IDENTITY: &str = r#"
ALTER TABLE artist_enrichment_state ADD COLUMN identity_origin TEXT;
ALTER TABLE artist_enrichment_state ADD COLUMN confirmed_musicbrainz_id TEXT;
ALTER TABLE artist_enrichment_state ADD COLUMN suppress_tags INTEGER NOT NULL DEFAULT 0;
CREATE INDEX idx_artist_mbid ON artist_enrichment_state(musicbrainz_id);
CREATE TABLE song_musicbrainz_tags (
    song_id INTEGER PRIMARY KEY REFERENCES songs(song_id) ON DELETE CASCADE,
    payload TEXT NOT NULL CHECK (json_valid(payload))
);
CREATE TABLE artist_tag_evidence (
    song_id INTEGER NOT NULL REFERENCES songs(song_id) ON DELETE CASCADE,
    artist_id INTEGER NOT NULL REFERENCES artists(artist_id) ON DELETE CASCADE,
    role TEXT NOT NULL CHECK (role IN ('track_artist', 'album_artist')),
    musicbrainz_id TEXT NOT NULL,
    uncertain INTEGER NOT NULL,
    PRIMARY KEY (song_id, artist_id, role, musicbrainz_id)
);
CREATE INDEX idx_tag_artist ON artist_tag_evidence(artist_id);
CREATE TABLE artist_identity_candidates (
    artist_id INTEGER PRIMARY KEY REFERENCES artist_enrichment_state(artist_id) ON DELETE CASCADE,
    generation INTEGER NOT NULL,
    payload TEXT NOT NULL CHECK (json_valid(payload)),
    truncated INTEGER NOT NULL DEFAULT 0
);
CREATE TRIGGER invalidate_inserted_artist_tag AFTER INSERT ON artist_tag_evidence BEGIN
    INSERT OR IGNORE INTO artist_enrichment_state(artist_id) VALUES (NEW.artist_id);
    UPDATE artist_enrichment_state SET generation = generation + 1,
        identity_status = 'unresolved', musicbrainz_id = NULL, identity_origin = NULL
        WHERE artist_id = NEW.artist_id;
END;
CREATE TRIGGER invalidate_deleted_artist_tag AFTER DELETE ON artist_tag_evidence BEGIN
    UPDATE artist_enrichment_state SET generation = generation + 1,
        identity_status = 'unresolved', musicbrainz_id = NULL, identity_origin = NULL
        WHERE artist_id = OLD.artist_id;
END;
"#;

pub fn migrate_enrichment(conn: &mut Connection) -> rusqlite::Result<()> {
    apply(conn, &[(1, FOUNDATION), (2, IDENTITY)])
}

fn apply(conn: &mut Connection, migrations: &[(i64, &str)]) -> rusqlite::Result<()> {
    // The version read and DDL share a write transaction, including on first open.
    let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
    tx.execute_batch(
        "CREATE TABLE IF NOT EXISTS enrichment_migrations (
            version INTEGER PRIMARY KEY,
            applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        )",
    )?;
    let current: i64 = tx.query_row(
        "SELECT COALESCE(MAX(version), 0) FROM enrichment_migrations",
        [],
        |row| row.get(0),
    )?;
    let supported = migrations.last().map_or(0, |(version, _)| *version);
    if current > supported {
        return Err(rusqlite::Error::InvalidParameterName(
            "Enrichment schema is newer than this core".into(),
        ));
    }
    for (version, sql) in migrations {
        if *version > current {
            tx.execute_batch(sql)?;
            tx.execute(
                "INSERT INTO enrichment_migrations (version) VALUES (?1)",
                [version],
            )?;
        }
    }
    tx.commit()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn legacy_rows_survive_migration_and_reopening() {
        let mut conn = Connection::open_in_memory().unwrap();
        crate::database::operations::create_tables(&conn).unwrap();
        conn.execute(
            "INSERT INTO artists (artist_id, name) VALUES (42, 'Björk')",
            [],
        )
        .unwrap();
        migrate_enrichment(&mut conn).unwrap();
        conn.execute("UPDATE enrichment_settings SET enabled = 1", [])
            .unwrap();
        migrate_enrichment(&mut conn).unwrap();
        assert_eq!(
            conn.query_row("SELECT name FROM artists WHERE artist_id = 42", [], |r| {
                r.get::<_, String>(0)
            })
            .unwrap(),
            "Björk"
        );
        assert!(
            conn.query_row("SELECT enabled FROM enrichment_settings", [], |r| r
                .get::<_, bool>(0))
                .unwrap()
        );
        assert_eq!(
            conn.query_row("SELECT COUNT(*) FROM enrichment_migrations", [], |r| r
                .get::<_, i64>(0))
                .unwrap(),
            2
        );
    }

    #[test]
    fn failed_migration_rolls_back_schema_and_version() {
        let mut conn = Connection::open_in_memory().unwrap();
        crate::database::operations::create_tables(&conn).unwrap();
        migrate_enrichment(&mut conn).unwrap();
        assert!(
            apply(
                &mut conn,
                &[
                    (1, FOUNDATION),
                    (2, IDENTITY),
                    (
                        3,
                        "CREATE TABLE must_rollback (id); INSERT INTO absent VALUES (1);"
                    )
                ]
            )
            .is_err()
        );
        assert!(!conn.table_exists(None, "must_rollback").unwrap());
        assert_eq!(
            conn.query_row("SELECT MAX(version) FROM enrichment_migrations", [], |r| {
                r.get::<_, i64>(0)
            })
            .unwrap(),
            2
        );
    }
}
