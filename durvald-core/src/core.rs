//! durvald-core: Core business logic for the durvald music player.
//! 
//! This crate contains all domain logic without any Tauri dependencies.
//! The public API is defined in the `api` module and exposed through
//! the `DurvaldCore` facade in the `core` module.

use crate::api::*;
use crate::audio::AudioPlayer;
use crate::database::models::FileInfo as CoreFileInfo;
use crate::database::operations::*;
use crate::lastfm::LastFmClient;
use crate::secure_store::SecureStore;
use std::path::PathBuf;
use std::sync::Arc;
use base64::Engine;

/// Opaque core engine - the main entry point for all operations.
///
/// Internally owns the database pool, audio player, secure storage,
/// and Last.fm client. All state is encapsulated here.
#[cfg_attr(feature = "uniffi", derive(uniffi::Object))]
pub struct DurvaldCore {
    db_pool: Arc<r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>>,
    audio_player: Arc<tokio::sync::Mutex<crate::audio::AudioPlayer>>,
    secure_store: Arc<tokio::sync::Mutex<SecureStore>>,
    lastfm: Arc<LastFmClient>,
    covers_dir: String,
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
}

/// Type alias for the core handle used in UniFFI
/// This is an opaque pointer that UniFFI can work with
pub type DurvaldCoreHandle = Arc<DurvaldCore>;

impl DurvaldCore {
    /// Creates a new core engine with the given configuration.
    /// Initializes database, audio, storage, and services.
    pub async fn open(config: CoreConfig) -> CoreResult<Arc<Self>> {
        // Create directories
        std::fs::create_dir_all(&config.app_support_dir)
            .map_err(|e| CoreError::Storage { message: e.to_string() })?;
        std::fs::create_dir_all(&config.covers_dir)
            .map_err(|e| CoreError::Storage { message: e.to_string() })?;

        // Initialize database
        let manager = r2d2_sqlite::SqliteConnectionManager::file(&config.database_path).with_init(|conn: &mut rusqlite::Connection| {
            let _ = conn.execute_batch(
                "PRAGMA journal_mode = WAL;\n PRAGMA busy_timeout = 5000;\n PRAGMA foreign_keys = ON;",
            );
            Ok(())
        });
        let pool = r2d2::Pool::new(manager)
            .map_err(|e| CoreError::Storage { message: e.to_string() })?;

        // Create tables
        let conn = pool.get().map_err(|e| CoreError::Storage { message: e.to_string() })?;
        crate::database::operations::create_tables(&conn)
            .map_err(|e| CoreError::Storage { message: e.to_string() })?;
        crate::database::operations::initiate_settings(&conn)
            .map_err(|e| CoreError::Storage { message: e.to_string() })?;
        crate::database::operations::initiate_last_session(&conn)
            .map_err(|e| CoreError::Storage { message: e.to_string() })?;

        // Initialize audio player
        let audio_player = crate::audio::AudioPlayer::new()
            .map_err(|e| CoreError::Playback { message: e.to_string() })?;

        // Initialize secure store
        let secure_store = SecureStore::new(config.app_support_dir.clone().into(), config.keychain_service.clone())
            .map_err(|e| CoreError::Storage { message: e.to_string() })?;

        // Initialize Last.fm client (clones the secure store)
        let lastfm = LastFmClient::new(Arc::new(tokio::sync::Mutex::new(secure_store.clone())));

        let core = Self {
            db_pool: Arc::new(pool),
            audio_player: Arc::new(tokio::sync::Mutex::new(audio_player)),
            secure_store: Arc::new(tokio::sync::Mutex::new(secure_store)),
            lastfm: Arc::new(lastfm),
            covers_dir: config.covers_dir.clone(),
        };

        let core = Arc::new(core);

        // Migrate covers in background
        let core_clone = core.clone();
        tokio::spawn(async move {
            let conn = core_clone.db_pool.get().ok();
            if let Some(conn) = conn {
                let covers_dir = std::path::PathBuf::from(&core_clone.covers_dir);
                let _ = crate::database::operations::migrate_covers(&conn, &covers_dir);
            }
        });

        Ok(core)
    }

    /// Scans the library at the given paths.
    pub async fn scan_library(&self, paths: Vec<String>) -> CoreResult<ScanResult> {
        let mut total_files: u64 = 0;
        let mut new_tracks: u64 = 0;
        let mut updated_tracks: u64 = 0;
        let mut errors = Vec::new();

        for path in &paths {
            let conn = self.db_pool.get().map_err(|e| CoreError::Storage { message: e.to_string() })?;
            let result = crate::database::operations::update_database(
                &conn,
                path.clone(),
                &std::path::PathBuf::from(&self.covers_dir),
            ).await;

            match result {
                Ok((new_count, total)) => {
                    total_files += total as u64;
                    new_tracks += new_count as u64;
                    // We can't easily get updated count from current API
                }
                Err(e) => errors.push(format!("{}: {}", path, e)),
            }
        }

        Ok(ScanResult {
            paths_scanned: paths.len() as u64,
            total_files_found: total_files,
            new_tracks_added: new_tracks,
            updated_tracks,
            errors,
        })
    }

    /// Returns all tracks in the library.
    pub fn tracks(&self) -> CoreResult<Vec<Track>> {
        let conn = self.db_pool.get().map_err(|e| CoreError::Storage { message: e.to_string() })?;
        let db_tracks = crate::database::operations::get_all_tracks(&conn)
            .map_err(|e| CoreError::Storage { message: e.to_string() })?;

        Ok(db_tracks.into_iter().map(|t| Track {
            id: t.song_id as i64,
            title: t.title,
            artist: t.artist_name,
            artist_id: t.artist_id as i64,
            release: t.release_title,
            release_id: t.release_id as i64,
            track_number: t.track_number,
            disc_number: t.disc_number,
            duration_seconds: t.duration as f64,
            file_path: t.file_path,
            artwork_id: if t.artwork.is_empty() { None } else { Some(t.artwork) },
            bitrate: t.bitrate.map(|b| b as u32),
            sample_rate: t.sample_rate.map(|s| s as u32),
            play_count: t.play_count,
            last_played: t.last_played,
            rating: t.rating,
            is_favorite: t.is_favorite,
            is_hidden: t.is_hidden,
            suggest_less: t.suggest_less,
        }).collect())
    }

    /// Returns all releases in the library.
    pub fn releases(&self) -> CoreResult<Vec<Release>> {
        let conn = self.db_pool.get().map_err(|e| CoreError::Storage { message: e.to_string() })?;
        let db_releases = crate::database::operations::get_all_releases(&conn)
            .map_err(|e| CoreError::Storage { message: e.to_string() })?;

        Ok(db_releases.into_iter().map(|r| Release {
            id: r.release_id as i64,
            title: r.title,
            artist: r.artist_name,
            artist_id: r.artist_id as i64,
            release_date: Some(r.release_date),
            total_tracks: r.total_tracks,
            total_discs: r.total_discs,
            duration_seconds: r.duration,
            artwork_id: Some(r.artwork),
            is_favorite: r.is_favorite,
            is_hidden: r.is_hidden,
            suggest_less: r.suggest_less,
            rating: r.rating,
        }).collect())
    }

    /// Returns all artists in the library.
    pub fn artists(&self) -> CoreResult<Vec<Artist>> {
        let conn = self.db_pool.get().map_err(|e| CoreError::Storage { message: e.to_string() })?;
        let db_artists = crate::database::operations::get_all_artists(&conn)
            .map_err(|e| CoreError::Storage { message: e.to_string() })?;

        Ok(db_artists.into_iter().map(|a| Artist {
            id: a.artist_id as i64,
            name: a.artist_name,
        }).collect())
    }

    /// Returns all playlists.
    pub fn playlists(&self) -> CoreResult<Vec<Playlist>> {
        let conn = self.db_pool.get().map_err(|e| CoreError::Storage { message: e.to_string() })?;
        let db_playlists = crate::database::operations::get_all_playlists(&conn)
            .map_err(|e| CoreError::Storage { message: e.to_string() })?;

        Ok(db_playlists.into_iter().map(|p| Playlist {
            id: p.id as i64,
            name: p.name,
            description: p.description,
            artwork_id: p.cover.map(|c| base64::engine::general_purpose::STANDARD.encode(c)),
            is_favorite: p.is_favorite,
            suggest_less: p.suggest_less,
            track_count: 0, // Would need separate query
            created_at: p.created_at,
            updated_at: p.updated_at,
        }).collect())
    }

    /// Starts playback of a track.
    pub async fn play(&self, track_id: i64) -> CoreResult<PlaybackSnapshot> {
        // Get track info
        let conn = self.db_pool.get().map_err(|e| CoreError::Storage { message: e.to_string() })?;
        let tracks = crate::database::operations::get_song_by_id(&conn, &track_id.to_string())
            .map_err(|e| CoreError::Storage { message: e.to_string() })?;
        
        let track = tracks.into_iter().next()
            .ok_or_else(|| CoreError::NotFound { message: format!("Track {} not found", track_id) })?;

        // Play the track
        let mut player = self.audio_player.lock().await;
        player.play(track.file_path.clone()).await
            .map_err(|e| CoreError::Playback { message: e.to_string() })?;

        // Add to queue if not already playing
        if player.is_empty() || player.queue_is_empty() {
            // Already playing
        } else {
            player.add_to_queue(track_id, track.file_path.clone()).await
                .map_err(|e| CoreError::Playback { message: e.to_string() })?;
        }

        // Save to DB
        let queue_data = player.get_queue_data_for_db();
        let db_pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            if let Ok(mut conn) = db_pool.get() {
                let _ = crate::audio::AudioPlayer::save_queue_to_db_blocking(&mut *conn, &queue_data);
            }
        });

        Ok(self.playback())
    }

    /// Returns the current playback state.
    pub fn playback(&self) -> PlaybackSnapshot {
        // Release the lock before creating the snapshot to avoid deadlock
        let player = self.audio_player.blocking_lock();
        let (position, duration) = player.get_progress();
        let current_track_id = player.get_current_song_id();
        let queue = player.get_queue();
        let volume = player.volume();
        let is_paused = player.is_paused();
        let is_empty = player.is_empty();
        
        // Drop the lock before doing any DB queries
        drop(player);
        
        let current_track = if let Some(id) = current_track_id {
            let conn = self.db_pool.get().ok();
            conn.and_then(|c| crate::database::operations::get_song_by_id(&c, &id.to_string()).ok())
                .and_then(|t| t.into_iter().next())
                .map(|t| Track {
                    id: t.song_id as i64,
                    title: t.title,
                    artist: t.artist_name,
                    artist_id: t.artist_id as i64,
                    release: t.release_title,
                    release_id: t.release_id as i64,
                    track_number: t.track_number,
                    disc_number: t.disc_number,
                    duration_seconds: t.duration as f64,
                    file_path: t.file_path,
                    artwork_id: Some(t.artwork),
                    bitrate: t.bitrate.map(|b| b as u32),
                    sample_rate: t.sample_rate.map(|s| s as u32),
                    play_count: t.play_count,
                    last_played: t.last_played,
                    rating: t.rating,
                    is_favorite: t.is_favorite,
                    is_hidden: t.is_hidden,
                    suggest_less: t.suggest_less,
                })
        } else {
            None
        };

        // Get queue with proper positions
        let mut queue_items: Vec<QueueItem> = Vec::new();
        for (pos, (id, _)) in queue.iter().enumerate() {
            queue_items.push(QueueItem { track_id: *id, position: pos as u64 });
        }

        PlaybackSnapshot {
            current_track,
            position_seconds: position.as_secs_f64(),
            duration_seconds: duration.map(|d| d.as_secs_f64()),
            volume,
            is_playing: !is_paused && !is_empty,
            is_paused,
            queue: queue_items,
            queue_position: 0,
            shuffle_enabled: false,
            repeat_mode: RepeatMode::None,
        }
    }

    /// Pauses playback.
    pub fn pause(&self) -> CoreResult<()> {
        let mut player = self.audio_player.blocking_lock();
        player.pause();
        Ok(())
    }

    /// Resumes playback.
    pub fn resume(&self) -> CoreResult<()> {
        let mut player = self.audio_player.blocking_lock();
        player.resume();
        Ok(())
    }

    /// Stops playback.
    pub fn stop(&self) -> CoreResult<()> {
        let mut player = self.audio_player.blocking_lock();
        player.stop();
        Ok(())
    }

    /// Seeks to a position in seconds.
    pub async fn seek(&self, seconds: u64) -> CoreResult<()> {
        let mut player = self.audio_player.lock().await;
        player.seek_to_position(seconds).await
            .map_err(|e| CoreError::Playback { message: e.to_string() })
    }

    /// Sets volume (0.0 - 1.0).
    pub fn set_volume(&self, volume: f32) -> CoreResult<()> {
        let mut player = self.audio_player.blocking_lock();
        player.set_volume(volume.clamp(0.0, 1.0));
        Ok(())
    }

    /// Returns Last.fm connection status.
    pub async fn lastfm_status(&self) -> CoreResult<LastFmStatus> {
        let connected = self.lastfm.is_connected().await;
        // Would need to get username from secure store
        Ok(LastFmStatus { connected, username: None })
    }

    /// Returns the last session state.
    pub fn last_session(&self) -> CoreResult<LastSession> {
        let conn = self.db_pool.get().map_err(|e| CoreError::Storage { message: e.to_string() })?;
        let session = crate::database::operations::get_last_session(&conn)
            .map_err(|e| CoreError::Storage { message: e.to_string() })?;
        
        Ok(LastSession {
            current_track_id: session.current_song_id,
            progress_seconds: session.progress_seconds,
            volume: session.volume as f32,
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

    /// Saves the current session state.
    pub fn save_session(&self, session: LastSession) -> CoreResult<()> {
        let conn = self.db_pool.get().map_err(|e| CoreError::Storage { message: e.to_string() })?;
        
        crate::database::operations::save_last_session(
            &conn,
            session.current_track_id,
            session.progress_seconds,
            session.volume as f64,
            session.shuffle_enabled,
            format!("{:?}", session.repeat_mode).to_lowercase(),
            serde_json::to_string(&session.queue).unwrap_or_default(),
            session.queue_position as i64,
            session.source_context,
        ).map_err(|e| CoreError::Storage { message: e.to_string() })
    }

    /// Returns application settings.
    pub fn settings(&self) -> CoreResult<Settings> {
        let conn = self.db_pool.get().map_err(|e| CoreError::Storage { message: e.to_string() })?;
        let s = crate::database::operations::get_settings(&conn)
            .map_err(|e| CoreError::Storage { message: e.to_string() })?;

        Ok(Settings {
            cross_fade: s.cross_fade,
            cross_fade_duration: s.cross_fade_duration as u32,
            normalize_volume: s.normalize_volume,
            explicit_content: s.explicit_content,
            autoplay: s.autoplay,
            preferred_audio_quality: s.preferred_audio_quality as u32,
            preferred_audio_source: s.preferrend_audio_source,
            download_path: s.download_path,
            open_on_startup: s.open_on_startup,
            minimize_on_close: s.minimize_on_close,
            onboarding_complete: !s.onboarding,
        })
    }

    /// Updates application settings.
    pub fn update_settings(&self, settings: Settings) -> CoreResult<()> {
        let conn = self.db_pool.get().map_err(|e| CoreError::Storage { message: e.to_string() })?;
        
        // Update each setting - this is a simplified implementation
        // Real implementation would need bulk update or individual updates
        let _ = conn.execute(
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
            rusqlite::params![
                settings.cross_fade as i64,
                settings.cross_fade_duration as i64,
                settings.normalize_volume as i64,
                settings.explicit_content as i64,
                settings.autoplay as i64,
                settings.preferred_audio_quality as i64,
                settings.preferred_audio_source,
                settings.download_path,
                settings.open_on_startup as i64,
                settings.minimize_on_close as i64,
                (!settings.onboarding_complete) as i64,
            ]
        ).map_err(|e| CoreError::Storage { message: e.to_string() })?;
        
        Ok(())
    }

    /// Adds a track to the playback queue.
    pub async fn add_to_queue(&self, track_id: i64) -> CoreResult<()> {
        let conn = self.db_pool.get().map_err(|e| CoreError::Storage { message: e.to_string() })?;
        let tracks = crate::database::operations::get_song_by_id(&conn, &track_id.to_string())
            .map_err(|e| CoreError::Storage { message: e.to_string() })?;
        
        let track = tracks.into_iter().next()
            .ok_or_else(|| CoreError::NotFound { message: format!("Track {} not found", track_id) })?;

        let mut player = self.audio_player.lock().await;
        player.add_to_queue(track_id, track.file_path.clone()).await
            .map_err(|e| CoreError::Playback { message: e.to_string() })?;

        let queue_data = player.get_queue_data_for_db();
        let db_pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            if let Ok(mut conn) = db_pool.get() {
                let _ = crate::audio::AudioPlayer::save_queue_to_db_blocking(&mut *conn, &queue_data);
            }
        });

        Ok(())
    }

    /// Returns the current queue.
    pub fn queue(&self) -> CoreResult<Vec<QueueItem>> {
        let player = self.audio_player.blocking_lock();
        let queue = player.get_queue();
        let mut items: Vec<QueueItem> = Vec::new();
        for (pos, (id, _)) in queue.iter().enumerate() {
            items.push(QueueItem { track_id: *id, position: pos as u64 });
        }
        Ok(items)
    }

    /// Gets a track by ID.
    pub fn track(&self, track_id: i64) -> CoreResult<Track> {
        let conn = self.db_pool.get().map_err(|e| CoreError::Storage { message: e.to_string() })?;
        let tracks = crate::database::operations::get_song_by_id(&conn, &track_id.to_string())
            .map_err(|e| CoreError::Storage { message: e.to_string() })?;

        tracks.into_iter().next()
            .map(|t| Track {
                id: t.song_id as i64,
                title: t.title,
                artist: t.artist_name,
                artist_id: t.artist_id as i64,
                release: t.release_title,
                release_id: t.release_id as i64,
                track_number: t.track_number,
                disc_number: t.disc_number,
                duration_seconds: t.duration as f64,
                file_path: t.file_path,
                artwork_id: if t.artwork.is_empty() { None } else { Some(t.artwork) },
                bitrate: t.bitrate.map(|b| b as u32),
                sample_rate: t.sample_rate.map(|s| s as u32),
                play_count: t.play_count,
                last_played: t.last_played,
                rating: t.rating,
                is_favorite: t.is_favorite,
                is_hidden: t.is_hidden,
                suggest_less: t.suggest_less,
            })
            .ok_or_else(|| CoreError::NotFound { message: format!("Track {} not found", track_id) })
    }

    /// Gets a release by ID.
    pub fn release(&self, release_id: i64) -> CoreResult<Release> {
        let conn = self.db_pool.get().map_err(|e| CoreError::Storage { message: e.to_string() })?;
        let r = crate::database::operations::get_release_by_id(&conn, &release_id.to_string())
            .map_err(|e| CoreError::Storage { message: e.to_string() })?;

        Ok(Release {
            id: r.release_id as i64,
            title: r.title,
            artist: r.artist_name,
            artist_id: r.artist_id as i64,
            release_date: Some(r.release_date),
            total_tracks: r.total_tracks,
            total_discs: r.total_discs,
            duration_seconds: r.duration,
            artwork_id: Some(r.artwork),
            is_favorite: r.is_favorite,
            is_hidden: r.is_hidden,
            suggest_less: r.suggest_less,
            rating: r.rating,
        })
    }

    /// Gets tracks for a release.
    pub fn release_tracks(&self, release_id: i64) -> CoreResult<Vec<Track>> {
        let conn = self.db_pool.get().map_err(|e| CoreError::Storage { message: e.to_string() })?;
        let db_tracks = crate::database::operations::get_songs_by_release_id(&conn, &release_id.to_string())
            .map_err(|e| CoreError::Storage { message: e.to_string() })?;

        Ok(db_tracks.into_iter().map(|t| Track {
            id: t.song_id as i64,
            title: t.title,
            artist: t.artist_name,
            artist_id: t.artist_id as i64,
            release: t.release_title,
            release_id: t.release_id as i64,
            track_number: t.track_number,
            disc_number: t.disc_number,
            duration_seconds: t.duration as f64,
            file_path: t.file_path,
            artwork_id: if t.artwork.is_empty() { None } else { Some(t.artwork) },
            bitrate: t.bitrate.map(|b| b as u32),
            sample_rate: t.sample_rate.map(|s| s as u32),
            play_count: t.play_count,
            last_played: t.last_played,
            rating: t.rating,
            is_favorite: t.is_favorite,
            is_hidden: t.is_hidden,
            suggest_less: t.suggest_less,
        }).collect())
    }

    }