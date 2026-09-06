//! durvald-core: Core business logic for the durvald music player.
//!
//! This crate contains all domain logic without any Tauri dependencies.
//! The public API is defined in the `api` module and exposed through
//! the `DurvaldCore` facade in the `core` module.

use crate::api::*;
use crate::lastfm::{LastFmClient, LastFmError};
use crate::secure_store::SecureStore;
use base64::Engine;
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};

/// Opaque core engine - the main entry point for all operations.
///
/// Internally owns the database pool, audio player, secure storage,
/// and Last.fm client. All state is encapsulated here.
#[cfg_attr(feature = "uniffi", derive(uniffi::Object))]
pub struct DurvaldCore {
    db_pool: Arc<r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>>,
    audio_player: Arc<tokio::sync::Mutex<crate::audio::AudioPlayer>>,
    playback_transition: tokio::sync::Mutex<()>,
    lastfm: Arc<LastFmClient>,
    covers_dir: String,
    scan_in_progress: Arc<AtomicBool>,
    scan_cancel_requested: Arc<AtomicBool>,
    scan_progress: Arc<std::sync::Mutex<Option<ScanProgress>>>,
    lastfm_playback: tokio::sync::Mutex<Option<LastFmPlayback>>,
}

struct LastFmPlayback {
    track_id: i64,
    artist: String,
    title: String,
    release: String,
    duration_seconds: u64,
    started_at: u64,
    active_since: Option<u64>,
    played_seconds: u64,
}

impl DurvaldCore {
    // Internal accessor methods for Tauri integration (not exported to UniFFI)
    pub fn db_pool(&self) -> &Arc<r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>> {
        &self.db_pool
    }

    pub fn audio_player(&self) -> &Arc<tokio::sync::Mutex<crate::audio::AudioPlayer>> {
        &self.audio_player
    }

    pub fn lastfm(&self) -> &Arc<LastFmClient> {
        &self.lastfm
    }

    pub fn covers_dir(&self) -> &String {
        &self.covers_dir
    }

    /// Runs SQLite work on Tokio's blocking pool so exported async methods never
    /// execute filesystem-backed database access on their caller's executor.
    async fn run_database<T, F>(&self, operation: F) -> CoreResult<T>
    where
        T: Send + 'static,
        F: FnOnce(&rusqlite::Connection) -> Result<T, String> + Send + 'static,
    {
        let db_pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = db_pool.get().map_err(|error| error.to_string())?;
            operation(&conn)
        })
        .await
        .map_err(|error| CoreError::Storage {
            message: format!("Blocking database task failed: {error}"),
        })?
        .map_err(|message| CoreError::Storage { message })
    }

    /// Variant for queries that need to preserve domain errors such as
    /// `NotFound` instead of flattening every failure into `Storage`.
    async fn run_database_core<T, F>(&self, operation: F) -> CoreResult<T>
    where
        T: Send + 'static,
        F: FnOnce(&rusqlite::Connection) -> CoreResult<T> + Send + 'static,
    {
        let db_pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = db_pool.get().map_err(|error| CoreError::Storage {
                message: error.to_string(),
            })?;
            operation(&conn)
        })
        .await
        .map_err(|error| CoreError::Storage {
            message: format!("Blocking database task failed: {error}"),
        })?
    }

    async fn run_entity_update<F>(
        &self,
        entity: &'static str,
        id: u64,
        operation: F,
    ) -> CoreResult<()>
    where
        F: FnOnce(&rusqlite::Connection) -> crate::database::operations::DatabaseResult<bool>
            + Send
            + 'static,
    {
        self.run_database_core(move |conn| {
            if !operation(conn).map_err(|error| CoreError::Storage {
                message: error.to_string(),
            })? {
                return Err(CoreError::NotFound {
                    message: format!("{entity} {id} not found"),
                });
            }
            Ok(())
        })
        .await
    }

    /// Runs non-database filesystem or parser work on Tokio's blocking pool.
    async fn run_blocking<T, F>(operation_name: &'static str, operation: F) -> CoreResult<T>
    where
        T: Send + 'static,
        F: FnOnce() -> CoreResult<T> + Send + 'static,
    {
        tokio::task::spawn_blocking(operation)
            .await
            .map_err(|error| CoreError::Storage {
                message: format!("{operation_name} task failed: {error}"),
            })?
    }

    async fn persist_playback_session(&self) -> CoreResult<()> {
        let (current_song_id, progress_seconds, volume, shuffle_enabled, repeat_mode, queue) = {
            let player = self.audio_player.lock().await;
            (
                player.get_current_song_id(),
                player.get_position().as_secs_f64(),
                player.volume() as f64,
                player.shuffle_enabled(),
                player.repeat_mode(),
                player
                    .get_playback_queue()
                    .into_iter()
                    .map(|(song_id, _)| song_id)
                    .collect::<Vec<_>>(),
            )
        };
        let db_pool = self.db_pool.clone();

        tokio::task::spawn_blocking(move || -> Result<(), String> {
            let conn = db_pool.get().map_err(|e| e.to_string())?;
            let previous =
                crate::database::operations::get_last_session(&conn).map_err(|e| e.to_string())?;
            let session = crate::database::models::LastSession {
                current_song_id,
                progress_seconds,
                volume,
                shuffle_enabled,
                repeat_mode: format!("{repeat_mode:?}").to_lowercase(),
                queue_snapshot: serde_json::to_string(&queue).map_err(|e| e.to_string())?,
                queue_position: 0,
                source_context: previous.source_context,
                updated_at: String::new(),
            };
            crate::database::operations::save_last_session(&conn, &session)
                .map_err(|e| e.to_string())
        })
        .await
        .map_err(|e| CoreError::Storage {
            message: format!("Session persistence task failed: {e}"),
        })?
        .map_err(|message| CoreError::Storage { message })
    }

    async fn persist_session_progress(&self, progress_seconds: f64) -> CoreResult<()> {
        let db_pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = db_pool.get().map_err(|e| e.to_string())?;
            crate::database::operations::update_session_progress(&conn, progress_seconds)
                .map_err(|e| e.to_string())
        })
        .await
        .map_err(|e| CoreError::Storage {
            message: format!("Session progress persistence task failed: {e}"),
        })?
        .map_err(|message| CoreError::Storage { message })
    }

    async fn persist_session_volume(&self, volume: f64) -> CoreResult<()> {
        let db_pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = db_pool.get().map_err(|e| e.to_string())?;
            crate::database::operations::update_session_volume(&conn, volume)
                .map_err(|e| e.to_string())
        })
        .await
        .map_err(|e| CoreError::Storage {
            message: format!("Session volume persistence task failed: {e}"),
        })?
        .map_err(|message| CoreError::Storage { message })
    }

    async fn prepare_sound(&self, path: String) -> CoreResult<crate::audio::player::PreparedSound> {
        let normalize_volume = self.audio_player.lock().await.normalize_volume_enabled();
        crate::audio::AudioPlayer::prepare_sound(path, normalize_volume)
            .await
            .map_err(|error| CoreError::Playback {
                message: error.to_string(),
            })
    }

    fn update_scan_progress(&self, progress: ScanProgress) {
        if let Ok(mut current) = self.scan_progress.lock() {
            *current = Some(progress);
        }
    }

    async fn report_lastfm_track_started(&self, track_id: i64) {
        if !self.lastfm.is_connected().await {
            return;
        }
        let track = self
            .run_database(move |conn| {
                crate::database::operations::get_song_by_id(conn, &track_id.to_string())
                    .map(|tracks| tracks.into_iter().next())
                    .map_err(|error| error.to_string())
            })
            .await
            .ok()
            .flatten();
        let Some(track) = track else {
            return;
        };
        let started_at = unix_timestamp_seconds();
        let playback = LastFmPlayback {
            track_id,
            artist: track.artist_name,
            title: track.title,
            release: track.release_title,
            duration_seconds: track.duration,
            started_at,
            active_since: Some(started_at),
            played_seconds: 0,
        };
        let artist = playback.artist.clone();
        let title = playback.title.clone();
        let release = (!playback.release.is_empty()).then_some(playback.release.clone());
        *self.lastfm_playback.lock().await = Some(playback);
        let _ = self.lastfm.update_now_playing(artist, title, release).await;
    }

    async fn pause_lastfm_playback(&self) {
        let now = unix_timestamp_seconds();
        if let Some(playback) = self.lastfm_playback.lock().await.as_mut() {
            if let Some(active_since) = playback.active_since.take() {
                playback.played_seconds += now.saturating_sub(active_since);
            }
        }
    }

    async fn resume_lastfm_playback(&self) {
        if let Some(playback) = self.lastfm_playback.lock().await.as_mut() {
            if playback.active_since.is_none() {
                playback.active_since = Some(unix_timestamp_seconds());
            }
        }
    }

    async fn is_tracking_lastfm_track(&self, track_id: i64) -> bool {
        self.lastfm_playback
            .lock()
            .await
            .as_ref()
            .is_some_and(|playback| playback.track_id == track_id)
    }

    async fn report_lastfm_track_completed(&self, track_id: i64) {
        let playback = {
            let mut current = self.lastfm_playback.lock().await;
            match current
                .take()
                .filter(|playback| playback.track_id == track_id)
            {
                Some(mut playback) => {
                    if let Some(active_since) = playback.active_since.take() {
                        playback.played_seconds +=
                            unix_timestamp_seconds().saturating_sub(active_since);
                    }
                    Some(playback)
                }
                None => None,
            }
        };
        let Some(playback) = playback else {
            return;
        };
        if !scrobble_eligible(playback.duration_seconds, playback.played_seconds) {
            return;
        }
        let _ = self
            .lastfm
            .scrobble_track(
                playback.artist,
                playback.title,
                (!playback.release.is_empty()).then_some(playback.release),
                playback.started_at,
            )
            .await;
    }

    async fn record_completed_playback(&self, track_id: i64) {
        let Ok(track_id) = u64::try_from(track_id) else {
            return;
        };
        let db_pool = self.db_pool.clone();
        let _ = tokio::task::spawn_blocking(move || {
            let conn = db_pool.get().map_err(|error| error.to_string())?;
            let duration =
                crate::database::operations::get_song_by_id(&conn, &track_id.to_string())
                    .map_err(|error| error.to_string())?
                    .into_iter()
                    .next()
                    .map(|track| track.duration)
                    .unwrap_or_default();
            crate::database::operations::record_completed_playback(&conn, track_id, duration)
                .map_err(|error| error.to_string())
        })
        .await;
    }
}

/// Type alias for the core handle used in UniFFI
pub type DurvaldCoreHandle = Arc<DurvaldCore>;

fn metadata_to_api(meta: crate::metadata::AudioMetadata) -> AudioMetadata {
    AudioMetadata {
        title: meta.title,
        artist: meta.artist,
        release: meta.release,
        genre: meta.genre,
        year: meta.year,
        track: meta.track,
        disc: meta.disc,
        duration_seconds: meta.duration,
        bitrate: meta.bitrate,
        sample_rate: meta.sample_rate,
        channels: meta.channels,
        cover_artwork_id: meta.cover_path,
        all_fields: meta
            .all_fields
            .into_iter()
            .map(|(key, value)| KeyValuePair { key, value })
            .collect(),
        file_path: meta.file_path,
    }
}

const MAX_LIBRARY_PAGE_SIZE: u64 = 200;

fn pagination_window(page_size: u64, offset: u64) -> CoreResult<(u64, usize)> {
    if page_size == 0 {
        return Err(CoreError::InvalidInput {
            message: "Page size must be greater than zero".to_string(),
        });
    }
    if offset > i64::MAX as u64 {
        return Err(CoreError::InvalidInput {
            message: "Page offset is too large".to_string(),
        });
    }
    let page_size = page_size.min(MAX_LIBRARY_PAGE_SIZE);
    Ok((page_size + 1, page_size as usize))
}

fn finish_page<T>(mut items: Vec<T>, page_size: usize, offset: u64) -> (Vec<T>, Option<u64>) {
    let has_more = items.len() > page_size;
    items.truncate(page_size);
    let next_offset = has_more.then(|| offset.saturating_add(page_size as u64));
    (items, next_offset)
}

fn track_from_song(track: crate::database::models::SongItem) -> Track {
    Track {
        id: track.song_id as i64,
        title: track.title,
        artist: track.artist_name,
        artist_id: track.artist_id as i64,
        release: track.release_title,
        release_id: track.release_id as i64,
        track_number: track.track_number,
        disc_number: track.disc_number,
        duration_seconds: track.duration as f64,
        file_path: track.file_path,
        artwork_id: (!track.artwork.is_empty()).then_some(track.artwork),
        bitrate: track.bitrate.map(u32::from),
        sample_rate: track.sample_rate.map(u32::from),
        play_count: track.play_count,
        last_played: track.last_played,
        rating: track.rating,
        is_favorite: track.is_favorite,
        is_hidden: track.is_hidden,
        suggest_less: track.suggest_less,
    }
}

fn release_from_database(release: crate::database::models::Releases) -> Release {
    Release {
        id: release.release_id as i64,
        title: release.title,
        artist: release.artist_name,
        artist_id: release.artist_id as i64,
        release_date: Some(release.release_date),
        total_tracks: release.total_tracks,
        total_discs: release.total_discs,
        duration_seconds: release.duration,
        artwork_id: (!release.artwork.is_empty()).then_some(release.artwork),
        is_favorite: release.is_favorite,
        is_hidden: release.is_hidden,
        suggest_less: release.suggest_less,
        rating: release.rating,
    }
}

fn history_from_database(item: crate::database::models::PlayHistory) -> PlaybackHistoryItem {
    PlaybackHistoryItem {
        id: item.history_id as i64,
        track_id: item.song_id as i64,
        played_at: item.played_at,
        duration_seconds: item.duration,
    }
}

/// Converts legacy 0–100 persisted values and normalized API values to the
/// single 0.0–1.0 scale used by the audio engine and Swift bindings.
fn normalized_volume(volume: f64) -> f32 {
    if !volume.is_finite() {
        return 0.5;
    }
    let normalized = if volume > 1.0 { volume / 100.0 } else { volume };
    normalized.clamp(0.0, 1.0) as f32
}

fn non_negative_id(value: i64, label: &str) -> CoreResult<u64> {
    u64::try_from(value).map_err(|_| CoreError::InvalidInput {
        message: format!("{label} must not be negative"),
    })
}

fn validate_rating(rating: Option<u8>) -> CoreResult<()> {
    if rating.is_some_and(|value| value > 5) {
        return Err(CoreError::InvalidInput {
            message: "Rating must be between 0 and 5".to_string(),
        });
    }
    Ok(())
}

fn validate_settings(settings: &Settings) -> CoreResult<()> {
    if settings.cross_fade_duration > 60 {
        return Err(CoreError::InvalidInput {
            message: "Cross-fade duration must be between 0 and 60 seconds".to_string(),
        });
    }
    if !(1..=1411).contains(&settings.preferred_audio_quality) {
        return Err(CoreError::InvalidInput {
            message: "Preferred audio quality must be between 1 and 1411 kbps".to_string(),
        });
    }
    for (name, value, maximum_length) in [
        (
            "Preferred audio source",
            &settings.preferred_audio_source,
            100,
        ),
        ("Download path", &settings.download_path, 4096),
    ] {
        if value.len() > maximum_length || value.chars().any(char::is_control) {
            return Err(CoreError::InvalidInput {
                message: format!("{name} contains invalid text"),
            });
        }
    }
    Ok(())
}

fn normalized_cross_fade_duration(value: i32) -> u32 {
    u32::try_from(value).unwrap_or_default().min(60)
}

fn normalized_audio_quality(value: i32) -> u32 {
    u32::try_from(value)
        .ok()
        .filter(|value| (1..=1411).contains(value))
        .unwrap_or(320)
}

fn repeat_mode_from_string(mode: &str) -> RepeatMode {
    match mode {
        "one" => RepeatMode::One,
        "all" => RepeatMode::All,
        _ => RepeatMode::None,
    }
}

fn lookup_error(
    error: crate::database::operations::DatabaseError,
    resource: &str,
    id: u64,
) -> CoreError {
    if matches!(
        &error,
        crate::database::operations::DatabaseError::Rusqlite(rusqlite::Error::QueryReturnedNoRows)
    ) {
        CoreError::NotFound {
            message: format!("{resource} {id} not found"),
        }
    } else {
        CoreError::Storage {
            message: error.to_string(),
        }
    }
}

fn lastfm_error(error: LastFmError) -> CoreError {
    let message = error.to_string();
    match error {
        LastFmError::Network(_) | LastFmError::RateLimit(_) => CoreError::Network { message },
        LastFmError::NotConnected | LastFmError::Api { .. } => {
            CoreError::Authentication { message }
        }
        LastFmError::SecureStore(_) => CoreError::Storage { message },
        _ => CoreError::Network { message },
    }
}

/// Last.fm accepts a scrobble after at least half the track or four minutes,
/// whichever is sooner, and never for tracks shorter than 30 seconds.
fn scrobble_eligible(duration_seconds: u64, played_seconds: u64) -> bool {
    duration_seconds >= 30 && played_seconds >= (duration_seconds / 2).min(240)
}

fn unix_timestamp_seconds() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn artwork_path_in_covers_dir(
    covers_dir: &str,
    artwork_id: &str,
) -> CoreResult<Option<std::path::PathBuf>> {
    if artwork_id.is_empty() {
        return Ok(None);
    }

    let artwork_path = std::path::Path::new(artwork_id);
    if !artwork_path.is_file() {
        return Ok(None);
    }
    let covers_dir = std::fs::canonicalize(covers_dir).map_err(|e| CoreError::Storage {
        message: format!("Unable to access covers directory: {e}"),
    })?;
    let artwork_path = std::fs::canonicalize(artwork_path).map_err(|e| CoreError::Storage {
        message: format!("Unable to access artwork: {e}"),
    })?;
    if !artwork_path.starts_with(&covers_dir) {
        return Err(CoreError::InvalidInput {
            message: "Artwork must be inside the configured covers directory".to_string(),
        });
    }
    Ok(Some(artwork_path))
}

impl DurvaldCore {
    /// Creates a new core engine with the given configuration.
    /// Initializes database, audio, storage, and services.
    pub async fn open(config: CoreConfig) -> CoreResult<Arc<Self>> {
        let runtime = tokio::runtime::Handle::current();
        tokio::task::spawn_blocking(move || {
            runtime.block_on(Self::open_with_audio_player(
                config,
                crate::audio::AudioPlayer::new,
            ))
        })
        .await
        .map_err(|error| CoreError::Storage {
            message: format!("Core initialization task failed: {error}"),
        })?
    }

    #[cfg(test)]
    async fn open_with_mock_audio(config: CoreConfig) -> CoreResult<Arc<Self>> {
        Self::open_with_audio_player(config, crate::audio::AudioPlayer::new_mock).await
    }

    async fn open_with_audio_player<F>(
        config: CoreConfig,
        create_audio_player: F,
    ) -> CoreResult<Arc<Self>>
    where
        F: FnOnce() -> Result<crate::audio::AudioPlayer, crate::audio::player::AudioError>,
    {
        // Create directories
        std::fs::create_dir_all(&config.app_support_dir).map_err(|e| CoreError::Storage {
            message: e.to_string(),
        })?;
        std::fs::create_dir_all(&config.covers_dir).map_err(|e| CoreError::Storage {
            message: e.to_string(),
        })?;

        // Initialize database
        let manager = r2d2_sqlite::SqliteConnectionManager::file(&config.database_path).with_init(|conn: &mut rusqlite::Connection| {
            conn.execute_batch(
                "PRAGMA journal_mode = WAL;\n PRAGMA busy_timeout = 5000;\n PRAGMA foreign_keys = ON;",
            )?;
            Ok(())
        });
        let pool = r2d2::Pool::new(manager).map_err(|e| CoreError::Storage {
            message: e.to_string(),
        })?;

        let (saved_session, crossfade, current_track, upcoming_tracks) = {
            // Create tables and resolve the saved queue while the connection
            // is scoped to this synchronous initialization block.
            let conn = pool.get().map_err(|e| CoreError::Storage {
                message: e.to_string(),
            })?;
            crate::database::operations::create_tables(&conn).map_err(|e| CoreError::Storage {
                message: e.to_string(),
            })?;
            crate::database::operations::initiate_settings(&conn).map_err(|e| {
                CoreError::Storage {
                    message: e.to_string(),
                }
            })?;
            crate::database::operations::initiate_last_session(&conn).map_err(|e| {
                CoreError::Storage {
                    message: e.to_string(),
                }
            })?;
            let saved_session =
                crate::database::operations::get_last_session(&conn).map_err(|e| {
                    CoreError::Storage {
                        message: e.to_string(),
                    }
                })?;
            let settings = crate::database::operations::get_settings(&conn).map_err(|e| {
                CoreError::Storage {
                    message: e.to_string(),
                }
            })?;
            let queue_ids =
                serde_json::from_str::<Vec<i64>>(&saved_session.queue_snapshot).unwrap_or_default();
            let song_path = |song_id: i64| {
                crate::database::operations::get_song_by_id(&conn, &song_id.to_string())
                    .ok()
                    .and_then(|tracks| tracks.into_iter().next())
                    .map(|track| (song_id, track.file_path))
            };
            let current_track = saved_session.current_song_id.and_then(song_path);
            let mut skipped_current = false;
            let upcoming_tracks = queue_ids
                .into_iter()
                .filter_map(|song_id| {
                    if !skipped_current && Some(song_id) == saved_session.current_song_id {
                        skipped_current = true;
                        None
                    } else {
                        song_path(song_id)
                    }
                })
                .collect();
            (
                saved_session,
                (
                    settings.cross_fade,
                    normalized_cross_fade_duration(settings.cross_fade_duration),
                    settings.normalize_volume,
                ),
                current_track,
                upcoming_tracks,
            )
        };

        // Initialize audio player
        let mut audio_player = create_audio_player().map_err(|e| CoreError::Playback {
            message: e.to_string(),
        })?;
        audio_player.set_volume(normalized_volume(saved_session.volume));
        audio_player.set_crossfade(crossfade.0, crossfade.1);
        audio_player.set_volume_normalization(crossfade.2);
        audio_player.restore_session(
            current_track,
            upcoming_tracks,
            saved_session.progress_seconds,
            saved_session.shuffle_enabled,
            repeat_mode_from_string(&saved_session.repeat_mode),
        );
        // Initialize secure store
        let secure_store = SecureStore::new(
            config.app_support_dir.clone().into(),
            config.keychain_service.clone(),
        )
        .map_err(|e| CoreError::Storage {
            message: e.to_string(),
        })?;

        // Initialize Last.fm client (clones the secure store)
        let lastfm = LastFmClient::new(Arc::new(tokio::sync::Mutex::new(secure_store.clone())))
            .map_err(lastfm_error)?;

        let core = Self {
            db_pool: Arc::new(pool),
            audio_player: Arc::new(tokio::sync::Mutex::new(audio_player)),
            playback_transition: tokio::sync::Mutex::new(()),
            lastfm: Arc::new(lastfm),
            covers_dir: config.covers_dir.clone(),
            scan_in_progress: Arc::new(AtomicBool::new(false)),
            scan_cancel_requested: Arc::new(AtomicBool::new(false)),
            scan_progress: Arc::new(std::sync::Mutex::new(None)),
            lastfm_playback: tokio::sync::Mutex::new(None),
        };

        let core = Arc::new(core);

        // Kira exposes completed playback through its sound state rather than a
        // callback. Poll in the background so the next queued track begins
        // without a SwiftUI view having to drive the transition.
        let weak_core = Arc::downgrade(&core);
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(std::time::Duration::from_millis(500)).await;
                let Some(core) = weak_core.upgrade() else {
                    break;
                };

                let transitioned = {
                    let _transition = core.playback_transition.lock().await;
                    let (completed_track_id, plan) = {
                        let player = core.audio_player.lock().await;
                        (
                            player.get_current_song_id(),
                            player.completed_playback_plan(),
                        )
                    };
                    let Some(plan) = plan else {
                        continue;
                    };
                    let Ok(prepared) = core.prepare_sound(plan.path().to_string()).await else {
                        continue;
                    };
                    let started_track_id = plan.song_id();
                    let mut player = core.audio_player.lock().await;
                    match player.commit_plan(plan, prepared) {
                        Ok(()) => Some((completed_track_id, Some(started_track_id))),
                        Err(_) => None,
                    }
                };

                if let Some((completed_track_id, started_track_id)) = transitioned {
                    if let Some(track_id) = completed_track_id {
                        core.record_completed_playback(track_id).await;
                        core.report_lastfm_track_completed(track_id).await;
                    }
                    if let Some(track_id) = started_track_id {
                        core.report_lastfm_track_started(track_id).await;
                    }
                    let _ = core.persist_playback_session().await;
                }
            }
        });

        Ok(core)
    }
}

#[cfg_attr(feature = "uniffi", uniffi::export(async_runtime = "tokio"))]
impl DurvaldCore {
    /// Scans the library at the given paths.
    pub async fn scan_library(&self, paths: Vec<String>) -> CoreResult<ScanResult> {
        if self
            .scan_in_progress
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return Err(CoreError::InvalidInput {
                message: "A library scan is already in progress".to_string(),
            });
        }
        self.scan_cancel_requested.store(false, Ordering::Release);

        let mut total_files: u64 = 0;
        let mut new_tracks: u64 = 0;
        let mut updated_tracks: u64 = 0;
        let mut errors = Vec::new();
        let mut paths_scanned = 0;

        for path in &paths {
            if self.scan_cancel_requested.load(Ordering::Acquire) {
                errors.push("Library scan cancelled".to_string());
                break;
            }
            paths_scanned += 1;
            self.update_scan_progress(ScanProgress {
                path: path.clone(),
                phase: ScanPhase::Scanning,
                total_files,
                processed_files: 0,
                new_tracks,
            });

            let db_pool = self.db_pool.clone();
            let cancellation = self.scan_cancel_requested.clone();
            let scan_path = path.clone();
            let pending = tokio::task::spawn_blocking(move || {
                let conn = db_pool.get().map_err(|e| e.to_string())?;
                crate::database::operations::prepare_database_update_with_cancel(
                    &conn,
                    scan_path,
                    Some(cancellation.as_ref()),
                )
                .map_err(|e| e.to_string())
            })
            .await;
            let pending = match pending {
                Ok(Ok(pending)) => pending,
                Ok(Err(message)) => {
                    errors.push(format!("{}: {}", path, message));
                    continue;
                }
                Err(error) => {
                    errors.push(format!(
                        "{}: Library scan preparation task failed: {}",
                        path, error
                    ));
                    continue;
                }
            };
            let path_total = pending.total_files() as u64;
            let (metadata_batches, reconciliation) = pending.into_metadata_batches();
            self.update_scan_progress(ScanProgress {
                path: path.clone(),
                phase: ScanPhase::ExtractingMetadata,
                total_files: path_total,
                processed_files: 0,
                new_tracks: 0,
            });

            let progress_state = self.scan_progress.clone();
            let progress_path = path.clone();
            let metadata_progress = move |processed_files: usize| {
                if let Ok(mut progress) = progress_state.lock() {
                    *progress = Some(ScanProgress {
                        path: progress_path.clone(),
                        phase: ScanPhase::ExtractingMetadata,
                        total_files: path_total,
                        processed_files: processed_files as u64,
                        new_tracks: 0,
                    });
                }
            };
            let mut path_failed = false;
            for batch in metadata_batches {
                let mut extracted =
                    crate::database::operations::extract_metadata_batch_with_cancel(
                        batch,
                        &std::path::PathBuf::from(&self.covers_dir),
                        Some(self.scan_cancel_requested.clone()),
                        Some(&metadata_progress),
                    )
                    .await;
                errors.append(&mut extracted.errors);
                if self.scan_cancel_requested.load(Ordering::Acquire) {
                    break;
                }
                self.update_scan_progress(ScanProgress {
                    path: path.clone(),
                    phase: ScanPhase::WritingDatabase,
                    total_files: path_total,
                    processed_files: extracted.attempted_files as u64,
                    new_tracks,
                });

                let db_pool = self.db_pool.clone();
                let write_result = tokio::task::spawn_blocking(move || {
                    let conn = db_pool.get().map_err(|e| e.to_string())?;
                    crate::database::operations::persist_metadata_with_existing_ids(
                        &conn,
                        extracted.metadata,
                        extracted.mtimes,
                        extracted.existing_song_ids,
                    )
                    .map_err(|e| e.to_string())
                })
                .await;
                match write_result {
                    Ok(Ok(written)) => {
                        new_tracks += written.added_tracks as u64;
                        updated_tracks += written.updated_tracks as u64;
                    }
                    Ok(Err(error)) => {
                        errors.push(format!("{}: {}", path, error));
                        path_failed = true;
                        break;
                    }
                    Err(error) => {
                        errors.push(format!(
                            "{}: Library database write task failed: {}",
                            path, error
                        ));
                        path_failed = true;
                        break;
                    }
                }
            }

            if self.scan_cancel_requested.load(Ordering::Acquire) {
                errors.push("Library scan cancelled".to_string());
                break;
            }
            if path_failed {
                continue;
            }

            if let Some(reconciliation) = reconciliation {
                let db_pool = self.db_pool.clone();
                let reconcile_result = tokio::task::spawn_blocking(move || {
                    let conn = db_pool.get().map_err(|e| e.to_string())?;
                    crate::database::operations::remove_missing_songs_in_folder(
                        &conn,
                        reconciliation,
                    )
                    .map_err(|e| e.to_string())
                })
                .await;
                if let Err(error) = reconcile_result
                    .map_err(|error| error.to_string())
                    .and_then(|result| result)
                {
                    errors.push(format!("{}: {}", path, error));
                    continue;
                }
            }
            total_files += path_total;
        }

        self.scan_in_progress.store(false, Ordering::Release);
        self.update_scan_progress(ScanProgress {
            path: paths.last().cloned().unwrap_or_default(),
            phase: ScanPhase::Complete,
            total_files,
            processed_files: total_files,
            new_tracks,
        });

        Ok(ScanResult {
            paths_scanned,
            total_files_found: total_files,
            new_tracks_added: new_tracks,
            updated_tracks,
            errors,
        })
    }

    /// Returns phase-level progress for the current or most recent library scan.
    pub fn scan_progress(&self) -> CoreResult<Option<ScanProgress>> {
        self.scan_progress
            .lock()
            .map(|progress| progress.clone())
            .map_err(|_| CoreError::Storage {
                message: "Library scan progress state is unavailable".to_string(),
            })
    }

    /// Requests cancellation of the active library scan.
    pub fn cancel_library_scan(&self) -> CoreResult<()> {
        if !self.scan_in_progress.load(Ordering::Acquire) {
            return Err(CoreError::NotFound {
                message: "No library scan is in progress".to_string(),
            });
        }
        self.scan_cancel_requested.store(true, Ordering::Release);
        Ok(())
    }

    /// Adds an existing folder to the configured library locations.
    pub async fn add_library_path(&self, path: String) -> CoreResult<()> {
        self.run_database_core(move |conn| {
            if !std::path::Path::new(&path).is_dir() {
                return Err(CoreError::InvalidInput {
                    message: format!("Library path is not a directory: {path}"),
                });
            }
            crate::database::operations::add_library_path(conn, path).map_err(|error| {
                CoreError::Storage {
                    message: error.to_string(),
                }
            })
        })
        .await
    }

    /// Lists configured library folders.
    pub async fn library_paths(&self) -> CoreResult<Vec<String>> {
        self.run_database(|conn| {
            crate::database::operations::get_library_paths(conn)
                .map(|paths| paths.into_iter().map(|path| path.path).collect())
                .map_err(|error| error.to_string())
        })
        .await
    }

    /// Scans every configured library folder.
    pub async fn scan_configured_library(&self) -> CoreResult<ScanResult> {
        let paths = self.library_paths().await?;
        if paths.is_empty() {
            return Err(CoreError::InvalidInput {
                message: "No library folders are configured".to_string(),
            });
        }
        self.scan_library(paths).await
    }

    /// Removes a configured library folder.
    pub async fn remove_library_path(&self, path: String) -> CoreResult<()> {
        self.run_database_core(move |conn| {
            let removed =
                crate::database::operations::remove_library_path(conn, &path).map_err(|error| {
                    CoreError::Storage {
                        message: error.to_string(),
                    }
                })?;
            if !removed {
                return Err(CoreError::NotFound {
                    message: format!("Library path is not configured: {path}"),
                });
            }
            Ok(())
        })
        .await
    }

    /// Searches tracks, releases, artists, and playlists by text.
    pub async fn search(&self, query: String) -> CoreResult<SearchResults> {
        if query.trim().is_empty() {
            return Err(CoreError::InvalidInput {
                message: "Search query cannot be empty".to_string(),
            });
        }

        let query = query.trim().to_owned();
        let results = self
            .run_database(move |conn| {
                crate::database::operations::search_library(conn, &query)
                    .map_err(|error| error.to_string())
            })
            .await?;

        Ok(SearchResults {
            tracks: results.tracks.into_iter().map(track_from_song).collect(),
            releases: results
                .releases
                .into_iter()
                .map(release_from_database)
                .collect(),
            artists: results
                .artists
                .into_iter()
                .map(|artist| Artist {
                    id: artist.artist_id as i64,
                    name: artist.artist_name,
                })
                .collect(),
            playlists: results
                .playlists
                .into_iter()
                .map(|playlist| Playlist {
                    id: playlist.id as i64,
                    name: playlist.name,
                    description: playlist.description,
                    artwork_id: playlist
                        .cover
                        .map(|cover| base64::engine::general_purpose::STANDARD.encode(cover)),
                    is_favorite: playlist.is_favorite,
                    suggest_less: playlist.suggest_less,
                    track_count: 0,
                    created_at: playlist.created_at,
                    updated_at: playlist.updated_at,
                })
                .collect(),
        })
    }

    /// Returns all tracks in the library.
    pub async fn tracks(&self) -> CoreResult<Vec<Track>> {
        let db_tracks = self
            .run_database(|conn| {
                crate::database::operations::get_all_tracks(conn).map_err(|error| error.to_string())
            })
            .await?;

        Ok(db_tracks.into_iter().map(track_from_song).collect())
    }

    /// Returns a bounded page of tracks ordered by their stable database ID.
    pub async fn tracks_page(&self, page_size: u64, offset: u64) -> CoreResult<TrackPage> {
        let (fetch_size, page_size) = pagination_window(page_size, offset)?;
        let tracks = self
            .run_database(move |conn| {
                crate::database::operations::get_tracks_page(conn, fetch_size, offset)
                    .map_err(|error| error.to_string())
            })
            .await?
            .into_iter()
            .map(track_from_song)
            .collect();
        let (items, next_offset) = finish_page(tracks, page_size, offset);
        Ok(TrackPage { items, next_offset })
    }

    /// Returns all releases in the library.
    pub async fn releases(&self) -> CoreResult<Vec<Release>> {
        let db_releases = self
            .run_database(|conn| {
                crate::database::operations::get_all_releases(conn)
                    .map_err(|error| error.to_string())
            })
            .await?;

        Ok(db_releases.into_iter().map(release_from_database).collect())
    }

    /// Returns a bounded page of releases ordered by their stable database ID.
    pub async fn releases_page(&self, page_size: u64, offset: u64) -> CoreResult<ReleasePage> {
        let (fetch_size, page_size) = pagination_window(page_size, offset)?;
        let releases = self
            .run_database(move |conn| {
                crate::database::operations::get_releases_page(conn, fetch_size, offset)
                    .map_err(|error| error.to_string())
            })
            .await?
            .into_iter()
            .map(release_from_database)
            .collect();
        let (items, next_offset) = finish_page(releases, page_size, offset);
        Ok(ReleasePage { items, next_offset })
    }

    /// Returns all artists in the library.
    pub async fn artists(&self) -> CoreResult<Vec<Artist>> {
        let db_artists = self
            .run_database(|conn| {
                crate::database::operations::get_all_artists(conn)
                    .map_err(|error| error.to_string())
            })
            .await?;

        Ok(db_artists
            .into_iter()
            .map(|a| Artist {
                id: a.artist_id as i64,
                name: a.artist_name,
            })
            .collect())
    }

    /// Gets an artist by ID.
    pub async fn artist(&self, artist_id: i64) -> CoreResult<Artist> {
        let artist_id = non_negative_id(artist_id, "Artist ID")?;
        self.run_database_core(move |conn| {
            crate::database::operations::get_artist_by_id(conn, &artist_id.to_string())
                .map(|artist| Artist {
                    id: artist.artist_id as i64,
                    name: artist.artist_name,
                })
                .map_err(|error| lookup_error(error, "Artist", artist_id))
        })
        .await
    }

    /// Returns releases by an artist.
    pub async fn artist_releases(&self, artist_id: i64) -> CoreResult<Vec<Release>> {
        let artist_id = non_negative_id(artist_id, "Artist ID")?;
        self.run_database(move |conn| {
            crate::database::operations::get_releases_by_artist_id(conn, &artist_id.to_string())
                .map(|releases| releases.into_iter().map(release_from_database).collect())
                .map_err(|error| error.to_string())
        })
        .await
    }

    /// Returns tracks by an artist.
    pub async fn artist_tracks(&self, artist_id: i64) -> CoreResult<Vec<Track>> {
        let artist_id = non_negative_id(artist_id, "Artist ID")?;
        self.run_database(move |conn| {
            crate::database::operations::get_songs_by_artist_id(conn, &artist_id.to_string())
                .map(|tracks| tracks.into_iter().map(track_from_song).collect())
                .map_err(|error| error.to_string())
        })
        .await
    }

    /// Returns all playlists.
    pub async fn playlists(&self) -> CoreResult<Vec<Playlist>> {
        self.run_database(|conn| {
            let db_playlists =
                crate::database::operations::get_all_playlists_with_track_counts(conn)
                    .map_err(|error| error.to_string())?;
            let mut playlists = Vec::with_capacity(db_playlists.len());
            for summary in db_playlists {
                let playlist = summary.playlist;
                playlists.push(Playlist {
                    id: playlist.id as i64,
                    name: playlist.name,
                    description: playlist.description,
                    artwork_id: playlist
                        .cover
                        .map(|cover| base64::engine::general_purpose::STANDARD.encode(cover)),
                    is_favorite: playlist.is_favorite,
                    suggest_less: playlist.suggest_less,
                    track_count: summary.track_count,
                    created_at: playlist.created_at,
                    updated_at: playlist.updated_at,
                });
            }
            Ok(playlists)
        })
        .await
    }

    /// Creates a playlist. Artwork is optional base64 or a data URL.
    pub async fn create_playlist(
        &self,
        name: String,
        description: String,
        artwork_base64: Option<String>,
    ) -> CoreResult<Playlist> {
        if name.trim().is_empty() {
            return Err(CoreError::InvalidInput {
                message: "Playlist name cannot be empty".to_string(),
            });
        }
        self.run_database(move |conn| {
            crate::database::operations::create_playlist(
                conn,
                name,
                artwork_base64.unwrap_or_default(),
                description,
            )
            .map(|playlist| Playlist {
                id: playlist.id as i64,
                name: playlist.name,
                description: playlist.description,
                artwork_id: playlist
                    .cover
                    .map(|cover| base64::engine::general_purpose::STANDARD.encode(cover)),
                is_favorite: playlist.is_favorite,
                suggest_less: playlist.suggest_less,
                track_count: 0,
                created_at: playlist.created_at,
                updated_at: playlist.updated_at,
            })
            .map_err(|error| error.to_string())
        })
        .await
    }

    /// Gets one playlist by ID.
    pub async fn playlist(&self, playlist_id: i64) -> CoreResult<Playlist> {
        let playlist_id = non_negative_id(playlist_id, "Playlist ID")?;
        self.run_database_core(move |conn| {
            let playlist = crate::database::operations::get_playlist_by_id(conn, playlist_id)
                .map_err(|error| lookup_error(error, "Playlist", playlist_id))?;
            let track_count =
                crate::database::operations::get_playlist_track_count(conn, playlist_id).map_err(
                    |error| CoreError::Storage {
                        message: error.to_string(),
                    },
                )?;
            Ok(Playlist {
                id: playlist.id as i64,
                name: playlist.name,
                description: playlist.description,
                artwork_id: playlist
                    .cover
                    .map(|cover| base64::engine::general_purpose::STANDARD.encode(cover)),
                is_favorite: playlist.is_favorite,
                suggest_less: playlist.suggest_less,
                track_count,
                created_at: playlist.created_at,
                updated_at: playlist.updated_at,
            })
        })
        .await
    }

    /// Updates a playlist's name, description, and optional artwork.
    pub async fn update_playlist(
        &self,
        playlist_id: i64,
        name: String,
        description: String,
        artwork_base64: Option<String>,
    ) -> CoreResult<()> {
        if name.trim().is_empty() {
            return Err(CoreError::InvalidInput {
                message: "Playlist name cannot be empty".to_string(),
            });
        }
        let playlist_id = non_negative_id(playlist_id, "Playlist ID")?;
        self.run_entity_update("Playlist", playlist_id, move |conn| {
            crate::database::operations::update_playlist(
                conn,
                playlist_id,
                name,
                description,
                artwork_base64.unwrap_or_default(),
            )
        })
        .await
    }

    /// Deletes a playlist and its track entries.
    pub async fn delete_playlist(&self, playlist_id: i64) -> CoreResult<()> {
        let playlist_id = non_negative_id(playlist_id, "Playlist ID")?;
        self.run_entity_update("Playlist", playlist_id, move |conn| {
            crate::database::operations::delete_playlist(conn, playlist_id)
        })
        .await
    }

    /// Returns tracks in playlist order.
    pub async fn playlist_tracks(&self, playlist_id: i64) -> CoreResult<Vec<Track>> {
        let playlist_id = non_negative_id(playlist_id, "Playlist ID")?;
        self.run_database(move |conn| {
            crate::database::operations::get_playlist_tracks(conn, playlist_id)
                .map(|tracks| tracks.into_iter().map(track_from_song).collect())
                .map_err(|error| error.to_string())
        })
        .await
    }

    /// Loads persisted track or release artwork as bytes for Swift `Data`.
    /// The supplied artwork identifier must resolve inside the covers directory.
    pub async fn artwork_bytes(&self, artwork_id: String) -> CoreResult<Option<Vec<u8>>> {
        let covers_dir = self.covers_dir.clone();
        Self::run_blocking("Artwork read", move || {
            let Some(path) = artwork_path_in_covers_dir(&covers_dir, &artwork_id)? else {
                return Ok(None);
            };
            std::fs::read(path)
                .map(Some)
                .map_err(|error| CoreError::Storage {
                    message: format!("Unable to read artwork: {error}"),
                })
        })
        .await
    }

    /// Loads a playlist's artwork blob as bytes for Swift `Data`.
    pub async fn playlist_artwork_bytes(&self, playlist_id: i64) -> CoreResult<Option<Vec<u8>>> {
        let playlist_id = non_negative_id(playlist_id, "Playlist ID")?;
        self.run_database(move |conn| {
            crate::database::operations::get_playlist_by_id(conn, playlist_id)
                .map(|playlist| playlist.cover)
                .map_err(|error| error.to_string())
        })
        .await
    }

    /// Sets whether a track is favorited.
    pub async fn set_track_favorite(&self, track_id: i64, favorite: bool) -> CoreResult<()> {
        let track_id = non_negative_id(track_id, "Track ID")?;
        self.run_entity_update("Track", track_id, move |conn| {
            crate::database::operations::set_track_favorite(conn, track_id, favorite)
        })
        .await
    }

    /// Sets whether a release is favorited.
    pub async fn set_release_favorite(&self, release_id: i64, favorite: bool) -> CoreResult<()> {
        let release_id = non_negative_id(release_id, "Release ID")?;
        self.run_entity_update("Release", release_id, move |conn| {
            crate::database::operations::set_release_favorite(conn, release_id, favorite)
        })
        .await
    }

    /// Sets whether a track is hidden from normal library views.
    pub async fn set_track_hidden(&self, track_id: i64, hidden: bool) -> CoreResult<()> {
        let track_id = non_negative_id(track_id, "Track ID")?;
        self.run_entity_update("Track", track_id, move |conn| {
            crate::database::operations::set_track_hidden(conn, track_id, hidden)
        })
        .await
    }

    /// Sets whether a release is hidden from normal library views.
    pub async fn set_release_hidden(&self, release_id: i64, hidden: bool) -> CoreResult<()> {
        let release_id = non_negative_id(release_id, "Release ID")?;
        self.run_entity_update("Release", release_id, move |conn| {
            crate::database::operations::set_release_hidden(conn, release_id, hidden)
        })
        .await
    }

    /// Sets whether recommendations should de-emphasize a track.
    pub async fn set_track_suggest_less(
        &self,
        track_id: i64,
        suggest_less: bool,
    ) -> CoreResult<()> {
        let track_id = non_negative_id(track_id, "Track ID")?;
        self.run_entity_update("Track", track_id, move |conn| {
            crate::database::operations::set_track_suggest_less(conn, track_id, suggest_less)
        })
        .await
    }

    /// Sets whether recommendations should de-emphasize a release.
    pub async fn set_release_suggest_less(
        &self,
        release_id: i64,
        suggest_less: bool,
    ) -> CoreResult<()> {
        let release_id = non_negative_id(release_id, "Release ID")?;
        self.run_entity_update("Release", release_id, move |conn| {
            crate::database::operations::set_release_suggest_less(conn, release_id, suggest_less)
        })
        .await
    }

    /// Sets whether a playlist is favorited.
    pub async fn set_playlist_favorite(&self, playlist_id: i64, favorite: bool) -> CoreResult<()> {
        let playlist_id = non_negative_id(playlist_id, "Playlist ID")?;
        self.run_entity_update("Playlist", playlist_id, move |conn| {
            crate::database::operations::set_playlist_favorite(conn, playlist_id, favorite)
        })
        .await
    }

    /// Sets whether recommendations should de-emphasize a playlist.
    pub async fn set_playlist_suggest_less(
        &self,
        playlist_id: i64,
        suggest_less: bool,
    ) -> CoreResult<()> {
        let playlist_id = non_negative_id(playlist_id, "Playlist ID")?;
        self.run_entity_update("Playlist", playlist_id, move |conn| {
            crate::database::operations::set_playlist_suggest_less(conn, playlist_id, suggest_less)
        })
        .await
    }

    /// Sets or clears a track rating on the 0–5 scale.
    pub async fn set_track_rating(&self, track_id: i64, rating: Option<u8>) -> CoreResult<()> {
        validate_rating(rating)?;
        let track_id = non_negative_id(track_id, "Track ID")?;
        self.run_entity_update("Track", track_id, move |conn| {
            crate::database::operations::set_track_rating(conn, track_id, rating)
        })
        .await
    }

    /// Sets or clears a release rating on the 0–5 scale.
    pub async fn set_release_rating(&self, release_id: i64, rating: Option<u8>) -> CoreResult<()> {
        validate_rating(rating)?;
        let release_id = non_negative_id(release_id, "Release ID")?;
        self.run_entity_update("Release", release_id, move |conn| {
            crate::database::operations::set_release_rating(conn, release_id, rating)
        })
        .await
    }

    /// Adds a track at a playlist position.
    pub async fn add_track_to_playlist(
        &self,
        playlist_id: i64,
        track_id: i64,
        position: u64,
    ) -> CoreResult<PlaylistTrack> {
        let playlist_id = non_negative_id(playlist_id, "Playlist ID")?;
        let track_id = non_negative_id(track_id, "Track ID")?;
        self.run_database(move |conn| {
            crate::database::operations::add_track_to_playlist_songs(
                conn,
                playlist_id,
                track_id,
                position,
            )
            .map(|entry| PlaylistTrack {
                playlist_id: entry.playlist_id as i64,
                track_id: entry.song_id as i64,
                position: entry.position,
                added_at: entry.added_at,
            })
            .map_err(|error| error.to_string())
        })
        .await
    }

    /// Removes a track entry at a playlist position.
    pub async fn remove_track_from_playlist(
        &self,
        playlist_id: i64,
        track_id: i64,
        position: u64,
    ) -> CoreResult<()> {
        let playlist_id = non_negative_id(playlist_id, "Playlist ID")?;
        let track_id = non_negative_id(track_id, "Track ID")?;
        self.run_database(move |conn| {
            crate::database::operations::remove_track_from_playlist(
                conn,
                playlist_id,
                track_id,
                position,
            )
            .map_err(|error| error.to_string())
        })
        .await
    }

    /// Starts playback of a track.
    pub async fn play(&self, track_id: i64) -> CoreResult<PlaybackSnapshot> {
        non_negative_id(track_id, "Track ID")?;
        // Get track info
        let track = self
            .run_database_core(move |conn| {
                let track =
                    crate::database::operations::get_song_by_id(conn, &track_id.to_string())
                        .map_err(|error| CoreError::Storage {
                            message: error.to_string(),
                        })?
                        .into_iter()
                        .next()
                        .ok_or_else(|| CoreError::NotFound {
                            message: format!("Track {} not found", track_id),
                        })?;
                Ok(track)
            })
            .await?;

        // Start the selected track. The player's queue represents upcoming
        // tracks, so playing directly must not append a duplicate entry.
        let _transition = self.playback_transition.lock().await;
        let prepared = self.prepare_sound(track.file_path.clone()).await?;
        let mut player = self.audio_player.lock().await;
        player
            .play_song_prepared(track_id, prepared)
            .map_err(|e| CoreError::Playback {
                message: e.to_string(),
            })?;

        let playback_state = playback_state_for_player(&player);
        drop(player);
        drop(_transition);
        let snapshot = playback_from_state(self, playback_state).await;
        self.persist_playback_session().await?;
        self.report_lastfm_track_started(track_id).await;
        Ok(snapshot)
    }

    /// Returns the current playback state.
    pub async fn playback(&self) -> PlaybackSnapshot {
        let playback_state = {
            let player = self.audio_player.lock().await;
            playback_state_for_player(&player)
        };
        playback_from_state(self, playback_state).await
    }
}

struct PlaybackStateSnapshot {
    current_track_id: Option<i64>,
    position_seconds: f64,
    duration_seconds: Option<f64>,
    volume: f32,
    is_playing: bool,
    is_paused: bool,
    queue: Vec<QueueItem>,
    shuffle_enabled: bool,
    repeat_mode: RepeatMode,
}

fn playback_state_for_player(player: &crate::audio::AudioPlayer) -> PlaybackStateSnapshot {
    let (position, duration) = player.get_progress();
    let current_track_id = player.get_current_song_id();
    let queue = player.get_playback_queue();
    let volume = player.volume();
    let is_paused = player.is_paused();
    let is_empty = player.is_empty();
    let shuffle_enabled = player.shuffle_enabled();
    let repeat_mode = player.repeat_mode();

    let queue = queue
        .into_iter()
        .enumerate()
        .map(|(position, (track_id, _))| QueueItem {
            track_id,
            position: position as u64,
        })
        .collect();

    PlaybackStateSnapshot {
        current_track_id,
        position_seconds: position.as_secs_f64(),
        duration_seconds: duration.map(|duration| duration.as_secs_f64()),
        volume,
        is_playing: !is_paused && !is_empty,
        is_paused,
        queue,
        shuffle_enabled,
        repeat_mode,
    }
}

async fn playback_from_state(core: &DurvaldCore, state: PlaybackStateSnapshot) -> PlaybackSnapshot {
    let current_track = if let Some(id) = state.current_track_id {
        core.run_database(move |conn| {
            crate::database::operations::get_song_by_id(conn, &id.to_string())
                .map(|tracks| tracks.into_iter().next())
                .map_err(|error| error.to_string())
        })
        .await
        .ok()
        .flatten()
        .map(track_from_song)
    } else {
        None
    };

    PlaybackSnapshot {
        current_track,
        position_seconds: state.position_seconds,
        duration_seconds: state.duration_seconds,
        volume: state.volume,
        is_playing: state.is_playing,
        is_paused: state.is_paused,
        queue: state.queue,
        // Presentation queues always place the active track first. When
        // there is no active track, callers should use `current_track` to
        // determine that this sentinel position has no selected item.
        queue_position: 0,
        shuffle_enabled: state.shuffle_enabled,
        repeat_mode: state.repeat_mode,
    }
}

#[cfg_attr(feature = "uniffi", uniffi::export(async_runtime = "tokio"))]
impl DurvaldCore {
    /// Pauses playback.
    pub async fn pause(&self) -> CoreResult<()> {
        let mut player = self.audio_player.lock().await;
        player.pause();
        drop(player);
        self.pause_lastfm_playback().await;
        self.persist_playback_session().await?;
        Ok(())
    }

    /// Resumes playback.
    pub async fn resume(&self) -> CoreResult<()> {
        let _transition = self.playback_transition.lock().await;
        let restored_track = {
            let mut player = self.audio_player.lock().await;
            let restored_track = player.restored_track();
            if restored_track.is_none() {
                player.resume();
            }
            restored_track
        };
        if let Some((song_id, path, position)) = restored_track {
            let prepared = self.prepare_sound(path).await?;
            let mut player = self.audio_player.lock().await;
            player
                .play_song_prepared(song_id, prepared)
                .map_err(|e| CoreError::Playback {
                    message: e.to_string(),
                })?;
            if position > 0.0 {
                player
                    .seek_to_position(position as u64)
                    .await
                    .map_err(|e| CoreError::Playback {
                        message: e.to_string(),
                    })?;
            }
        }
        let current_track_id = self.audio_player.lock().await.get_current_song_id();
        drop(_transition);
        if let Some(track_id) = current_track_id {
            if self.is_tracking_lastfm_track(track_id).await {
                self.resume_lastfm_playback().await;
            } else {
                self.report_lastfm_track_started(track_id).await;
            }
        }
        self.persist_playback_session().await?;
        Ok(())
    }

    /// Stops playback.
    pub async fn stop(&self) -> CoreResult<()> {
        let _transition = self.playback_transition.lock().await;
        let mut player = self.audio_player.lock().await;
        player.stop();
        drop(player);
        drop(_transition);
        *self.lastfm_playback.lock().await = None;
        self.persist_playback_session().await?;
        Ok(())
    }

    /// Seeks to a position in seconds.
    pub async fn seek(&self, seconds: u64) -> CoreResult<()> {
        let mut player = self.audio_player.lock().await;
        player
            .seek_to_position(seconds)
            .await
            .map_err(|e| CoreError::Playback {
                message: e.to_string(),
            })?;
        drop(player);
        self.persist_session_progress(seconds as f64).await
    }

    /// Sets volume (0.0 - 1.0).
    pub async fn set_volume(&self, volume: f32) -> CoreResult<()> {
        if !volume.is_finite() {
            return Err(CoreError::InvalidInput {
                message: "Volume must be a finite number between 0.0 and 1.0".to_string(),
            });
        }
        let mut player = self.audio_player.lock().await;
        player.set_volume(volume.clamp(0.0, 1.0));
        let volume = player.volume() as f64;
        drop(player);
        self.persist_session_volume(volume).await?;
        Ok(())
    }

    /// Enables or disables randomized selection when advancing the queue.
    pub async fn set_shuffle_enabled(&self, enabled: bool) -> CoreResult<PlaybackSnapshot> {
        let _transition = self.playback_transition.lock().await;
        let mut player = self.audio_player.lock().await;
        player.set_shuffle_enabled(enabled);
        let playback_state = playback_state_for_player(&player);
        drop(player);
        drop(_transition);
        let snapshot = playback_from_state(self, playback_state).await;
        self.persist_playback_session().await?;
        Ok(snapshot)
    }

    /// Sets whether playback stops, repeats one track, or repeats the queue.
    pub async fn set_repeat_mode(&self, mode: RepeatMode) -> CoreResult<PlaybackSnapshot> {
        let _transition = self.playback_transition.lock().await;
        let mut player = self.audio_player.lock().await;
        player.set_repeat_mode(mode);
        let playback_state = playback_state_for_player(&player);
        drop(player);
        drop(_transition);
        let snapshot = playback_from_state(self, playback_state).await;
        self.persist_playback_session().await?;
        Ok(snapshot)
    }

    /// Returns Last.fm connection status.
    pub async fn lastfm_status(&self) -> CoreResult<LastFmStatus> {
        let connected = self.lastfm.is_connected().await;
        let username = if connected {
            self.lastfm.username().await.map_err(lastfm_error)?
        } else {
            None
        };
        Ok(LastFmStatus {
            connected,
            username,
        })
    }

    /// Stores Last.fm API credentials in the secure store.
    pub async fn configure_lastfm(&self, api_key: String, api_secret: String) -> CoreResult<()> {
        if api_key.trim().is_empty() || api_secret.trim().is_empty() {
            return Err(CoreError::InvalidInput {
                message: "Last.fm API key and secret cannot be empty".to_string(),
            });
        }
        self.lastfm
            .initialize_lastfm(api_key, api_secret)
            .await
            .map_err(lastfm_error)
    }

    /// Starts browser-based Last.fm authorization and returns its approval URL.
    pub async fn lastfm_auth_token(&self) -> CoreResult<AuthTokenResponse> {
        self.lastfm
            .get_auth_token()
            .await
            .map(|response| AuthTokenResponse {
                token: response.token,
                auth_url: response.auth_url,
            })
            .map_err(lastfm_error)
    }

    /// Completes Last.fm authorization after the user approved the token.
    pub async fn complete_lastfm_auth(&self, token: String) -> CoreResult<SessionResponse> {
        if token.trim().is_empty() {
            return Err(CoreError::InvalidInput {
                message: "Last.fm authorization token cannot be empty".to_string(),
            });
        }
        self.lastfm
            .poll_session(token)
            .await
            .map(|response| SessionResponse {
                username: response.username,
            })
            .map_err(lastfm_error)
    }

    /// Removes the locally stored Last.fm session and username.
    pub async fn disconnect_lastfm(&self) -> CoreResult<()> {
        self.lastfm.disconnect_lastfm().await.map_err(lastfm_error)
    }

    /// Returns the last session state.
    pub async fn last_session(&self) -> CoreResult<LastSession> {
        let session = self
            .run_database(|conn| {
                crate::database::operations::get_last_session(conn)
                    .map_err(|error| error.to_string())
            })
            .await?;

        Ok(LastSession {
            current_track_id: session.current_song_id,
            progress_seconds: session.progress_seconds,
            volume: normalized_volume(session.volume),
            shuffle_enabled: session.shuffle_enabled,
            repeat_mode: match session.repeat_mode.as_str() {
                "one" => RepeatMode::One,
                "all" => RepeatMode::All,
                _ => RepeatMode::None,
            },
            queue: serde_json::from_str(&session.queue_snapshot).unwrap_or_default(),
            queue_position: session.queue_position as u64,
            source_context: session.source_context,
            updated_at: session.updated_at,
        })
    }

    /// Returns completed playback events, newest-first as stored by the core.
    pub async fn playback_history(&self) -> CoreResult<Vec<PlaybackHistoryItem>> {
        self.run_database(|conn| {
            crate::database::operations::get_play_history(conn)
                .map(|history| history.into_iter().map(history_from_database).collect())
                .map_err(|error| error.to_string())
        })
        .await
    }

    /// Returns a bounded page of completed playback events, newest first.
    pub async fn playback_history_page(
        &self,
        page_size: u64,
        offset: u64,
    ) -> CoreResult<PlaybackHistoryPage> {
        let (fetch_size, page_size) = pagination_window(page_size, offset)?;
        let history = self
            .run_database(move |conn| {
                crate::database::operations::get_play_history_page(conn, fetch_size, offset)
                    .map_err(|error| error.to_string())
            })
            .await?
            .into_iter()
            .map(history_from_database)
            .collect();
        let (items, next_offset) = finish_page(history, page_size, offset);
        Ok(PlaybackHistoryPage { items, next_offset })
    }

    /// Removes a single completed-playback event.
    pub async fn remove_playback_history_item(&self, history_id: i64) -> CoreResult<()> {
        let history_id = non_negative_id(history_id, "Playback history ID")?;
        self.run_entity_update("Playback history item", history_id, move |conn| {
            crate::database::operations::remove_song_from_history(conn, history_id)
        })
        .await
    }

    /// Deletes every completed-playback event and returns the number removed.
    pub async fn clear_playback_history(&self) -> CoreResult<u64> {
        self.run_database(|conn| {
            crate::database::operations::clear_play_history(conn).map_err(|error| error.to_string())
        })
        .await
    }

    /// Saves the current session state.
    pub async fn save_session(&self, session: LastSession) -> CoreResult<()> {
        let db_session = crate::database::models::LastSession {
            current_song_id: session.current_track_id,
            progress_seconds: session.progress_seconds,
            volume: normalized_volume(session.volume as f64) as f64,
            shuffle_enabled: session.shuffle_enabled,
            repeat_mode: format!("{:?}", session.repeat_mode).to_lowercase(),
            queue_snapshot: serde_json::to_string(&session.queue).unwrap_or_default(),
            queue_position: session.queue_position as i64,
            source_context: session.source_context,
            updated_at: String::new(),
        };
        self.run_database(move |conn| {
            crate::database::operations::save_last_session(conn, &db_session)
                .map_err(|error| error.to_string())
        })
        .await
    }

    /// Returns application settings.
    pub async fn settings(&self) -> CoreResult<Settings> {
        let s = self
            .run_database(|conn| {
                crate::database::operations::get_settings(conn).map_err(|error| error.to_string())
            })
            .await?;

        Ok(Settings {
            cross_fade: s.cross_fade,
            cross_fade_duration: normalized_cross_fade_duration(s.cross_fade_duration),
            normalize_volume: s.normalize_volume,
            explicit_content: s.explicit_content,
            autoplay: s.autoplay,
            preferred_audio_quality: normalized_audio_quality(s.preferred_audio_quality),
            preferred_audio_source: s.preferred_audio_source,
            download_path: s.download_path,
            open_on_startup: s.open_on_startup,
            minimize_on_close: s.minimize_on_close,
            onboarding_complete: !s.onboarding,
        })
    }

    /// Updates application settings.
    pub async fn update_settings(&self, settings: Settings) -> CoreResult<()> {
        validate_settings(&settings)?;
        let database_settings = crate::database::models::Settings {
            settings_id: 1,
            cross_fade: settings.cross_fade,
            cross_fade_duration: settings.cross_fade_duration as i32,
            normalize_volume: settings.normalize_volume,
            explicit_content: settings.explicit_content,
            autoplay: settings.autoplay,
            preferred_audio_quality: settings.preferred_audio_quality as i32,
            preferred_audio_source: settings.preferred_audio_source,
            download_path: settings.download_path,
            open_on_startup: settings.open_on_startup,
            minimize_on_close: settings.minimize_on_close,
            onboarding: !settings.onboarding_complete,
        };
        let mut player = self.audio_player.lock().await;
        player.set_crossfade(settings.cross_fade, settings.cross_fade_duration);
        player.set_volume_normalization(settings.normalize_volume);
        drop(player);
        self.run_database(move |conn| {
            crate::database::operations::save_settings(conn, &database_settings)
                .map_err(|error| error.to_string())
        })
        .await
    }

    /// Adds a track to the playback queue.
    pub async fn add_to_queue(&self, track_id: i64) -> CoreResult<()> {
        non_negative_id(track_id, "Track ID")?;
        let track = self.track(track_id).await?;
        let _transition = self.playback_transition.lock().await;
        let starts_playback = self.audio_player.lock().await.should_start_queued_track();
        let prepared = if starts_playback {
            Some(self.prepare_sound(track.file_path.clone()).await?)
        } else {
            None
        };
        let mut player = self.audio_player.lock().await;
        if let Some(prepared) = prepared {
            player
                .play_song_prepared(track_id, prepared)
                .map_err(|e| CoreError::Playback {
                    message: e.to_string(),
                })?;
        } else {
            player.enqueue(track_id, track.file_path.clone());
        }

        drop(player);
        drop(_transition);
        self.persist_playback_session().await?;
        if starts_playback {
            self.report_lastfm_track_started(track_id).await;
        }

        Ok(())
    }

    /// Advances to the next queued track.
    pub async fn next_track(&self) -> CoreResult<PlaybackSnapshot> {
        let _transition = self.playback_transition.lock().await;
        let plan =
            self.audio_player
                .lock()
                .await
                .plan_next()
                .ok_or_else(|| CoreError::NotFound {
                    message: "No next track in the queue".to_string(),
                })?;
        let prepared = self.prepare_sound(plan.path().to_string()).await?;
        let (started_track_id, playback_state) = {
            let mut player = self.audio_player.lock().await;
            let started_track_id = plan.song_id();
            player
                .commit_plan(plan, prepared)
                .map_err(|e| CoreError::Playback {
                    message: e.to_string(),
                })?;
            (Some(started_track_id), playback_state_for_player(&player))
        };
        drop(_transition);
        let snapshot = playback_from_state(self, playback_state).await;
        self.persist_playback_session().await?;

        if let Some(track_id) = started_track_id {
            self.report_lastfm_track_started(track_id).await;
        }
        Ok(snapshot)
    }

    /// Returns to the previously played track, when one exists.
    pub async fn previous_track(&self) -> CoreResult<PlaybackSnapshot> {
        let _transition = self.playback_transition.lock().await;
        let plan = self
            .audio_player
            .lock()
            .await
            .plan_previous()
            .ok_or_else(|| CoreError::NotFound {
                message: "No previously played track".to_string(),
            })?;
        let prepared = self.prepare_sound(plan.path().to_string()).await?;
        let (started_track_id, playback_state) = {
            let mut player = self.audio_player.lock().await;
            let started_track_id = plan.song_id();
            player
                .commit_plan(plan, prepared)
                .map_err(|e| CoreError::Playback {
                    message: e.to_string(),
                })?;
            (Some(started_track_id), playback_state_for_player(&player))
        };
        drop(_transition);
        let snapshot = playback_from_state(self, playback_state).await;
        self.persist_playback_session().await?;

        if let Some(track_id) = started_track_id {
            self.report_lastfm_track_started(track_id).await;
        }
        Ok(snapshot)
    }

    /// Starts the upcoming track at the given queue position.
    pub async fn play_queue_item(&self, position: u64) -> CoreResult<PlaybackSnapshot> {
        let _transition = self.playback_transition.lock().await;
        let plan = {
            let player = self.audio_player.lock().await;
            let upcoming_position = if player.get_current_song_id().is_some() {
                position
                    .checked_sub(1)
                    .ok_or_else(|| CoreError::InvalidInput {
                        message: "The active track is already playing".to_string(),
                    })?
            } else {
                position
            };
            player
                .plan_skip(upcoming_position as usize)
                .map_err(|e| CoreError::InvalidInput {
                    message: e.to_string(),
                })?
        };
        let prepared = self.prepare_sound(plan.path().to_string()).await?;
        let (started_track_id, playback_state) = {
            let mut player = self.audio_player.lock().await;
            let started_track_id = plan.song_id();
            player
                .commit_plan(plan, prepared)
                .map_err(|e| CoreError::Playback {
                    message: e.to_string(),
                })?;
            (Some(started_track_id), playback_state_for_player(&player))
        };
        drop(_transition);
        let snapshot = playback_from_state(self, playback_state).await;
        self.persist_playback_session().await?;
        if let Some(track_id) = started_track_id {
            self.report_lastfm_track_started(track_id).await;
        }
        Ok(snapshot)
    }

    /// Removes an upcoming queue item.
    pub async fn remove_from_queue(&self, position: u64) -> CoreResult<()> {
        let _transition = self.playback_transition.lock().await;
        {
            let mut player = self.audio_player.lock().await;
            let upcoming_position = if player.get_current_song_id().is_some() {
                position
                    .checked_sub(1)
                    .ok_or_else(|| CoreError::InvalidInput {
                        message: "The active track cannot be removed from the queue".to_string(),
                    })?
            } else {
                position
            };
            player
                .remove_from_queue(upcoming_position as usize)
                .map_err(|e| CoreError::InvalidInput {
                    message: e.to_string(),
                })?;
        }
        drop(_transition);
        self.persist_playback_session().await
    }

    /// Moves an upcoming queue item to a new queue position.
    pub async fn move_queue_item(&self, from: u64, to: u64) -> CoreResult<()> {
        let _transition = self.playback_transition.lock().await;
        {
            let mut player = self.audio_player.lock().await;
            let (upcoming_from, upcoming_to) = if player.get_current_song_id().is_some() {
                (
                    from.checked_sub(1).ok_or_else(|| CoreError::InvalidInput {
                        message: "The active track cannot be moved".to_string(),
                    })?,
                    to.checked_sub(1).ok_or_else(|| CoreError::InvalidInput {
                        message: "The active track cannot be moved".to_string(),
                    })?,
                )
            } else {
                (from, to)
            };
            player
                .move_in_queue(upcoming_from as usize, upcoming_to as usize)
                .map_err(|e| CoreError::InvalidInput {
                    message: e.to_string(),
                })?;
        }
        drop(_transition);
        self.persist_playback_session().await
    }

    /// Clears every upcoming queue item while leaving the active track alone.
    pub async fn clear_queue(&self) -> CoreResult<()> {
        let _transition = self.playback_transition.lock().await;
        {
            let mut player = self.audio_player.lock().await;
            player.clear_queue();
        }
        drop(_transition);
        self.persist_playback_session().await
    }

    /// Returns the current queue.
    pub async fn queue(&self) -> CoreResult<Vec<QueueItem>> {
        let player = self.audio_player.lock().await;
        let queue = player.get_playback_queue();
        let mut items: Vec<QueueItem> = Vec::new();
        for (pos, (id, _)) in queue.iter().enumerate() {
            items.push(QueueItem {
                track_id: *id,
                position: pos as u64,
            });
        }
        Ok(items)
    }

    /// Gets a track by ID.
    pub async fn track(&self, track_id: i64) -> CoreResult<Track> {
        let track_id = non_negative_id(track_id, "Track ID")?;
        self.run_database_core(move |conn| {
            crate::database::operations::get_song_by_id(conn, &track_id.to_string())
                .map_err(|error| CoreError::Storage {
                    message: error.to_string(),
                })?
                .into_iter()
                .next()
                .map(track_from_song)
                .ok_or_else(|| CoreError::NotFound {
                    message: format!("Track {track_id} not found"),
                })
        })
        .await
    }

    /// Gets a release by ID.
    pub async fn release(&self, release_id: i64) -> CoreResult<Release> {
        let release_id = non_negative_id(release_id, "Release ID")?;
        self.run_database_core(move |conn| {
            crate::database::operations::get_release_by_id(conn, &release_id.to_string())
                .map(release_from_database)
                .map_err(|error| lookup_error(error, "Release", release_id))
        })
        .await
    }

    /// Gets tracks for a release.
    pub async fn release_tracks(&self, release_id: i64) -> CoreResult<Vec<Track>> {
        let release_id = non_negative_id(release_id, "Release ID")?;
        self.run_database(move |conn| {
            crate::database::operations::get_songs_by_release_id(conn, &release_id.to_string())
                .map(|tracks| tracks.into_iter().map(track_from_song).collect())
                .map_err(|error| error.to_string())
        })
        .await
    }

    /// Extracts metadata from an audio file (for preview/import).
    pub async fn extract_metadata(&self, file_path: String) -> CoreResult<AudioMetadata> {
        let covers_dir = std::path::PathBuf::from(&self.covers_dir);
        let meta = Self::run_blocking("Metadata extraction", move || {
            crate::metadata::extract_metadata_blocking(&file_path, &covers_dir).map_err(|error| {
                CoreError::Storage {
                    message: error.to_string(),
                }
            })
        })
        .await?;
        Ok(metadata_to_api(meta))
    }
}

/// Opens a new core engine. Exported to FFI as the factory for `DurvaldCore` handles.
#[cfg(feature = "uniffi")]
#[uniffi::export(async_runtime = "tokio")]
pub async fn open(config: CoreConfig) -> CoreResult<Arc<DurvaldCore>> {
    DurvaldCore::open(config).await
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temporary_directory(label: &str) -> std::path::PathBuf {
        std::env::temp_dir().join(format!(
            "durvald-{label}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("current time")
                .as_nanos()
        ))
    }

    fn wav_fixture() -> Vec<u8> {
        let sample_rate = 8_000u32;
        let data_len = sample_rate * 2; // mono, 16-bit, one second
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

    fn settings() -> Settings {
        Settings {
            cross_fade: true,
            cross_fade_duration: 5,
            normalize_volume: true,
            explicit_content: true,
            autoplay: true,
            preferred_audio_quality: 320,
            preferred_audio_source: "local".to_string(),
            download_path: String::new(),
            open_on_startup: false,
            minimize_on_close: false,
            onboarding_complete: false,
        }
    }

    #[tokio::test]
    async fn core_opens_with_mock_audio_and_persists_settings() {
        let directory = temporary_directory("core-lifecycle-test");
        let config = CoreConfig::new(
            directory.to_string_lossy().into_owned(),
            format!("durvald-core-test-{}", std::process::id()),
        );
        let core = DurvaldCore::open_with_mock_audio(config.clone())
            .await
            .expect("open core with mock audio");

        assert!(std::path::Path::new(&config.database_path).is_file());
        assert!(std::path::Path::new(&config.covers_dir).is_dir());
        assert!(
            !std::path::Path::new(&config.covers_dir)
                .join(".thumbs_done")
                .exists()
        );
        assert_eq!(
            core.last_session()
                .await
                .expect("read initial session")
                .volume,
            0.5
        );

        let mut updated = core.settings().await.expect("read default settings");
        updated.autoplay = false;
        updated.preferred_audio_source = "local".to_string();
        core.update_settings(updated.clone())
            .await
            .expect("persist settings");
        assert_eq!(
            core.settings().await.expect("read persisted settings"),
            updated
        );

        let music_directory = directory.join("music");
        std::fs::create_dir_all(&music_directory).expect("create music directory");
        std::fs::write(music_directory.join("tone.wav"), wav_fixture())
            .expect("write test audio file");
        let scan = core
            .scan_library(vec![music_directory.to_string_lossy().into_owned()])
            .await
            .expect("scan test library");
        assert_eq!(scan.new_tracks_added, 1);
        let tracks = core.tracks().await.expect("read scanned tracks");
        assert_eq!(tracks.len(), 1);

        drop(core);
        tokio::time::sleep(std::time::Duration::from_millis(25)).await;
        std::fs::remove_dir_all(directory).expect("remove temporary core directory");
    }

    #[tokio::test]
    async fn completed_playback_advances_the_queue_and_records_history() {
        let directory = temporary_directory("completion-lifecycle-test");
        let config = CoreConfig::new(
            directory.to_string_lossy().into_owned(),
            format!("durvald-completion-test-{}", std::process::id()),
        );
        let core = DurvaldCore::open_with_mock_audio(config).await.unwrap();
        let music_directory = directory.join("music");
        std::fs::create_dir_all(&music_directory).unwrap();
        std::fs::write(music_directory.join("first.wav"), wav_fixture()).unwrap();
        std::fs::write(music_directory.join("second.wav"), wav_fixture()).unwrap();
        core.scan_library(vec![music_directory.to_string_lossy().into_owned()])
            .await
            .unwrap();
        let tracks = core.tracks().await.unwrap();
        assert_eq!(tracks.len(), 2);
        core.add_to_queue(tracks[0].id).await.unwrap();
        core.add_to_queue(tracks[1].id).await.unwrap();

        {
            let mut player = core.audio_player.lock().await;
            player.process_mock_audio(80);
        }
        tokio::time::sleep(std::time::Duration::from_millis(650)).await;

        let history = core.playback_history().await.unwrap();
        assert_eq!(history.len(), 1);
        assert_eq!(history[0].track_id, tracks[0].id);
        let player = core.audio_player.lock().await;
        assert_eq!(player.get_current_song_id(), Some(tracks[1].id));
        drop(player);

        drop(core);
        tokio::time::sleep(std::time::Duration::from_millis(25)).await;
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[tokio::test]
    async fn repeated_track_completion_records_each_listen() {
        let directory = temporary_directory("repeat-history-test");
        let config = CoreConfig::new(
            directory.to_string_lossy().into_owned(),
            format!("durvald-repeat-history-test-{}", std::process::id()),
        );
        let core = DurvaldCore::open_with_mock_audio(config).await.unwrap();
        let music_directory = directory.join("music");
        std::fs::create_dir_all(&music_directory).unwrap();
        std::fs::write(music_directory.join("loop.wav"), wav_fixture()).unwrap();
        core.scan_library(vec![music_directory.to_string_lossy().into_owned()])
            .await
            .unwrap();
        let track_id = core.tracks().await.unwrap()[0].id;
        core.add_to_queue(track_id).await.unwrap();
        core.set_repeat_mode(RepeatMode::One).await.unwrap();

        {
            let mut player = core.audio_player.lock().await;
            player.process_mock_audio(80);
        }
        tokio::time::sleep(std::time::Duration::from_millis(650)).await;

        let history = core.playback_history().await.unwrap();
        assert_eq!(history.len(), 1);
        assert_eq!(history[0].track_id, track_id);
        let player = core.audio_player.lock().await;
        assert_eq!(player.get_current_song_id(), Some(track_id));
        drop(player);

        drop(core);
        tokio::time::sleep(std::time::Duration::from_millis(25)).await;
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn settings_validation_rejects_out_of_range_and_unsafe_values() {
        let mut invalid = settings();
        invalid.cross_fade_duration = 61;
        assert!(validate_settings(&invalid).is_err());

        invalid = settings();
        invalid.preferred_audio_quality = 0;
        assert!(validate_settings(&invalid).is_err());

        invalid = settings();
        invalid.preferred_audio_source = "local\nremote".to_string();
        assert!(validate_settings(&invalid).is_err());
    }

    #[test]
    fn persisted_settings_values_are_sanitized_before_ffi_conversion() {
        assert_eq!(normalized_cross_fade_duration(-1), 0);
        assert_eq!(normalized_cross_fade_duration(120), 60);
        assert_eq!(normalized_audio_quality(-1), 320);
        assert_eq!(normalized_audio_quality(0), 320);
        assert_eq!(normalized_audio_quality(320), 320);
        assert_eq!(normalized_audio_quality(2_000), 320);
    }

    #[test]
    fn volume_normalization_rejects_non_finite_persisted_values() {
        assert_eq!(normalized_volume(f64::NAN), 0.5);
        assert_eq!(normalized_volume(f64::INFINITY), 0.5);
        assert_eq!(normalized_volume(50.0), 0.5);
        assert_eq!(normalized_volume(-1.0), 0.0);
    }

    #[test]
    fn identifier_validation_rejects_negative_values() {
        assert!(matches!(
            non_negative_id(-1, "Track ID"),
            Err(CoreError::InvalidInput { .. })
        ));
        assert_eq!(non_negative_id(0, "Track ID").unwrap(), 0);
    }

    #[test]
    fn pagination_is_bounded_and_reports_the_next_offset() {
        let (fetch_size, page_size) = pagination_window(1_000, 0).unwrap();
        assert_eq!(fetch_size, MAX_LIBRARY_PAGE_SIZE + 1);
        assert_eq!(page_size, MAX_LIBRARY_PAGE_SIZE as usize);

        let (items, next_offset) = finish_page(
            (0..=MAX_LIBRARY_PAGE_SIZE).collect::<Vec<_>>(),
            page_size,
            40,
        );
        assert_eq!(items.len(), MAX_LIBRARY_PAGE_SIZE as usize);
        assert_eq!(next_offset, Some(40 + MAX_LIBRARY_PAGE_SIZE));

        let (items, next_offset) = finish_page(vec![1, 2], 10, 20);
        assert_eq!(items, vec![1, 2]);
        assert_eq!(next_offset, None);
        assert!(pagination_window(0, 0).is_err());
        assert!(pagination_window(10, i64::MAX as u64 + 1).is_err());
    }

    #[test]
    fn scrobbling_requires_a_meaningful_amount_of_playback() {
        assert!(!scrobble_eligible(29, 29));
        assert!(!scrobble_eligible(180, 89));
        assert!(scrobble_eligible(180, 90));
        assert!(!scrobble_eligible(1_000, 239));
        assert!(scrobble_eligible(1_000, 240));
    }

    #[test]
    fn artwork_paths_must_be_contained_by_the_covers_directory() {
        let directory = std::env::temp_dir().join(format!(
            "durvald-artwork-path-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let covers_dir = directory.join("covers");
        std::fs::create_dir_all(&covers_dir).unwrap();
        let inside = covers_dir.join("cover.jpg");
        let outside = directory.join("outside.jpg");
        std::fs::write(&inside, [1, 2, 3]).unwrap();
        std::fs::write(&outside, [4, 5, 6]).unwrap();

        assert_eq!(
            artwork_path_in_covers_dir(&covers_dir.to_string_lossy(), &inside.to_string_lossy(),)
                .unwrap(),
            Some(std::fs::canonicalize(&inside).unwrap())
        );
        assert!(matches!(
            artwork_path_in_covers_dir(&covers_dir.to_string_lossy(), &outside.to_string_lossy(),),
            Err(CoreError::InvalidInput { .. })
        ));

        std::fs::remove_dir_all(directory).unwrap();
    }
}
