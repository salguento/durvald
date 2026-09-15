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

const PROFILE: &str = r#"
CREATE TABLE artist_external_ids (
    artist_id INTEGER NOT NULL REFERENCES artist_enrichment_state(artist_id) ON DELETE CASCADE,
    provider TEXT NOT NULL,
    external_id TEXT NOT NULL,
    generation INTEGER NOT NULL CHECK (generation >= 0),
    origin TEXT NOT NULL,
    fetched_at INTEGER NOT NULL,
    PRIMARY KEY (artist_id, provider)
);
CREATE INDEX idx_artist_external_provider_id
    ON artist_external_ids(provider, external_id);
"#;

const PROFILE_ASSETS: &str = r#"
CREATE TABLE enrichment_assets (
    artist_id INTEGER NOT NULL REFERENCES artist_enrichment_state(artist_id) ON DELETE CASCADE,
    provider TEXT NOT NULL,
    provider_id TEXT NOT NULL,
    generation INTEGER NOT NULL CHECK (generation >= 0),
    source_url TEXT NOT NULL,
    managed_path TEXT NOT NULL,
    width INTEGER CHECK (width IS NULL OR width > 0),
    height INTEGER CHECK (height IS NULL OR height > 0),
    attribution TEXT NOT NULL CHECK (json_valid(attribution)),
    fetched_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL CHECK (expires_at >= fetched_at),
    PRIMARY KEY (artist_id, provider)
);
CREATE INDEX idx_enrichment_asset_provider_id
    ON enrichment_assets(provider, provider_id);
"#;

const PROFILE_OVERRIDES: &str = r#"
CREATE TABLE artist_profile_overrides (
    artist_id INTEGER NOT NULL REFERENCES artists(artist_id) ON DELETE CASCADE,
    field TEXT NOT NULL,
    language TEXT NOT NULL,
    value TEXT,
    updated_at INTEGER NOT NULL,
    PRIMARY KEY (artist_id, field, language)
);
"#;

const DISCOGRAPHY: &str = r#"
CREATE TABLE external_release_groups (
    musicbrainz_id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    primary_type TEXT,
    secondary_types TEXT NOT NULL CHECK (json_valid(secondary_types)),
    first_release_year INTEGER,
    first_release_month INTEGER CHECK (first_release_month IS NULL OR first_release_month BETWEEN 1 AND 12),
    first_release_day INTEGER CHECK (first_release_day IS NULL OR first_release_day BETWEEN 1 AND 31),
    attribution TEXT NOT NULL CHECK (json_valid(attribution)),
    fetched_at INTEGER NOT NULL,
    CHECK (first_release_month IS NULL OR first_release_year IS NOT NULL),
    CHECK (first_release_day IS NULL OR first_release_month IS NOT NULL)
);

CREATE TABLE artist_discography_state (
    artist_id INTEGER PRIMARY KEY REFERENCES artist_enrichment_state(artist_id) ON DELETE CASCADE,
    identity_generation INTEGER NOT NULL CHECK (identity_generation >= 0),
    active_generation INTEGER NOT NULL DEFAULT 0 CHECK (active_generation >= 0),
    active_remote_next_offset INTEGER CHECK (active_remote_next_offset IS NULL OR active_remote_next_offset >= 0),
    active_remote_exhausted INTEGER NOT NULL DEFAULT 0 CHECK (active_remote_exhausted IN (0, 1)),
    active_fetched_at INTEGER,
    active_expires_at INTEGER,
    active_etag TEXT,
    active_last_modified TEXT,
    building_generation INTEGER CHECK (building_generation IS NULL OR building_generation > 0),
    building_next_offset INTEGER CHECK (building_next_offset IS NULL OR building_next_offset >= 0),
    building_fetched_at INTEGER,
    building_expires_at INTEGER,
    building_etag TEXT,
    building_last_modified TEXT,
    CHECK (active_expires_at IS NULL OR (active_fetched_at IS NOT NULL AND active_expires_at >= active_fetched_at)),
    CHECK (building_expires_at IS NULL OR (building_fetched_at IS NOT NULL AND building_expires_at >= building_fetched_at))
);

CREATE TABLE external_artist_release_groups (
    artist_id INTEGER NOT NULL REFERENCES artist_enrichment_state(artist_id) ON DELETE CASCADE,
    release_group_mbid TEXT NOT NULL REFERENCES external_release_groups(musicbrainz_id) ON DELETE CASCADE,
    identity_generation INTEGER NOT NULL CHECK (identity_generation >= 0),
    catalog_generation INTEGER NOT NULL CHECK (catalog_generation > 0),
    provider_position INTEGER NOT NULL CHECK (provider_position >= 0),
    PRIMARY KEY (artist_id, catalog_generation, release_group_mbid)
);
CREATE INDEX idx_external_artist_release_active
    ON external_artist_release_groups(artist_id, identity_generation, catalog_generation, provider_position);

CREATE TABLE local_release_external_ids (
    release_id INTEGER PRIMARY KEY REFERENCES releases(release_id) ON DELETE CASCADE,
    release_mbid TEXT,
    release_group_mbid TEXT,
    origin TEXT NOT NULL,
    updated_at INTEGER NOT NULL,
    CHECK (release_mbid IS NOT NULL OR release_group_mbid IS NOT NULL)
);
CREATE INDEX idx_local_release_mbid ON local_release_external_ids(release_mbid);
CREATE INDEX idx_local_release_group_mbid ON local_release_external_ids(release_group_mbid);

ALTER TABLE enrichment_assets RENAME TO enrichment_assets_phase3;
CREATE TABLE enrichment_assets (
    artist_id INTEGER NOT NULL REFERENCES artist_enrichment_state(artist_id) ON DELETE CASCADE,
    provider TEXT NOT NULL,
    catalog_key TEXT NOT NULL DEFAULT '',
    provider_id TEXT NOT NULL,
    generation INTEGER NOT NULL CHECK (generation >= 0),
    release_group_mbid TEXT REFERENCES external_release_groups(musicbrainz_id) ON DELETE CASCADE,
    exact_release_mbid TEXT,
    artwork_scope TEXT CHECK (artwork_scope IS NULL OR artwork_scope IN ('exact_release', 'release_group')),
    source_url TEXT NOT NULL,
    managed_path TEXT NOT NULL,
    width INTEGER CHECK (width IS NULL OR width > 0),
    height INTEGER CHECK (height IS NULL OR height > 0),
    attribution TEXT NOT NULL CHECK (json_valid(attribution)),
    fetched_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL CHECK (expires_at >= fetched_at),
    PRIMARY KEY (artist_id, provider, catalog_key),
    CHECK (
        (catalog_key = '' AND release_group_mbid IS NULL AND exact_release_mbid IS NULL AND artwork_scope IS NULL)
        OR
        (catalog_key != '' AND provider = 'cover_art_archive' AND release_group_mbid IS NOT NULL
            AND ((artwork_scope = 'exact_release' AND exact_release_mbid IS NOT NULL)
                OR (artwork_scope = 'release_group' AND exact_release_mbid IS NULL)))
    )
);
INSERT INTO enrichment_assets (
    artist_id, provider, catalog_key, provider_id, generation, source_url,
    managed_path, width, height, attribution, fetched_at, expires_at
)
SELECT artist_id, provider, '', provider_id, generation, source_url,
       managed_path, width, height, attribution, fetched_at, expires_at
FROM enrichment_assets_phase3;
DROP TABLE enrichment_assets_phase3;
CREATE INDEX idx_enrichment_asset_provider_id
    ON enrichment_assets(provider, provider_id);
CREATE INDEX idx_enrichment_asset_release_group
    ON enrichment_assets(artist_id, release_group_mbid);
"#;

const RELEASE_IDENTIFIER_BACKFILL: &str = r#"
CREATE TABLE enrichment_backfills (
    key TEXT PRIMARY KEY,
    completed_at INTEGER NOT NULL
);
"#;

const DISCOGRAPHY_TOTALS: &str = r#"
ALTER TABLE artist_discography_state
    ADD COLUMN active_remote_total INTEGER
    CHECK (active_remote_total IS NULL OR active_remote_total >= 0);
ALTER TABLE artist_discography_state
    ADD COLUMN building_remote_total INTEGER
    CHECK (building_remote_total IS NULL OR building_remote_total >= 0);
"#;

// Keep the catalog entry itself generation-scoped. `external_release_groups`
// remains the shared identity used by artwork foreign keys, but readers use
// this immutable payload so an unpublished refresh cannot mutate an active
// snapshot that happens to contain the same release-group.
const TRANSACTIONAL_DISCOGRAPHY_SNAPSHOTS: &str = r#"
ALTER TABLE external_artist_release_groups
    ADD COLUMN snapshot_payload TEXT
    CHECK (snapshot_payload IS NULL OR json_valid(snapshot_payload));
UPDATE external_artist_release_groups AS ar
SET snapshot_payload = (
    SELECT json_object(
        'musicbrainz_id', g.musicbrainz_id,
        'title', g.title,
        'primary_type', g.primary_type,
        'secondary_types', json(g.secondary_types),
        'first_release_date', CASE
            WHEN g.first_release_year IS NULL THEN NULL
            ELSE json_object(
                'year', g.first_release_year,
                'month', g.first_release_month,
                'day', g.first_release_day
            )
        END,
        'attribution', json(g.attribution)
    )
    FROM external_release_groups g
    WHERE g.musicbrainz_id = ar.release_group_mbid
);
"#;

const EXTERNAL_ARTWORK_NEGATIVE_RESULTS: &str = r#"
CREATE TABLE external_artwork_negative_results (
    artist_id INTEGER NOT NULL REFERENCES artist_enrichment_state(artist_id) ON DELETE CASCADE,
    catalog_key TEXT NOT NULL,
    release_group_mbid TEXT NOT NULL REFERENCES external_release_groups(musicbrainz_id) ON DELETE CASCADE,
    exact_release_mbid TEXT,
    identity_generation INTEGER NOT NULL CHECK (identity_generation >= 0),
    catalog_generation INTEGER NOT NULL CHECK (catalog_generation > 0),
    result TEXT NOT NULL CHECK (result IN ('not_found', 'invalid_image', 'temporary_failure')),
    recorded_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL CHECK (expires_at >= recorded_at),
    PRIMARY KEY (artist_id, catalog_key),
    CHECK (
        (exact_release_mbid IS NULL AND catalog_key = 'release-group:' || release_group_mbid)
        OR
        (exact_release_mbid IS NOT NULL AND catalog_key = 'release:' || exact_release_mbid)
    )
);
CREATE INDEX idx_external_artwork_negative_expiry
    ON external_artwork_negative_results(artist_id, identity_generation, catalog_generation, expires_at);
"#;

const PERSISTENT_EXTERNAL_ARTWORK_QUEUE: &str = r#"
CREATE TABLE artist_artwork_queue_state (
    artist_id INTEGER PRIMARY KEY REFERENCES artist_enrichment_state(artist_id) ON DELETE CASCADE,
    identity_generation INTEGER NOT NULL CHECK (identity_generation >= 0),
    catalog_generation INTEGER NOT NULL CHECK (catalog_generation > 0),
    cursor_position INTEGER NOT NULL DEFAULT -1 CHECK (cursor_position >= -1),
    updated_at INTEGER NOT NULL
);

CREATE TABLE external_artwork_queue (
    artist_id INTEGER NOT NULL REFERENCES artist_enrichment_state(artist_id) ON DELETE CASCADE,
    catalog_key TEXT NOT NULL,
    release_group_mbid TEXT NOT NULL REFERENCES external_release_groups(musicbrainz_id) ON DELETE CASCADE,
    exact_release_mbid TEXT,
    identity_generation INTEGER NOT NULL CHECK (identity_generation >= 0),
    catalog_generation INTEGER NOT NULL CHECK (catalog_generation > 0),
    provider_position INTEGER NOT NULL CHECK (provider_position >= 0),
    state TEXT NOT NULL CHECK (state IN ('pending', 'in_progress', 'completed', 'absent', 'blocked')),
    attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
    next_attempt_at INTEGER,
    last_error TEXT CHECK (last_error IS NULL OR length(last_error) BETWEEN 1 AND 64),
    updated_at INTEGER NOT NULL,
    PRIMARY KEY (artist_id, catalog_key),
    CHECK (
        (exact_release_mbid IS NULL AND catalog_key = 'release-group:' || release_group_mbid)
        OR
        (exact_release_mbid IS NOT NULL AND catalog_key = 'release:' || exact_release_mbid)
    ),
    CHECK ((state IN ('absent', 'blocked') AND next_attempt_at IS NOT NULL)
        OR (state NOT IN ('absent', 'blocked') AND next_attempt_at IS NULL))
);
CREATE INDEX idx_external_artwork_queue_schedule
    ON external_artwork_queue(
        artist_id, identity_generation, catalog_generation,
        state, next_attempt_at, provider_position
    );
"#;

const PROVIDER_FAILURE_CACHE: &str = r#"
CREATE TABLE enrichment_provider_failures (
    artist_id INTEGER NOT NULL REFERENCES artist_enrichment_state(artist_id) ON DELETE CASCADE,
    provider TEXT NOT NULL,
    operation TEXT NOT NULL CHECK (length(operation) BETWEEN 1 AND 64),
    resource_key TEXT NOT NULL CHECK (length(resource_key) = 32),
    identity_generation INTEGER NOT NULL CHECK (identity_generation >= 0),
    error_code TEXT NOT NULL CHECK (length(error_code) BETWEEN 1 AND 64),
    retry_after_seconds INTEGER CHECK (retry_after_seconds IS NULL OR retry_after_seconds >= 0),
    recorded_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL CHECK (expires_at >= recorded_at),
    PRIMARY KEY (artist_id, provider, operation)
);
CREATE INDEX idx_enrichment_provider_failure_expiry
    ON enrichment_provider_failures(artist_id, identity_generation, expires_at);
"#;

// Enriched album fields stay separate from metadata read from the audio files.
// Readers only apply rows belonging to the artist's current identity generation.
const LOCAL_RELEASE_METADATA: &str = r#"
CREATE TABLE IF NOT EXISTS local_release_metadata (
    release_id INTEGER PRIMARY KEY REFERENCES releases(release_id) ON DELETE CASCADE,
    artist_id INTEGER NOT NULL REFERENCES artist_enrichment_state(artist_id) ON DELETE CASCADE,
    identity_generation INTEGER NOT NULL CHECK (identity_generation >= 0),
    release_group_mbid TEXT NOT NULL REFERENCES external_release_groups(musicbrainz_id) ON DELETE CASCADE,
    release_mbid TEXT,
    match_kind TEXT NOT NULL CHECK (match_kind IN ('tag', 'catalog_exact')),
    release_date TEXT,
    genres TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(genres)),
    composers TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(composers)),
    producers TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(producers)),
    source_url TEXT NOT NULL,
    updated_at INTEGER NOT NULL
);
CREATE INDEX idx_local_release_metadata_identity
    ON local_release_metadata(artist_id, identity_generation);
CREATE TABLE IF NOT EXISTS local_release_metadata_attempts (
    release_id INTEGER PRIMARY KEY REFERENCES releases(release_id) ON DELETE CASCADE,
    artist_id INTEGER NOT NULL REFERENCES artist_enrichment_state(artist_id) ON DELETE CASCADE,
    identity_generation INTEGER NOT NULL CHECK (identity_generation >= 0),
    attempted_at INTEGER NOT NULL
);
CREATE TRIGGER invalidate_local_release_metadata_identity
AFTER UPDATE OF generation ON artist_enrichment_state
WHEN NEW.generation != OLD.generation
BEGIN
    DELETE FROM local_release_metadata
    WHERE artist_id = NEW.artist_id AND identity_generation != NEW.generation;
    DELETE FROM local_release_metadata_attempts
    WHERE artist_id = NEW.artist_id AND identity_generation != NEW.generation;
    DELETE FROM local_release_external_ids
    WHERE origin = 'catalog_exact'
      AND release_id IN (SELECT release_id FROM releases WHERE artist_id = NEW.artist_id);
END;
"#;

// Identity depends on the set of distinct MusicBrainz IDs and on whether any
// evidence is uncertain, not on how many tracks repeat the same evidence.
// The original row-level triggers advanced the generation for every repeated
// tag added or removed, which could hide an artist's otherwise valid cached
// profile, discography, and artwork after a metadata rescan.
const AGGREGATE_IDENTITY_INVALIDATION: &str = r#"
DROP TRIGGER invalidate_inserted_artist_tag;
DROP TRIGGER invalidate_deleted_artist_tag;

CREATE TRIGGER invalidate_inserted_artist_tag AFTER INSERT ON artist_tag_evidence
WHEN NOT EXISTS (
        SELECT 1 FROM artist_tag_evidence
        WHERE artist_id = NEW.artist_id
          AND musicbrainz_id = NEW.musicbrainz_id
          AND NOT (song_id = NEW.song_id AND role = NEW.role)
    )
    OR (
        NEW.uncertain = 1
        AND NOT EXISTS (
            SELECT 1 FROM artist_tag_evidence
            WHERE artist_id = NEW.artist_id
              AND uncertain = 1
              AND NOT (song_id = NEW.song_id AND role = NEW.role
                       AND musicbrainz_id = NEW.musicbrainz_id)
        )
    )
BEGIN
    INSERT OR IGNORE INTO artist_enrichment_state(artist_id) VALUES (NEW.artist_id);
    UPDATE artist_enrichment_state SET generation = generation + 1,
        identity_status = 'unresolved', musicbrainz_id = NULL, identity_origin = NULL
        WHERE artist_id = NEW.artist_id;
END;

CREATE TRIGGER invalidate_deleted_artist_tag AFTER DELETE ON artist_tag_evidence
WHEN NOT EXISTS (
        SELECT 1 FROM artist_tag_evidence
        WHERE artist_id = OLD.artist_id
          AND musicbrainz_id = OLD.musicbrainz_id
    )
    OR (
        OLD.uncertain = 1
        AND NOT EXISTS (
            SELECT 1 FROM artist_tag_evidence
            WHERE artist_id = OLD.artist_id AND uncertain = 1
        )
    )
BEGIN
    UPDATE artist_enrichment_state SET generation = generation + 1,
        identity_status = 'unresolved', musicbrainz_id = NULL, identity_origin = NULL
        WHERE artist_id = OLD.artist_id;
END;
"#;

// Full MusicBrainz edition details are cached separately from playable local
// tracks. This keeps online-only releases available without repeated requests.
const EXTERNAL_RELEASE_DETAILS_CACHE: &str = r#"
CREATE TABLE external_release_details (
    artist_id INTEGER NOT NULL REFERENCES artist_enrichment_state(artist_id) ON DELETE CASCADE,
    release_group_mbid TEXT NOT NULL REFERENCES external_release_groups(musicbrainz_id) ON DELETE CASCADE,
    identity_generation INTEGER NOT NULL CHECK (identity_generation >= 0),
    payload_version INTEGER NOT NULL DEFAULT 1,
    payload TEXT NOT NULL CHECK (json_valid(payload)),
    fetched_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL CHECK (expires_at >= fetched_at),
    etag TEXT,
    last_modified TEXT,
    PRIMARY KEY (artist_id, release_group_mbid)
);
CREATE INDEX idx_external_release_details_expiry
    ON external_release_details(artist_id, identity_generation, expires_at);
CREATE TRIGGER invalidate_external_release_details_identity
AFTER UPDATE OF generation ON artist_enrichment_state
WHEN NEW.generation != OLD.generation
BEGIN
    DELETE FROM external_release_details
    WHERE artist_id = NEW.artist_id AND identity_generation != NEW.generation;
END;
"#;

pub fn migrate_enrichment(conn: &mut Connection) -> rusqlite::Result<()> {
    apply(
        conn,
        &[
            (1, FOUNDATION),
            (2, IDENTITY),
            (3, PROFILE),
            (4, PROFILE_ASSETS),
            (5, PROFILE_OVERRIDES),
            (6, DISCOGRAPHY),
            (7, RELEASE_IDENTIFIER_BACKFILL),
            (8, DISCOGRAPHY_TOTALS),
            (9, TRANSACTIONAL_DISCOGRAPHY_SNAPSHOTS),
            (10, EXTERNAL_ARTWORK_NEGATIVE_RESULTS),
            (11, PERSISTENT_EXTERNAL_ARTWORK_QUEUE),
            (12, PROVIDER_FAILURE_CACHE),
            (13, LOCAL_RELEASE_METADATA),
            (14, AGGREGATE_IDENTITY_INVALIDATION),
            (15, EXTERNAL_RELEASE_DETAILS_CACHE),
        ],
    )?;
    crate::database::identity::backfill_release_external_ids(conn)
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
            15
        );
    }

    #[test]
    fn repeated_tag_evidence_does_not_invalidate_artist_identity() {
        let mut conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("PRAGMA foreign_keys = ON;").unwrap();
        crate::database::operations::create_tables(&conn).unwrap();
        migrate_enrichment(&mut conn).unwrap();
        conn.execute(
            "INSERT INTO artists (artist_id, name) VALUES (1, 'Artist')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO releases (release_id, title, artist_id, artist_name)
             VALUES (1, 'Album', 1, 'Artist')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO songs
             (song_id, title, artist_id, artist_name, release_id, release_title,
              track_number, disc_number, duration, file_path)
             VALUES
             (1, 'One', 1, 'Artist', 1, 'Album', 1, 1, 180, '/one'),
             (2, 'Two', 1, 'Artist', 1, 'Album', 2, 1, 180, '/two')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO artist_enrichment_state
             (artist_id, generation, identity_status, musicbrainz_id)
             VALUES (1, 7, 'resolved', '11111111-1111-4111-8111-111111111111')",
            [],
        )
        .unwrap();

        conn.execute(
            "INSERT INTO artist_tag_evidence
             (song_id, artist_id, role, musicbrainz_id, uncertain)
             VALUES (1, 1, 'track_artist', '11111111-1111-4111-8111-111111111111', 0)",
            [],
        )
        .unwrap();
        let first_generation: i64 = conn
            .query_row(
                "SELECT generation FROM artist_enrichment_state WHERE artist_id = 1",
                [],
                |row| row.get(0),
            )
            .unwrap();

        conn.execute(
            "INSERT INTO artist_tag_evidence
             (song_id, artist_id, role, musicbrainz_id, uncertain)
             VALUES (2, 1, 'track_artist', '11111111-1111-4111-8111-111111111111', 0)",
            [],
        )
        .unwrap();
        conn.execute("DELETE FROM artist_tag_evidence WHERE song_id = 2", [])
            .unwrap();
        assert_eq!(
            conn.query_row(
                "SELECT generation FROM artist_enrichment_state WHERE artist_id = 1",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
            first_generation
        );

        conn.execute(
            "INSERT INTO artist_tag_evidence
             (song_id, artist_id, role, musicbrainz_id, uncertain)
             VALUES (2, 1, 'track_artist', '22222222-2222-4222-8222-222222222222', 0)",
            [],
        )
        .unwrap();
        assert_eq!(
            conn.query_row(
                "SELECT generation FROM artist_enrichment_state WHERE artist_id = 1",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
            first_generation + 1
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
                    (3, PROFILE),
                    (4, PROFILE_ASSETS),
                    (5, PROFILE_OVERRIDES),
                    (6, DISCOGRAPHY,),
                    (7, RELEASE_IDENTIFIER_BACKFILL),
                    (8, DISCOGRAPHY_TOTALS),
                    (9, TRANSACTIONAL_DISCOGRAPHY_SNAPSHOTS),
                    (10, EXTERNAL_ARTWORK_NEGATIVE_RESULTS),
                    (11, PERSISTENT_EXTERNAL_ARTWORK_QUEUE),
                    (12, PROVIDER_FAILURE_CACHE),
                    (13, LOCAL_RELEASE_METADATA),
                    (14, AGGREGATE_IDENTITY_INVALIDATION),
                    (
                        16,
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
            15
        );
    }

    #[test]
    fn phase_three_assets_survive_discography_schema_upgrade() {
        let mut conn = Connection::open_in_memory().unwrap();
        crate::database::operations::create_tables(&conn).unwrap();
        conn.execute(
            "INSERT INTO artists (artist_id, name) VALUES (1, 'Artist')",
            [],
        )
        .unwrap();
        apply(
            &mut conn,
            &[
                (1, FOUNDATION),
                (2, IDENTITY),
                (3, PROFILE),
                (4, PROFILE_ASSETS),
                (5, PROFILE_OVERRIDES),
            ],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO artist_enrichment_state (artist_id) VALUES (1)",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO enrichment_assets
             (artist_id, provider, provider_id, generation, source_url, managed_path,
              attribution, fetched_at, expires_at)
             VALUES (1, 'commons', 'Portrait.jpg', 0, 'https://example.test/source',
                     '/covers/hash.jpg', '{}', 10, 20)",
            [],
        )
        .unwrap();

        migrate_enrichment(&mut conn).unwrap();
        assert_eq!(
            conn.query_row(
                "SELECT provider_id FROM enrichment_assets
                 WHERE artist_id = 1 AND provider = 'commons' AND catalog_key = ''",
                [],
                |row| row.get::<_, String>(0),
            )
            .unwrap(),
            "Portrait.jpg"
        );
        assert_eq!(
            conn.query_row("SELECT COUNT(*) FROM pragma_foreign_key_check", [], |row| {
                row.get::<_, i64>(0)
            })
            .unwrap(),
            0
        );
    }

    #[test]
    fn phase_four_catalog_rows_gain_immutable_snapshot_payloads() {
        let mut conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("PRAGMA foreign_keys = ON;").unwrap();
        crate::database::operations::create_tables(&conn).unwrap();
        apply(
            &mut conn,
            &[
                (1, FOUNDATION),
                (2, IDENTITY),
                (3, PROFILE),
                (4, PROFILE_ASSETS),
                (5, PROFILE_OVERRIDES),
                (6, DISCOGRAPHY),
                (7, RELEASE_IDENTIFIER_BACKFILL),
                (8, DISCOGRAPHY_TOTALS),
            ],
        )
        .unwrap();
        conn.execute("INSERT INTO artists VALUES (1, 'Artist')", [])
            .unwrap();
        conn.execute(
            "INSERT INTO artist_enrichment_state
             (artist_id, generation, identity_status, musicbrainz_id)
             VALUES (1, 2, 'resolved', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')",
            [],
        )
        .unwrap();
        let group_id = "11111111-1111-4111-8111-111111111111";
        conn.execute(
            "INSERT INTO external_release_groups
             VALUES (?1, 'Original title', 'Album', '[\"Live\"]', 2001, 2, NULL,
                     '{\"source_url\":\"https://example.test\",\"author\":null,\"license_name\":null,\"license_url\":null,\"revision\":null}', 10)",
            [group_id],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO external_artist_release_groups
             VALUES (1, ?1, 2, 1, 0)",
            [group_id],
        )
        .unwrap();

        migrate_enrichment(&mut conn).unwrap();
        let payload: String = conn
            .query_row(
                "SELECT snapshot_payload FROM external_artist_release_groups",
                [],
                |row| row.get(0),
            )
            .unwrap();
        let payload: serde_json::Value = serde_json::from_str(&payload).unwrap();
        assert_eq!(payload["musicbrainz_id"], group_id);
        assert_eq!(payload["title"], "Original title");
        assert_eq!(payload["secondary_types"], serde_json::json!(["Live"]));
        assert_eq!(payload["first_release_date"]["year"], 2001);
        assert_eq!(payload["first_release_date"]["month"], 2);
    }

    #[test]
    fn existing_normalized_song_tags_are_backfilled_once() {
        let mut conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("PRAGMA foreign_keys = ON;").unwrap();
        crate::database::operations::create_tables(&conn).unwrap();
        apply(
            &mut conn,
            &[
                (1, FOUNDATION),
                (2, IDENTITY),
                (3, PROFILE),
                (4, PROFILE_ASSETS),
                (5, PROFILE_OVERRIDES),
                (6, DISCOGRAPHY),
            ],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO artists (artist_id, name) VALUES (1, 'Artist')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO releases (release_id, title, artist_id, artist_name)
             VALUES (10, 'Album', 1, 'Artist')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO songs
             (song_id, title, artist_id, artist_name, release_id, release_title,
              track_number, disc_number, duration, file_path)
             VALUES (100, 'Track', 1, 'Artist', 10, 'Album', 1, 1, 180, '/music/a.mp3')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO song_musicbrainz_tags (song_id, payload) VALUES (100, ?1)",
            [serde_json::json!({
                "releases": ["aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"],
                "release_groups": ["11111111-1111-4111-8111-111111111111"]
            })
            .to_string()],
        )
        .unwrap();

        migrate_enrichment(&mut conn).unwrap();
        assert_eq!(
            conn.query_row(
                "SELECT release_mbid, release_group_mbid
                 FROM local_release_external_ids WHERE release_id = 10",
                [],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            )
            .unwrap(),
            (
                "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa".into(),
                "11111111-1111-4111-8111-111111111111".into()
            )
        );
        assert_eq!(
            conn.query_row(
                "SELECT COUNT(*) FROM enrichment_backfills
                 WHERE key = 'local_release_external_ids_v1'",
                [],
                |row| row.get::<_, i64>(0)
            )
            .unwrap(),
            1
        );

        conn.execute(
            "UPDATE song_musicbrainz_tags SET payload = '{}' WHERE song_id = 100",
            [],
        )
        .unwrap();
        migrate_enrichment(&mut conn).unwrap();
        assert_eq!(
            conn.query_row(
                "SELECT release_mbid FROM local_release_external_ids WHERE release_id = 10",
                [],
                |row| row.get::<_, String>(0)
            )
            .unwrap(),
            "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        );
    }
}
