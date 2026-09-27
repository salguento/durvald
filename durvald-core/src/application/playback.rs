//! Playback use-case coordination.
//!
//! Responsibilities move here incrementally while [`crate::core::DurvaldCore`]
//! remains the stable public facade.

use std::sync::Arc;
use std::time::Duration;

use crate::{
    api::{CoreError, CoreResult, LastSession, PlaybackSnapshot, QueueItem, RepeatMode, Track},
    application::library::track_from_catalog,
    audio::AudioPlayer,
    domain::{ids::TrackId, playback_session::PlaybackSessionState},
    infrastructure::sqlite::catalog_track::{CatalogTrackLookupError, SqliteCatalogTrackQuery},
    infrastructure::sqlite::playback_history::SqlitePlaybackHistoryRepository,
    infrastructure::sqlite::playback_session::SqlitePlaybackSessionRepository,
    lastfm::LastFmClient,
};

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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct AutomaticPlaybackEvent {
    completed_track_id: Option<i64>,
    started_track_id: Option<i64>,
}

const ACTIVE_COORDINATION_INTERVAL: Duration = Duration::from_millis(50);
const IDLE_COORDINATION_INTERVAL: Duration = Duration::from_secs(1);

/// Coordinates playback use cases behind the public core facade.
///
/// The concrete collaborators remain in use during the first extraction. Ports
/// are introduced only if later application boundaries require them.
#[allow(dead_code)]
pub(crate) struct PlaybackApplication {
    track_query: SqliteCatalogTrackQuery,
    history_repository: SqlitePlaybackHistoryRepository,
    session_repository: SqlitePlaybackSessionRepository,
    audio_player: Arc<tokio::sync::Mutex<AudioPlayer>>,
    playback_transition: tokio::sync::Mutex<()>,
    coordination_wakeup: tokio::sync::Notify,
    lastfm: Arc<LastFmClient>,
    lastfm_playback: tokio::sync::Mutex<Option<LastFmPlayback>>,
}

impl PlaybackApplication {
    pub(crate) fn new(
        track_query: SqliteCatalogTrackQuery,
        history_repository: SqlitePlaybackHistoryRepository,
        session_repository: SqlitePlaybackSessionRepository,
        audio_player: AudioPlayer,
        lastfm: Arc<LastFmClient>,
    ) -> Self {
        Self {
            track_query,
            history_repository,
            session_repository,
            audio_player: Arc::new(tokio::sync::Mutex::new(audio_player)),
            playback_transition: tokio::sync::Mutex::new(()),
            coordination_wakeup: tokio::sync::Notify::new(),
            lastfm,
            lastfm_playback: tokio::sync::Mutex::new(None),
        }
    }

    pub(crate) fn audio_player(&self) -> &Arc<tokio::sync::Mutex<AudioPlayer>> {
        &self.audio_player
    }

    pub(crate) async fn clear_lastfm_tracking(&self) {
        *self.lastfm_playback.lock().await = None;
    }

    pub(crate) fn start_automatic_coordination(self: &Arc<Self>) {
        let (event_sender, mut event_receiver) =
            tokio::sync::mpsc::unbounded_channel::<AutomaticPlaybackEvent>();
        let reporting_application = Arc::downgrade(self);
        tokio::spawn(async move {
            while let Some(event) = event_receiver.recv().await {
                let Some(application) = reporting_application.upgrade() else {
                    break;
                };
                if let Some(track_id) = event.completed_track_id {
                    application.record_completed_playback(track_id).await;
                    application.report_track_completed(track_id).await;
                }
                if let Some(track_id) = event.started_track_id {
                    application.report_track_started(track_id).await;
                }
                let _ = application.persist_session().await;
            }
        });

        let playback_application = Arc::downgrade(self);
        tokio::spawn(async move {
            loop {
                let Some(application) = playback_application.upgrade() else {
                    break;
                };
                if let Some((completed_track_id, started_track_id)) =
                    application.process_automatic_transition().await
                {
                    let _ = event_sender.send(AutomaticPlaybackEvent {
                        completed_track_id,
                        started_track_id,
                    });
                }
                let interval = application.automatic_coordination_interval().await;
                tokio::select! {
                    _ = tokio::time::sleep(interval) => {}
                    _ = application.coordination_wakeup.notified() => {}
                }
            }
        });
    }

    async fn automatic_coordination_interval(&self) -> Duration {
        let player = self.audio_player.lock().await;
        if !player.is_paused() && !player.is_empty() {
            ACTIVE_COORDINATION_INTERVAL
        } else {
            IDLE_COORDINATION_INTERVAL
        }
    }

    fn wake_automatic_coordination(&self) {
        self.coordination_wakeup.notify_one();
    }

    pub(crate) async fn play(&self, track_id: TrackId) -> CoreResult<PlaybackSnapshot> {
        let track = self
            .track_query
            .find(track_id)
            .await
            .map_err(|error| playback_track_error(error, track_id))?;
        let track_id = track_id.get() as i64;

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
        self.wake_automatic_coordination();

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
        self.wake_automatic_coordination();
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
        self.wake_automatic_coordination();
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
        self.wake_automatic_coordination();
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

    pub(crate) async fn set_shuffle_enabled(&self, enabled: bool) -> CoreResult<PlaybackSnapshot> {
        let _transition = self.playback_transition.lock().await;
        let state = {
            let mut player = self.audio_player.lock().await;
            player.set_shuffle_enabled(enabled);
            PlaybackStateSnapshot::from_player(&player)
        };
        drop(_transition);
        let snapshot = self.snapshot_from_state(state).await;
        self.persist_session().await?;
        Ok(snapshot)
    }

    pub(crate) async fn set_repeat_mode(&self, mode: RepeatMode) -> CoreResult<PlaybackSnapshot> {
        let _transition = self.playback_transition.lock().await;
        let state = {
            let mut player = self.audio_player.lock().await;
            player.set_repeat_mode(mode);
            PlaybackStateSnapshot::from_player(&player)
        };
        drop(_transition);
        let snapshot = self.snapshot_from_state(state).await;
        self.persist_session().await?;
        Ok(snapshot)
    }

    pub(crate) async fn add_to_queue(&self, track_id: TrackId) -> CoreResult<()> {
        let track_id = track_id.get() as i64;
        let track = self.find_track(track_id).await?;
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
                .map_err(|error| CoreError::Playback {
                    message: error.to_string(),
                })?;
        } else {
            player.enqueue(track_id, track.file_path);
        }
        drop(player);
        drop(_transition);
        if starts_playback {
            self.wake_automatic_coordination();
        }
        self.persist_session().await?;
        if starts_playback {
            self.report_track_started(track_id).await;
        }
        Ok(())
    }

    pub(crate) async fn next_track(&self) -> CoreResult<PlaybackSnapshot> {
        let _transition = self.playback_transition.lock().await;
        let plan = {
            let mut player = self.audio_player.lock().await;
            player.cancel_gapless_transition();
            player.plan_next().ok_or_else(|| CoreError::NotFound {
                message: "No next track in the queue".to_string(),
            })?
        };
        self.commit_navigation_plan(plan).await
    }

    pub(crate) async fn previous_track(&self) -> CoreResult<PlaybackSnapshot> {
        let _transition = self.playback_transition.lock().await;
        let plan = {
            let mut player = self.audio_player.lock().await;
            player.cancel_gapless_transition();
            player.plan_previous().ok_or_else(|| CoreError::NotFound {
                message: "No previously played track".to_string(),
            })?
        };
        self.commit_navigation_plan(plan).await
    }

    pub(crate) async fn play_queue_item(&self, position: u64) -> CoreResult<PlaybackSnapshot> {
        let _transition = self.playback_transition.lock().await;
        let plan = {
            let mut player = self.audio_player.lock().await;
            player.cancel_gapless_transition();
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
                .map_err(|error| CoreError::InvalidInput {
                    message: error.to_string(),
                })?
        };
        self.commit_navigation_plan(plan).await
    }

    pub(crate) async fn remove_from_queue(&self, position: u64) -> CoreResult<()> {
        let _transition = self.playback_transition.lock().await;
        let mut player = self.audio_player.lock().await;
        let position = public_to_upcoming_position(&player, position, "removed from the queue")?;
        player
            .remove_from_queue(position)
            .map_err(|error| CoreError::InvalidInput {
                message: error.to_string(),
            })?;
        drop(player);
        drop(_transition);
        self.persist_session().await
    }

    pub(crate) async fn move_queue_item(&self, from: u64, to: u64) -> CoreResult<()> {
        let _transition = self.playback_transition.lock().await;
        let mut player = self.audio_player.lock().await;
        let from = public_to_upcoming_position(&player, from, "moved")?;
        let to = public_to_upcoming_position(&player, to, "moved")?;
        player
            .move_in_queue(from, to)
            .map_err(|error| CoreError::InvalidInput {
                message: error.to_string(),
            })?;
        drop(player);
        drop(_transition);
        self.persist_session().await
    }

    pub(crate) async fn clear_queue(&self) -> CoreResult<()> {
        let _transition = self.playback_transition.lock().await;
        self.audio_player.lock().await.clear_queue();
        drop(_transition);
        self.persist_session().await
    }

    pub(crate) async fn queue(&self) -> CoreResult<Vec<QueueItem>> {
        let mut player = self.audio_player.lock().await;
        player.synchronize_gapless();
        Ok(player
            .get_playback_queue()
            .into_iter()
            .enumerate()
            .map(|(position, (track_id, _))| QueueItem {
                track_id,
                position: position as u64,
            })
            .collect())
    }

    async fn commit_navigation_plan(
        &self,
        plan: crate::audio::player::PlaybackPlan,
    ) -> CoreResult<PlaybackSnapshot> {
        let prepared = self.prepare_sound(plan.path().to_string()).await?;
        let track_id = plan.song_id();
        let state = {
            let mut player = self.audio_player.lock().await;
            player
                .commit_plan(plan, prepared)
                .map_err(|error| CoreError::Playback {
                    message: error.to_string(),
                })?;
            PlaybackStateSnapshot::from_player(&player)
        };
        let snapshot = self.snapshot_from_state(state).await;
        self.wake_automatic_coordination();
        self.persist_session().await?;
        self.report_track_started(track_id).await;
        Ok(snapshot)
    }

    async fn find_track(&self, track_id: i64) -> CoreResult<Track> {
        let track_id = TrackId::try_from(track_id).map_err(|_| CoreError::InvalidInput {
            message: "Track ID must not be negative".to_string(),
        })?;
        self.track_query
            .find(track_id)
            .await
            .map(track_from_catalog)
            .map_err(|error| playback_track_error(error, track_id))
    }

    async fn prepare_sound(&self, path: String) -> CoreResult<crate::audio::player::PreparedSound> {
        let normalize_volume = self.audio_player.lock().await.normalize_volume_enabled();
        AudioPlayer::prepare_sound(path, normalize_volume)
            .await
            .map_err(|error| CoreError::Playback {
                message: error.to_string(),
            })
    }

    async fn process_automatic_transition(&self) -> Option<(Option<i64>, Option<i64>)> {
        let _transition = self.playback_transition.lock().await;
        let gapless_plan = {
            let mut player = self.audio_player.lock().await;
            player.synchronize_gapless();
            player.gapless_plan()
        };
        if let Some(plan) = gapless_plan
            && let Ok(prepared) = self.prepare_sound(plan.path().to_string()).await
        {
            let _ = self
                .audio_player
                .lock()
                .await
                .schedule_gapless(plan, prepared);
        }
        if let Some((previous, next)) = self.audio_player.lock().await.pop_completed_transition() {
            return Some((previous, Some(next)));
        }

        let (completed_track_id, plan) = {
            let player = self.audio_player.lock().await;
            (
                player.get_current_song_id(),
                player.completed_playback_plan(),
            )
        };
        let plan = plan?;
        let prepared = self.prepare_sound(plan.path().to_string()).await.ok()?;
        let started_track_id = plan.song_id();
        self.audio_player
            .lock()
            .await
            .commit_plan(plan, prepared)
            .ok()?;
        Some((completed_track_id, Some(started_track_id)))
    }

    pub(crate) async fn persist_session(&self) -> CoreResult<()> {
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
        let session = PlaybackSessionState {
            current_track_id: current_song_id,
            progress_seconds,
            volume,
            shuffle_enabled,
            repeat_mode: format!("{repeat_mode:?}").to_lowercase(),
            queue,
            queue_position: 0,
            source_context: String::new(),
            updated_at: String::new(),
        };
        self.session_repository
            .save_preserving_source_context(session)
            .await
            .map_err(|message| CoreError::Storage { message })
    }

    async fn persist_progress(&self, progress_seconds: f64) -> CoreResult<()> {
        self.session_repository
            .update_progress(progress_seconds)
            .await
            .map_err(|message| CoreError::Storage { message })
    }

    async fn persist_volume(&self, volume: f64) -> CoreResult<()> {
        self.session_repository
            .update_volume(volume)
            .await
            .map_err(|message| CoreError::Storage { message })
    }

    pub(crate) async fn last_session(&self) -> CoreResult<LastSession> {
        let session = self
            .session_repository
            .load()
            .await
            .map_err(|message| CoreError::Storage { message })?;

        Ok(LastSession {
            current_track_id: session.current_track_id,
            progress_seconds: session.progress_seconds,
            volume: normalized_volume(session.volume),
            shuffle_enabled: session.shuffle_enabled,
            repeat_mode: match session.repeat_mode.as_str() {
                "one" => RepeatMode::One,
                "all" => RepeatMode::All,
                _ => RepeatMode::None,
            },
            queue: session.queue,
            queue_position: session.queue_position,
            source_context: session.source_context,
            updated_at: session.updated_at,
        })
    }

    pub(crate) async fn save_session(&self, session: LastSession) -> CoreResult<()> {
        let db_session = PlaybackSessionState {
            current_track_id: session.current_track_id,
            progress_seconds: session.progress_seconds,
            volume: normalized_volume(session.volume as f64) as f64,
            shuffle_enabled: session.shuffle_enabled,
            repeat_mode: format!("{:?}", session.repeat_mode).to_lowercase(),
            queue: session.queue,
            queue_position: session.queue_position,
            source_context: session.source_context,
            updated_at: String::new(),
        };
        self.session_repository
            .save(db_session)
            .await
            .map_err(|message| CoreError::Storage { message })
    }

    async fn snapshot_from_state(&self, state: PlaybackStateSnapshot) -> PlaybackSnapshot {
        let current_track = if let Some(id) = state.current_track_id {
            let track_id = TrackId::try_from(id).ok();
            match track_id {
                Some(track_id) => self
                    .track_query
                    .find(track_id)
                    .await
                    .ok()
                    .map(track_from_catalog),
                None => None,
            }
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
        let Some(typed_track_id) = TrackId::try_from(track_id).ok() else {
            return;
        };
        let track = self.track_query.find(typed_track_id).await.ok();
        let Some(track) = track else { return };
        let started_at = unix_timestamp_seconds();
        let playback = LastFmPlayback {
            track_id,
            artist: track.artist_name,
            title: track.title,
            release: track.release_title,
            duration_seconds: track.duration_seconds,
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

    async fn report_track_completed(&self, track_id: i64) {
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
        let Some(playback) = playback else { return };
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
        let Ok(typed_track_id) = TrackId::try_from(track_id) else {
            return;
        };
        let duration = match self.track_query.find(typed_track_id).await {
            Ok(track) => track.duration_seconds,
            Err(CatalogTrackLookupError::NotFound) => 0,
            Err(CatalogTrackLookupError::Storage(_)) => return,
        };
        let _ = self
            .history_repository
            .record_completed(typed_track_id, duration)
            .await;
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

fn playback_track_error(error: CatalogTrackLookupError, track_id: TrackId) -> CoreError {
    match error {
        CatalogTrackLookupError::NotFound => CoreError::NotFound {
            message: format!("Track {} not found", track_id.get()),
        },
        CatalogTrackLookupError::Storage(message) => CoreError::Storage { message },
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

fn unix_timestamp_seconds() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn normalized_volume(volume: f64) -> f32 {
    if volume.is_finite() {
        volume.clamp(0.0, 1.0) as f32
    } else {
        1.0
    }
}

pub(crate) fn scrobble_eligible(duration_seconds: u64, played_seconds: u64) -> bool {
    duration_seconds >= 30 && played_seconds >= (duration_seconds / 2).min(240)
}

fn public_to_upcoming_position(
    player: &AudioPlayer,
    position: u64,
    action: &str,
) -> CoreResult<usize> {
    let position = if player.get_current_song_id().is_some() {
        position
            .checked_sub(1)
            .ok_or_else(|| CoreError::InvalidInput {
                message: format!("The active track cannot be {action}"),
            })?
    } else {
        position
    };
    Ok(position as usize)
}
