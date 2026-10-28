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
    pub(super) integration_runtime:
        tokio::sync::Mutex<Option<Arc<super::music_plugins::PluginRuntime>>>,
    pub(super) source_status: tokio::sync::Mutex<Option<crate::api::PlaybackSourceStatus>>,
    pub(super) gapless_skip: tokio::sync::Mutex<Option<String>>,
    pub(super) embedded: tokio::sync::Mutex<Option<super::playback_embedded::EmbeddedSession>>,
    pub(super) embedded_host:
        tokio::sync::Mutex<Option<Arc<super::playback_embedded::EmbeddedHostDispatcher>>>,
    pub(super) track_query: SqliteCatalogTrackQuery,
    pub(super) history_repository: SqlitePlaybackHistoryRepository,
    session_repository: SqlitePlaybackSessionRepository,
    pub(super) audio_player: Arc<tokio::sync::Mutex<AudioPlayer>>,
    pub(super) playback_transition: tokio::sync::Mutex<()>,
    source_override: tokio::sync::Mutex<Option<(String, i64)>>,
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
            integration_runtime: Default::default(),
            source_status: Default::default(),
            gapless_skip: Default::default(),
            embedded: Default::default(),
            embedded_host: Default::default(),
            track_query,
            history_repository,
            session_repository,
            audio_player: Arc::new(tokio::sync::Mutex::new(audio_player)),
            playback_transition: tokio::sync::Mutex::new(()),
            source_override: tokio::sync::Mutex::new(None),
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
        self.play_with_context(track_id, String::new()).await
    }

    pub(crate) async fn play_with_context(
        &self,
        track_id: TrackId,
        source_context: String,
    ) -> CoreResult<PlaybackSnapshot> {
        self.play_selection(track_id, source_context, None).await
    }
    pub(crate) async fn play_source(
        &self,
        track_id: TrackId,
        source: i64,
    ) -> CoreResult<PlaybackSnapshot> {
        self.play_selection(track_id, String::new(), Some(source))
            .await
    }
    async fn play_selection(
        &self,
        track_id: TrackId,
        source_context: String,
        source: Option<i64>,
    ) -> CoreResult<PlaybackSnapshot> {
        validate_source_context(&source_context)?;
        let selected_track = self
            .track_query
            .find(track_id)
            .await
            .map_err(|error| playback_track_error(error, track_id))?;
        let track_id = track_id.get() as i64;

        let _transition = self.playback_transition.lock().await;
        let (prepared, remaining, fallback) = self.prepare_selection(track_id, source).await?;
        let prepared = match prepared {
            super::playback_sources::PreparedSource::Local(sound, selected) => {
                self.source_selected(&selected, fallback).await;
                *sound
            }
            super::playback_sources::PreparedSource::Embedded(url, selected) => {
                self.audio_player.lock().await.discard_collection();
                let result = self
                    .start_embedded_selection_locked(
                        crate::application::library::track_from_catalog(selected_track),
                        selected,
                        url,
                        remaining,
                        source_context,
                        None,
                        fallback,
                    )
                    .await;
                if let Err(error) = result {
                    if !self.fallback_before_audio_locked().await? {
                        return Err(error);
                    }
                }
                return Ok(self.playback().await);
            }
        };
        self.stop_embedded_locked().await?;
        let state = {
            let mut player = self.audio_player.lock().await;
            player
                .play_song_prepared(track_id, prepared)
                .map_err(|error| CoreError::Playback {
                    message: error.to_string(),
                })?;
            player.discard_collection();
            player.set_source_context(source_context);
            PlaybackStateSnapshot::from_player(&player)
        };
        *self.source_override.lock().await = source.and_then(|source| {
            state
                .queue
                .first()
                .map(|q| (q.occurrence_id.clone(), source))
        });
        drop(_transition);
        self.wake_automatic_coordination();

        let snapshot = self.snapshot_from_state(state).await;
        self.persist_session().await?;
        self.report_track_started(track_id).await;
        Ok(snapshot)
    }

    /// Validate and prepare the selected sound before atomically replacing the queue.
    pub(crate) async fn play_collection(
        &self,
        track_ids: Vec<i64>,
        source_contexts: Vec<String>,
        starting_position: Option<u64>,
        shuffle_enabled: Option<bool>,
    ) -> CoreResult<PlaybackSnapshot> {
        if track_ids.is_empty() || track_ids.len() != source_contexts.len() {
            return Err(CoreError::InvalidInput {
                message: "Invalid playback collection".into(),
            });
        }
        if starting_position.is_some_and(|index| index >= track_ids.len() as u64) {
            return Err(CoreError::InvalidInput {
                message: "Invalid collection position".into(),
            });
        }
        for context in &source_contexts {
            validate_source_context(context)?;
        }
        let ids = track_ids
            .iter()
            .map(|&id| {
                TrackId::try_from(id).map_err(|_| CoreError::InvalidInput {
                    message: "Invalid collection track ID".into(),
                })
            })
            .collect::<CoreResult<Vec<_>>>()?;
        let first_id = ids[0];
        let tracks = self
            .track_query
            .find_many(ids)
            .await
            .map_err(|error| playback_track_error(error, first_id))?;
        let identities: std::collections::HashSet<_> = tracks
            .into_iter()
            .map(|track| track.id.get() as i64)
            .collect();
        let mut items = Vec::with_capacity(track_ids.len());
        for (id, context) in track_ids.into_iter().zip(source_contexts) {
            if !identities.contains(&id) {
                return Err(CoreError::NotFound {
                    message: format!("Track {id} not found"),
                });
            }
            items.push(crate::audio::player::QueueItem {
                song_id: id,
                occurrence_id: crate::audio::player::new_occurrence_id(),
                path: None,
                source_context: context,
                collection_position: None,
            });
        }
        let transition = self.playback_transition.lock().await;
        let shuffle = shuffle_enabled.unwrap_or(self.audio_player.lock().await.shuffle_enabled());
        let start = if let Some(index) = starting_position {
            index as usize
        } else if shuffle {
            let mut indices: Vec<_> = (0..items.len()).collect();
            crate::audio::player::shuffle_items(&mut indices);
            indices[0]
        } else {
            0
        };
        let track_id = items[start].song_id;
        let (prepared, remaining, fallback) = self.prepare_selection(track_id, None).await?;
        let prepared = match prepared {
            super::playback_sources::PreparedSource::Local(sound, selected) => {
                self.source_selected(&selected, fallback).await;
                *sound
            }
            super::playback_sources::PreparedSource::Embedded(url, selected) => {
                let track = self.find_track(track_id).await?;
                let occurrence = items[start].occurrence_id.clone();
                let context = items[start].source_context.clone();
                let result = self
                    .start_embedded_selection_locked(
                        track,
                        selected,
                        url,
                        remaining,
                        context,
                        Some(occurrence),
                        fallback,
                    )
                    .await;
                if let Err(error) = result {
                    if !self.fallback_before_audio_locked().await? {
                        return Err(error);
                    }
                }
                self.audio_player
                    .lock()
                    .await
                    .start_collection(items, start, shuffle);
                self.persist_session().await?;
                return Ok(self.playback().await);
            }
        };
        self.stop_embedded_locked().await?;
        let state = {
            let mut player = self.audio_player.lock().await;
            player
                .play_song_prepared(track_id, prepared)
                .map_err(|error| CoreError::Playback {
                    message: error.to_string(),
                })?;
            player.start_collection(items, start, shuffle);
            PlaybackStateSnapshot::from_player(&player)
        };
        drop(transition);
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
        if self
            .embedded_command(crate::api::EmbeddedCommandKind::Pause, 0.0)
            .await?
        {
            return Ok(());
        }
        self.audio_player.lock().await.pause();
        self.wake_automatic_coordination();
        self.pause_lastfm().await;
        self.persist_session().await
    }

    pub(crate) async fn resume(&self) -> CoreResult<()> {
        if self
            .embedded_command(crate::api::EmbeddedCommandKind::Play, 0.0)
            .await?
        {
            return Ok(());
        }
        let _transition = self.playback_transition.lock().await;
        let restored_track = {
            let mut player = self.audio_player.lock().await;
            let restored_track = player.restored_track();
            if restored_track.is_none() {
                player.resume();
            }
            restored_track
        };
        if let Some((song_id, position)) = restored_track {
            let prepared = self.prepare_track(song_id).await?;
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
        self.stop_embedded_locked().await?;
        *self.source_status.lock().await = None;
        self.audio_player.lock().await.stop();
        drop(_transition);
        self.wake_automatic_coordination();
        *self.lastfm_playback.lock().await = None;
        self.persist_session().await
    }

    pub(crate) async fn seek(&self, seconds: u64) -> CoreResult<()> {
        if self
            .embedded_command(crate::api::EmbeddedCommandKind::Seek, seconds as f64)
            .await?
        {
            return Ok(());
        }
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
        self.embedded_command(
            crate::api::EmbeddedCommandKind::Volume,
            volume.clamp(0.0, 1.0) as f64,
        )
        .await?;
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
        self.add_to_queue_with_context(track_id, String::new())
            .await
    }

    pub(crate) async fn add_to_queue_with_context(
        &self,
        track_id: TrackId,
        source_context: String,
    ) -> CoreResult<()> {
        validate_source_context(&source_context)?;
        let track_id = track_id.get() as i64;
        self.find_track(track_id).await?;
        let _transition = self.playback_transition.lock().await;
        let starts_playback = self.embedded.lock().await.is_none()
            && self.audio_player.lock().await.should_start_queued_track()
            && !self
                .track_query
                .local_media_paths(track_id)
                .await?
                .is_empty();
        let prepared = if starts_playback {
            Some(self.prepare_track(track_id).await?)
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
            player.set_source_context(source_context);
        } else {
            player.enqueue_with_context(track_id, None, source_context);
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
        if self.embedded.lock().await.is_some() {
            return self.next_from_embedded().await;
        }
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
            let upcoming_position = if player.get_current_song_id().is_some()
                || self
                    .embedded
                    .lock()
                    .await
                    .as_ref()
                    .is_some_and(|s| s.snapshot.track_id.is_some())
            {
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
        let position = if self
            .embedded
            .lock()
            .await
            .as_ref()
            .is_some_and(|s| s.snapshot.track_id.is_some())
        {
            position
                .checked_sub(1)
                .ok_or_else(|| CoreError::InvalidInput {
                    message: "Cannot remove the active embedded track".into(),
                })? as usize
        } else {
            public_to_upcoming_position(&player, position, "removed from the queue")?
        };
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
        let (from, to) = if self
            .embedded
            .lock()
            .await
            .as_ref()
            .is_some_and(|s| s.snapshot.track_id.is_some())
        {
            (
                from.checked_sub(1).ok_or_else(|| CoreError::InvalidInput {
                    message: "Cannot move the active embedded track".into(),
                })? as usize,
                to.checked_sub(1).ok_or_else(|| CoreError::InvalidInput {
                    message: "Cannot move the active embedded track".into(),
                })? as usize,
            )
        } else {
            (
                public_to_upcoming_position(&player, from, "moved")?,
                public_to_upcoming_position(&player, to, "moved")?,
            )
        };
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
        Ok(self.playback().await.queue)
    }

    pub(super) async fn commit_navigation_plan(
        &self,
        plan: crate::audio::player::PlaybackPlan,
    ) -> CoreResult<PlaybackSnapshot> {
        let explicit = self
            .source_override
            .lock()
            .await
            .as_ref()
            .filter(|(occurrence, _)| occurrence == plan.occurrence_id())
            .map(|(_, source)| *source);
        let (prepared, remaining, fallback) =
            self.prepare_selection(plan.song_id(), explicit).await?;
        let prepared = match prepared {
            super::playback_sources::PreparedSource::Local(sound, selected) => {
                self.source_selected(&selected, fallback).await;
                *sound
            }
            super::playback_sources::PreparedSource::Embedded(url, selected) => {
                let track = self.find_track(plan.song_id()).await?;
                let occurrence = plan.occurrence_id().to_owned();
                let context = plan.source_context().to_owned();
                self.stop_embedded_locked().await?;
                self.audio_player
                    .lock()
                    .await
                    .commit_external_plan(plan)
                    .map_err(|e| CoreError::Playback {
                        message: e.to_string(),
                    })?;
                let result = self
                    .start_embedded_selection_locked(
                        track,
                        selected,
                        url,
                        remaining,
                        context,
                        Some(occurrence),
                        fallback,
                    )
                    .await;
                if let Err(error) = result {
                    if !self.fallback_before_audio_locked().await? {
                        return Err(error);
                    }
                }
                self.persist_session().await?;
                return Ok(self.playback().await);
            }
        };
        self.stop_embedded_locked().await?;
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

    pub(super) async fn find_track(&self, track_id: i64) -> CoreResult<Track> {
        let track_id = TrackId::try_from(track_id).map_err(|_| CoreError::InvalidInput {
            message: "Track ID must not be negative".to_string(),
        })?;
        self.track_query
            .find(track_id)
            .await
            .map(track_from_catalog)
            .map_err(|error| playback_track_error(error, track_id))
    }

    async fn prepare_plan(
        &self,
        plan: &crate::audio::player::PlaybackPlan,
    ) -> CoreResult<crate::audio::player::PreparedSound> {
        if self.gapless_skip.lock().await.as_deref() == Some(plan.occurrence_id()) {
            return Err(CoreError::Playback {
                message: "Integrated source requires a normal transition".into(),
            });
        }
        let source = self
            .source_override
            .lock()
            .await
            .as_ref()
            .filter(|(occurrence, _)| occurrence == plan.occurrence_id())
            .map(|(_, id)| *id);
        let (prepared, _, _) = self.prepare_selection(plan.song_id(), source).await?;
        match prepared {
            super::playback_sources::PreparedSource::Local(sound, _) => Ok(*sound),
            super::playback_sources::PreparedSource::Embedded(_, _) => {
                *self.gapless_skip.lock().await = Some(plan.occurrence_id().to_owned());
                Err(CoreError::Playback {
                    message: "Integrated source requires a normal transition".into(),
                })
            }
        }
    }

    pub(super) async fn prepare_track(
        &self,
        track_id: i64,
    ) -> CoreResult<crate::audio::player::PreparedSound> {
        let paths = self.track_query.local_media_paths(track_id).await?;
        for path in paths {
            if let Ok(sound) = self.prepare_sound(path).await {
                return Ok(sound);
            }
        }
        Err(CoreError::Playback {
            message: format!(
                "Track {track_id} has no available local audio source; remote playback is not supported yet"
            ),
        })
    }

    pub(super) async fn prepare_sound(
        &self,
        path: String,
    ) -> CoreResult<crate::audio::player::PreparedSound> {
        let (normalize_volume, equalizer, meter) = {
            let player = self.audio_player.lock().await;
            let (equalizer, meter) = player.equalizer_processing();
            (player.normalize_volume_enabled(), equalizer, meter)
        };
        AudioPlayer::prepare_sound(path, normalize_volume, equalizer, meter)
            .await
            .map_err(|error| CoreError::Playback {
                message: error.to_string(),
            })
    }

    async fn process_automatic_transition(&self) -> Option<(Option<i64>, Option<i64>)> {
        let _transition = self.playback_transition.lock().await;
        self.check_embedded_timeout_locked().await;
        if self.embedded.lock().await.is_some() {
            return None;
        }
        let gapless_plan = {
            let mut player = self.audio_player.lock().await;
            player.synchronize_gapless();
            player.gapless_plan()
        };
        if let Some(plan) = gapless_plan
            && let Ok(prepared) = self.prepare_plan(&plan).await
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
        let prepared = match self.prepare_plan(&plan).await {
            Ok(sound) => sound,
            Err(_) => {
                if let Some(track) = completed_track_id {
                    self.report_track_completed(track).await;
                }
                self.commit_navigation_plan(plan).await.ok()?;
                return Some((completed_track_id, None));
            }
        };
        let started_track_id = plan.song_id();
        self.audio_player
            .lock()
            .await
            .commit_plan(plan, prepared)
            .ok()?;
        Some((completed_track_id, Some(started_track_id)))
    }

    pub(crate) async fn persist_session(&self) -> CoreResult<()> {
        let (
            current_song_id,
            progress_seconds,
            volume,
            shuffle_enabled,
            repeat_mode,
            queue,
            contexts,
            collection,
            occurrences,
        ) = {
            let mut player = self.audio_player.lock().await;
            player.synchronize_gapless();
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
                player.playback_contexts(),
                player.stored_collection(),
                player
                    .queue_occurrences()
                    .into_iter()
                    .map(|(_, id)| id)
                    .collect(),
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
            source_context: crate::domain::playback_session::encode_queue(
                contexts,
                collection,
                occurrences,
            ),
            updated_at: String::new(),
        };
        self.session_repository
            .save(session)
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
        let mut snapshot = PlaybackSnapshot {
            source_context: state.source_context,
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
        };
        self.overlay_embedded(&mut snapshot).await;
        snapshot
    }

    pub(super) async fn report_track_started(&self, track_id: i64) {
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
    source_context: String,
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
            source_context: player.source_context().to_string(),
            current_track_id: player.get_current_song_id(),
            position_seconds: position.as_secs_f64(),
            duration_seconds: duration.map(|duration| duration.as_secs_f64()),
            volume: player.volume(),
            is_playing: !is_paused && !player.is_empty(),
            is_paused,
            queue: player
                .queue_occurrences()
                .into_iter()
                .enumerate()
                .map(|(position, (track_id, occurrence_id))| QueueItem {
                    occurrence_id,
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

fn validate_source_context(context: &str) -> CoreResult<()> {
    if context.len() > 2048 || context.chars().any(char::is_control) {
        return Err(CoreError::InvalidInput {
            message: "Invalid playback source context".into(),
        });
    }
    Ok(())
}
