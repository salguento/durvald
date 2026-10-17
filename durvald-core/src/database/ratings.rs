//! Versioned half-star storage and atomic granularity changes.
use crate::{
    api::{
        RatingConversionPreview, RatingGranularity, RatingPreferenceChange, RatingRounding,
        RatingScalePreferences,
    },
    domain::rating::{RatingError, RatingHalfSteps},
};
use rusqlite::{Connection, Transaction, TransactionBehavior};

const TABLES: [(&str, &str); 4] = [
    ("songs", "song_id"),
    ("releases", "release_id"),
    ("missing_tracks", "missing_id"),
    ("artists_releases", "artists_release_id"),
];

impl From<rusqlite::Error> for RatingError {
    fn from(error: rusqlite::Error) -> Self {
        Self::Storage(error.to_string())
    }
}

pub(crate) fn migrate(conn: &Connection) -> rusqlite::Result<()> {
    let tx = Transaction::new_unchecked(conn, TransactionBehavior::Immediate)?;
    tx.execute_batch("CREATE TABLE IF NOT EXISTS rating_schema_migrations(version INTEGER PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS rating_preferences(
            singleton INTEGER PRIMARY KEY CHECK(singleton=1),
            granularity TEXT NOT NULL DEFAULT 'half_stars' CHECK(granularity IN ('half_stars','whole_stars'))
        );
        INSERT OR IGNORE INTO rating_preferences(singleton) VALUES(1);")?;
    let applied: bool = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM rating_schema_migrations WHERE version=1)",
        [],
        |row| row.get(0),
    )?;
    if !applied {
        for (table, _) in TABLES {
            let columns = tx
                .prepare(&format!("PRAGMA table_info({table})"))?
                .query_map([], |row| row.get::<_, String>(1))?
                .collect::<Result<Vec<_>, _>>()?;
            if !columns.iter().any(|column| column == "rating_half_steps") {
                tx.execute_batch(&format!("ALTER TABLE {table} ADD COLUMN rating_half_steps INTEGER
                    CHECK(rating_half_steps IS NULL OR (typeof(rating_half_steps)='integer' AND rating_half_steps BETWEEN 0 AND 10));"))?;
                if columns.iter().any(|column| column == "rating") {
                    // Preserve legacy columns for recoverability. All runtime SQL
                    // uses the explicit canonical column after this migration.
                    // Validate before arithmetic: SQLite would coerce malformed
                    // text to zero, silently inventing a valid rating. Invalid
                    // legacy values deliberately fail the new column's CHECK.
                    tx.execute(
                        &format!(
                            "UPDATE {table} SET rating_half_steps=CASE
                                WHEN typeof(rating)='integer' AND rating BETWEEN 0 AND 5
                                THEN rating*2 ELSE -1 END
                             WHERE rating IS NOT NULL"
                        ),
                        [],
                    )?;
                }
            }
        }
        tx.execute(
            "INSERT INTO rating_schema_migrations(version) VALUES(1)",
            [],
        )?;
    }
    // Protect every write path, including relinking/restoring missing tracks.
    for (table, _) in TABLES {
        for event in ["INSERT", "UPDATE OF rating_half_steps"] {
            let suffix = if event == "INSERT" {
                "insert"
            } else {
                "update"
            };
            tx.execute_batch(&format!(
                "CREATE TRIGGER IF NOT EXISTS {table}_rating_granularity_{suffix}
                BEFORE {event} ON {table}
                WHEN NEW.rating_half_steps IS NOT NULL AND NEW.rating_half_steps%2!=0
                    AND (SELECT granularity FROM rating_preferences WHERE singleton=1)='whole_stars'
                BEGIN SELECT RAISE(ABORT,'Half-star ratings are disabled'); END;"
            ))?;
        }
    }
    tx.commit()
}

pub(crate) fn preferences(conn: &Connection) -> Result<RatingScalePreferences, RatingError> {
    let value: String = conn.query_row(
        "SELECT granularity FROM rating_preferences WHERE singleton=1",
        [],
        |row| row.get(0),
    )?;
    Ok(RatingScalePreferences {
        granularity: if value == "whole_stars" {
            RatingGranularity::WholeStars
        } else {
            RatingGranularity::HalfStars
        },
    })
}

pub(crate) fn conversion_preview(
    conn: &Connection,
) -> Result<RatingConversionPreview, RatingError> {
    let count = |table: &str| -> rusqlite::Result<u64> {
        conn.query_row(
            &format!("SELECT COUNT(*) FROM {table} WHERE rating_half_steps%2=1"),
            [],
            |row| row.get(0),
        )
    };
    Ok(RatingConversionPreview {
        tracks: count("songs")?,
        releases: count("releases")?,
        missing_tracks: count("missing_tracks")?,
        archived_releases: count("artists_releases")?,
    })
}

pub(crate) fn change_preferences(
    conn: &Connection,
    granularity: RatingGranularity,
    rounding: Option<RatingRounding>,
) -> Result<RatingPreferenceChange, RatingError> {
    let tx = Transaction::new_unchecked(conn, TransactionBehavior::Immediate)?;
    // Recheck after taking the writer lock: ratings may have changed since the
    // settings screen displayed its conversion preview.
    let affected = conversion_preview(&tx)?;
    let total =
        affected.tracks + affected.releases + affected.missing_tracks + affected.archived_releases;
    let mut converted = RatingConversionPreview::default();
    if granularity == RatingGranularity::WholeStars && total > 0 {
        let rounding = rounding.ok_or_else(|| {
            RatingError::InvalidInput(
                "Choose rounding up or down before converting existing half-star ratings".into(),
            )
        })?;
        let operator = match rounding {
            RatingRounding::Up => "+1",
            RatingRounding::Down => "-1",
        };
        for (table, _) in TABLES {
            tx.execute(&format!("UPDATE {table} SET rating_half_steps=rating_half_steps{operator} WHERE rating_half_steps%2=1"), [])?;
        }
        converted = affected;
    }
    let value = if granularity == RatingGranularity::WholeStars {
        "whole_stars"
    } else {
        "half_stars"
    };
    tx.execute(
        "UPDATE rating_preferences SET granularity=?1 WHERE singleton=1",
        [value],
    )?;
    tx.commit()?;
    Ok(RatingPreferenceChange {
        preferences: RatingScalePreferences { granularity },
        converted,
    })
}

pub(crate) fn set_rating(
    conn: &Connection,
    release: bool,
    id: u64,
    steps: Option<u8>,
) -> Result<bool, RatingError> {
    let rating = steps
        .map(RatingHalfSteps::new)
        .transpose()
        .map_err(|message| RatingError::InvalidInput(message.into()))?;
    let tx = Transaction::new_unchecked(conn, TransactionBehavior::Immediate)?;
    if rating.is_some_and(RatingHalfSteps::is_fractional)
        && preferences(&tx)?.granularity == RatingGranularity::WholeStars
    {
        return Err(RatingError::InvalidInput(
            "Half-star ratings are disabled".into(),
        ));
    }
    let changed = if release {
        super::operations::set_release_rating(&tx, id, steps)
    } else {
        super::operations::set_track_rating(&tx, id, steps)
    }
    .map_err(|error| RatingError::Storage(error.to_string()))?;
    tx.commit()?;
    Ok(changed)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn legacy(conn: &Connection) {
        conn.execute_batch("PRAGMA foreign_keys=ON;
            CREATE TABLE songs(song_id INTEGER PRIMARY KEY,rating INTEGER CHECK(rating IS NULL OR rating BETWEEN 0 AND 5),updated_at TEXT DEFAULT CURRENT_TIMESTAMP);
            CREATE TABLE releases(release_id INTEGER PRIMARY KEY,rating INTEGER,updated_at TEXT DEFAULT CURRENT_TIMESTAMP);
            CREATE TABLE missing_tracks(missing_id INTEGER PRIMARY KEY,rating INTEGER);
            CREATE TABLE artists_releases(artists_release_id INTEGER PRIMARY KEY,rating INTEGER);
            CREATE TABLE playlist_songs(playlist_id INTEGER,song_id INTEGER REFERENCES songs(song_id));
            INSERT INTO songs(song_id,rating) VALUES(1,NULL),(2,0),(3,1),(4,3),(5,5);
            INSERT INTO releases(release_id,rating) VALUES(1,4);
            INSERT INTO missing_tracks(missing_id,rating) VALUES(1,3);
            INSERT INTO artists_releases(artists_release_id,rating) VALUES(1,2);
            INSERT INTO playlist_songs VALUES(7,4);").unwrap();
    }
    fn value(conn: &Connection, table: &str, id: &str, key: u64) -> Option<u8> {
        conn.query_row(
            &format!("SELECT rating_half_steps FROM {table} WHERE {id}=?1"),
            [key],
            |row| row.get(0),
        )
        .unwrap()
    }

    #[test]
    fn rating_migration_preserves_star_meaning_null_zero_relationships_and_runs_once_after_restart()
    {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("rating.db");
        let conn = Connection::open(&path).unwrap();
        legacy(&conn);
        migrate(&conn).unwrap();
        for (id, expected) in [
            (1, None),
            (2, Some(0)),
            (3, Some(2)),
            (4, Some(6)),
            (5, Some(10)),
        ] {
            assert_eq!(value(&conn, "songs", "song_id", id), expected);
        }
        assert_eq!(value(&conn, "releases", "release_id", 1), Some(8));
        assert_eq!(value(&conn, "missing_tracks", "missing_id", 1), Some(6));
        assert_eq!(
            value(&conn, "artists_releases", "artists_release_id", 1),
            Some(4)
        );
        assert_eq!(
            preferences(&conn).unwrap().granularity,
            RatingGranularity::HalfStars
        );
        assert_eq!(
            conn.query_row(
                "SELECT song_id FROM playlist_songs WHERE playlist_id=7",
                [],
                |row| row.get::<_, u64>(0)
            )
            .unwrap(),
            4
        );
        assert_eq!(
            conn.query_row("SELECT COUNT(*) FROM pragma_foreign_key_check", [], |row| {
                row.get::<_, u64>(0)
            })
            .unwrap(),
            0
        );
        assert!(
            conn.execute("UPDATE songs SET rating_half_steps=11 WHERE song_id=1", [])
                .is_err()
        );
        assert!(
            conn.execute("UPDATE songs SET rating_half_steps=0.5 WHERE song_id=1", [])
                .is_err()
        );
        set_rating(&conn, false, 4, Some(7)).unwrap();
        drop(conn);
        let reopened = Connection::open(path).unwrap();
        migrate(&reopened).unwrap();
        assert_eq!(value(&reopened, "songs", "song_id", 4), Some(7));
        assert_eq!(
            reopened
                .query_row("SELECT COUNT(*) FROM rating_schema_migrations", [], |row| {
                    row.get::<_, u64>(0)
                })
                .unwrap(),
            1
        );
    }

    #[test]
    fn rating_migration_rolls_back_all_tables_on_invalid_legacy_data() {
        let conn = Connection::open_in_memory().unwrap();
        legacy(&conn);
        conn.execute("UPDATE releases SET rating=9", []).unwrap();
        assert!(migrate(&conn).is_err());
        let columns = conn
            .prepare("PRAGMA table_info(songs)")
            .unwrap()
            .query_map([], |row| row.get::<_, String>(1))
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        assert!(!columns.contains(&"rating_half_steps".into()));
        conn.execute("UPDATE releases SET rating=4", []).unwrap();
        migrate(&conn).unwrap();
        assert_eq!(value(&conn, "songs", "song_id", 5), Some(10));
    }

    #[test]
    fn rating_migration_rejects_malformed_legacy_values_without_coercing_them_to_zero() {
        for invalid in ["'not a rating'", "1.5", "-1", "6", "x'3432'"] {
            let conn = Connection::open_in_memory().unwrap();
            legacy(&conn);
            conn.execute_batch(&format!(
                "UPDATE missing_tracks SET rating={invalid} WHERE missing_id=1"
            ))
            .unwrap();
            let original: rusqlite::types::Value = conn
                .query_row(
                    "SELECT rating FROM missing_tracks WHERE missing_id=1",
                    [],
                    |row| row.get(0),
                )
                .unwrap();
            assert!(
                migrate(&conn).is_err(),
                "invalid legacy rating {invalid} must fail"
            );
            let retained: rusqlite::types::Value = conn
                .query_row(
                    "SELECT rating FROM missing_tracks WHERE missing_id=1",
                    [],
                    |row| row.get(0),
                )
                .unwrap();
            assert_eq!(retained, original, "failure must retain original data");
            let migrated_columns: u64 = conn.query_row(
                "SELECT COUNT(*) FROM pragma_table_info('songs') WHERE name='rating_half_steps'",
                [], |row| row.get(0)
            ).unwrap();
            assert_eq!(migrated_columns, 0, "no table may be partially migrated");
            conn.execute("UPDATE missing_tracks SET rating=3 WHERE missing_id=1", [])
                .unwrap();
            migrate(&conn).unwrap();
            assert_eq!(value(&conn, "missing_tracks", "missing_id", 1), Some(6));
        }
    }

    #[test]
    fn rating_granularity_conversion_requires_explicit_rounding_and_updates_all_scopes_atomically()
    {
        for rounding in [RatingRounding::Up, RatingRounding::Down] {
            let conn = Connection::open_in_memory().unwrap();
            legacy(&conn);
            migrate(&conn).unwrap();
            for (table, key) in TABLES {
                conn.execute(
                    &format!("UPDATE {table} SET rating_half_steps=7 WHERE {key}=1"),
                    [],
                )
                .unwrap();
            }
            conn.execute("UPDATE songs SET rating_half_steps=1 WHERE song_id=2", [])
                .unwrap();
            let before = conversion_preview(&conn).unwrap();
            assert_eq!(before.tracks, 2);
            assert_eq!(before.releases, 1);
            assert_eq!(before.missing_tracks, 1);
            assert_eq!(before.archived_releases, 1);
            assert!(matches!(
                change_preferences(&conn, RatingGranularity::WholeStars, None),
                Err(RatingError::InvalidInput(_))
            ));
            assert_eq!(value(&conn, "songs", "song_id", 1), Some(7));
            assert_eq!(
                preferences(&conn).unwrap().granularity,
                RatingGranularity::HalfStars
            );
            let changed =
                change_preferences(&conn, RatingGranularity::WholeStars, Some(rounding)).unwrap();
            assert_eq!(changed.converted, before);
            let expected = if rounding == RatingRounding::Up { 8 } else { 6 };
            for (table, key) in TABLES {
                assert_eq!(value(&conn, table, key, 1), Some(expected));
            }
            assert_eq!(
                value(&conn, "songs", "song_id", 2),
                Some(if rounding == RatingRounding::Up { 2 } else { 0 })
            );
            assert!(matches!(
                set_rating(&conn, false, 1, Some(7)),
                Err(RatingError::InvalidInput(_))
            ));
            assert!(set_rating(&conn, false, 1, Some(11)).is_err());
            assert!(
                conn.execute("UPDATE missing_tracks SET rating_half_steps=5", [])
                    .is_err()
            );
            assert!(
                conn.execute(
                    "INSERT INTO songs(song_id,rating_half_steps) VALUES(9,9)",
                    []
                )
                .is_err()
            );
            set_rating(&conn, false, 1, None).unwrap();
            assert_eq!(value(&conn, "songs", "song_id", 1), None);
            set_rating(&conn, false, 1, Some(0)).unwrap();
            assert_eq!(value(&conn, "songs", "song_id", 1), Some(0));
            change_preferences(&conn, RatingGranularity::HalfStars, None).unwrap();
            assert_eq!(
                value(&conn, "missing_tracks", "missing_id", 1),
                Some(expected)
            );
            set_rating(&conn, true, 1, Some(9)).unwrap();
            assert_eq!(value(&conn, "releases", "release_id", 1), Some(9));
        }
    }

    #[test]
    fn rating_conversion_failure_does_not_partially_round_data_or_change_preferences() {
        let conn = Connection::open_in_memory().unwrap();
        legacy(&conn);
        migrate(&conn).unwrap();
        conn.execute("UPDATE songs SET rating_half_steps=7", [])
            .unwrap();
        conn.execute("UPDATE releases SET rating_half_steps=7", [])
            .unwrap();
        conn.execute_batch("CREATE TRIGGER fail_rating_conversion BEFORE UPDATE OF rating_half_steps ON releases BEGIN SELECT RAISE(ABORT,'disk write failure'); END;").unwrap();
        assert!(
            change_preferences(
                &conn,
                RatingGranularity::WholeStars,
                Some(RatingRounding::Up)
            )
            .is_err()
        );
        assert_eq!(value(&conn, "songs", "song_id", 1), Some(7));
        assert_eq!(
            preferences(&conn).unwrap().granularity,
            RatingGranularity::HalfStars
        );
    }

    #[test]
    fn rating_writer_racing_a_granularity_change_cannot_leave_fractional_values_in_whole_mode() {
        use std::sync::{Arc, Barrier};
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("rating.db");
        let conn = Connection::open(&path).unwrap();
        legacy(&conn);
        migrate(&conn).unwrap();
        conn.execute_batch("PRAGMA journal_mode=WAL;PRAGMA busy_timeout=5000;")
            .unwrap();
        for _ in 0..8 {
            change_preferences(&conn, RatingGranularity::HalfStars, None).unwrap();
            set_rating(&conn, false, 1, Some(6)).unwrap();
            let writer = Connection::open(&path).unwrap();
            writer
                .busy_timeout(std::time::Duration::from_secs(5))
                .unwrap();
            let converter = Connection::open(&path).unwrap();
            converter
                .busy_timeout(std::time::Duration::from_secs(5))
                .unwrap();
            let barrier = Arc::new(Barrier::new(3));
            let begin = barrier.clone();
            let write = std::thread::spawn(move || {
                begin.wait();
                set_rating(&writer, false, 1, Some(7))
            });
            let begin = barrier.clone();
            let conversion = std::thread::spawn(move || {
                begin.wait();
                change_preferences(
                    &converter,
                    RatingGranularity::WholeStars,
                    Some(RatingRounding::Up),
                )
            });
            barrier.wait();
            assert!(matches!(
                write.join().unwrap(),
                Ok(true) | Err(RatingError::InvalidInput(_))
            ));
            conversion.join().unwrap().unwrap();
            assert_eq!(
                preferences(&conn).unwrap().granularity,
                RatingGranularity::WholeStars
            );
            assert_eq!(value(&conn, "songs", "song_id", 1).unwrap() % 2, 0);
        }
    }

    #[test]
    fn rating_preference_survives_restart_and_switching_without_fractions_needs_no_rounding() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("rating.db");
        let conn = Connection::open(&path).unwrap();
        legacy(&conn);
        migrate(&conn).unwrap();
        assert_eq!(
            change_preferences(&conn, RatingGranularity::WholeStars, None)
                .unwrap()
                .converted,
            RatingConversionPreview::default()
        );
        drop(conn);
        let conn = Connection::open(path).unwrap();
        migrate(&conn).unwrap();
        assert_eq!(
            preferences(&conn).unwrap().granularity,
            RatingGranularity::WholeStars
        );
        assert!(set_rating(&conn, false, 1, Some(3)).is_err());
        assert!(set_rating(&conn, false, 999, Some(2)).is_ok_and(|changed| !changed));
    }
}

#[cfg(test)]
mod integration_tests {
    use super::*;
    use crate::{
        api::{SmartPlaylistDefinition, SmartPlaylistRule},
        database::operations,
    };

    #[test]
    fn half_star_rating_filters_preserve_existing_whole_star_rule_meaning_and_nullable_queries() {
        let conn = Connection::open_in_memory().unwrap();
        operations::create_tables(&conn).unwrap();
        for (id, steps) in [
            (1, Some(7)),
            (2, Some(8)),
            (3, Some(9)),
            (4, Some(10)),
            (5, None),
            (6, Some(0)),
        ] {
            conn.execute("INSERT INTO songs(song_id,title,artist_id,artist_name,release_id,release_title,track_number,disc_number,duration,file_path,rating_half_steps)
                VALUES(?1,?2,1,'Artist',1,'Album',1,1,180,?3,?4)",rusqlite::params![id,format!("Track {id}"),format!("/music/{id}.mp3"),steps]).unwrap();
        }
        let mut definition = SmartPlaylistDefinition {
            match_all: true,
            rules: vec![SmartPlaylistRule {
                field: "rating".into(),
                comparison: "greater_or_equal".into(),
                value: "4".into(),
            }],
            limit: None,
            sort_by: "rating".into(),
            descending: true,
        };
        let ids = |definition: &SmartPlaylistDefinition| {
            operations::get_smart_playlist_tracks(&conn, definition)
                .unwrap()
                .into_iter()
                .map(|track| track.song_id)
                .collect::<Vec<_>>()
        };
        assert_eq!(ids(&definition), vec![4, 3, 2]);
        definition.rules[0].value = "4.5".into();
        assert_eq!(ids(&definition), vec![4, 3]);
        definition.rules[0].value = "4.25".into();
        assert!(operations::validate_smart_playlist_definition(&definition).is_err());
        definition.rules[0].comparison = "is_empty".into();
        definition.rules[0].value = String::new();
        assert_eq!(ids(&definition), vec![5]);
        definition.rules[0].comparison = "equals".into();
        definition.rules[0].value = "0".into();
        assert_eq!(ids(&definition), vec![6]);
        assert_eq!(
            preferences(&conn).unwrap().granularity,
            RatingGranularity::HalfStars
        );
        assert!(set_rating(&conn, false, 1, Some(1)).unwrap());
        let unchanged = change_preferences(
            &conn,
            RatingGranularity::HalfStars,
            Some(RatingRounding::Up),
        )
        .unwrap();
        assert_eq!(unchanged.converted, RatingConversionPreview::default());
        assert_eq!(
            conn.query_row(
                "SELECT rating_half_steps FROM songs WHERE song_id=1",
                [],
                |row| row.get::<_, u8>(0)
            )
            .unwrap(),
            1
        );
    }
}
