//! Playback use-case coordination.
//!
//! Responsibilities move here incrementally while [`crate::core::DurvaldCore`]
//! remains the stable public facade.

use std::sync::Arc;

use crate::{
    api::{CoreError, CoreResult, PlaybackSnapshot, QueueItem, Track},
    audio::AudioPlayer,
    lastfm::LastFmClient,
};

type DatabasePool = r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>;

pub(crate) struct LastFmPlayback {
    pub(crate) track_id: i64,
    pub(crate) artist: String,
    pub(crate) title: String,
    pub(crate) release: String,
    pub(crate) duration_seconds: u64,
    pub(crate) started_at: u64,
    pub(crate) active_since: Option<u64>,
    pub(crate) played_seconds: u64,
}

/// Coordinates playback use cases behind the public core facade.
///
/// The concrete collaborators remain in use during the first extraction. Ports
/// are introduced only if later application boundaries require them.
#[allow(dead_code)]
pub(crate) struct PlaybackApplication {
    db_pool: Arc<DatabasePool>,
    audio_player: Arc<tokio::sync::Mutex<AudioPlayer>>,
    playback_transition: tokio::sync::Mutex<()>,
    lastfm: Arc<LastFmClient>,
    lastfm_playback: tokio::sync::Mutex<Option<LastFmPlayback>>,
}

impl PlaybackApplication {
    pub(crate) fn new(
        db_pool: Arc<DatabasePool>,
        audio_player: AudioPlayer,
        lastfm: Arc<LastFmClient>,
    ) -> Self {
        Self {
            db_pool,
            audio_player: Arc::new(tokio::sync::Mutex::new(audio_player)),
            playback_transition: tokio::sync::Mutex::new(()),
            lastfm,
            lastfm_playback: tokio::sync::Mutex::new(None),
        }
    }

    pub(crate) fn audio_player(&self) -> &Arc<tokio::sync::Mutex<AudioPlayer>> {
        &self.audio_player
    }

    pub(crate) fn playback_transition(&self) -> &tokio::sync::Mutex<()> {
        &self.playback_transition
    }

    pub(crate) fn lastfm_playback(&self) -> &tokio::sync::Mutex<Option<LastFmPlayback>> {
        &self.lastfm_playback
    }

    pub(crate) async fn play(&self, track_id: i64) -> CoreResult<PlaybackSnapshot> {
        if track_id < 0 {
            return Err(CoreError::InvalidInput {
                message: "Track ID must not be negative".to_string(),
            });
        }
        let db_pool = self.db_pool.clone();
        let track = tokio::task::spawn_blocking(move || {
            let conn = db_pool.get().map_err(|error| CoreError::Storage {
                message: error.to_string(),
            })?;
            crate::database::operations::get_song_by_id(&conn, &track_id.to_string())
                .map_err(|error| CoreError::Storage {
                    message: error.to_string(),
                })?
                .into_iter()
                .next()
                .ok_or_else(|| CoreError::NotFound {
                    message: format!("Track {track_id} not found"),
                })
        })
        .await
        .map_err(|error| CoreError::Storage {
            message: format!("Blocking database task failed: {error}"),
        })??;

        let _transition = self.playback_transition.lock().await;
        let prepared = self.prepare_sound(track.file_path).await?;
        let state = {
            let mut player = self.audio_player.lock().await;
            player
                .play_song_prepared(track_id, prepared)
                .map_err(|error| CoreError::Playback {
                    message: error.to_string(),
                })?;
            PlaybackStateSnapshot::from_player(&player)
        };
        drop(_transition);

        let snapshot = self.snapshot_from_state(state).await;
        self.persist_session().await?;
        self.report_track_started(track_id).await;
        Ok(snapshot)
    }

    pub(crate) async fn playback(&self) -> PlaybackSnapshot {
        let state = {
            let mut player = self.audio_player.lock().await;
            player.synchronize_gapless();
            PlaybackStateSnapshot::from_player(&player)
        };
        self.snapshot_from_state(state).await
    }

    pub(crate) async fn pause(&self) -> CoreResult<()> {
        self.audio_player.lock().await.pause();
        self.pause_lastfm().await;
        self.persist_session().await
    }

    pub(crate) async fn resume(&self) -> CoreResult<()> {
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
            self.audio_player
                .lock()
                .await
                .play_song_prepared_from(song_id, prepared, position)
                .map_err(|error| CoreError::Playback {
                    message: error.to_string(),
                })?;
        }
        let current_track_id = self.audio_player.lock().await.get_current_song_id();
        drop(_transition);
        if let Some(track_id) = current_track_id {
            if self.is_tracking(track_id).await {
                self.resume_lastfm().await;
            } else {
                self.report_track_started(track_id).await;
            }
        }
        self.persist_session().await
    }

    pub(crate) async fn stop(&self) -> CoreResult<()> {
        let _transition = self.playback_transition.lock().await;
        self.audio_player.lock().await.stop();
        drop(_transition);
        *self.lastfm_playback.lock().await = None;
        self.persist_session().await
    }

    pub(crate) async fn seek(&self, seconds: u64) -> CoreResult<()> {
        self.audio_player
            .lock()
            .await
            .seek_to_position(seconds)
            .await
            .map_err(|error| CoreError::Playback {
                message: error.to_string(),
            })?;
        self.persist_progress(seconds as f64).await
    }

    pub(crate) async fn set_volume(&self, volume: f32) -> CoreResult<()> {
        if !volume.is_finite() {
            return Err(CoreError::InvalidInput {
                message: "Volume must be a finite number between 0.0 and 1.0".to_string(),
            });
        }
        let volume = {
            let mut player = self.audio_player.lock().await;
            player.set_volume(volume.clamp(0.0, 1.0));
            player.volume() as f64
        };
        self.persist_volume(volume).await
    }

    async fn prepare_sound(&self, path: String) -> CoreResult<crate::audio::player::PreparedSound> {
        let normalize_volume = self.audio_player.lock().await.normalize_volume_enabled();
        AudioPlayer::prepare_sound(path, normalize_volume)
            .await
            .map_err(|error| CoreError::Playback {
                message: error.to_string(),
            })
    }

    async fn persist_session(&self) -> CoreResult<()> {
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
            let conn = db_pool.get().map_err(|error| error.to_string())?;
            let previous = crate::database::operations::get_last_session(&conn)
                .map_err(|error| error.to_string())?;
            let session = crate::database::models::LastSession {
                current_song_id,
                progress_seconds,
                volume,
                shuffle_enabled,
                repeat_mode: format!("{repeat_mode:?}").to_lowercase(),
                queue_snapshot: serde_json::to_string(&queue).map_err(|error| error.to_string())?,
                queue_position: 0,
                source_context: previous.source_context,
                updated_at: String::new(),
            };
            crate::database::operations::save_last_session(&conn, &session)
                .map_err(|error| error.to_string())
        })
        .await
        .map_err(|error| CoreError::Storage {
            message: format!("Session persistence task failed: {error}"),
        })?
        .map_err(|message| CoreError::Storage { message })
    }

    async fn persist_progress(&self, progress_seconds: f64) -> CoreResult<()> {
        let db_pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = db_pool.get().map_err(|error| error.to_string())?;
            crate::database::operations::update_session_progress(&conn, progress_seconds)
                .map_err(|error| error.to_string())
        })
        .await
        .map_err(|error| CoreError::Storage {
            message: format!("Session progress persistence task failed: {error}"),
        })?
        .map_err(|message| CoreError::Storage { message })
    }

    async fn persist_volume(&self, volume: f64) -> CoreResult<()> {
        let db_pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = db_pool.get().map_err(|error| error.to_string())?;
            crate::database::operations::update_session_volume(&conn, volume)
                .map_err(|error| error.to_string())
        })
        .await
        .map_err(|error| CoreError::Storage {
            message: format!("Session volume persistence task failed: {error}"),
        })?
        .map_err(|message| CoreError::Storage { message })
    }

    async fn snapshot_from_state(&self, state: PlaybackStateSnapshot) -> PlaybackSnapshot {
        let current_track = if let Some(id) = state.current_track_id {
            let db_pool = self.db_pool.clone();
            tokio::task::spawn_blocking(move || {
                let conn = db_pool.get().ok()?;
                crate::database::operations::get_song_by_id(&conn, &id.to_string())
                    .ok()?
                    .into_iter()
                    .next()
                    .map(track_from_song)
            })
            .await
            .ok()
            .flatten()
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
            queue_position: 0,
            shuffle_enabled: state.shuffle_enabled,
            repeat_mode: state.repeat_mode,
        }
    }

    async fn report_track_started(&self, track_id: i64) {
        if !self.lastfm.is_connected().await {
            return;
        }
        let db_pool = self.db_pool.clone();
        let track = tokio::task::spawn_blocking(move || {
            let conn = db_pool.get().ok()?;
            crate::database::operations::get_song_by_id(&conn, &track_id.to_string())
                .ok()?
                .into_iter()
                .next()
        })
        .await
        .ok()
        .flatten();
        let Some(track) = track else { return };
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

    async fn pause_lastfm(&self) {
        let now = unix_timestamp_seconds();
        if let Some(playback) = self.lastfm_playback.lock().await.as_mut()
            && let Some(active_since) = playback.active_since.take()
        {
            playback.played_seconds += now.saturating_sub(active_since);
        }
    }

    async fn resume_lastfm(&self) {
        if let Some(playback) = self.lastfm_playback.lock().await.as_mut()
            && playback.active_since.is_none()
        {
            playback.active_since = Some(unix_timestamp_seconds());
        }
    }

    async fn is_tracking(&self, track_id: i64) -> bool {
        self.lastfm_playback
            .lock()
            .await
            .as_ref()
            .is_some_and(|playback| playback.track_id == track_id)
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
    repeat_mode: crate::api::RepeatMode,
}

impl PlaybackStateSnapshot {
    fn from_player(player: &AudioPlayer) -> Self {
        let (position, duration) = player.get_progress();
        let is_paused = player.is_paused();
        Self {
            current_track_id: player.get_current_song_id(),
            position_seconds: position.as_secs_f64(),
            duration_seconds: duration.map(|duration| duration.as_secs_f64()),
            volume: player.volume(),
            is_playing: !is_paused && !player.is_empty(),
            is_paused,
            queue: player
                .get_playback_queue()
                .into_iter()
                .enumerate()
                .map(|(position, (track_id, _))| QueueItem {
                    track_id,
                    position: position as u64,
                })
                .collect(),
            shuffle_enabled: player.shuffle_enabled(),
            repeat_mode: player.repeat_mode(),
        }
    }
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
        bitrate: track.bitrate,
        sample_rate: track.sample_rate,
        bit_depth: track.bit_depth,
        play_count: track.play_count,
        last_played: track.last_played,
        rating: track.rating,
        is_favorite: track.is_favorite,
        is_hidden: track.is_hidden,
        suggest_less: track.suggest_less,
    }
}

fn unix_timestamp_seconds() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
