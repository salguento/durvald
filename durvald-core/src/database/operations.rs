use crate::database::models::*;
use crate::metadata::AudioMetadata;
use base64::engine::general_purpose::STANDARD;
use base64::Engine as _;
use chrono::Utc;
use image;
use md5::{Digest, Md5};
use rusqlite::{params, Connection, OptionalExtension, Result as RusqliteResult};
use std::collections::HashMap;
use std::fs;
use std::io::Cursor;
use std::path::{Path, PathBuf};
use thiserror::Error;

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
            cross_fade_duration INTEGER DEFAULT 5,
            normalize_volume BOOL DEFAULT TRUE,
            explicit_content BOOL DEFAULT TRUE,
            autoplay BOOL DEFAULT TRUE,
            preferred_audio_quality INTEGER DEFAULT 320,
            preferrend_audio_source TEXT DEFAULT '',
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
            rating INTEGER DEFAULT NULL,
            lyrics TEXT,
            is_favorite BOOL DEFAULT FALSE,
            is_hidden BOOL DEFAULT FALSE,
            suggest_less BOOL DEFAULT FALSE,
            file_path TEXT NOT NULL,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            file_mtime INTEGER
        )",
        (),
    )?;

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
            rating INTEGER DEFAULT NULL,
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
            FOREIGN KEY (label_id) REFERENCES labels(label_id) ON DELETE CASCADE
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
            volume          REAL NOT NULL DEFAULT 50.0,
            shuffle_enabled INTEGER NOT NULL DEFAULT 0,
            repeat_mode     TEXT NOT NULL DEFAULT 'none',
            queue_snapshot  TEXT NOT NULL DEFAULT '[]',
            queue_position  INTEGER NOT NULL DEFAULT 0,
            source_context  TEXT NOT NULL DEFAULT '',
            updated_at      DATETIME DEFAULT CURRENT_TIMESTAMP
        )",
        (),
    )?;

    // Databases created before the incremental-scan column existed need the
    // column added; no-op when it is already present.
    ensure_song_mtime_column(conn)?;

    // Indexes speed up the common queries on large libraries (idempotent).
    ensure_indexes(conn)?;

    Ok(())
}

/// Adds the `file_mtime` column to `songs` on databases that predate it.
/// No-op when the column already exists.
fn ensure_song_mtime_column(conn: &Connection) -> DatabaseResult<()> {
    let has: bool = conn
        .query_row(
            "SELECT COUNT(*) FROM pragma_table_info('songs') WHERE name = 'file_mtime'",
            [],
            |row| Ok(row.get::<_, i64>(0)? > 0),
        )?;

    if !has {
        conn.execute("ALTER TABLE songs ADD COLUMN file_mtime INTEGER", [])?;
    }

    Ok(())
}

/// Creates the indexes that back the common library queries. Idempotent
/// (IF NOT EXISTS), so it safely applies to existing databases on next boot.
fn ensure_indexes(conn: &Connection) -> DatabaseResult<()> {
    const INDEXES: &[&str] = &[
        "CREATE INDEX IF NOT EXISTS idx_songs_release ON songs(release_id)",
        "CREATE INDEX IF NOT EXISTS idx_songs_artist ON songs(artist_id)",
        "CREATE INDEX IF NOT EXISTS idx_songs_title ON songs(title)",
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

// ===== Settings =====

pub fn initiate_settings(conn: &Connection) -> DatabaseResult<()> {
    let count: i64 = conn.query_row("SELECT COUNT(*) FROM settings", [], |row| row.get(0))?;
    if count == 0 {
        conn.execute("INSERT INTO settings DEFAULT VALUES", [])?;
    }
    Ok(())
}

pub fn get_settings(conn: &Connection) -> DatabaseResult<Settings> {
    let mut stmt = conn.prepare("SELECT * FROM settings")?;
    let mut rows = stmt.query_map([], |row| {
        Ok(Settings {
            settings_id: row.get(0)?,
            cross_fade: row.get(1)?,
            cross_fade_duration: row.get(2)?,
            normalize_volume: row.get(3)?,
            explicit_content: row.get(4)?,
            autoplay: row.get(5)?,
            preferred_audio_quality: row.get(6)?,
            preferrend_audio_source: row.get(7)?,
            download_path: row.get(8)?,
            open_on_startup: row.get(9)?,
            minimize_on_close: row.get(10)?,
            onboarding: row.get(11)?,
        })
    })?;

    match rows.next() {
        Some(Ok(settings)) => Ok(settings),
        Some(Err(e)) => Err(DatabaseError::Custom(format!("Failed to parse settings: {}", e))),
        None => Err(DatabaseError::Custom("No settings found in database".to_string())),
    }
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
    let exists: bool = conn
        .query_row(
            "SELECT COUNT(*) FROM artists WHERE name = ?1",
            params![&artist],
            |row| Ok(row.get::<_, i64>(0)? > 0),
        )?;

    if !exists {
        conn.execute("INSERT INTO artists (name) VALUES (?1)", params![&artist])?;
    }
    Ok(())
}

pub fn add_release(conn: &Connection, release: ReleaseGroup) -> DatabaseResult<()> {
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

    let exists: bool = conn
        .query_row(
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
                &release.cover_image_base64
            ],
        )?;
    }
    Ok(())
}

fn lookup_artist_id(conn: &Connection, song: &AudioMetadata) -> DatabaseResult<i64> {
    let id: Option<i64> = conn
        .query_row(
            "SELECT artist_id FROM artists WHERE name = ?1",
            params![&song.artist],
            |row| row.get(0),
        )
        .optional()?;
    id.ok_or_else(|| DatabaseError::Custom(format!("Artist '{:?}' not found", song.artist)))
}

fn lookup_release_id(
    conn: &Connection,
    song: &AudioMetadata,
    artist_id: i64,
) -> DatabaseResult<i64> {
    let id: Option<i64> = conn
        .query_row(
            "SELECT release_id FROM releases WHERE title = ?1 AND artist_id = ?2",
            params![&song.release, artist_id],
            |row| row.get(0),
        )
        .optional()?;
    id.ok_or_else(|| DatabaseError::Custom(format!("Release '{:?}' not found", song.release)))
}

pub fn add_song(conn: &Connection, song: AudioMetadata, mtime: i64) -> DatabaseResult<()> {
    let artwork = song.cover_path.as_deref().or(song.cover_image_base64.as_deref());

    let existing_id: Option<i64> = conn
        .query_row(
            "SELECT song_id FROM songs WHERE file_path = ?1",
            params![&song.file_path],
            |row| row.get(0),
        )
        .optional()?;

    if let Some(song_id) = existing_id {
        let artist_id = lookup_artist_id(conn, &song)?;
        let release_id = lookup_release_id(conn, &song, artist_id)?;
        conn.execute(
            "UPDATE songs SET title=?1, artwork=?2, artist_id=?3, artist_name=?4, release_id=?5, release_title=?6, track_number=?7, disc_number=?8, duration=?9, file_mtime=?10, updated_at=CURRENT_TIMESTAMP WHERE song_id=?11",
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
                mtime,
                song_id,
            ],
        )?;
        return Ok(());
    }

    let artist_id = lookup_artist_id(conn, &song)?;
    let release_id = lookup_release_id(conn, &song, artist_id)?;

    let exists: bool = conn
        .query_row(
            "SELECT COUNT(*) FROM songs WHERE title = ?1 AND artist_id = ?2 AND release_id = ?3",
            params![&song.title, artist_id, release_id],
            |row| Ok(row.get::<_, i64>(0)? > 0),
        )?;

    if !exists {
        conn.execute(
            "INSERT INTO songs (title, artwork, artist_id, artist_name, release_id, release_title, duration, track_number, disc_number, file_path, file_mtime) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
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
            ],
        )?;
    }

    Ok(())
}

pub fn group_artists(array: &Vec<AudioMetadata>) -> Vec<String> {
    let artists: std::collections::HashSet<String> = array
        .iter()
        .filter_map(|item| item.artist.as_ref().cloned())
        .collect();

    artists.into_iter().collect()
}

pub fn group_releases(array: &Vec<AudioMetadata>) -> Vec<ReleaseGroup> {
    let mut release_map: HashMap<String, ReleaseGroup> = HashMap::new();

    for item in array {
        let artwork = item.cover_path.as_ref().or(item.cover_image_base64.as_ref());
        if let (Some(title), Some(artist), Some(artwork), Some(year)) = (
            &item.release,
            &item.artist,
            artwork,
            &item.year,
        ) {
            let key = format!("{}|{}|{}", title, artist, year);

            let release_group = release_map.entry(key).or_insert_with(|| ReleaseGroup {
                title: title.clone(),
                artist: artist.clone(),
                cover_image_base64: artwork.clone(),
                date: year.clone(),
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
    }

    release_map.into_values().collect()
}

// ===== Query Operations =====

pub fn get_releases(conn: &Connection) -> DatabaseResult<Vec<Releases>> {
    let mut stmt = conn.prepare("SELECT * FROM releases")?;
    let releases_iter = stmt.query_map([], |row| {
        Ok(Releases {
            release_id: row.get(0)?,
            title: row.get(1)?,
            artist_id: row.get(2)?,
            artist_name: row.get(3)?,
            release_date: row.get::<_, i64>(4)?.to_string(),
            total_tracks: row.get(5)?,
            total_discs: row.get(6)?,
            duration: row.get(7)?,
            artwork: row.get(8)?,
            created_at: row.get::<_, String>(9)?.to_string(),
            updated_at: row.get::<_, String>(10)?.to_string(),
            is_favorite: row.get(11)?,
            is_hidden: row.get(12)?,
            suggest_less: row.get(13)?,
            rating: row.get(14)?,
        })
    })?;

    let releases: Result<Vec<Releases>, _> = releases_iter.collect();
    Ok(releases?)
}

pub fn get_release_by_id(conn: &Connection, release_id: &str) -> DatabaseResult<Releases> {
    conn.query_row(
        "SELECT * FROM releases WHERE release_id = ?1",
        [release_id],
        |row| {
            Ok(Releases {
                release_id: row.get(0)?,
                title: row.get(1)?,
                artist_id: row.get(2)?,
                artist_name: row.get(3)?,
                release_date: row.get::<_, i64>(4)?.to_string(),
                total_tracks: row.get(5)?,
                total_discs: row.get(6)?,
                duration: row.get(7)?,
                artwork: row.get(8)?,
                created_at: row.get::<_, String>(9)?.to_string(),
                updated_at: row.get::<_, String>(10)?.to_string(),
                is_favorite: row.get(11)?,
                is_hidden: row.get(12)?,
                suggest_less: row.get(13)?,
                rating: row.get(14)?,
            })
        },
    )
    .map_err(DatabaseError::from)
}

pub fn get_songs_by_release_id(conn: &Connection, release_id: &str) -> DatabaseResult<Vec<SongItem>> {
    let mut stmt = conn.prepare("SELECT * FROM songs WHERE release_id = ?1")?;
    let song_iter = stmt.query_map([release_id], |row| {
        Ok(SongItem {
            song_id: row.get(0)?,
            title: row.get(1)?,
            artwork: row.get(2)?,
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
            created_at: row.get::<_, String>(20)?.to_string(),
            updated_at: row.get::<_, String>(21)?.to_string(),
        })
    })?;

    let mut songs = Vec::new();
    for song in song_iter {
        songs.push(song?);
    }
    Ok(songs)
}

pub fn get_song_by_id(conn: &Connection, song_id: &str) -> DatabaseResult<Vec<SongItem>> {
    let mut stmt = conn.prepare("SELECT * FROM songs WHERE song_id = ?1")?;
    let song_iter = stmt.query_map([song_id], |row| {
        Ok(SongItem {
            song_id: row.get(0)?,
            title: row.get(1)?,
            artwork: row.get(2)?,
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
            created_at: row.get::<_, String>(20)?.to_string(),
            updated_at: row.get::<_, String>(21)?.to_string(),
        })
    })?;

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

pub fn get_play_history(conn: &Connection) -> DatabaseResult<Vec<PlayHistory>> {
    let mut stmt = conn.prepare("SELECT * FROM play_history")?;
    let history = stmt.query_map([], |row| {
        Ok(PlayHistory {
            history_id: row.get(0)?,
            song_id: row.get(1)?,
            played_at: row.get(2)?,
            duration: row.get(3)?,
        })
    })?;

    let mut results = Vec::new();
    for item in history {
        results.push(item?);
    }
    Ok(results)
}

pub fn remove_song_from_history(conn: &Connection, history_id: u64) -> DatabaseResult<()> {
    conn.execute(
        "DELETE FROM play_history WHERE history_id = ?1 ",
        params![history_id],
    )?;
    Ok(())
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

pub fn get_all_tracks(conn: &Connection) -> DatabaseResult<Vec<SongItem>> {
    let mut tracks = conn.prepare("SELECT * FROM songs")?;
    let tracks_map = tracks.query_map([], |row| {
        Ok(SongItem {
            song_id: row.get(0)?,
            title: row.get(1)?,
            artwork: row.get(2)?,
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
            created_at: row.get::<_, String>(20)?.to_string(),
            updated_at: row.get::<_, String>(21)?.to_string(),
        })
    })?;

    let mut results = Vec::new();
    for item in tracks_map {
        results.push(item?);
    }
    Ok(results)
}

pub fn get_all_releases(conn: &Connection) -> DatabaseResult<Vec<Releases>> {
    let mut releases = conn.prepare("SELECT * FROM releases")?;
    let releases_map = releases.query_map([], |row| {
        Ok(Releases {
            release_id: row.get(0)?,
            title: row.get(1)?,
            artist_id: row.get(2)?,
            artist_name: row.get(3)?,
            release_date: row.get::<_, i64>(4)?.to_string(),
            total_tracks: row.get(5)?,
            total_discs: row.get(6)?,
            duration: row.get(7)?,
            artwork: row.get(8)?,
            created_at: row.get::<_, String>(9)?.to_string(),
            updated_at: row.get::<_, String>(10)?.to_string(),
            is_favorite: row.get(11)?,
            is_hidden: row.get(12)?,
            suggest_less: row.get(13)?,
            rating: row.get(14)?,
        })
    })?;

    let mut results = Vec::new();
    for item in releases_map {
        results.push(item?);
    }
    Ok(results)
}

pub fn get_all_artists(conn: &Connection) -> DatabaseResult<Vec<ArtistItem>> {
    let mut artists = conn.prepare("SELECT * FROM artists")?;
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

pub fn create_playlist(
    conn: &Connection,
    name: String,
    cover: String,
    description: String,
) -> DatabaseResult<Playlist> {
    let cover_blob = if !cover.is_empty() {
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
            &cover
        };

        let base64_data = base64_data.trim();
        match STANDARD.decode(base64_data) {
            Ok(data) => Some(data),
            Err(e) => {
                return Err(DatabaseError::Custom(format!(
                    "Failed to decode base64 image: {} (data: '{}')",
                    e,
                    if base64_data.len() > 50 {
                        format!("{}...", &base64_data[..50])
                    } else {
                        base64_data.to_string()
                    }
                )))
            }
        }
    } else {
        None
    };

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

pub fn get_all_playlists(conn: &Connection) -> DatabaseResult<Vec<Playlist>> {
    let mut playlists = conn.prepare("SELECT * FROM playlists")?;
    let playlist_map = playlists.query_map([], |row| {
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

    let mut results = Vec::new();
    for item in playlist_map {
        results.push(item?);
    }
    Ok(results)
}

pub fn get_all_playlist_songs(conn: &Connection) -> DatabaseResult<Vec<PlaylistSong>> {
    let mut playlist_song = conn.prepare("SELECT * FROM playlist_songs")?;
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
        volume: 50.0,
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
pub fn save_last_session(
    conn: &Connection,
    current_song_id: Option<i64>,
    progress_seconds: f64,
    volume: f64,
    shuffle_enabled: bool,
    repeat_mode: String,
    queue_snapshot: String,
    queue_position: i64,
    source_context: String,
) -> DatabaseResult<()> {
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
            current_song_id,
            progress_seconds,
            volume,
            shuffle_enabled as i64,
            repeat_mode,
            queue_snapshot,
            queue_position,
            source_context,
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

// ===== Cover Migration =====

/// Extracts the front cover (or first embedded picture) as `(mime, raw bytes)`.
fn extract_cover_bytes(tag: &lofty::tag::Tag) -> Option<(String, Vec<u8>)> {
    let picture = tag
        .get_picture_type(lofty::picture::PictureType::CoverFront)
        .or_else(|| tag.pictures().first())?;

    let mime = match picture.mime_type() {
        Some(lofty::picture::MimeType::Jpeg) => "image/jpeg".to_string(),
        Some(lofty::picture::MimeType::Png) => "image/png".to_string(),
        Some(lofty::picture::MimeType::Bmp) => "image/bmp".to_string(),
        Some(lofty::picture::MimeType::Gif) => "image/gif".to_string(),
        Some(lofty::picture::MimeType::Tiff) => "image/tiff".to_string(),
        _ => "image/jpeg".to_string(),
    };

    Some((mime, picture.data().to_vec()))
}

/// Writes the cover to `{covers_dir}/{content_md5}.{ext}` (idempotent by
/// content hash, so equal covers dedupe) and returns its absolute path.
fn write_cover_file(covers_dir: &Path, mime: &str, bytes: &[u8]) -> DatabaseResult<Option<String>> {
    let ext = match mime {
        "image/png" => "png",
        "image/bmp" => "bmp",
        "image/gif" => "gif",
        "image/tiff" => "tiff",
        _ => "jpg",
    };

    fs::create_dir_all(covers_dir)?;

    let hash = format!("{:x}", Md5::digest(bytes));
    let path = covers_dir.join(format!("{}.{}", hash, ext));

    if !path.exists() {
        fs::write(&path, bytes)?;
    }

    // Best-effort thumbnail
    write_thumbnail(&path, bytes)?;

    Ok(Some(path.to_string_lossy().to_string()))
}

/// Returns the expected thumbnail path for a full cover file.
fn thumb_path_for(full_path: &Path) -> PathBuf {
    let dir = full_path.parent().unwrap_or(Path::new(""));
    let stem = full_path.file_stem().unwrap_or_default().to_string_lossy();
    dir.join(format!("thumb_{}.jpg", stem))
}

/// Downsizes an embedded cover to a ~256px JPEG thumbnail next to the full file.
fn write_thumbnail(full_path: &Path, bytes: &[u8]) -> DatabaseResult<()> {
    let Ok(img) = image::load_from_memory(bytes) else {
        return Ok(());
    };
    let thumb = img.thumbnail(256, 256);
    let mut out = Vec::new();
    if thumb
        .write_to(&mut Cursor::new(&mut out), image::ImageFormat::Jpeg)
        .is_err()
    {
        return Ok(());
    }

    let thumb_path = thumb_path_for(full_path);
    if !thumb_path.exists() {
        fs::write(&thumb_path, &out)?;
    }

    Ok(())
}

/// Parses a legacy `data:<mime>;base64,<payload>` artwork value, writes the
/// decoded bytes to the covers dir and returns the absolute file path.
fn cover_path_from_data_url(
    covers_dir: &Path,
    data_url: &str,
) -> DatabaseResult<Option<String>> {
    let rest = data_url.strip_prefix("data:").unwrap_or(data_url);
    let (mime, payload) = match rest.split_once(";base64,") {
        Some((m, p)) => (m, p.trim()),
        None => return Ok(None),
    };

    let bytes = STANDARD.decode(payload)?;
    write_cover_file(covers_dir, mime, &bytes)
}

fn migrate_table_artwork(
    conn: &Connection,
    covers_dir: &Path,
    table: &str,
    id_col: &str,
) -> DatabaseResult<()> {
    let sql = format!(
        "SELECT {}, artwork FROM {} WHERE artwork LIKE 'data:%'",
        id_col, table
    );
    let mut stmt = conn.prepare(&sql)?;

    let rows: Vec<(i64, String)> = stmt
        .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?
        .collect::<Result<_, _>>()?;

    for (id, artwork) in rows {
        if let Some(path) = cover_path_from_data_url(covers_dir, &artwork)? {
            let update = format!("UPDATE {} SET artwork = ?1 WHERE {} = ?2", table, id_col);
            conn.execute(&update, params![path, id])?;
        }
    }

    Ok(())
}

/// Generates thumbnails for artwork rows that are already file paths.
fn backfill_thumbnails(conn: &Connection, covers_dir: &Path) -> DatabaseResult<()> {
    let sentinel = covers_dir.join(".thumbs_done");
    if sentinel.exists() {
        return Ok(());
    }

    for table in ["songs", "releases"] {
        let sql = format!(
            "SELECT DISTINCT artwork FROM {} WHERE artwork NOT LIKE 'data:%' AND artwork != ''",
            table
        );
        let mut stmt = conn.prepare(&sql)?;

        let rows: Vec<String> = stmt
            .query_map([], |row| row.get(0))?
            .collect::<Result<_, _>>()?;

        for artwork in rows {
            let full = PathBuf::from(artwork);
            if !full.exists() {
                continue;
            }
            let thumb = thumb_path_for(&full);
            if !thumb.exists() {
                if let Ok(bytes) = fs::read(&full) {
                    write_thumbnail(&full, &bytes)?;
                }
            }
        }
    }

    fs::write(&sentinel, "")?;

    Ok(())
}

/// Migrates any legacy `data:...` artwork values (songs and releases) to cover
/// files on disk. Idempotent: only rows whose artwork starts with "data:" are
/// processed; after the first pass they become absolute paths and are skipped.
pub fn migrate_covers(conn: &Connection, covers_dir: &Path) -> DatabaseResult<()> {
    migrate_table_artwork(conn, covers_dir, "songs", "song_id")?;
    migrate_table_artwork(conn, covers_dir, "releases", "release_id")?;
    backfill_thumbnails(conn, covers_dir)?;
    Ok(())
}

// ===== Scan Operations =====

fn is_audio_file(extension: &str) -> bool {
    let audio_extensions = [
        "mp3", "wav", "flac", "ogg", "m4a", "wma", "aiff", "aif", "ape", "opus", "dsd", "dsf",
        "dff", "alac", "mp4", "m4b", "m4p", "amr", "3gp", "aa", "aax", "aac", "webm", "ra", "rm",
        "mid", "midi",
    ];

    audio_extensions.contains(&extension.to_lowercase().as_str())
}

fn file_mtime(path: &str) -> DatabaseResult<i64> {
    let meta = fs::metadata(path)?;
    let sys = meta.modified()?;
    Ok(sys.duration_since(std::time::UNIX_EPOCH)?.as_millis() as i64)
}

pub fn scan_folder(folder_path: String) -> DatabaseResult<Vec<FileInfo>> {
    let path = PathBuf::from(folder_path);

    if !path.exists() {
        return Err(DatabaseError::Custom("Folder does not exist".to_string()));
    }

    if !path.is_dir() {
        return Err(DatabaseError::Custom("Path is not a directory".to_string()));
    }

    let mut files = Vec::new();

    fn scan_directory(dir: &PathBuf, files: &mut Vec<FileInfo>) -> DatabaseResult<()> {
        let entries = fs::read_dir(dir)?;

        for entry in entries {
            let entry = entry?;
            let path = entry.path();
            let metadata = fs::metadata(&path)?;

            if metadata.is_dir() {
                scan_directory(&path, files)?;
                continue;
            }

            let file_info = FileInfo {
                name: path
                    .file_name()
                    .unwrap_or_default()
                    .to_string_lossy()
                    .to_string(),
                path: path.to_string_lossy().to_string(),
                size: metadata.len(),
                is_directory: false,
                extension: path
                    .extension()
                    .map(|ext| ext.to_string_lossy().to_string())
                    .unwrap_or_default(),
            };

            if is_audio_file(&file_info.extension) {
                files.push(file_info);
            }
        }

        Ok(())
    }

    scan_directory(&path, &mut files)?;
    Ok(files)
}

/// Updates the database with new/changed files from a folder.
/// Returns (new_or_changed_count, total_files_scanned)
pub async fn update_database(
    conn: &Connection,
    folder_path: String,
    covers_dir: &Path,
) -> DatabaseResult<(usize, usize)> {
    let all_files = scan_folder(folder_path.clone())?;
    let total_files = all_files.len();

    // Incremental scan: skip files whose path + mtime already match the DB.
    let mut unchanged = conn.prepare("SELECT COUNT(*) FROM songs WHERE file_path = ?1 AND file_mtime = ?2")?;
    let mut to_process: Vec<(FileInfo, i64)> = Vec::new();

    for file in all_files {
        let mtime = file_mtime(&file.path)?;
        let is_unchanged: bool = unchanged.query_row(params![&file.path, mtime], |row| {
            Ok(row.get::<_, i64>(0)? > 0)
        })?;
        if !is_unchanged {
            to_process.push((file, mtime));
        }
    }

    // Extract metadata for new/changed files
    let to_process_len = to_process.len();
    let mut tasks: Vec<(tokio::task::JoinHandle<Result<AudioMetadata, String>>, i64)> =
        Vec::with_capacity(to_process_len);
    for (file, mtime) in to_process {
        let path = file.path;
        let covers_dir = covers_dir.to_path_buf();
        tasks.push((
            tokio::task::spawn_blocking(move || {
                crate::metadata::extract_metadata_blocking(&path, &covers_dir)
                    .map_err(|e| e.to_string())
            }),
            mtime,
        ));
    }

    let mut metadata: Vec<AudioMetadata> = Vec::with_capacity(tasks.len());
    let mut mtimes: Vec<i64> = Vec::with_capacity(tasks.len());
    for (handle, mtime) in tasks {
        let inner = handle
            .await
            .map_err(|e| DatabaseError::Custom(format!("Metadata task panicked: {}", e)))?;
        let md = inner.map_err(|e| DatabaseError::Custom(format!("Failed to get audio metadata: {}", e)))?;
        mtimes.push(mtime);
        metadata.push(md);
    }

    // Writes: sequential
    let all_artist = group_artists(&metadata);
    for artist in all_artist {
        add_artist(conn, artist)?;
    }

    let all_releases = group_releases(&metadata);
    for release in all_releases {
        add_release(conn, release)?;
    }

    for (i, md) in metadata.into_iter().enumerate() {
        add_song(conn, md, mtimes[i])?;
    }

    Ok((to_process_len, total_files))
}

/// Kicks off a full library scan for all configured paths.
pub async fn start_library_scan(
    db_pool: std::sync::Arc<r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>>,
    covers_dir: PathBuf,
) -> DatabaseResult<()> {
    let conn = db_pool.get()?;
    let paths = get_library_paths(&conn)?;

    for item in paths {
        let _ = update_database(&conn, item.path, &covers_dir).await?;
    }

    Ok(())
}