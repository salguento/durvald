use chrono::Utc;
use rusqlite::{params, Connection, OptionalExtension, Result as RusqliteResult};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;

#[derive(Serialize, Clone, Debug)]
pub struct LibraryPath {
    pub path: String,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub struct Settings {
    pub settings_id: i8,
    pub cross_fade: bool,
    pub cross_fade_duration: i32,
    pub normalize_volume: bool,
    pub explicit_content: bool,
    pub autoplay: bool,
    pub preferred_audio_quality: i32,
    pub preferrend_audio_source: String,
    pub download_path: String,
    pub open_on_startup: bool,
    pub minimize_on_close: bool,
    pub onboarding: bool,
}

#[derive(Serialize, Clone, Debug)]
pub struct Releases {
    pub release_id: u64,
    pub title: String,
    pub artist_id: u64,
    pub artist_name: String,
    pub release_date: String,
    pub total_tracks: u8,
    pub total_discs: u8,
    pub duration: u64,
    pub artwork: String,
    pub is_favorite: bool,
    pub is_hidden: bool,
    pub suggest_less: bool,
    pub rating: Option<u8>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Serialize, Clone, Debug)]
pub struct ArtistItem {
    pub artist_id: u64,
    pub artist_name: String,
}

#[derive(Serialize, Clone, Debug)]
pub struct PlayHistory {
    pub history_id: u64,
    pub song_id: u64,
    pub played_at: String,
    pub duration: u64,
}

#[derive(Serialize, Clone, Debug)]
pub struct Playlist {
    pub id: u64,
    pub name: String,
    pub cover: Option<Vec<u8>>,
    pub description: String,
    pub is_favorite: bool,
    pub suggest_less: bool,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Serialize, Clone, Debug)]
pub struct PlaylistSong {
    pub playlist_id: u64,
    pub song_id: u64,
    pub position: u64,
    pub added_at: String,
}

// ===== LAST SESSION =====
// Stores exactly one row (session_id = 1) that is upserted on every meaningful
// player state change so the app can resume from where it left off.
#[derive(Debug, Deserialize, Serialize, Clone)]
#[serde(rename_all = "snake_case")]
pub struct LastSession {
    // Playback position
    pub current_song_id: Option<i64>, // song_id of the track that was playing
    pub progress_seconds: f64,        // playback position in seconds (fractional)

    // Player state
    pub volume: f64,          // 0.0 – 100.0
    pub shuffle_enabled: bool,
    pub repeat_mode: String,  // "none" | "one" | "all"

    // Queue snapshot: JSON array of song_ids in order, e.g. "[12, 7, 33, 5]"
    // Stored as TEXT so we don't need a separate junction table.
    pub queue_snapshot: String,
    pub queue_position: i64, // index of current_song_id inside queue_snapshot

    // Source context — lets the UI restore the "view" the user was in
    // e.g. "release:42", "playlist:7", "library", "search", ""
    pub source_context: String,

    pub updated_at: String,
}

#[derive(Serialize, Clone, Debug, Hash, Eq, PartialEq)]
pub struct ReleaseGroup {
    pub title: String,
    pub artist: String,
    pub cover_image_base64: String,
    pub tracks: u32,
    pub disc: u32,
    pub date: u32,
    pub duration: u64,
}

#[derive(Serialize, Clone, Debug)]
pub struct SongItem {
    pub song_id: u64,
    pub title: String,
    pub artwork: String,
    pub artist_id: u64,
    pub artist_name: String,
    pub release_id: u64,
    pub release_title: String,
    pub track_number: u8,
    pub disc_number: u8,
    pub duration: u64,
    pub bitrate: Option<u16>,
    pub sample_rate: Option<u16>,
    pub play_count: u64,
    pub last_played: Option<String>,
    pub rating: Option<u8>,
    pub lyrics: Option<String>,
    pub is_favorite: bool,
    pub is_hidden: bool,
    pub suggest_less: bool,
    pub file_path: String,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Serialize, Clone, Debug)]
pub struct FileInfo {
    pub name: String,
    pub path: String,
    pub size: u64,
    pub is_directory: bool,
    pub extension: String,
}