use crate::database::models::*;
use crate::metadata::AudioMetadata;
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use chrono::Utc;
use rusqlite::{Connection, OptionalExtension, Row, params, types::ValueRef};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use thiserror::Error;

const CURRENT_METADATA_VERSION: i64 = 3;
static SCAN_ID_COUNTER: AtomicU64 = AtomicU64::new(0);
const SCAN_DISCOVERY_BATCH_SIZE: usize = 512;

#[derive(Error, Debug)]
pub enum DatabaseError {
    #[error("Rusqlite error: {0}")]
    Rusqlite(#[from] rusqlite::Error),
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
    #[error("Base64 decode error: {0}")]
    Base64(#[from] base64::DecodeError),
    #[error("Image error: {0}")]
    Image(#[from] image::ImageError),
    #[error("UTF-8 error: {0}")]
    Utf8(#[from] std::string::FromUtf8Error),
    #[error("System time error: {0}")]
    SystemTime(#[from] std::time::SystemTimeError),
    #[error("R2D2 error: {0}")]
    R2D2(#[from] r2d2::Error),
    #[error("{0}")]
    Custom(String),
}

pub type DatabaseResult<T> = Result<T, DatabaseError>;

// Keep positional row decoders coupled to an explicit projection instead of
// the physical table layout, which is allowed to evolve through migrations.
macro_rules! song_columns {
    ($table:literal) => {
        concat!(
            $table,
            ".song_id, ",
            $table,
            ".title, ",
            $table,
            ".artwork, ",
            $table,
            ".artist_id, ",
            $table,
            ".artist_name, ",
            $table,
            ".release_id, ",
            $table,
            ".release_title, ",
            $table,
            ".track_number, ",
            $table,
            ".disc_number, ",
            $table,
            ".duration, ",
            $table,
            ".bitrate, ",
            $table,
            ".sample_rate, ",
            $table,
            ".play_count, ",
            $table,
            ".last_played, ",
            $table,
            ".rating, ",
            $table,
            ".lyrics, ",
            $table,
            ".is_favorite, ",
            $table,
            ".is_hidden, ",
            $table,
            ".suggest_less, ",
            $table,
            ".file_path, ",
            $table,
            ".created_at, ",
            $table,
            ".updated_at"
        )
    };
}

macro_rules! release_columns {
    ($table:literal) => {
        concat!(
            $table,
            ".release_id, ",
            $table,
            ".title, ",
            $table,
            ".artist_id, ",
            $table,
            ".artist_name, ",
            $table,
            ".release_date, ",
            $table,
            ".total_tracks, ",
            $table,
            ".total_discs, ",
            $table,
            ".duration, ",
            $table,
            ".artwork, ",
            $table,
            ".created_at, ",
            $table,
            ".updated_at, ",
            $table,
            ".is_favorite, ",
            $table,
            ".is_hidden, ",
            $table,
            ".suggest_less, ",
            $table,
            ".rating"
        )
    };
}

/// Reads a duration from SQLite regardless of whether its INTEGER affinity
/// stored a whole-second value as `INTEGER` or a fractional value as `REAL`.
/// The public core model uses whole seconds, so fractional values are truncated.
fn duration_from_row(row: &Row<'_>, index: usize) -> rusqlite::Result<u64> {
    match row.get_ref(index)? {
        ValueRef::Null => Ok(0),
        ValueRef::Integer(value) => Ok(value.max(0) as u64),
        ValueRef::Real(value) if value.is_finite() && value >= 0.0 => Ok(value as u64),
        _ => Err(rusqlite::Error::FromSqlConversionFailure(
            index,
            rusqlite::types::Type::Text,
            "duration must be a finite, non-negative SQLite number".into(),
        )),
    }
}

fn song_item_from_row(row: &Row<'_>) -> rusqlite::Result<SongItem> {
    Ok(SongItem {
        song_id: row.get(0)?,
        title: row.get(1)?,
        artwork: row.get::<_, Option<String>>(2)?.unwrap_or_default(),
        artist_id: row.get(3)?,
        artist_name: row.get(4)?,
        release_id: row.get(5)?,
        release_title: row.get(6)?,
        track_number: row.get(7)?,
        disc_number: row.get(8)?,
        duration: row.get::<_, f64>(9)? as u64,
        bitrate: row.get(10)?,
        sample_rate: row.get(11)?,
        play_count: row.get(12)?,
        last_played: row.get(13)?,
        rating: row.get(14)?,
        lyrics: row.get(15)?,
        is_favorite: row.get(16)?,
        is_hidden: row.get(17)?,
        suggest_less: row.get(18)?,
        file_path: row.get(19)?,
        created_at: row.get(20)?,
        updated_at: row.get(21)?,
    })
}

fn release_from_row(row: &Row<'_>) -> rusqlite::Result<Releases> {
    Ok(Releases {
        release_id: row.get(0)?,
        title: row.get(1)?,
        artist_id: row.get(2)?,
        artist_name: row.get(3)?,
        release_date: row
            .get::<_, Option<i64>>(4)?
            .map(|date| date.to_string())
            .unwrap_or_default(),
        total_tracks: row.get(5)?,
        total_discs: row.get(6)?,
        duration: duration_from_row(row, 7)?,
        artwork: row.get::<_, Option<String>>(8)?.unwrap_or_default(),
        created_at: row.get(9)?,
        updated_at: row.get(10)?,
        is_favorite: row.get(11)?,
        is_hidden: row.get(12)?,
        suggest_less: row.get(13)?,
        rating: row.get(14)?,
    })
}

fn play_history_from_row(row: &Row<'_>) -> rusqlite::Result<PlayHistory> {
    Ok(PlayHistory {
        history_id: row.get(0)?,
        song_id: row.get(1)?,
        played_at: row.get(2)?,
        duration: row.get(3)?,
    })
}

// ===== Schema Management =====

/// Creates all tables and indexes. Idempotent.
pub fn create_tables(conn: &Connection) -> DatabaseResult<()> {
    conn.execute(
        "CREATE TABLE IF NOT EXISTS library_paths (
            path_id   INTEGER PRIMARY KEY,
            path TEXT UNIQUE
        )",
        (),
    )?;

    conn.execute(
        "CREATE TABLE IF NOT EXISTS settings (
            settings_id   INTEGER PRIMARY KEY,
            cross_fade BOOL DEFAULT TRUE,
            cross_fade_duration INTEGER DEFAULT 5 CHECK (cross_fade_duration BETWEEN 0 AND 60),
            normalize_volume BOOL DEFAULT TRUE,
            explicit_content BOOL DEFAULT TRUE,
            autoplay BOOL DEFAULT TRUE,
            preferred_audio_quality INTEGER DEFAULT 320 CHECK (preferred_audio_quality BETWEEN 1 AND 1411),
            preferred_audio_source TEXT DEFAULT '',
            download_path TEXT DEFAULT '',
            open_on_startup BOOL DEFAULT FALSE,
            minimize_on_close BOOL DEFAULT FALSE,
            onboarding BOOL DEFAULT TRUE
        )",
        (),
    )?;

    conn.execute(
        "CREATE TABLE IF NOT EXISTS queue (
            queue_id INTEGER PRIMARY KEY AUTOINCREMENT,
            song_id INTEGER NOT NULL,
            position INTEGER NOT NULL UNIQUE,
            added_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (song_id) REFERENCES songs(song_id) ON DELETE CASCADE
        )",
        (),
    )?;

    conn.execute(
        "CREATE TABLE IF NOT EXISTS genres (
            genre_id   INTEGER PRIMARY KEY,
            name TEXT,
            description TEXT,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        )",
        (),
    )?;

    conn.execute(
        "CREATE TABLE IF NOT EXISTS playlists (
            id   INTEGER PRIMARY KEY,
            name TEXT,
            cover BLOB,
            description TEXT,
            is_favorite BOOL DEFAULT FALSE,
            suggest_less BOOL DEFAULT FALSE,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        )",
        (),
    )?;

    conn.execute(
        "CREATE TABLE IF NOT EXISTS songs (
            song_id   INTEGER PRIMARY KEY,
            title TEXT NOT NULL,
            artwork TEXT,
            artist_id INTEGER NOT NULL,
            artist_name TEXT NOT NULL,
            release_id INTEGER NOT NULL,
            release_title TEXT NOT NULL,
            track_number INTEGER NOT NULL,
            disc_number INTEGER NOT NULL DEFAULT 1,
            duration INTEGER NOT NULL,
            bitrate INTEGER,
            sample_rate INTEGER,
            play_count INTEGER DEFAULT 0,
            last_played DATETIME,
            rating INTEGER DEFAULT NULL CHECK (rating IS NULL OR rating BETWEEN 0 AND 5),
            lyrics TEXT,
            is_favorite BOOL DEFAULT FALSE,
            is_hidden BOOL DEFAULT FALSE,
            suggest_less BOOL DEFAULT FALSE,
            file_path TEXT NOT NULL,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            file_mtime INTEGER,
            metadata_version INTEGER NOT NULL DEFAULT 1
        )",
        (),
    )?;

    let has_metadata_version = conn
        .prepare("PRAGMA table_info(songs)")?
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<Result<Vec<_>, _>>()?
        .iter()
        .any(|column| column == "metadata_version");
    if !has_metadata_version {
        conn.execute(
            "ALTER TABLE songs ADD COLUMN metadata_version INTEGER NOT NULL DEFAULT 0",
            [],
        )?;
    }

    conn.execute(
        "CREATE TABLE IF NOT EXISTS playlist_songs (
            playlist_id   INTEGER NOT NULL,
            song_id INTEGER NOT NULL,
            position INTEGER NOT NULL,
            added_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (playlist_id, song_id, position),
            FOREIGN KEY (playlist_id) REFERENCES playlists(id) ON DELETE CASCADE,
            FOREIGN KEY (song_id) REFERENCES songs(song_id) ON DELETE CASCADE
        )",
        (),
    )?;

    conn.execute(
        "CREATE TABLE IF NOT EXISTS artists (
            artist_id   INTEGER PRIMARY KEY,
            name TEXT
        )",
        (),
    )?;

    conn.execute(
        "CREATE TABLE IF NOT EXISTS song_artists (
            song_id INTEGER NOT NULL,
            artist_id INTEGER NOT NULL,
            position INTEGER NOT NULL,
            PRIMARY KEY (song_id, artist_id),
            FOREIGN KEY (song_id) REFERENCES songs(song_id) ON DELETE CASCADE,
            FOREIGN KEY (artist_id) REFERENCES artists(artist_id) ON DELETE CASCADE
        )",
        (),
    )?;

    conn.execute(
        "CREATE TABLE IF NOT EXISTS release_types (
            release_type_id   INTEGER PRIMARY KEY,
            name TEXT
        )",
        (),
    )?;

    conn.execute(
        "CREATE TABLE IF NOT EXISTS labels (
            id   INTEGER PRIMARY KEY,
            name TEXT,
            country TEXT
        )",
        (),
    )?;

    conn.execute(
        "CREATE TABLE IF NOT EXISTS releases (
            release_id   INTEGER PRIMARY KEY,
            title TEXT,
            artist_id INTEGER NOT NULL,
            artist_name TEXT NOT NULL,
            release_date DATETIME,
            total_tracks INTEGER DEFAULT 1,
            total_discs INTEGER DEFAULT 1,
            duration INTEGER,
            artwork TEXT,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            is_favorite BOOL DEFAULT FALSE,
            is_hidden BOOL DEFAULT FALSE,
            suggest_less BOOL DEFAULT FALSE,
            rating INTEGER DEFAULT NULL CHECK (rating IS NULL OR rating BETWEEN 0 AND 5),
            FOREIGN KEY (artist_id) REFERENCES artists(artist_id) ON DELETE CASCADE
        )",
        (),
    )?;

    conn.execute(
        "CREATE TABLE IF NOT EXISTS artists_releases (
            id   INTEGER PRIMARY KEY,
            title TEXT,
            artist_id INTEGER NOT NULL,
            artists_name TEXT,
            release_type_id INTEGER NOT NULL,
            release_date DATETIME,
            total_tracks INTEGER DEFAULT 1,
            total_discs INTEGER DEFAULT 1,
            label_id INTEGER NOT NULL,
            artwork TEXT,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            description TEXT,
            is_explicit BOOL,
            is_favorite BOOL,
            rating INTEGER,
            spotify_url TEXT,
            apple_music_url TEXT,
            last_fm_url TEXT,
            discog_url TEXT,
            rate_your_music_url TEXT,
            FOREIGN KEY (artist_id) REFERENCES artists(artist_id) ON DELETE CASCADE,
            FOREIGN KEY (release_type_id) REFERENCES release_types(release_type_id) ON DELETE CASCADE
        )",
        (),
    )?;

    conn.execute(
        "CREATE TABLE IF NOT EXISTS artists_playlists (
            id   INTEGER PRIMARY KEY,
            artist_id INTEGER NOT NULL,
            playlist_id INTEGER NOT NULL,
            FOREIGN KEY (artist_id) REFERENCES artists(artist_id) ON DELETE CASCADE,
            FOREIGN KEY (playlist_id) REFERENCES playlists(id) ON DELETE CASCADE
        )",
        (),
    )?;

    conn.execute(
        "CREATE TABLE IF NOT EXISTS labels_artists (
            id   INTEGER PRIMARY KEY,
            artist_id INTEGER NOT NULL,
            label_id INTEGER NOT NULL,
            FOREIGN KEY (artist_id) REFERENCES artists(artist_id) ON DELETE CASCADE,
            FOREIGN KEY (label_id) REFERENCES labels(id) ON DELETE CASCADE
        )",
        (),
    )?;

    conn.execute(
        "CREATE TABLE IF NOT EXISTS play_history (
            history_id INTEGER PRIMARY KEY AUTOINCREMENT,
            song_id INTEGER NOT NULL,
            played_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            play_duration INTEGER,
            FOREIGN KEY (song_id) REFERENCES songs(song_id) ON DELETE CASCADE
        )",
        (),
    )?;

    // Single-row table (session_id = 1 always) that persists the player state
    // across restarts so the user can resume exactly where they left off.
    conn.execute(
        "CREATE TABLE IF NOT EXISTS last_session (
            session_id      INTEGER PRIMARY KEY DEFAULT 1 CHECK (session_id = 1),
            current_song_id INTEGER REFERENCES songs(song_id) ON DELETE SET NULL,
            progress_seconds REAL NOT NULL DEFAULT 0.0,
            volume          REAL NOT NULL DEFAULT 0.5,
            shuffle_enabled INTEGER NOT NULL DEFAULT 0,
            repeat_mode     TEXT NOT NULL DEFAULT 'none',
            queue_snapshot  TEXT NOT NULL DEFAULT '[]',
            queue_position  INTEGER NOT NULL DEFAULT 0,
            source_context  TEXT NOT NULL DEFAULT '',
            updated_at      DATETIME DEFAULT CURRENT_TIMESTAMP
        )",
        (),
    )?;

    ensure_indexes(conn)?;
    ensure_search_indexes(conn)?;

    Ok(())
}

/// Creates the indexes that back the common library queries.
fn ensure_indexes(conn: &Connection) -> DatabaseResult<()> {
    const INDEXES: &[&str] = &[
        "CREATE INDEX IF NOT EXISTS idx_songs_release ON songs(release_id)",
        "CREATE INDEX IF NOT EXISTS idx_songs_artist ON songs(artist_id)",
        "CREATE INDEX IF NOT EXISTS idx_song_artists_artist ON song_artists(artist_id)",
        "CREATE INDEX IF NOT EXISTS idx_songs_title ON songs(title)",
        "CREATE INDEX IF NOT EXISTS idx_songs_file_path ON songs(file_path)",
        "CREATE INDEX IF NOT EXISTS idx_songs_dedupe ON songs(title, artist_id, release_id)",
        "CREATE INDEX IF NOT EXISTS idx_releases_artist ON releases(artist_id)",
        "CREATE INDEX IF NOT EXISTS idx_playlist_songs_playlist ON playlist_songs(playlist_id)",
        "CREATE INDEX IF NOT EXISTS idx_play_history_song ON play_history(song_id)",
    ];

    for sql in INDEXES {
        conn.execute(sql, [])?;
    }

    Ok(())
}

/// Creates substring-search indexes and keeps them synchronized with their
/// content tables. Trigram FTS makes the common `contains` search indexable
/// while retaining the behavior of the former `%query%` scans.
fn ensure_search_indexes(conn: &Connection) -> DatabaseResult<()> {
    let definitions = [
        (
            "songs_search",
            "songs",
            "song_id",
            "title, artist_name, release_title",
        ),
        (
            "releases_search",
            "releases",
            "release_id",
            "title, artist_name",
        ),
        ("artists_search", "artists", "artist_id", "name"),
        ("playlists_search", "playlists", "id", "name, description"),
    ];

    for (index, table, row_id, columns) in definitions {
        let existed = conn.query_row(
            "SELECT EXISTS(
                SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1
             )",
            [index],
            |row| row.get::<_, bool>(0),
        )?;
        conn.execute_batch(&format!(
            "CREATE VIRTUAL TABLE IF NOT EXISTS {index}
                 USING fts5({columns}, content='{table}', content_rowid='{row_id}', tokenize='trigram');
             CREATE TRIGGER IF NOT EXISTS {index}_insert AFTER INSERT ON {table} BEGIN
                 INSERT INTO {index}(rowid, {columns}) VALUES (new.{row_id}, {new_columns});
             END;
             CREATE TRIGGER IF NOT EXISTS {index}_delete AFTER DELETE ON {table} BEGIN
                 INSERT INTO {index}({index}, rowid, {columns})
                 VALUES ('delete', old.{row_id}, {old_columns});
             END;
             CREATE TRIGGER IF NOT EXISTS {index}_update
                 AFTER UPDATE OF {columns} ON {table} BEGIN
                 INSERT INTO {index}({index}, rowid, {columns})
                 VALUES ('delete', old.{row_id}, {old_columns});
                 INSERT INTO {index}(rowid, {columns}) VALUES (new.{row_id}, {new_columns});
             END;",
            new_columns = columns
                .split(", ")
                .map(|column| format!("new.{column}"))
                .collect::<Vec<_>>()
                .join(", "),
            old_columns = columns
                .split(", ")
                .map(|column| format!("old.{column}"))
                .collect::<Vec<_>>()
                .join(", "),
        ))?;
        if !existed {
            conn.execute(
                &format!("INSERT INTO {index}({index}) VALUES ('rebuild')"),
                [],
            )?;
        }
    }
    Ok(())
}

// ===== Library Path Operations =====

pub fn add_library_path(conn: &Connection, path: String) -> DatabaseResult<()> {
    conn.execute(
        "INSERT OR IGNORE INTO library_paths (path) VALUES (?1)",
        params![&path],
    )?;
    Ok(())
}

pub fn get_library_paths(conn: &Connection) -> DatabaseResult<Vec<LibraryPath>> {
    let mut stmt = conn.prepare("SELECT path_id, path FROM library_paths")?;
    let path_iter = stmt.query_map([], |row| Ok(LibraryPath { path: row.get(1)? }))?;
    let paths: Result<Vec<LibraryPath>, _> = path_iter.collect();
    Ok(paths?)
}

/// Removes a configured library path and reports whether it existed.
pub fn remove_library_path(conn: &Connection, path: &str) -> DatabaseResult<bool> {
    Ok(conn.execute("DELETE FROM library_paths WHERE path = ?1", params![path])? > 0)
}

// ===== Settings =====

pub fn initiate_settings(conn: &Connection) -> DatabaseResult<()> {
    let count: i64 = conn.query_row("SELECT COUNT(*) FROM settings", [], |row| row.get(0))?;
    if count == 0 {
        conn.execute("INSERT INTO settings DEFAULT VALUES", [])?;
    }
    Ok(())
}

pub fn get_settings(conn: &Connection) -> DatabaseResult<Settings> {
    let mut stmt = conn.prepare(
        "SELECT settings_id, cross_fade, cross_fade_duration, normalize_volume,
                explicit_content, autoplay, preferred_audio_quality,
                preferred_audio_source, download_path, open_on_startup,
                minimize_on_close, onboarding
         FROM settings",
    )?;
    let mut rows = stmt.query_map([], |row| {
        Ok(Settings {
            settings_id: row.get(0)?,
            cross_fade: row.get(1)?,
            cross_fade_duration: row.get(2)?,
            normalize_volume: row.get(3)?,
            explicit_content: row.get(4)?,
            autoplay: row.get(5)?,
            preferred_audio_quality: row.get(6)?,
            preferred_audio_source: row.get(7)?,
            download_path: row.get(8)?,
            open_on_startup: row.get(9)?,
            minimize_on_close: row.get(10)?,
            onboarding: row.get(11)?,
        })
    })?;

    match rows.next() {
        Some(Ok(settings)) => Ok(settings),
        Some(Err(e)) => Err(DatabaseError::Custom(format!(
            "Failed to parse settings: {}",
            e
        ))),
        None => Err(DatabaseError::Custom(
            "No settings found in database".to_string(),
        )),
    }
}

/// Persists the singleton settings row and reports an error if it has not been
/// initialized. Keeping this write here lets every frontend use the identical
/// persistence path.
pub fn save_settings(conn: &Connection, settings: &Settings) -> DatabaseResult<()> {
    let changed = conn.execute(
        "UPDATE settings SET
            cross_fade = ?1,
            cross_fade_duration = ?2,
            normalize_volume = ?3,
            explicit_content = ?4,
            autoplay = ?5,
            preferred_audio_quality = ?6,
            preferred_audio_source = ?7,
            download_path = ?8,
            open_on_startup = ?9,
            minimize_on_close = ?10,
            onboarding = ?11
         WHERE settings_id = 1",
        params![
            settings.cross_fade,
            settings.cross_fade_duration,
            settings.normalize_volume,
            settings.explicit_content,
            settings.autoplay,
            settings.preferred_audio_quality,
            settings.preferred_audio_source,
            settings.download_path,
            settings.open_on_startup,
            settings.minimize_on_close,
            settings.onboarding,
        ],
    )?;
    if changed == 0 {
        return Err(DatabaseError::Custom(
            "Settings have not been initialized".to_string(),
        ));
    }
    Ok(())
}

pub fn update_onboarding_setting(conn: &Connection, value: bool) -> DatabaseResult<()> {
    conn.execute(
        "UPDATE settings SET onboarding = ?1 WHERE settings_id = 1",
        params![value],
    )?;
    Ok(())
}

// ===== Artist/Release/Song Operations =====

pub fn add_artist(conn: &Connection, artist: String) -> DatabaseResult<()> {
    let exists: bool = conn.query_row(
        "SELECT COUNT(*) FROM artists WHERE name = ?1",
        params![&artist],
        |row| Ok(row.get::<_, i64>(0)? > 0),
    )?;

    if !exists {
        conn.execute("INSERT INTO artists (name) VALUES (?1)", params![&artist])?;
    }
    Ok(())
}

pub fn add_release(conn: &Connection, release: &ReleaseGroup) -> DatabaseResult<()> {
    let artist_id: Option<i64> = conn
        .query_row(
            "SELECT artist_id FROM artists WHERE name = ?1",
            params![&release.artist],
            |row| row.get(0),
        )
        .optional()?;

    let artist_id = match artist_id {
        Some(id) => id,
        None => {
            return Err(DatabaseError::Custom(format!(
                "Artist '{}' not found in database",
                release.artist
            )));
        }
    };

    let exists: bool = conn.query_row(
        "SELECT COUNT(*) FROM releases WHERE title = ?1 AND artist_id = ?2",
        params![&release.title, artist_id],
        |row| Ok(row.get::<_, i64>(0)? > 0),
    )?;

    if !exists {
        conn.execute(
            "INSERT INTO releases (title, artist_id, artist_name, release_date, total_tracks, total_discs, duration, artwork) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![
                &release.title,
                artist_id,
                &release.artist,
                &release.date,
                &release.tracks,
                &release.disc,
                &release.duration,
                &release.artwork
            ],
        )?;
    } else {
        // Keep better metadata discovered by a later scan without replacing
        // existing artwork/date with an empty or unknown value.
        conn.execute(
            "UPDATE releases
             SET artwork = CASE WHEN ?1 <> '' THEN ?1 ELSE artwork END,
                 release_date = CASE WHEN ?2 > 0 THEN ?2 ELSE release_date END,
                 updated_at = CURRENT_TIMESTAMP
             WHERE title = ?3 AND artist_id = ?4",
            params![&release.artwork, release.date, &release.title, artist_id,],
        )?;
    }
    Ok(())
}

fn refresh_release_statistics(conn: &Connection, release: &ReleaseGroup) -> DatabaseResult<()> {
    let artist_id: i64 = conn.query_row(
        "SELECT artist_id FROM artists WHERE name = ?1",
        params![&release.artist],
        |row| row.get(0),
    )?;
    let release_id: i64 = conn.query_row(
        "SELECT release_id FROM releases WHERE title = ?1 AND artist_id = ?2",
        params![&release.title, artist_id],
        |row| row.get(0),
    )?;
    let (track_count, disc_count, duration): (u32, u32, u64) = conn.query_row(
        "SELECT COUNT(*), COALESCE(MAX(disc_number), 1), COALESCE(SUM(duration), 0)
         FROM songs WHERE release_id = ?1",
        [release_id],
        |row| Ok((row.get(0)?, row.get(1)?, duration_from_row(row, 2)?)),
    )?;
    conn.execute(
        "UPDATE releases
         SET total_tracks = ?1, total_discs = ?2, duration = ?3, updated_at = CURRENT_TIMESTAMP
         WHERE release_id = ?4",
        params![track_count, disc_count, duration, release_id],
    )?;
    Ok(())
}

fn lookup_artist_id(conn: &Connection, song: &AudioMetadata) -> DatabaseResult<i64> {
    let artist = song
        .track_artists
        .first()
        .or(song.artist.as_ref())
        .ok_or_else(|| DatabaseError::Custom("Track artist is missing".to_string()))?;
    let id: Option<i64> = conn
        .query_row(
            "SELECT artist_id FROM artists WHERE name = ?1",
            params![artist],
            |row| row.get(0),
        )
        .optional()?;
    id.ok_or_else(|| DatabaseError::Custom(format!("Artist '{artist}' not found")))
}

fn replace_song_artists(conn: &Connection, song_id: i64, artists: &[String]) -> DatabaseResult<()> {
    conn.execute("DELETE FROM song_artists WHERE song_id = ?1", [song_id])?;
    for (position, artist) in artists.iter().enumerate() {
        conn.execute(
            "INSERT OR IGNORE INTO song_artists (song_id, artist_id, position)
             SELECT ?1, artist_id, ?2 FROM artists WHERE name = ?3",
            params![song_id, position, artist],
        )?;
    }
    Ok(())
}

fn lookup_release_id(conn: &Connection, song: &AudioMetadata) -> DatabaseResult<i64> {
    let id: Option<i64> = conn
        .query_row(
            "SELECT releases.release_id
             FROM releases
             JOIN artists ON artists.artist_id = releases.artist_id
             WHERE releases.title = ?1 AND artists.name = ?2",
            params![&song.release, &song.album_artist],
            |row| row.get(0),
        )
        .optional()?;
    id.ok_or_else(|| DatabaseError::Custom(format!("Release '{:?}' not found", song.release)))
}

pub(crate) enum SongWriteResult {
    Added,
    Updated,
    SkippedDuplicate,
}

pub(crate) fn add_song(
    conn: &Connection,
    song: AudioMetadata,
    mtime: i64,
    existing_id: Option<i64>,
) -> DatabaseResult<SongWriteResult> {
    let artwork = song.cover_path.as_deref();

    if let Some(song_id) = existing_id {
        let artist_id = lookup_artist_id(conn, &song)?;
        let release_id = lookup_release_id(conn, &song)?;
        conn.execute(
            "UPDATE songs SET title=?1, artwork=?2, artist_id=?3, artist_name=?4, release_id=?5, release_title=?6, track_number=?7, disc_number=?8, duration=?9, file_mtime=?10, metadata_version=?11, updated_at=CURRENT_TIMESTAMP WHERE song_id=?12",
            params![
                &song.title,
                artwork,
                artist_id,
                &song.artist,
                release_id,
                &song.release,
                &song.track.unwrap_or(1),
                &song.disc.unwrap_or(1),
                &song.duration,
                mtime,
                CURRENT_METADATA_VERSION,
                song_id,
            ],
        )?;
        replace_song_artists(conn, song_id, &song.track_artists)?;
        return Ok(SongWriteResult::Updated);
    }

    let artist_id = lookup_artist_id(conn, &song)?;
    let release_id = lookup_release_id(conn, &song)?;

    let exists: bool = conn.query_row(
        "SELECT COUNT(*) FROM songs WHERE title = ?1 AND artist_id = ?2 AND release_id = ?3",
        params![&song.title, artist_id, release_id],
        |row| Ok(row.get::<_, i64>(0)? > 0),
    )?;

    if !exists {
        conn.execute(
            "INSERT INTO songs (title, artwork, artist_id, artist_name, release_id, release_title, duration, track_number, disc_number, file_path, file_mtime, metadata_version) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
            params![
                &song.title,
                artwork,
                artist_id,
                &song.artist,
                release_id,
                &song.release,
                &song.duration,
                &song.track.unwrap_or(1),
                &song.disc.unwrap_or(1),
                &song.file_path,
                mtime,
                CURRENT_METADATA_VERSION,
            ],
        )?;
        replace_song_artists(conn, conn.last_insert_rowid(), &song.track_artists)?;
        return Ok(SongWriteResult::Added);
    }

    Ok(SongWriteResult::SkippedDuplicate)
}

pub fn group_artists(array: &[AudioMetadata]) -> Vec<String> {
    let artists: std::collections::HashSet<String> = array
        .iter()
        .flat_map(|item| item.track_artists.iter().chain(item.album_artist.iter()))
        .cloned()
        .collect();

    artists.into_iter().collect()
}

pub fn group_releases(array: &Vec<AudioMetadata>) -> Vec<ReleaseGroup> {
    let mut release_map: HashMap<String, ReleaseGroup> = HashMap::new();

    for item in array {
        let artwork = item.cover_path.clone().unwrap_or_default();
        let title = item.release.as_deref().unwrap_or("Unknown Album");
        let artist = item.album_artist.as_deref().unwrap_or("Unknown Artist");
        let year = item.year.unwrap_or_default();
        let key = format!("{}|{}|{}", title, artist, year);

        let release_group = release_map.entry(key).or_insert_with(|| ReleaseGroup {
            title: title.to_string(),
            artist: artist.to_string(),
            artwork,
            date: year,
            duration: 0,
            tracks: 0,
            disc: 1,
        });

        release_group.duration += item.duration as u64;
        release_group.tracks += 1;
        if let Some(disc) = item.disc {
            release_group.disc = release_group.disc.max(disc);
        }
    }

    release_map.into_values().collect()
}

// ===== Query Operations =====

pub fn get_releases(conn: &Connection) -> DatabaseResult<Vec<Releases>> {
    let mut stmt = conn.prepare(concat!(
        "SELECT ",
        release_columns!("releases"),
        " FROM releases"
    ))?;
    let releases_iter = stmt.query_map([], release_from_row)?;

    let releases: Result<Vec<Releases>, _> = releases_iter.collect();
    Ok(releases?)
}

pub fn get_release_by_id(conn: &Connection, release_id: &str) -> DatabaseResult<Releases> {
    conn.query_row(
        concat!(
            "SELECT ",
            release_columns!("releases"),
            " FROM releases WHERE releases.release_id = ?1"
        ),
        [release_id],
        release_from_row,
    )
    .map_err(DatabaseError::from)
}

pub fn get_songs_by_release_id(
    conn: &Connection,
    release_id: &str,
) -> DatabaseResult<Vec<SongItem>> {
    let mut stmt = conn.prepare(concat!(
        "SELECT ",
        song_columns!("songs"),
        " FROM songs WHERE songs.release_id = ?1"
    ))?;
    let song_iter = stmt.query_map([release_id], song_item_from_row)?;

    let mut songs = Vec::new();
    for song in song_iter {
        songs.push(song?);
    }
    Ok(songs)
}

pub fn get_song_by_id(conn: &Connection, song_id: &str) -> DatabaseResult<Vec<SongItem>> {
    let mut stmt = conn.prepare(concat!(
        "SELECT ",
        song_columns!("songs"),
        " FROM songs WHERE songs.song_id = ?1"
    ))?;
    let song_iter = stmt.query_map([song_id], song_item_from_row)?;

    let mut songs = Vec::new();
    for song in song_iter {
        songs.push(song?);
    }
    Ok(songs)
}

pub fn add_song_to_history(conn: &Connection, song_id: u64, duration: u64) -> DatabaseResult<()> {
    let played_at = Utc::now().to_rfc3339();
    conn.execute(
        "INSERT INTO play_history (song_id, played_at, play_duration) VALUES (?1, ?2, ?3)",
        params![song_id, played_at, duration],
    )?;
    Ok(())
}

/// Records a naturally completed track. The counter, timestamp, and history
/// entry share one transaction so playback statistics cannot drift apart.
pub fn record_completed_playback(
    conn: &Connection,
    song_id: u64,
    duration: u64,
) -> DatabaseResult<bool> {
    let transaction = conn.unchecked_transaction()?;
    let changed = transaction.execute(
        "UPDATE songs
         SET play_count = play_count + 1, last_played = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
         WHERE song_id = ?1",
        [song_id],
    )?;
    if changed == 0 {
        return Ok(false);
    }
    let played_at = Utc::now().to_rfc3339();
    transaction.execute(
        "INSERT INTO play_history (song_id, played_at, play_duration) VALUES (?1, ?2, ?3)",
        params![song_id, played_at, duration],
    )?;
    transaction.commit()?;
    Ok(true)
}

pub fn get_play_history(conn: &Connection) -> DatabaseResult<Vec<PlayHistory>> {
    let mut stmt = conn.prepare(
        "SELECT history_id, song_id, played_at, play_duration
         FROM play_history ORDER BY played_at DESC, history_id DESC",
    )?;
    Ok(stmt
        .query_map([], play_history_from_row)?
        .collect::<Result<_, _>>()?)
}

pub fn get_play_history_page(
    conn: &Connection,
    limit: u64,
    offset: u64,
) -> DatabaseResult<Vec<PlayHistory>> {
    let mut stmt = conn.prepare(
        "SELECT history_id, song_id, played_at, play_duration
         FROM play_history ORDER BY played_at DESC, history_id DESC
         LIMIT ?1 OFFSET ?2",
    )?;
    Ok(stmt
        .query_map(params![limit, offset], play_history_from_row)?
        .collect::<Result<_, _>>()?)
}

pub fn remove_song_from_history(conn: &Connection, history_id: u64) -> DatabaseResult<bool> {
    Ok(conn.execute(
        "DELETE FROM play_history WHERE history_id = ?1 ",
        params![history_id],
    )? > 0)
}

/// Deletes all completed-playback events and returns how many were removed.
pub fn clear_play_history(conn: &Connection) -> DatabaseResult<u64> {
    Ok(conn.execute("DELETE FROM play_history", [])? as u64)
}

pub fn favorite_track(conn: &Connection, song_id: u64) -> DatabaseResult<()> {
    conn.execute(
        "UPDATE songs SET is_favorite = NOT is_favorite, updated_at = CURRENT_TIMESTAMP WHERE song_id = ?1 ",
        params![song_id],
    )?;
    Ok(())
}

pub fn favorite_release(conn: &Connection, release_id: u64) -> DatabaseResult<()> {
    conn.execute(
        "UPDATE releases SET is_favorite = NOT is_favorite, updated_at = CURRENT_TIMESTAMP WHERE release_id = ?1 ",
        params![release_id],
    )?;
    Ok(())
}

pub fn hide_track(conn: &Connection, song_id: u64) -> DatabaseResult<()> {
    conn.execute(
        "UPDATE songs SET is_hidden = NOT is_hidden, updated_at = CURRENT_TIMESTAMP WHERE song_id = ?1 ",
        params![song_id],
    )?;
    Ok(())
}

pub fn suggest_less_track(conn: &Connection, song_id: u64) -> DatabaseResult<()> {
    conn.execute(
        "UPDATE songs SET suggest_less = NOT suggest_less, updated_at = CURRENT_TIMESTAMP WHERE song_id = ?1 ",
        params![song_id],
    )?;
    Ok(())
}

pub fn set_track_favorite(conn: &Connection, song_id: u64, favorite: bool) -> DatabaseResult<bool> {
    Ok(conn.execute(
        "UPDATE songs SET is_favorite = ?1, updated_at = CURRENT_TIMESTAMP WHERE song_id = ?2",
        params![favorite, song_id],
    )? > 0)
}

pub fn set_release_favorite(
    conn: &Connection,
    release_id: u64,
    favorite: bool,
) -> DatabaseResult<bool> {
    Ok(conn.execute(
        "UPDATE releases SET is_favorite = ?1, updated_at = CURRENT_TIMESTAMP WHERE release_id = ?2",
        params![favorite, release_id],
    )? > 0)
}

pub fn set_track_hidden(conn: &Connection, song_id: u64, hidden: bool) -> DatabaseResult<bool> {
    Ok(conn.execute(
        "UPDATE songs SET is_hidden = ?1, updated_at = CURRENT_TIMESTAMP WHERE song_id = ?2",
        params![hidden, song_id],
    )? > 0)
}

pub fn set_release_hidden(
    conn: &Connection,
    release_id: u64,
    hidden: bool,
) -> DatabaseResult<bool> {
    Ok(conn.execute(
        "UPDATE releases SET is_hidden = ?1, updated_at = CURRENT_TIMESTAMP WHERE release_id = ?2",
        params![hidden, release_id],
    )? > 0)
}

pub fn set_track_suggest_less(
    conn: &Connection,
    song_id: u64,
    suggest_less: bool,
) -> DatabaseResult<bool> {
    Ok(conn.execute(
        "UPDATE songs SET suggest_less = ?1, updated_at = CURRENT_TIMESTAMP WHERE song_id = ?2",
        params![suggest_less, song_id],
    )? > 0)
}

pub fn set_release_suggest_less(
    conn: &Connection,
    release_id: u64,
    suggest_less: bool,
) -> DatabaseResult<bool> {
    Ok(conn.execute(
        "UPDATE releases SET suggest_less = ?1, updated_at = CURRENT_TIMESTAMP WHERE release_id = ?2",
        params![suggest_less, release_id],
    )? > 0)
}

pub fn set_track_rating(
    conn: &Connection,
    song_id: u64,
    rating: Option<u8>,
) -> DatabaseResult<bool> {
    Ok(conn.execute(
        "UPDATE songs SET rating = ?1, updated_at = CURRENT_TIMESTAMP WHERE song_id = ?2",
        params![rating, song_id],
    )? > 0)
}

pub fn set_release_rating(
    conn: &Connection,
    release_id: u64,
    rating: Option<u8>,
) -> DatabaseResult<bool> {
    Ok(conn.execute(
        "UPDATE releases SET rating = ?1, updated_at = CURRENT_TIMESTAMP WHERE release_id = ?2",
        params![rating, release_id],
    )? > 0)
}

pub fn get_all_tracks(conn: &Connection) -> DatabaseResult<Vec<SongItem>> {
    let mut tracks = conn.prepare(concat!(
        "SELECT ",
        song_columns!("songs"),
        " FROM songs ORDER BY songs.song_id"
    ))?;
    Ok(tracks
        .query_map([], song_item_from_row)?
        .collect::<Result<_, _>>()?)
}

pub fn get_tracks_page(
    conn: &Connection,
    limit: u64,
    offset: u64,
) -> DatabaseResult<Vec<SongItem>> {
    let mut tracks = conn.prepare(concat!(
        "SELECT ",
        song_columns!("songs"),
        " FROM songs ORDER BY songs.song_id LIMIT ?1 OFFSET ?2"
    ))?;
    Ok(tracks
        .query_map(params![limit, offset], song_item_from_row)?
        .collect::<Result<_, _>>()?)
}

pub fn get_all_releases(conn: &Connection) -> DatabaseResult<Vec<Releases>> {
    let mut releases = conn.prepare(concat!(
        "SELECT ",
        release_columns!("releases"),
        " FROM releases ORDER BY releases.release_id"
    ))?;
    Ok(releases
        .query_map([], release_from_row)?
        .collect::<Result<_, _>>()?)
}

pub fn get_releases_page(
    conn: &Connection,
    limit: u64,
    offset: u64,
) -> DatabaseResult<Vec<Releases>> {
    let mut releases = conn.prepare(concat!(
        "SELECT ",
        release_columns!("releases"),
        " FROM releases ORDER BY releases.release_id LIMIT ?1 OFFSET ?2"
    ))?;
    Ok(releases
        .query_map(params![limit, offset], release_from_row)?
        .collect::<Result<_, _>>()?)
}

pub fn get_all_artists(conn: &Connection) -> DatabaseResult<Vec<ArtistItem>> {
    let mut artists = conn.prepare("SELECT artist_id, name FROM artists ORDER BY artist_id")?;
    let artists_map = artists.query_map([], |row| {
        Ok(ArtistItem {
            artist_id: row.get(0)?,
            artist_name: row.get(1)?,
        })
    })?;

    let mut results = Vec::new();
    for item in artists_map {
        results.push(item?);
    }
    Ok(results)
}

pub fn get_artist_by_id(conn: &Connection, artist_id: &str) -> DatabaseResult<ArtistItem> {
    conn.query_row(
        "SELECT artist_id, name FROM artists WHERE artist_id = ?1",
        [artist_id],
        |row| {
            Ok(ArtistItem {
                artist_id: row.get(0)?,
                artist_name: row.get(1)?,
            })
        },
    )
    .map_err(DatabaseError::from)
}

pub fn get_songs_by_artist_id(conn: &Connection, artist_id: &str) -> DatabaseResult<Vec<SongItem>> {
    let mut stmt = conn.prepare(concat!(
        "SELECT ",
        song_columns!("songs"),
        " FROM songs
         JOIN song_artists ON song_artists.song_id = songs.song_id
         WHERE song_artists.artist_id = ?1
         ORDER BY songs.release_title, songs.disc_number, songs.track_number"
    ))?;
    let songs = stmt
        .query_map([artist_id], |row| {
            Ok(SongItem {
                song_id: row.get(0)?,
                title: row.get(1)?,
                artwork: row.get::<_, Option<String>>(2)?.unwrap_or_default(),
                artist_id: row.get(3)?,
                artist_name: row.get(4)?,
                release_id: row.get(5)?,
                release_title: row.get(6)?,
                track_number: row.get(7)?,
                disc_number: row.get(8)?,
                duration: duration_from_row(row, 9)?,
                bitrate: row.get(10)?,
                sample_rate: row.get(11)?,
                play_count: row.get(12)?,
                last_played: row.get(13)?,
                rating: row.get(14)?,
                lyrics: row.get(15)?,
                is_favorite: row.get(16)?,
                is_hidden: row.get(17)?,
                suggest_less: row.get(18)?,
                file_path: row.get(19)?,
                created_at: row.get(20)?,
                updated_at: row.get(21)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(songs)
}

pub fn get_releases_by_artist_id(
    conn: &Connection,
    artist_id: &str,
) -> DatabaseResult<Vec<Releases>> {
    let mut stmt = conn.prepare(concat!(
        "SELECT DISTINCT ",
        release_columns!("releases"),
        " FROM releases
         LEFT JOIN songs ON songs.release_id = releases.release_id
         LEFT JOIN song_artists ON song_artists.song_id = songs.song_id
         WHERE releases.artist_id = ?1 OR song_artists.artist_id = ?1
         ORDER BY releases.release_date DESC, releases.title COLLATE NOCASE"
    ))?;
    let releases = stmt
        .query_map([artist_id], |row| {
            Ok(Releases {
                release_id: row.get(0)?,
                title: row.get(1)?,
                artist_id: row.get(2)?,
                artist_name: row.get(3)?,
                release_date: row
                    .get::<_, Option<i64>>(4)?
                    .map(|date| date.to_string())
                    .unwrap_or_default(),
                total_tracks: row.get(5)?,
                total_discs: row.get(6)?,
                duration: duration_from_row(row, 7)?,
                artwork: row.get::<_, Option<String>>(8)?.unwrap_or_default(),
                created_at: row.get(9)?,
                updated_at: row.get(10)?,
                is_favorite: row.get(11)?,
                is_hidden: row.get(12)?,
                suggest_less: row.get(13)?,
                rating: row.get(14)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(releases)
}

pub struct LibrarySearchResults {
    pub tracks: Vec<SongItem>,
    pub releases: Vec<Releases>,
    pub artists: Vec<ArtistItem>,
    pub playlists: Vec<Playlist>,
}

const DEFAULT_SEARCH_RESULT_LIMIT: usize = 50;
const MAX_SEARCH_RESULT_LIMIT: usize = 100;

/// Searches the first bounded page of every library category.
pub fn search_library(conn: &Connection, query: &str) -> DatabaseResult<LibrarySearchResults> {
    search_library_page(conn, query, DEFAULT_SEARCH_RESULT_LIMIT, 0)
}

/// Searches the library with an indexed, case-insensitive substring query.
/// Exposed separately so future frontends can page without changing the query
/// implementation or materializing the complete library.
pub fn search_library_page(
    conn: &Connection,
    query: &str,
    limit: usize,
    offset: usize,
) -> DatabaseResult<LibrarySearchResults> {
    let limit = limit.clamp(1, MAX_SEARCH_RESULT_LIMIT) as i64;
    let offset = offset as i64;
    let escaped = query
        .replace('\\', "\\\\")
        .replace('%', "\\%")
        .replace('_', "\\_");
    let pattern = format!("%{}%", escaped);
    let use_fts = query.chars().count() >= 3;
    let fts_query = format!("\"{}\"", query.replace('"', "\"\""));

    let tracks_sql = if use_fts {
        "SELECT s.song_id, s.title, s.artwork, s.artist_id, s.artist_name,
                s.release_id, s.release_title, s.track_number, s.disc_number,
                s.duration, s.bitrate, s.sample_rate, s.play_count, s.last_played,
                s.rating, NULL, s.is_favorite, s.is_hidden, s.suggest_less,
                s.file_path, s.created_at, s.updated_at
         FROM songs_search
         JOIN songs s ON s.song_id = songs_search.rowid
         WHERE songs_search MATCH ?1
         ORDER BY bm25(songs_search), s.title COLLATE NOCASE
         LIMIT ?2 OFFSET ?3"
    } else {
        "SELECT s.song_id, s.title, s.artwork, s.artist_id, s.artist_name,
                s.release_id, s.release_title, s.track_number, s.disc_number,
                s.duration, s.bitrate, s.sample_rate, s.play_count, s.last_played,
                s.rating, NULL, s.is_favorite, s.is_hidden, s.suggest_less,
                s.file_path, s.created_at, s.updated_at
         FROM songs s
         WHERE s.title LIKE ?1 ESCAPE '\\' COLLATE NOCASE
            OR s.artist_name LIKE ?1 ESCAPE '\\' COLLATE NOCASE
            OR s.release_title LIKE ?1 ESCAPE '\\' COLLATE NOCASE
         ORDER BY s.title COLLATE NOCASE
         LIMIT ?2 OFFSET ?3"
    };
    let search_term = if use_fts { &fts_query } else { &pattern };
    let mut tracks_stmt = conn.prepare(tracks_sql)?;
    let tracks = tracks_stmt
        .query_map(params![search_term, limit, offset], song_item_from_row)?
        .collect::<Result<Vec<_>, _>>()?;

    let releases_sql = if use_fts {
        "SELECT r.release_id, r.title, r.artist_id, r.artist_name, r.release_date,
                r.total_tracks, r.total_discs, r.duration, r.artwork, r.created_at,
                r.updated_at, r.is_favorite, r.is_hidden, r.suggest_less, r.rating
         FROM releases_search
         JOIN releases r ON r.release_id = releases_search.rowid
         WHERE releases_search MATCH ?1
         ORDER BY bm25(releases_search), r.title COLLATE NOCASE
         LIMIT ?2 OFFSET ?3"
    } else {
        "SELECT r.release_id, r.title, r.artist_id, r.artist_name, r.release_date,
                r.total_tracks, r.total_discs, r.duration, r.artwork, r.created_at,
                r.updated_at, r.is_favorite, r.is_hidden, r.suggest_less, r.rating
         FROM releases r
         WHERE r.title LIKE ?1 ESCAPE '\\' COLLATE NOCASE
            OR r.artist_name LIKE ?1 ESCAPE '\\' COLLATE NOCASE
         ORDER BY r.title COLLATE NOCASE
         LIMIT ?2 OFFSET ?3"
    };
    let mut releases_stmt = conn.prepare(releases_sql)?;
    let releases = releases_stmt
        .query_map(params![search_term, limit, offset], release_from_row)?
        .collect::<Result<Vec<_>, _>>()?;

    let artists_sql = if use_fts {
        "SELECT a.artist_id, a.name
         FROM artists_search
         JOIN artists a ON a.artist_id = artists_search.rowid
         WHERE artists_search MATCH ?1
         ORDER BY bm25(artists_search), a.name COLLATE NOCASE
         LIMIT ?2 OFFSET ?3"
    } else {
        "SELECT a.artist_id, a.name FROM artists a
         WHERE a.name LIKE ?1 ESCAPE '\\' COLLATE NOCASE
         ORDER BY a.name COLLATE NOCASE
         LIMIT ?2 OFFSET ?3"
    };
    let mut artists_stmt = conn.prepare(artists_sql)?;
    let artists = artists_stmt
        .query_map(params![search_term, limit, offset], |row| {
            Ok(ArtistItem {
                artist_id: row.get(0)?,
                artist_name: row.get(1)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;

    let playlists_sql = if use_fts {
        "SELECT p.id, p.name, NULL, p.description, p.is_favorite,
                p.suggest_less, p.created_at, p.updated_at
         FROM playlists_search
         JOIN playlists p ON p.id = playlists_search.rowid
         WHERE playlists_search MATCH ?1
         ORDER BY bm25(playlists_search), p.name COLLATE NOCASE
         LIMIT ?2 OFFSET ?3"
    } else {
        "SELECT p.id, p.name, NULL, p.description, p.is_favorite,
                p.suggest_less, p.created_at, p.updated_at
         FROM playlists p
         WHERE p.name LIKE ?1 ESCAPE '\\' COLLATE NOCASE
            OR p.description LIKE ?1 ESCAPE '\\' COLLATE NOCASE
         ORDER BY p.name COLLATE NOCASE
         LIMIT ?2 OFFSET ?3"
    };
    let mut playlists_stmt = conn.prepare(playlists_sql)?;
    let playlists = playlists_stmt
        .query_map(params![search_term, limit, offset], |row| {
            Ok(Playlist {
                id: row.get(0)?,
                name: row.get(1)?,
                cover: row.get(2)?,
                description: row.get(3)?,
                is_favorite: row.get(4)?,
                suggest_less: row.get(5)?,
                created_at: row.get(6)?,
                updated_at: row.get(7)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;

    Ok(LibrarySearchResults {
        tracks,
        releases,
        artists,
        playlists,
    })
}

pub fn create_playlist(
    conn: &Connection,
    name: String,
    cover: String,
    description: String,
) -> DatabaseResult<Playlist> {
    let cover_blob = decode_playlist_cover(&cover)?;

    let mut stmt = conn.prepare(
        "INSERT INTO playlists (name, cover, description)
         VALUES (?1, ?2, ?3)
         RETURNING id, name, cover, description, is_favorite, suggest_less, created_at, updated_at",
    )?;

    let playlist: Playlist = stmt.query_row(params![&name, &cover_blob, &description], |row| {
        Ok(Playlist {
            id: row.get(0)?,
            name: row.get(1)?,
            cover: row.get(2)?,
            description: row.get(3)?,
            is_favorite: row.get(4)?,
            suggest_less: row.get(5)?,
            created_at: row.get(6)?,
            updated_at: row.get(7)?,
        })
    })?;

    Ok(playlist)
}

fn decode_playlist_cover(cover: &str) -> DatabaseResult<Option<Vec<u8>>> {
    if !cover.is_empty() {
        let base64_data = if cover.starts_with("data:") {
            if let Some(pos) = cover.find("base64,") {
                &cover[pos + 7..]
            } else if let Some(pos) = cover.find(',') {
                &cover[pos + 1..]
            } else {
                return Err(DatabaseError::Custom(
                    "Invalid Data URL: no base64 data found".to_string(),
                ));
            }
        } else {
            cover
        };

        let base64_data = base64_data.trim();
        let maximum_encoded_length = crate::metadata::MAX_ARTWORK_BYTES.div_ceil(3) * 4;
        if base64_data.len() > maximum_encoded_length {
            return Err(DatabaseError::Custom(format!(
                "Playlist artwork exceeds the {} MiB limit",
                crate::metadata::MAX_ARTWORK_BYTES / (1024 * 1024)
            )));
        }
        match STANDARD.decode(base64_data) {
            Ok(data) => {
                crate::metadata::validate_artwork_bytes(&data).map_err(|error| {
                    DatabaseError::Custom(format!("Invalid playlist artwork: {error}"))
                })?;
                Ok(Some(data))
            }
            Err(e) => Err(DatabaseError::Custom(format!(
                "Failed to decode base64 image: {} (data: '{}')",
                e,
                if base64_data.len() > 50 {
                    format!("{}...", &base64_data[..50])
                } else {
                    base64_data.to_string()
                }
            ))),
        }
    } else {
        Ok(None)
    }
}

/// Fetches playlists and their track counts in one aggregate query. The LEFT
/// JOIN intentionally keeps empty playlists in the result.
pub fn get_all_playlists_with_track_counts(
    conn: &Connection,
) -> DatabaseResult<Vec<PlaylistWithTrackCount>> {
    let mut playlists = conn.prepare(
        "SELECT
            p.id, p.name, p.cover, p.description, p.is_favorite,
            p.suggest_less, p.created_at, p.updated_at,
            COUNT(ps.song_id)
         FROM playlists p
         LEFT JOIN playlist_songs ps ON ps.playlist_id = p.id
         GROUP BY
            p.id, p.name, p.cover, p.description, p.is_favorite,
            p.suggest_less, p.created_at, p.updated_at
         ORDER BY p.id",
    )?;
    let playlist_map = playlists.query_map([], |row| {
        Ok(PlaylistWithTrackCount {
            playlist: Playlist {
                id: row.get(0)?,
                name: row.get(1)?,
                cover: row.get(2)?,
                description: row.get(3)?,
                is_favorite: row.get(4)?,
                suggest_less: row.get(5)?,
                created_at: row.get(6)?,
                updated_at: row.get(7)?,
            },
            track_count: row.get(8)?,
        })
    })?;

    let mut results = Vec::new();
    for item in playlist_map {
        results.push(item?);
    }
    Ok(results)
}

pub fn get_playlist_by_id(conn: &Connection, playlist_id: u64) -> DatabaseResult<Playlist> {
    conn.query_row(
        "SELECT id, name, cover, description, is_favorite, suggest_less,
                created_at, updated_at
         FROM playlists WHERE id = ?1",
        [playlist_id],
        |row| {
            Ok(Playlist {
                id: row.get(0)?,
                name: row.get(1)?,
                cover: row.get(2)?,
                description: row.get(3)?,
                is_favorite: row.get(4)?,
                suggest_less: row.get(5)?,
                created_at: row.get(6)?,
                updated_at: row.get(7)?,
            })
        },
    )
    .map_err(DatabaseError::from)
}

pub fn update_playlist(
    conn: &Connection,
    playlist_id: u64,
    name: String,
    description: String,
    cover: String,
) -> DatabaseResult<bool> {
    let cover_blob = decode_playlist_cover(&cover)?;
    Ok(conn.execute(
        "UPDATE playlists SET name = ?1, description = ?2, cover = ?3, updated_at = CURRENT_TIMESTAMP WHERE id = ?4",
        params![name, description, cover_blob, playlist_id],
    )? > 0)
}

pub fn set_playlist_favorite(
    conn: &Connection,
    playlist_id: u64,
    favorite: bool,
) -> DatabaseResult<bool> {
    Ok(conn.execute(
        "UPDATE playlists SET is_favorite = ?1, updated_at = CURRENT_TIMESTAMP WHERE id = ?2",
        params![favorite, playlist_id],
    )? > 0)
}

pub fn set_playlist_suggest_less(
    conn: &Connection,
    playlist_id: u64,
    suggest_less: bool,
) -> DatabaseResult<bool> {
    Ok(conn.execute(
        "UPDATE playlists SET suggest_less = ?1, updated_at = CURRENT_TIMESTAMP WHERE id = ?2",
        params![suggest_less, playlist_id],
    )? > 0)
}

pub fn delete_playlist(conn: &Connection, playlist_id: u64) -> DatabaseResult<bool> {
    Ok(conn.execute("DELETE FROM playlists WHERE id = ?1", [playlist_id])? > 0)
}

pub fn get_playlist_tracks(conn: &Connection, playlist_id: u64) -> DatabaseResult<Vec<SongItem>> {
    let mut stmt = conn.prepare(concat!(
        "SELECT ",
        song_columns!("s"),
        " FROM playlist_songs ps
         JOIN songs s ON s.song_id = ps.song_id
         WHERE ps.playlist_id = ?1
         ORDER BY ps.position"
    ))?;
    let tracks = stmt
        .query_map([playlist_id], |row| {
            Ok(SongItem {
                song_id: row.get(0)?,
                title: row.get(1)?,
                artwork: row.get::<_, Option<String>>(2)?.unwrap_or_default(),
                artist_id: row.get(3)?,
                artist_name: row.get(4)?,
                release_id: row.get(5)?,
                release_title: row.get(6)?,
                track_number: row.get(7)?,
                disc_number: row.get(8)?,
                duration: row.get::<_, f64>(9)? as u64,
                bitrate: row.get(10)?,
                sample_rate: row.get(11)?,
                play_count: row.get(12)?,
                last_played: row.get(13)?,
                rating: row.get(14)?,
                lyrics: row.get(15)?,
                is_favorite: row.get(16)?,
                is_hidden: row.get(17)?,
                suggest_less: row.get(18)?,
                file_path: row.get(19)?,
                created_at: row.get(20)?,
                updated_at: row.get(21)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(tracks)
}

pub fn get_playlist_track_count(conn: &Connection, playlist_id: u64) -> DatabaseResult<u64> {
    conn.query_row(
        "SELECT COUNT(*) FROM playlist_songs WHERE playlist_id = ?1",
        [playlist_id],
        |row| row.get(0),
    )
    .map_err(DatabaseError::from)
}

pub fn get_all_playlist_songs(conn: &Connection) -> DatabaseResult<Vec<PlaylistSong>> {
    let mut playlist_song = conn.prepare(
        "SELECT playlist_id, song_id, position, added_at
         FROM playlist_songs ORDER BY playlist_id, position",
    )?;
    let playlist_song_map = playlist_song.query_map([], |row| {
        Ok(PlaylistSong {
            playlist_id: row.get(0)?,
            song_id: row.get(1)?,
            position: row.get(2)?,
            added_at: row.get(3)?,
        })
    })?;

    let mut results = Vec::new();
    for item in playlist_song_map {
        results.push(item?);
    }
    Ok(results)
}

pub fn add_track_to_playlist_songs(
    conn: &Connection,
    playlist_id: u64,
    song_id: u64,
    position: u64,
) -> DatabaseResult<PlaylistSong> {
    let added_at = Utc::now().to_rfc3339();

    let mut stmt = conn.prepare(
        "INSERT INTO playlist_songs (playlist_id, song_id, position, added_at) VALUES (?1, ?2, ?3, ?4) RETURNING playlist_id, song_id, position, added_at",
    )?;

    let playlist_song: PlaylistSong = stmt.query_row(
        params![&playlist_id, &song_id, &position, &added_at],
        |row| {
            Ok(PlaylistSong {
                playlist_id: row.get(0)?,
                song_id: row.get(1)?,
                position: row.get(2)?,
                added_at: row.get(3)?,
            })
        },
    )?;

    Ok(playlist_song)
}

pub fn remove_track_from_playlist(
    conn: &Connection,
    playlist_id: u64,
    song_id: u64,
    position: u64,
) -> DatabaseResult<()> {
    conn.execute(
        "DELETE FROM playlist_songs WHERE playlist_id = ?1 AND song_id = ?2 AND position = ?3",
        params![playlist_id, song_id, position],
    )?;
    Ok(())
}

// ===== LAST SESSION COMMANDS =====

/// Ensures a default session row exists (session_id = 1).
/// Called once on startup alongside `initiate_settings`.
pub fn initiate_last_session(conn: &Connection) -> DatabaseResult<()> {
    conn.execute(
        "INSERT OR IGNORE INTO last_session (session_id) VALUES (1)",
        [],
    )?;
    Ok(())
}

/// Returns the persisted session, or a sensible default if none exists yet.
pub fn get_last_session(conn: &Connection) -> DatabaseResult<LastSession> {
    let session = conn
        .query_row(
            "SELECT
                current_song_id,
                progress_seconds,
                volume,
                shuffle_enabled,
                repeat_mode,
                queue_snapshot,
                queue_position,
                source_context,
                updated_at
             FROM last_session
             WHERE session_id = 1",
            [],
            |row| {
                Ok(LastSession {
                    current_song_id: row.get(0)?,
                    progress_seconds: row.get(1)?,
                    volume: row.get(2)?,
                    shuffle_enabled: row.get::<_, i64>(3)? != 0,
                    repeat_mode: row.get(4)?,
                    queue_snapshot: row.get(5)?,
                    queue_position: row.get(6)?,
                    source_context: row.get(7)?,
                    updated_at: row.get(8)?,
                })
            },
        )
        .optional()?;

    // If the row doesn't exist yet (e.g. first ever launch before initiate_last_session
    // ran), return a zero-state default rather than an error.
    Ok(session.unwrap_or(LastSession {
        current_song_id: None,
        progress_seconds: 0.0,
        volume: 0.5,
        shuffle_enabled: false,
        repeat_mode: "none".to_string(),
        queue_snapshot: "[]".to_string(),
        queue_position: 0,
        source_context: "".to_string(),
        updated_at: Utc::now().to_rfc3339(),
    }))
}

/// Upserts the complete session state in one call.
/// Call this whenever any of the tracked fields change (song change, seek,
/// volume, shuffle toggle, etc.) — it's a single cheap SQLite write.
pub fn save_last_session(conn: &Connection, session: &LastSession) -> DatabaseResult<()> {
    let updated_at = Utc::now().to_rfc3339();

    conn.execute(
        "INSERT INTO last_session (
            session_id, current_song_id, progress_seconds, volume,
            shuffle_enabled, repeat_mode, queue_snapshot, queue_position,
            source_context, updated_at
         ) VALUES (1, ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
         ON CONFLICT(session_id) DO UPDATE SET
            current_song_id  = excluded.current_song_id,
            progress_seconds = excluded.progress_seconds,
            volume           = excluded.volume,
            shuffle_enabled  = excluded.shuffle_enabled,
            repeat_mode      = excluded.repeat_mode,
            queue_snapshot   = excluded.queue_snapshot,
            queue_position   = excluded.queue_position,
            source_context   = excluded.source_context,
            updated_at       = excluded.updated_at",
        params![
            session.current_song_id,
            session.progress_seconds,
            session.volume,
            session.shuffle_enabled as i64,
            session.repeat_mode,
            session.queue_snapshot,
            session.queue_position,
            session.source_context,
            updated_at,
        ],
    )?;

    Ok(())
}

/// Convenience command: update only the playback position (called on seek / every N seconds).
/// Avoids having to pass the full session state on every progress tick.
pub fn update_session_progress(conn: &Connection, progress_seconds: f64) -> DatabaseResult<()> {
    let updated_at = Utc::now().to_rfc3339();

    conn.execute(
        "UPDATE last_session
         SET progress_seconds = ?1, updated_at = ?2
         WHERE session_id = 1",
        params![progress_seconds, updated_at],
    )?;

    Ok(())
}

/// Convenience command: update only the volume level.
pub fn update_session_volume(conn: &Connection, volume: f64) -> DatabaseResult<()> {
    let updated_at = Utc::now().to_rfc3339();

    conn.execute(
        "UPDATE last_session
         SET volume = ?1, updated_at = ?2
         WHERE session_id = 1",
        params![volume, updated_at],
    )?;

    Ok(())
}

/// Convenience command: update the current song and reset progress to 0.
/// Call this when a track change happens so you never read stale progress for a new song.
pub fn update_session_current_song(
    conn: &Connection,
    current_song_id: Option<i64>,
    queue_snapshot: String,
    queue_position: i64,
    source_context: String,
) -> DatabaseResult<()> {
    let updated_at = Utc::now().to_rfc3339();

    conn.execute(
        "UPDATE last_session
         SET current_song_id  = ?1,
             progress_seconds = 0.0,
             queue_snapshot   = ?2,
             queue_position   = ?3,
             source_context   = ?4,
             updated_at       = ?5
         WHERE session_id = 1",
        params![
            current_song_id,
            queue_snapshot,
            queue_position,
            source_context,
            updated_at,
        ],
    )?;

    Ok(())
}

/// Clears the session back to defaults (e.g. user explicitly stops playback).
pub fn clear_last_session(conn: &Connection) -> DatabaseResult<()> {
    let updated_at = Utc::now().to_rfc3339();

    conn.execute(
        "UPDATE last_session
         SET current_song_id  = NULL,
             progress_seconds = 0.0,
             queue_snapshot   = '[]',
             queue_position   = 0,
             source_context   = '',
             updated_at       = ?1
         WHERE session_id = 1",
        params![updated_at],
    )?;

    Ok(())
}

// ===== Scan Operations =====

fn is_audio_file(extension: &str) -> bool {
    crate::audio::SUPPORTED_AUDIO_EXTENSIONS.contains(&extension.to_lowercase().as_str())
}

fn file_mtime(path: &str) -> DatabaseResult<i64> {
    let meta = fs::metadata(path)?;
    let sys = meta.modified()?;
    Ok(sys.duration_since(std::time::UNIX_EPOCH)?.as_millis() as i64)
}

pub fn scan_folder(folder_path: String) -> DatabaseResult<Vec<FileInfo>> {
    let mut files = Vec::new();
    walk_audio_files(&folder_path, None, |file| {
        files.push(file);
        Ok(())
    })?;
    Ok(files)
}

struct FolderScan {
    root: PathBuf,
    total_files: usize,
    complete: bool,
}

fn walk_audio_files(
    folder_path: &str,
    cancel_requested: Option<&std::sync::atomic::AtomicBool>,
    mut on_file: impl FnMut(FileInfo) -> DatabaseResult<()>,
) -> DatabaseResult<FolderScan> {
    let path = PathBuf::from(folder_path);

    if !path.exists() {
        return Err(DatabaseError::Custom("Folder does not exist".to_string()));
    }

    if !path.is_dir() {
        return Err(DatabaseError::Custom("Path is not a directory".to_string()));
    }

    let root = fs::canonicalize(&path)?;
    let mut directories = vec![root.clone()];
    let mut total_files = 0;
    let mut complete = true;

    while let Some(dir) = directories.pop() {
        if scan_cancelled(cancel_requested) {
            complete = false;
            break;
        }
        // A directory can become inaccessible or disappear during a long scan.
        // Skip that subtree and continue discovering the rest of the library.
        let Ok(entries) = fs::read_dir(&dir) else {
            complete = false;
            continue;
        };

        for entry in entries {
            if scan_cancelled(cancel_requested) {
                complete = false;
                break;
            }
            let Ok(entry) = entry else {
                complete = false;
                continue;
            };
            let path = entry.path();
            let Ok(metadata) = fs::symlink_metadata(&path) else {
                complete = false;
                continue;
            };

            // Never traverse links: a directory link can form a cycle, and a
            // file link would otherwise make one track appear under many paths.
            if metadata.file_type().is_symlink() {
                continue;
            }
            if metadata.is_dir() {
                directories.push(path);
                continue;
            }
            if !metadata.is_file() {
                continue;
            }

            let Ok(canonical_path) = fs::canonicalize(&path) else {
                complete = false;
                continue;
            };

            let extension = canonical_path
                .extension()
                .map(|ext| ext.to_string_lossy().to_string())
                .unwrap_or_default();
            if !is_audio_file(&extension) {
                continue;
            }
            on_file(FileInfo {
                name: canonical_path
                    .file_name()
                    .unwrap_or_default()
                    .to_string_lossy()
                    .to_string(),
                path: canonical_path.to_string_lossy().to_string(),
                size: metadata.len(),
                is_directory: false,
                extension,
            })?;
            total_files += 1;
        }
    }
    Ok(FolderScan {
        root,
        total_files,
        complete,
    })
}

/// The synchronous portion of an incremental scan.  Keeping this separate from
/// metadata extraction ensures a SQLite connection never lives across an await.
pub(crate) struct PendingDatabaseUpdate {
    total_files: usize,
    files: Vec<(FileInfo, i64, Option<i64>)>,
    reconciliation: Option<ScanReconciliation>,
}

pub(crate) struct ScanReconciliation {
    scan_id: String,
    root: PathBuf,
}

pub(crate) struct PendingMetadataBatch {
    processed_before: usize,
    files: Vec<(FileInfo, i64, Option<i64>)>,
}

pub(crate) struct PendingMetadataBatches {
    processed_files: usize,
    files: std::vec::IntoIter<(FileInfo, i64, Option<i64>)>,
}

const METADATA_PERSIST_BATCH_SIZE: usize = 128;

impl Iterator for PendingMetadataBatches {
    type Item = PendingMetadataBatch;

    fn next(&mut self) -> Option<Self::Item> {
        let files: Vec<_> = self
            .files
            .by_ref()
            .take(METADATA_PERSIST_BATCH_SIZE)
            .collect();
        if files.is_empty() {
            return None;
        }
        let processed_before = self.processed_files;
        self.processed_files += files.len();
        Some(PendingMetadataBatch {
            processed_before,
            files,
        })
    }
}

/// Metadata that was extracted successfully, alongside file-level failures.
pub(crate) struct ExtractedMetadata {
    pub(crate) metadata: Vec<AudioMetadata>,
    pub(crate) mtimes: Vec<i64>,
    pub(crate) existing_song_ids: Vec<Option<i64>>,
    pub(crate) attempted_files: usize,
    pub(crate) errors: Vec<String>,
}

pub(crate) struct PersistedMetadata {
    pub(crate) added_tracks: usize,
    pub(crate) updated_tracks: usize,
}

type MetadataTask = (
    String,
    tokio::task::JoinHandle<Result<AudioMetadata, String>>,
    i64,
    Option<i64>,
);
pub(crate) type MetadataProgressCallback = dyn Fn(usize) + Send + Sync;

const MAX_METADATA_TASKS: usize = 4;

fn scan_cancelled(cancel_requested: Option<&std::sync::atomic::AtomicBool>) -> bool {
    cancel_requested.is_some_and(|cancel| cancel.load(std::sync::atomic::Ordering::Acquire))
}

fn reset_scan_discovery_table(conn: &Connection) -> DatabaseResult<()> {
    // The staging table deliberately lives in the main schema while a scan is
    // active: SQLite TEMP tables are connection-local, but scan preparation and
    // reconciliation use different connections from the pool. It is dropped
    // as soon as reconciliation finishes (or immediately for incomplete scans).
    conn.execute_batch(
        "DROP TABLE IF EXISTS scan_discovered_paths;
         CREATE TABLE scan_discovered_paths (
             scan_id    TEXT NOT NULL,
             file_path TEXT NOT NULL,
             name      TEXT NOT NULL,
             size      INTEGER NOT NULL,
             extension TEXT NOT NULL,
             file_mtime INTEGER NOT NULL,
             PRIMARY KEY (scan_id, file_path)
         ) WITHOUT ROWID;",
    )?;
    Ok(())
}

fn stage_discovered_files(
    conn: &Connection,
    scan_id: &str,
    files: &[(FileInfo, i64)],
) -> DatabaseResult<()> {
    let transaction = conn.unchecked_transaction()?;
    {
        let mut statement = transaction.prepare_cached(
            "INSERT OR IGNORE INTO scan_discovered_paths
                (scan_id, file_path, name, size, extension, file_mtime)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        )?;
        for (file, mtime) in files {
            statement.execute(params![
                scan_id,
                file.path,
                file.name,
                file.size,
                file.extension,
                mtime
            ])?;
        }
    }
    transaction.commit()?;
    Ok(())
}

impl PendingDatabaseUpdate {
    pub(crate) fn total_files(&self) -> usize {
        self.total_files
    }

    pub(crate) fn into_metadata_batches(
        self,
    ) -> (PendingMetadataBatches, Option<ScanReconciliation>) {
        let processed_files = self.total_files.saturating_sub(self.files.len());
        (
            PendingMetadataBatches {
                processed_files,
                files: self.files.into_iter(),
            },
            self.reconciliation,
        )
    }
}

pub(crate) fn prepare_database_update(
    conn: &Connection,
    folder_path: String,
) -> DatabaseResult<PendingDatabaseUpdate> {
    prepare_database_update_with_cancel(conn, folder_path, None)
}

pub(crate) fn prepare_database_update_with_cancel(
    conn: &Connection,
    folder_path: String,
    cancel_requested: Option<&std::sync::atomic::AtomicBool>,
) -> DatabaseResult<PendingDatabaseUpdate> {
    let scan_id = format!(
        "{}-{}",
        std::process::id(),
        SCAN_ID_COUNTER.fetch_add(1, Ordering::Relaxed)
    );
    reset_scan_discovery_table(conn)?;

    let mut discovery_batch = Vec::with_capacity(SCAN_DISCOVERY_BATCH_SIZE);
    let scan = walk_audio_files(&folder_path, cancel_requested, |file| {
        let mtime = file_mtime(&file.path)?;
        discovery_batch.push((file, mtime));
        if discovery_batch.len() == SCAN_DISCOVERY_BATCH_SIZE {
            stage_discovered_files(conn, &scan_id, &discovery_batch)?;
            discovery_batch.clear();
        }
        Ok(())
    })?;
    stage_discovered_files(conn, &scan_id, &discovery_batch)?;

    let to_process = {
        let mut statement = conn.prepare(
            "SELECT discovered.name,
                    discovered.file_path,
                    discovered.size,
                    discovered.extension,
                    discovered.file_mtime,
                    songs.song_id
             FROM scan_discovered_paths AS discovered
             LEFT JOIN songs ON songs.file_path = discovered.file_path
             WHERE discovered.scan_id = ?1
               AND (songs.song_id IS NULL
                    OR songs.file_mtime IS NULL
                    OR songs.file_mtime != discovered.file_mtime
                    OR songs.metadata_version != ?2)
             ORDER BY discovered.file_path",
        )?;
        statement
            .query_map(params![scan_id, CURRENT_METADATA_VERSION], |row| {
                let size = row.get::<_, u64>(2)?;
                Ok((
                    FileInfo {
                        name: row.get(0)?,
                        path: row.get(1)?,
                        size,
                        is_directory: false,
                        extension: row.get(3)?,
                    },
                    row.get(4)?,
                    row.get(5)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?
    };

    let reconciliation = if scan.complete {
        Some(ScanReconciliation {
            scan_id,
            root: scan.root,
        })
    } else {
        conn.execute_batch("DROP TABLE scan_discovered_paths")?;
        None
    };

    Ok(PendingDatabaseUpdate {
        total_files: scan.total_files,
        files: to_process,
        reconciliation,
    })
}

/// Extracts metadata without holding a SQLite connection.
#[cfg(test)]
pub(crate) async fn extract_pending_metadata(
    pending: PendingDatabaseUpdate,
    covers_dir: &Path,
) -> ExtractedMetadata {
    extract_pending_metadata_with_cancel(pending, covers_dir, None, None).await
}

/// Extracts metadata with bounded parallelism and optional cooperative
/// cancellation. A cancellation request stops awaiting immediately, aborts
/// queued blocking tasks, and prevents completed results from being written.
/// The decoder also checks cancellation before and after each safe boundary.
#[cfg(test)]
pub(crate) async fn extract_pending_metadata_with_cancel(
    pending: PendingDatabaseUpdate,
    covers_dir: &Path,
    cancel_requested: Option<std::sync::Arc<std::sync::atomic::AtomicBool>>,
    progress: Option<&MetadataProgressCallback>,
) -> ExtractedMetadata {
    let (batches, _) = pending.into_metadata_batches();
    let mut combined = ExtractedMetadata {
        metadata: Vec::new(),
        mtimes: Vec::new(),
        existing_song_ids: Vec::new(),
        attempted_files: 0,
        errors: Vec::new(),
    };
    for batch in batches {
        let mut extracted = extract_metadata_batch_with_cancel(
            batch,
            covers_dir,
            cancel_requested.clone(),
            progress,
        )
        .await;
        combined.metadata.append(&mut extracted.metadata);
        combined.mtimes.append(&mut extracted.mtimes);
        combined
            .existing_song_ids
            .append(&mut extracted.existing_song_ids);
        combined.attempted_files = extracted.attempted_files;
        combined.errors.append(&mut extracted.errors);
        if scan_cancelled(cancel_requested.as_deref()) {
            break;
        }
    }
    combined
}

pub(crate) async fn extract_metadata_batch_with_cancel(
    batch: PendingMetadataBatch,
    covers_dir: &Path,
    cancel_requested: Option<std::sync::Arc<std::sync::atomic::AtomicBool>>,
    progress: Option<&MetadataProgressCallback>,
) -> ExtractedMetadata {
    let mut files = batch.files.into_iter();
    let mut processed_files = batch.processed_before;
    if let Some(progress) = progress {
        progress(processed_files);
    }
    let mut tasks: Vec<MetadataTask> = Vec::with_capacity(MAX_METADATA_TASKS);

    let mut schedule_next = |tasks: &mut Vec<MetadataTask>| {
        if scan_cancelled(cancel_requested.as_deref()) {
            return false;
        }
        let Some((file, mtime, existing_song_id)) = files.next() else {
            return false;
        };
        let path = file.path;
        let task_path = path.clone();
        let covers_dir = covers_dir.to_path_buf();
        let cancellation = cancel_requested.clone();
        tasks.push((
            task_path,
            tokio::task::spawn_blocking(move || {
                crate::metadata::extract_metadata_blocking_with_cancel(
                    &path,
                    &covers_dir,
                    cancellation.as_deref(),
                )
                .map_err(|e| e.to_string())
            }),
            mtime,
            existing_song_id,
        ));
        true
    };

    while tasks.len() < MAX_METADATA_TASKS && schedule_next(&mut tasks) {}

    let mut metadata: Vec<AudioMetadata> = Vec::with_capacity(tasks.len());
    let mut mtimes: Vec<i64> = Vec::with_capacity(tasks.len());
    let mut existing_song_ids = Vec::with_capacity(tasks.len());
    let mut errors = Vec::new();
    let mut attempted_files = processed_files + tasks.len();
    while let Some((path, mut handle, mtime, existing_song_id)) = tasks.pop() {
        let task_result = loop {
            tokio::select! {
                result = &mut handle => break Some(result),
                _ = tokio::time::sleep(std::time::Duration::from_millis(25)) => {
                    if scan_cancelled(cancel_requested.as_deref()) {
                        handle.abort();
                        for (_, handle, _, _) in tasks {
                            handle.abort();
                        }
                        errors.push("Metadata extraction cancelled".to_string());
                        return ExtractedMetadata {
                            metadata,
                            mtimes,
                            existing_song_ids,
                            attempted_files,
                            errors,
                        };
                    }
                }
            }
        };
        match task_result.expect("metadata task result is always set") {
            Ok(Ok(metadata_item)) => {
                mtimes.push(mtime);
                existing_song_ids.push(existing_song_id);
                metadata.push(metadata_item);
            }
            Ok(Err(error)) => errors.push(format!("{}: {}", path, error)),
            Err(error) => errors.push(format!("{}: Metadata task panicked: {}", path, error)),
        }
        processed_files += 1;
        if let Some(progress) = progress {
            progress(processed_files);
        }

        if scan_cancelled(cancel_requested.as_deref()) {
            for (_, handle, _, _) in tasks {
                handle.abort();
            }
            errors.push("Metadata extraction cancelled".to_string());
            break;
        }
        if schedule_next(&mut tasks) {
            attempted_files += 1;
        }
    }

    ExtractedMetadata {
        metadata,
        mtimes,
        existing_song_ids,
        attempted_files,
        errors,
    }
}

/// Writes already-extracted metadata to the database.
#[cfg(test)]
pub(crate) fn persist_metadata(
    conn: &Connection,
    metadata: Vec<AudioMetadata>,
    mtimes: Vec<i64>,
) -> DatabaseResult<PersistedMetadata> {
    if metadata.len() != mtimes.len() {
        return Err(DatabaseError::Custom(format!(
            "Metadata and modification-time counts differ ({} metadata records, {} mtimes)",
            metadata.len(),
            mtimes.len()
        )));
    }
    let existing_song_ids: HashMap<String, i64> = {
        let mut statement = conn.prepare("SELECT file_path, song_id FROM songs")?;
        statement
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?
            .collect::<Result<_, _>>()?
    };
    let existing_song_ids = metadata
        .iter()
        .map(|item| existing_song_ids.get(&item.file_path).copied())
        .collect();
    persist_metadata_with_existing_ids(conn, metadata, mtimes, existing_song_ids)
}

pub(crate) fn persist_metadata_with_existing_ids(
    conn: &Connection,
    metadata: Vec<AudioMetadata>,
    mtimes: Vec<i64>,
    existing_song_ids: Vec<Option<i64>>,
) -> DatabaseResult<PersistedMetadata> {
    if metadata.len() != mtimes.len() || metadata.len() != existing_song_ids.len() {
        return Err(DatabaseError::Custom(
            "Metadata batch contains mismatched record counts".to_string(),
        ));
    }
    let metadata: Vec<AudioMetadata> = metadata.into_iter().map(normalize_metadata).collect();
    let transaction = conn.unchecked_transaction()?;
    let all_artist = group_artists(&metadata);
    for artist in all_artist {
        add_artist(&transaction, artist)?;
    }

    let all_releases = group_releases(&metadata);
    for release in &all_releases {
        add_release(&transaction, release)?;
    }

    let mut added_tracks = 0;
    let mut updated_tracks = 0;
    for (i, md) in metadata.into_iter().enumerate() {
        match add_song(&transaction, md, mtimes[i], existing_song_ids[i])? {
            SongWriteResult::Added => added_tracks += 1,
            SongWriteResult::Updated => updated_tracks += 1,
            SongWriteResult::SkippedDuplicate => {}
        }
    }

    for release in &all_releases {
        refresh_release_statistics(&transaction, release)?;
    }

    transaction.commit()?;

    Ok(PersistedMetadata {
        added_tracks,
        updated_tracks,
    })
}

/// Removes tracks beneath a fully scanned folder that were not discovered in
/// that scan, then refreshes or removes their affected release/artist rows.
pub(crate) fn remove_missing_songs_in_folder(
    conn: &Connection,
    reconciliation: ScanReconciliation,
) -> DatabaseResult<u64> {
    let mut root_prefix = reconciliation.root.to_string_lossy().into_owned();
    if !root_prefix.ends_with(std::path::MAIN_SEPARATOR) {
        root_prefix.push(std::path::MAIN_SEPARATOR);
    }
    let transaction = conn.unchecked_transaction()?;
    let removed = transaction.execute(
        "DELETE FROM songs
         WHERE substr(file_path, 1, length(?1)) = ?1
           AND NOT EXISTS (
               SELECT 1
               FROM scan_discovered_paths AS discovered
               WHERE discovered.scan_id = ?2
                 AND discovered.file_path = songs.file_path
           )",
        params![root_prefix, reconciliation.scan_id],
    )?;
    transaction.execute(
        "UPDATE releases
         SET total_tracks = (SELECT COUNT(*) FROM songs WHERE songs.release_id = releases.release_id),
             total_discs = COALESCE((SELECT MAX(disc_number) FROM songs WHERE songs.release_id = releases.release_id), 1),
             duration = COALESCE((SELECT SUM(duration) FROM songs WHERE songs.release_id = releases.release_id), 0),
             updated_at = CURRENT_TIMESTAMP
         WHERE EXISTS (SELECT 1 FROM songs WHERE songs.release_id = releases.release_id)",
        [],
    )?;
    transaction.execute(
        "DELETE FROM releases WHERE NOT EXISTS (SELECT 1 FROM songs WHERE songs.release_id = releases.release_id)",
        [],
    )?;
    transaction.execute(
        "DELETE FROM artists
         WHERE NOT EXISTS (SELECT 1 FROM releases WHERE releases.artist_id = artists.artist_id)
           AND NOT EXISTS (SELECT 1 FROM songs WHERE songs.artist_id = artists.artist_id)
           AND NOT EXISTS (SELECT 1 FROM song_artists WHERE song_artists.artist_id = artists.artist_id)",
        [],
    )?;
    transaction.execute_batch("DROP TABLE scan_discovered_paths")?;
    transaction.commit()?;
    Ok(removed as u64)
}

fn normalize_metadata(mut metadata: AudioMetadata) -> AudioMetadata {
    if metadata.title.as_deref().is_none_or(str::is_empty) {
        metadata.title = Path::new(&metadata.file_path)
            .file_stem()
            .map(|name| name.to_string_lossy().to_string())
            .filter(|name| !name.is_empty())
            .or_else(|| Some("Unknown Title".to_string()));
    }
    if metadata.artist.as_deref().is_none_or(str::is_empty) {
        metadata.artist = Some("Unknown Artist".to_string());
    }
    if metadata.track_artists.is_empty() {
        metadata.track_artists = metadata
            .artist
            .as_deref()
            .map(crate::metadata::split_artist_credit)
            .unwrap_or_else(|| vec!["Unknown Artist".to_string()]);
    }
    if metadata.album_artist.as_deref().is_none_or(str::is_empty) {
        metadata.album_artist = metadata.artist.clone();
    }
    if metadata.release.as_deref().is_none_or(str::is_empty) {
        metadata.release = Some("Unknown Album".to_string());
    }
    metadata
}

/// Kicks off a full library scan for all configured paths.
pub async fn start_library_scan(
    db_pool: std::sync::Arc<r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>>,
    covers_dir: PathBuf,
) -> DatabaseResult<()> {
    let paths = {
        let conn = db_pool.get()?;
        get_library_paths(&conn)?
    };

    for item in paths {
        let pending = {
            let conn = db_pool.get()?;
            prepare_database_update(&conn, item.path)?
        };
        let (batches, reconciliation) = pending.into_metadata_batches();
        for batch in batches {
            let extracted =
                extract_metadata_batch_with_cancel(batch, &covers_dir, None, None).await;
            let conn = db_pool.get()?;
            persist_metadata_with_existing_ids(
                &conn,
                extracted.metadata,
                extracted.mtimes,
                extracted.existing_song_ids,
            )?;
        }
        if let Some(reconciliation) = reconciliation {
            let conn = db_pool.get()?;
            remove_missing_songs_in_folder(&conn, reconciliation)?;
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    use std::sync::{Arc, Mutex};

    fn metadata(artist: &str, release: &str, year: u32) -> AudioMetadata {
        AudioMetadata {
            title: Some("Track".to_string()),
            artist: Some(artist.to_string()),
            track_artists: vec![artist.to_string()],
            album_artist: Some(artist.to_string()),
            release: Some(release.to_string()),
            genre: None,
            year: Some(year),
            track: Some(1),
            disc: Some(1),
            duration: 180.0,
            bitrate: Some(320),
            sample_rate: Some(44_100),
            channels: Some(2),
            cover_path: Some("/covers/cover.jpg".to_string()),
            all_fields: HashMap::new(),
            file_path: "/music/track.mp3".to_string(),
        }
    }

    #[test]
    fn audio_file_filter_only_accepts_enabled_playback_formats() {
        for extension in ["mp3", "WAV", "flac", "Ogg", "oga"] {
            assert!(is_audio_file(extension), "{extension} should be playable");
        }
        for extension in ["m4a", "aac", "aiff", "opus", "wma"] {
            assert!(
                !is_audio_file(extension),
                "{extension} is not enabled in the playback backend"
            );
        }
    }

    fn wav_fixture() -> Vec<u8> {
        let sample_rate = 8_000u32;
        let samples = sample_rate as usize;
        let data_len = (samples * 2) as u32; // mono, 16-bit, one second
        let mut wav = Vec::with_capacity(44 + data_len as usize);
        wav.extend_from_slice(b"RIFF");
        wav.extend_from_slice(&(36 + data_len).to_le_bytes());
        wav.extend_from_slice(b"WAVEfmt ");
        wav.extend_from_slice(&16u32.to_le_bytes());
        wav.extend_from_slice(&1u16.to_le_bytes());
        wav.extend_from_slice(&1u16.to_le_bytes());
        wav.extend_from_slice(&sample_rate.to_le_bytes());
        wav.extend_from_slice(&(sample_rate * 2).to_le_bytes());
        wav.extend_from_slice(&2u16.to_le_bytes());
        wav.extend_from_slice(&16u16.to_le_bytes());
        wav.extend_from_slice(b"data");
        wav.extend_from_slice(&data_len.to_le_bytes());
        wav.resize(44 + data_len as usize, 0);
        wav
    }

    #[test]
    fn settings_and_last_session_round_trip() {
        let conn = Connection::open_in_memory().unwrap();
        create_tables(&conn).unwrap();
        initiate_settings(&conn).unwrap();
        initiate_last_session(&conn).unwrap();
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
            "INSERT INTO songs (
                song_id, title, artist_id, artist_name, release_id, release_title,
                track_number, disc_number, duration, file_path
             ) VALUES (42, 'Track', 1, 'Artist', 1, 'Album', 1, 1, 180, '/music/track.mp3')",
            [],
        )
        .unwrap();

        let settings = get_settings(&conn).unwrap();
        assert!(settings.cross_fade);
        assert_eq!(settings.cross_fade_duration, 5);
        let updated_settings = Settings {
            settings_id: 1,
            cross_fade: false,
            cross_fade_duration: 8,
            normalize_volume: false,
            explicit_content: false,
            autoplay: false,
            preferred_audio_quality: 256,
            preferred_audio_source: "local".to_string(),
            download_path: "/music/downloads".to_string(),
            open_on_startup: true,
            minimize_on_close: true,
            onboarding: false,
        };
        save_settings(&conn, &updated_settings).unwrap();
        let persisted_settings = get_settings(&conn).unwrap();
        assert!(!persisted_settings.cross_fade);
        assert_eq!(persisted_settings.cross_fade_duration, 8);
        assert_eq!(persisted_settings.preferred_audio_source, "local");
        assert_eq!(persisted_settings.download_path, "/music/downloads");
        assert!(
            conn.execute("UPDATE settings SET cross_fade_duration = 61", [])
                .is_err()
        );
        assert!(
            conn.execute("UPDATE settings SET preferred_audio_quality = 0", [])
                .is_err()
        );
        assert_eq!(get_last_session(&conn).unwrap().volume, 0.5);

        let session = LastSession {
            current_song_id: Some(42),
            progress_seconds: 12.5,
            volume: 0.75,
            shuffle_enabled: true,
            repeat_mode: "all".to_string(),
            queue_snapshot: "[42,43]".to_string(),
            queue_position: 0,
            source_context: "library".to_string(),
            updated_at: String::new(),
        };
        save_last_session(&conn, &session).unwrap();

        let restored = get_last_session(&conn).unwrap();
        assert_eq!(restored.current_song_id, Some(42));
        assert_eq!(restored.progress_seconds, 12.5);
        assert_eq!(restored.volume, 0.75);
        assert!(restored.shuffle_enabled);
        assert_eq!(restored.repeat_mode, "all");
        assert_eq!(restored.queue_snapshot, "[42,43]");

        update_session_progress(&conn, 24.0).unwrap();
        update_session_volume(&conn, 0.25).unwrap();
        let partially_updated = get_last_session(&conn).unwrap();
        assert_eq!(partially_updated.progress_seconds, 24.0);
        assert_eq!(partially_updated.volume, 0.25);
        assert_eq!(partially_updated.queue_snapshot, "[42,43]");
        assert_eq!(partially_updated.current_song_id, Some(42));
    }

    #[test]
    fn schema_foreign_keys_are_valid() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("PRAGMA foreign_keys = ON").unwrap();
        create_tables(&conn).unwrap();

        let violations = conn
            .prepare("PRAGMA foreign_key_check")
            .unwrap()
            .query_map([], |_| Ok(()))
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        assert!(violations.is_empty());
    }

    #[test]
    fn metadata_grouping_deduplicates_artists_and_releases() {
        let records = vec![
            metadata("Artist A", "Album", 2024),
            metadata("Artist A", "Album", 2024),
            metadata("Artist B", "Other Album", 2025),
        ];

        let mut artists = group_artists(&records);
        artists.sort();
        assert_eq!(artists, vec!["Artist A", "Artist B"]);

        let mut releases = group_releases(&records);
        releases.sort_by(|left, right| left.title.cmp(&right.title));
        assert_eq!(releases.len(), 2);
        assert_eq!(releases[0].title, "Album");
        assert_eq!(releases[0].tracks, 2);
        assert_eq!(releases[1].title, "Other Album");
        assert_eq!(releases[1].tracks, 1);
    }

    #[test]
    fn metadata_persistence_reports_added_and_updated_tracks() {
        let conn = Connection::open_in_memory().unwrap();
        create_tables(&conn).unwrap();
        let track = metadata("Artist", "Album", 2024);

        assert!(persist_metadata(&conn, vec![track.clone()], vec![]).is_err());
        assert!(get_all_tracks(&conn).unwrap().is_empty());

        let first = persist_metadata(&conn, vec![track.clone()], vec![1]).unwrap();
        assert_eq!(first.added_tracks, 1);
        assert_eq!(first.updated_tracks, 0);
        // `duration` is persisted with INTEGER affinity; listing tracks must
        // read that representation without requiring SQLite to coerce it to REAL.
        assert_eq!(get_all_tracks(&conn).unwrap()[0].duration, 180);

        let second = persist_metadata(&conn, vec![track], vec![2]).unwrap();
        assert_eq!(second.added_tracks, 0);
        assert_eq!(second.updated_tracks, 1);
        let (track_number, disc_number, duration): (u8, u8, u64) = conn
            .query_row(
                "SELECT track_number, disc_number, duration FROM songs WHERE file_path = '/music/track.mp3'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .unwrap();
        assert_eq!((track_number, disc_number, duration), (1, 1, 180));

        let mut second_track = metadata("Artist", "Album", 2024);
        second_track.title = Some("Second Track".to_string());
        second_track.file_path = "/music/second-track.mp3".to_string();
        second_track.disc = Some(2);
        second_track.duration = 120.5;
        let third = persist_metadata(&conn, vec![second_track], vec![3]).unwrap();
        assert_eq!(third.added_tracks, 1);
        assert_eq!(
            get_all_tracks(&conn)
                .unwrap()
                .into_iter()
                .find(|track| track.title == "Second Track")
                .unwrap()
                .duration,
            120
        );
        let release = get_release_by_id(&conn, "1").unwrap();
        assert_eq!(release.total_tracks, 2);
        assert_eq!(release.total_discs, 2);
        assert_eq!(release.duration, 300);
        assert!(set_release_hidden(&conn, 1, true).unwrap());
        assert!(set_release_suggest_less(&conn, 1, true).unwrap());
        let release = get_release_by_id(&conn, "1").unwrap();
        assert!(release.is_hidden);
        assert!(release.suggest_less);

        reset_scan_discovery_table(&conn).unwrap();
        conn.execute(
            "INSERT INTO scan_discovered_paths
                (scan_id, file_path, name, size, extension, file_mtime)
             VALUES ('test-scan', '/music/track.mp3', 'track.mp3', 1, 'mp3', 1)",
            [],
        )
        .unwrap();
        assert_eq!(
            remove_missing_songs_in_folder(
                &conn,
                ScanReconciliation {
                    scan_id: "test-scan".to_string(),
                    root: PathBuf::from("/music"),
                },
            )
            .unwrap(),
            1
        );
        assert_eq!(
            conn.query_row(
                "SELECT COUNT(*) FROM sqlite_master
                 WHERE type = 'table' AND name = 'scan_discovered_paths'",
                [],
                |row| row.get::<_, u64>(0),
            )
            .unwrap(),
            0
        );
        assert_eq!(get_all_tracks(&conn).unwrap().len(), 1);
        let release = get_release_by_id(&conn, "1").unwrap();
        assert_eq!(release.total_tracks, 1);
        assert_eq!(release.duration, 180);
        assert!(set_track_rating(&conn, 1, Some(6)).is_err());
        assert!(set_release_rating(&conn, 1, Some(6)).is_err());

        assert!(record_completed_playback(&conn, 1, 180).unwrap());
        assert!(!record_completed_playback(&conn, 999, 180).unwrap());
        let mut first_tracks = get_song_by_id(&conn, "1").unwrap();
        let first_track = first_tracks.remove(0);
        assert_eq!(first_track.play_count, 1);
        assert!(first_track.last_played.is_some());
        let history = get_play_history(&conn).unwrap();
        assert_eq!(history.len(), 1);
        assert_eq!(history[0].song_id, 1);
        assert_eq!(history[0].duration, 180);
        assert!(remove_song_from_history(&conn, history[0].history_id).unwrap());
        assert!(!remove_song_from_history(&conn, history[0].history_id).unwrap());
        assert!(record_completed_playback(&conn, 1, 180).unwrap());
        assert!(record_completed_playback(&conn, 1, 180).unwrap());
        assert_eq!(clear_play_history(&conn).unwrap(), 2);
        assert!(get_play_history(&conn).unwrap().is_empty());
    }

    #[test]
    fn library_paths_can_be_added_listed_and_removed() {
        let conn = Connection::open_in_memory().unwrap();
        create_tables(&conn).unwrap();

        add_library_path(&conn, "/music/a".to_string()).unwrap();
        add_library_path(&conn, "/music/a".to_string()).unwrap();
        add_library_path(&conn, "/music/b".to_string()).unwrap();

        let mut paths = get_library_paths(&conn)
            .unwrap()
            .into_iter()
            .map(|path| path.path)
            .collect::<Vec<_>>();
        paths.sort();
        assert_eq!(paths, vec!["/music/a", "/music/b"]);

        assert!(remove_library_path(&conn, "/music/a").unwrap());
        assert!(!remove_library_path(&conn, "/music/a").unwrap());
        assert_eq!(get_library_paths(&conn).unwrap().len(), 1);
    }

    #[test]
    fn search_matches_every_library_category_case_insensitively() {
        let conn = Connection::open_in_memory().unwrap();
        create_tables(&conn).unwrap();
        conn.execute(
            "INSERT INTO artists (artist_id, name) VALUES (1, 'Rock Artist')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO releases (release_id, title, artist_id, artist_name, release_date)
             VALUES (1, 'Rock Album', 1, 'Rock Artist', 2024)",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO songs (
                song_id, title, artist_id, artist_name, release_id, release_title,
                track_number, disc_number, duration, file_path
             ) VALUES (1, 'Rock Track', 1, 'Rock Artist', 1, 'Rock Album', 1, 1, 180, '/music/rock.mp3')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO playlists (id, name, cover, description)
             VALUES (1, 'Rock Mix', X'010203', 'Rock favorites')",
            [],
        )
        .unwrap();

        let results = search_library(&conn, "rOcK").unwrap();
        assert_eq!(results.tracks.len(), 1);
        assert_eq!(results.releases.len(), 1);
        assert_eq!(results.artists.len(), 1);
        assert_eq!(results.playlists.len(), 1);
        assert!(results.playlists[0].cover.is_none());

        let short_query = search_library(&conn, "Ro").unwrap();
        assert_eq!(short_query.tracks.len(), 1);
        assert_eq!(short_query.releases.len(), 1);
        assert_eq!(short_query.artists.len(), 1);
        assert_eq!(short_query.playlists.len(), 1);
        assert!(get_all_tracks(&conn).unwrap()[0].artwork.is_empty());
        assert!(get_song_by_id(&conn, "1").unwrap()[0].artwork.is_empty());
        assert!(
            get_songs_by_release_id(&conn, "1").unwrap()[0]
                .artwork
                .is_empty()
        );
        assert!(get_all_releases(&conn).unwrap()[0].artwork.is_empty());
        assert_eq!(get_release_by_id(&conn, "1").unwrap().release_date, "2024");
    }

    #[test]
    fn search_is_bounded_pageable_and_tracks_content_changes() {
        let conn = Connection::open_in_memory().unwrap();
        create_tables(&conn).unwrap();
        for artist_id in 1..=105 {
            conn.execute(
                "INSERT INTO artists (artist_id, name) VALUES (?1, ?2)",
                params![artist_id, format!("Needle Artist {artist_id:03}")],
            )
            .unwrap();
        }

        let first_page = search_library_page(&conn, "Needle", 1_000, 0).unwrap();
        assert_eq!(first_page.artists.len(), MAX_SEARCH_RESULT_LIMIT);
        let second_page = search_library_page(&conn, "Needle", 100, 100).unwrap();
        assert_eq!(second_page.artists.len(), 5);

        conn.execute(
            "UPDATE artists SET name = 'Renamed Performer' WHERE artist_id = 1",
            [],
        )
        .unwrap();
        assert_eq!(search_library(&conn, "Renamed").unwrap().artists.len(), 1);
        assert_eq!(
            search_library_page(&conn, "Needle", 100, 100)
                .unwrap()
                .artists
                .len(),
            4
        );

        conn.execute("DELETE FROM artists WHERE artist_id = 1", [])
            .unwrap();
        assert!(search_library(&conn, "Renamed").unwrap().artists.is_empty());
    }

    #[test]
    fn search_index_backfills_an_existing_library() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute(
            "CREATE TABLE artists (artist_id INTEGER PRIMARY KEY, name TEXT)",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO artists (artist_id, name) VALUES (1, 'Migrated Artist')",
            [],
        )
        .unwrap();

        create_tables(&conn).unwrap();

        let results = search_library(&conn, "grated Art").unwrap();
        assert_eq!(results.artists.len(), 1);
        assert_eq!(results.artists[0].artist_name, "Migrated Artist");
    }

    #[test]
    fn library_pages_are_bounded_and_stably_ordered() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("PRAGMA foreign_keys = ON").unwrap();
        create_tables(&conn).unwrap();
        conn.execute(
            "INSERT INTO artists (artist_id, name) VALUES (1, 'Artist')",
            [],
        )
        .unwrap();
        for id in 1..=3 {
            conn.execute(
                "INSERT INTO releases (release_id, title, artist_id, artist_name)
                 VALUES (?1, ?2, 1, 'Artist')",
                params![id, format!("Album {id}")],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO songs (
                    song_id, title, artist_id, artist_name, release_id, release_title,
                    track_number, disc_number, duration, file_path
                 ) VALUES (?1, ?2, 1, 'Artist', ?1, ?3, 1, 1, 180, ?4)",
                params![
                    id,
                    format!("Track {id}"),
                    format!("Album {id}"),
                    format!("/music/{id}.mp3")
                ],
            )
            .unwrap();
            add_song_to_history(&conn, id, 180).unwrap();
        }

        assert_eq!(
            get_tracks_page(&conn, 2, 0)
                .unwrap()
                .into_iter()
                .map(|track| track.song_id)
                .collect::<Vec<_>>(),
            vec![1, 2]
        );
        assert_eq!(get_tracks_page(&conn, 2, 2).unwrap()[0].song_id, 3);
        assert_eq!(
            get_releases_page(&conn, 2, 0)
                .unwrap()
                .into_iter()
                .map(|release| release.release_id)
                .collect::<Vec<_>>(),
            vec![1, 2]
        );
        assert_eq!(get_releases_page(&conn, 2, 2).unwrap()[0].release_id, 3);
        assert_eq!(
            get_play_history_page(&conn, 2, 0)
                .unwrap()
                .into_iter()
                .map(|history| history.song_id)
                .collect::<Vec<_>>(),
            vec![3, 2]
        );
        assert_eq!(get_play_history_page(&conn, 2, 2).unwrap()[0].song_id, 1);
    }

    #[test]
    fn playlists_support_crud_and_ordered_tracks() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("PRAGMA foreign_keys = ON").unwrap();
        create_tables(&conn).unwrap();
        let cover_base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";
        let cover_bytes = STANDARD.decode(cover_base64).unwrap();

        let playlist = create_playlist(
            &conn,
            "Road Trip".to_string(),
            format!("data:image/png;base64,{cover_base64}"),
            "Initial description".to_string(),
        )
        .unwrap();
        let empty_playlist =
            create_playlist(&conn, "Empty".to_string(), String::new(), String::new()).unwrap();
        assert_eq!(playlist.cover.as_deref(), Some(cover_bytes.as_slice()));
        assert!(set_playlist_favorite(&conn, playlist.id, true).unwrap());
        assert!(set_playlist_suggest_less(&conn, playlist.id, true).unwrap());
        let playlist = get_playlist_by_id(&conn, playlist.id).unwrap();
        assert!(playlist.is_favorite);
        assert!(playlist.suggest_less);
        assert!(
            update_playlist(
                &conn,
                playlist.id,
                "Updated Road Trip".to_string(),
                "Updated description".to_string(),
                format!("data:image/png;base64,{cover_base64}"),
            )
            .unwrap()
        );
        assert_eq!(
            get_playlist_by_id(&conn, playlist.id).unwrap().name,
            "Updated Road Trip"
        );
        assert_eq!(
            get_playlist_by_id(&conn, playlist.id)
                .unwrap()
                .cover
                .as_deref(),
            Some(cover_bytes.as_slice())
        );

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
            "INSERT INTO songs (
                song_id, title, artist_id, artist_name, release_id, release_title,
                track_number, disc_number, duration, file_path
             ) VALUES (1, 'Track', 1, 'Artist', 1, 'Album', 1, 1, 180, '/music/track.mp3')",
            [],
        )
        .unwrap();
        let release = get_release_by_id(&conn, "1").unwrap();
        assert!(release.release_date.is_empty());
        assert!(release.artwork.is_empty());
        assert_eq!(release.duration, 0);

        add_track_to_playlist_songs(&conn, playlist.id, 1, 0).unwrap();
        assert_eq!(get_playlist_track_count(&conn, playlist.id).unwrap(), 1);
        assert_eq!(get_playlist_tracks(&conn, playlist.id).unwrap().len(), 1);
        let playlist_summaries = get_all_playlists_with_track_counts(&conn).unwrap();
        assert_eq!(playlist_summaries.len(), 2);
        assert_eq!(playlist_summaries[0].playlist.id, playlist.id);
        assert_eq!(playlist_summaries[0].track_count, 1);
        assert_eq!(playlist_summaries[1].playlist.id, empty_playlist.id);
        assert_eq!(playlist_summaries[1].track_count, 0);
        remove_track_from_playlist(&conn, playlist.id, 1, 0).unwrap();
        assert!(get_playlist_tracks(&conn, playlist.id).unwrap().is_empty());

        assert!(delete_playlist(&conn, playlist.id).unwrap());
        assert!(get_playlist_by_id(&conn, playlist.id).is_err());
    }

    #[test]
    fn playlist_artwork_rejects_invalid_and_excessive_inputs() {
        assert!(decode_playlist_cover("AQIDBA==").is_err());

        let maximum_encoded_length = crate::metadata::MAX_ARTWORK_BYTES.div_ceil(3) * 4;
        let excessive = "A".repeat(maximum_encoded_length + 1);
        let error = decode_playlist_cover(&excessive).unwrap_err().to_string();
        assert!(error.contains("exceeds"));
    }

    #[test]
    fn incremental_scan_skips_an_unchanged_file() {
        let unique = format!(
            "durvald-scan-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        );
        let directory = std::env::temp_dir().join(unique);
        std::fs::create_dir_all(&directory).unwrap();
        let audio_file = directory.join("track.mp3");
        std::fs::write(&audio_file, []).unwrap();

        let conn = Connection::open_in_memory().unwrap();
        create_tables(&conn).unwrap();
        let first =
            prepare_database_update(&conn, directory.to_string_lossy().to_string()).unwrap();
        assert_eq!(first.total_files, 1);
        assert_eq!(first.files.len(), 1);

        let path = std::fs::canonicalize(&audio_file)
            .unwrap()
            .to_string_lossy()
            .to_string();
        let mtime = file_mtime(&path).unwrap();
        conn.execute(
            "INSERT INTO songs (
                title, artist_id, artist_name, release_id, release_title,
                track_number, disc_number, duration, file_path, file_mtime, metadata_version
             ) VALUES ('Track', 1, 'Artist', 1, 'Album', 1, 1, 180, ?1, ?2, ?3)",
            params![path, mtime, CURRENT_METADATA_VERSION],
        )
        .unwrap();

        let second =
            prepare_database_update(&conn, directory.to_string_lossy().to_string()).unwrap();
        assert_eq!(second.total_files, 1);
        assert!(second.files.is_empty());

        std::fs::remove_dir_all(directory).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn scan_folder_skips_file_and_directory_symlinks() {
        use std::os::unix::fs::symlink;

        let directory = std::env::temp_dir().join(format!(
            "durvald-symlink-scan-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(directory.join("nested")).unwrap();
        let track = directory.join("nested/track.mp3");
        std::fs::write(&track, []).unwrap();
        symlink(&track, directory.join("duplicate.mp3")).unwrap();
        symlink(&directory, directory.join("nested/loop")).unwrap();

        let files = scan_folder(directory.to_string_lossy().to_string()).unwrap();
        assert_eq!(files.len(), 1);
        assert_eq!(
            files[0].path,
            std::fs::canonicalize(track).unwrap().to_string_lossy()
        );

        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn scan_folder_stops_when_cancellation_is_requested() {
        let directory = std::env::temp_dir().join(format!(
            "durvald-cancelled-scan-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&directory).unwrap();
        std::fs::write(directory.join("track.mp3"), []).unwrap();
        let cancelled = std::sync::atomic::AtomicBool::new(true);

        let scan =
            walk_audio_files(&directory.to_string_lossy(), Some(&cancelled), |_| Ok(())).unwrap();
        assert_eq!(scan.total_files, 0);
        assert!(!scan.complete);

        std::fs::remove_dir_all(directory).unwrap();
    }

    #[tokio::test]
    async fn metadata_extraction_reports_bad_files_without_aborting() {
        let directory = std::env::temp_dir().join(format!(
            "durvald-metadata-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&directory).unwrap();
        std::fs::write(directory.join("invalid.mp3"), []).unwrap();

        let conn = Connection::open_in_memory().unwrap();
        create_tables(&conn).unwrap();
        let pending =
            prepare_database_update(&conn, directory.to_string_lossy().to_string()).unwrap();
        let extracted = extract_pending_metadata(pending, &directory).await;

        assert!(extracted.metadata.is_empty());
        assert_eq!(extracted.errors.len(), 1);
        assert!(extracted.errors[0].contains("invalid.mp3"));

        std::fs::remove_dir_all(directory).unwrap();
    }

    #[tokio::test]
    async fn metadata_extraction_reads_a_valid_wav_fixture() {
        let directory = std::env::temp_dir().join(format!(
            "durvald-wav-metadata-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&directory).unwrap();
        let audio_file = directory.join("tone.wav");
        std::fs::write(&audio_file, wav_fixture()).unwrap();

        let conn = Connection::open_in_memory().unwrap();
        create_tables(&conn).unwrap();
        let pending =
            prepare_database_update(&conn, directory.to_string_lossy().to_string()).unwrap();
        let observed_progress = Arc::new(Mutex::new(Vec::new()));
        let callback_progress = observed_progress.clone();
        let progress = move |processed_files| {
            callback_progress.lock().unwrap().push(processed_files);
        };
        let extracted =
            extract_pending_metadata_with_cancel(pending, &directory, None, Some(&progress)).await;

        assert!(extracted.errors.is_empty());
        assert_eq!(extracted.metadata.len(), 1);
        assert_eq!(*observed_progress.lock().unwrap(), vec![0, 1]);
        assert_eq!(
            extracted.metadata[0].file_path,
            std::fs::canonicalize(&audio_file)
                .unwrap()
                .to_string_lossy()
        );
        assert!((extracted.metadata[0].duration - 1.0).abs() < 0.01);
        let written = persist_metadata(&conn, extracted.metadata, extracted.mtimes).unwrap();
        assert_eq!(written.added_tracks, 1);
        let mut tracks = get_all_tracks(&conn).unwrap();
        let track = tracks.remove(0);
        assert_eq!(track.title, "tone");
        assert_eq!(track.artist_name, "Unknown Artist");
        assert_eq!(track.release_title, "Unknown Album");

        std::fs::remove_dir_all(directory).unwrap();
    }
}
