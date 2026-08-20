//! Public DTO types for the durvald-core API.
//! 
//! These are stable, frontend-safe types that can be serialized
//! and sent across FFI boundaries (UniFFI, Tauri, etc.).

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Configuration for initializing the core engine.
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct CoreConfig {
    /// Path to the SQLite database file
    pub database_path: String,
    /// Application support directory (platform-specific)
    pub app_support_dir: String,
    /// Directory for cover art files
    pub covers_dir: String,
    /// Keychain service name for secret storage (macOS)
    pub keychain_service: String,
}

impl CoreConfig {
    /// Creates a CoreConfig with platform-appropriate defaults
    pub fn new(app_support_dir: String, keychain_service: String) -> Self {
        let covers_dir = format!("{}/covers", app_support_dir);
        let database_path = format!("{}/music.db3", app_support_dir);
        Self {
            database_path,
            app_support_dir,
            covers_dir,
            keychain_service,
        }
    }
}

/// Stable error type for the public API.
#[derive(Debug, Clone, Serialize, Deserialize, thiserror::Error, uniffi::Error)]
pub enum CoreError {
    #[error("Invalid input: {message}")]
    InvalidInput { message: String },
    #[error("Not found: {message}")]
    NotFound { message: String },
    #[error("Storage error: {message}")]
    Storage { message: String },
    #[error("Playback error: {message}")]
    Playback { message: String },
    #[error("Authentication error: {message}")]
    Authentication { message: String },
    #[error("Network error: {message}")]
    Network { message: String },
}

/// Result type for core operations
pub type CoreResult<T> = Result<T, CoreError>;

/// Audio track DTO
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, uniffi::Record)]
pub struct Track {
    pub id: i64,
    pub title: String,
    pub artist: String,
    pub artist_id: i64,
    pub release: String,
    pub release_id: i64,
    pub track_number: u8,
    pub disc_number: u8,
    pub duration_seconds: f64,
    pub file_path: String,
    pub artwork_id: Option<String>, // Relative asset identifier
    pub bitrate: Option<u32>,
    pub sample_rate: Option<u32>,
    pub play_count: u64,
    pub last_played: Option<String>, // ISO 8601
    pub rating: Option<u8>,
    pub is_favorite: bool,
    pub is_hidden: bool,
    pub suggest_less: bool,
}

/// Release/album DTO
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, uniffi::Record)]
pub struct Release {
    pub id: i64,
    pub title: String,
    pub artist: String,
    pub artist_id: i64,
    pub release_date: Option<String>, // ISO 8601
    pub total_tracks: u8,
    pub total_discs: u8,
    pub duration_seconds: u64,
    pub artwork_id: Option<String>,
    pub is_favorite: bool,
    pub is_hidden: bool,
    pub suggest_less: bool,
    pub rating: Option<u8>,
}

/// Artist DTO
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, uniffi::Record)]
pub struct Artist {
    pub id: i64,
    pub name: String,
}

/// Playlist DTO
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, uniffi::Record)]
pub struct Playlist {
    pub id: i64,
    pub name: String,
    pub description: String,
    pub artwork_id: Option<String>,
    pub is_favorite: bool,
    pub suggest_less: bool,
    pub track_count: u64,
    pub created_at: String,
    pub updated_at: String,
}

/// Playlist track entry
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, uniffi::Record)]
pub struct PlaylistTrack {
    pub playlist_id: i64,
    pub track_id: i64,
    pub position: u64,
    pub added_at: String,
}

/// Queue item DTO
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, uniffi::Record)]
pub struct QueueItem {
    pub track_id: i64,
    pub position: u64,
}

/// Playback state snapshot
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, uniffi::Record)]
pub struct PlaybackSnapshot {
    pub current_track: Option<Track>,
    pub position_seconds: f64,
    pub duration_seconds: Option<f64>,
    pub volume: f32,
    pub is_playing: bool,
    pub is_paused: bool,
    pub queue: Vec<QueueItem>,
    pub queue_position: u64,
    pub shuffle_enabled: bool,
    pub repeat_mode: RepeatMode,
}

/// Repeat mode for playback
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum RepeatMode {
    None,
    One,
    All,
}

/// Last.fm connection status
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, uniffi::Record)]
pub struct LastFmStatus {
    pub connected: bool,
    pub username: Option<String>,
}

/// Library scan progress
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, uniffi::Record)]
pub struct ScanProgress {
    pub path: String,
    pub phase: ScanPhase,
    pub total_files: u64,
    pub processed_files: u64,
    pub new_tracks: u64,
}

/// Library scan phase
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, uniffi::Enum)]
#[serde(rename_all = "snake_case")]
pub enum ScanPhase {
    Scanning,
    ExtractingMetadata,
    WritingDatabase,
    Complete,
}

/// Library scan result
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, uniffi::Record)]
pub struct ScanResult {
    pub paths_scanned: u64,
    pub total_files_found: u64,
    pub new_tracks_added: u64,
    pub updated_tracks: u64,
    pub errors: Vec<String>,
}

/// Last session state for resume
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, uniffi::Record)]
pub struct LastSession {
    pub current_track_id: Option<i64>,
    pub progress_seconds: f64,
    pub volume: f32,
    pub shuffle_enabled: bool,
    pub repeat_mode: RepeatMode,
    pub queue: Vec<i64>, // track IDs
    pub queue_position: u64,
    pub source_context: String, // "release:42", "playlist:7", "library", "search", ""
    pub updated_at: String,
}

/// Application settings
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, uniffi::Record)]
pub struct Settings {
    pub cross_fade: bool,
    pub cross_fade_duration: u32,
    pub normalize_volume: bool,
    pub explicit_content: bool,
    pub autoplay: bool,
    pub preferred_audio_quality: u32,
    pub preferred_audio_source: String,
    pub download_path: String,
    pub open_on_startup: bool,
    pub minimize_on_close: bool,
    pub onboarding_complete: bool,
}

/// Audio metadata extracted from a file
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct AudioMetadata {
    pub title: Option<String>,
    pub artist: Option<String>,
    pub release: Option<String>,
    pub genre: Option<String>,
    pub year: Option<u32>,
    pub track: Option<u32>,
    pub disc: Option<u32>,
    pub duration_seconds: f64,
    pub bitrate: Option<u32>,
    pub sample_rate: Option<u32>,
    pub channels: Option<u8>,
    pub cover_artwork_id: Option<String>,
    pub all_fields: HashMap<String, String>,
    pub file_path: String,
}

/// Search result
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct SearchResults {
    pub tracks: Vec<Track>,
    pub releases: Vec<Release>,
    pub artists: Vec<Artist>,
    pub playlists: Vec<Playlist>,
}