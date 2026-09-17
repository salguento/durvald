use crate::api::RepeatMode;
use kira::Tween;
use kira::sound::FromFileError;
use kira::sound::streaming::StreamingSoundData;
use kira::{AudioManager, AudioManagerSettings, DefaultBackend};
use std::collections::VecDeque;
use std::time::Duration;
use thiserror::Error;

use super::gapless::{GaplessData, StreamHandle, Transport, Voice};
use std::sync::atomic::Ordering;
type SoundHandle = StreamHandle;

#[derive(Debug, Clone)]
pub struct QueueItem {
    pub song_id: i64,
    pub path: String,
}

#[derive(Debug, Clone)]
pub struct QueueData {
    pub items: Vec<QueueItem>,
}

const MAX_PLAYBACK_HISTORY_ITEMS: usize = 100;

pub(crate) struct PreparedSound {
    path: String,
    sound_data: StreamingSoundData<FromFileError>,
    gain_db: f32,
}

#[derive(Clone)]
pub(crate) enum PlaybackPlan {
    RepeatCurrent(QueueItem),
    Next { item: QueueItem, index: usize },
    RepeatAll(QueueItem),
    Previous(QueueItem),
    Skip { item: QueueItem, position: usize },
}

struct ScheduledNext {
    plan: PlaybackPlan,
    sound: SoundHandle,
    duration: Duration,
    path: String,
    gain_db: f32,
    token: u64,
}

impl PlaybackPlan {
    pub(crate) fn path(&self) -> &str {
        match self {
            Self::RepeatCurrent(item)
            | Self::Next { item, .. }
            | Self::RepeatAll(item)
            | Self::Previous(item)
            | Self::Skip { item, .. } => &item.path,
        }
    }

    pub(crate) fn song_id(&self) -> i64 {
        match self {
            Self::RepeatCurrent(item)
            | Self::Next { item, .. }
            | Self::RepeatAll(item)
            | Self::Previous(item)
            | Self::Skip { item, .. } => item.song_id,
        }
    }
}

#[derive(Error, Debug)]
pub enum AudioError {
    #[error("Kira error: {0}")]
    Kira(#[from] Box<dyn std::error::Error + Send + Sync>),
    #[error("Join error: {0}")]
    Join(#[from] tokio::task::JoinError),
    #[error("No track is currently loaded")]
    NoTrackLoaded,
    #[error("Duration not available")]
    DurationNotAvailable,
    #[error("Position out of bounds")]
    PositionOutOfBounds,
    #[error("Failed to remove item")]
    FailedToRemove,
    #[error("Database error: {0}")]
    Database(#[from] rusqlite::Error),
    #[cfg(test)]
    #[error("Failed to initialize mock audio backend")]
    MockBackend,
}

enum PlayerBackend {
    Default(Box<AudioManager<DefaultBackend>>),
    #[cfg(test)]
    Mock(Box<AudioManager<kira::backend::mock::MockBackend>>),
}

pub struct AudioPlayer {
    manager: PlayerBackend,
    current_sound: Option<SoundHandle>,
    total_duration: Option<Duration>,
    current_path: Option<String>,
    paused_position: Option<f64>,
    current_volume: f32,
    current_gain_db: f32,
    normalize_volume: bool,
    queue: VecDeque<QueueItem>,
    history: VecDeque<QueueItem>,
    current_song_id: Option<i64>,
    crossfade_duration: Option<Duration>,
    shuffle_enabled: bool,
    repeat_mode: RepeatMode,
    playback_requested: bool,
    gapless: Option<Transport>,
    scheduled_next: Option<ScheduledNext>,
    next_token: u64,
    completed_transitions: VecDeque<(Option<i64>, i64)>,
}

impl AudioPlayer {
    pub fn volume(&self) -> f32 {
        self.current_volume
    }
}

impl AudioPlayer {
    pub fn new() -> Result<Self, AudioError> {
        let manager = AudioManager::<DefaultBackend>::new(AudioManagerSettings::default())
            .map_err(|e| AudioError::Kira(Box::new(e)))?;
        Ok(Self::from_backend(PlayerBackend::Default(Box::new(
            manager,
        ))))
    }
}

#[cfg(test)]
impl AudioPlayer {
    pub(crate) fn new_mock() -> Result<Self, AudioError> {
        let manager = AudioManager::<kira::backend::mock::MockBackend>::new(AudioManagerSettings {
            backend_settings: kira::backend::mock::MockBackendSettings { sample_rate: 8_000 },
            ..Default::default()
        })
        .map_err(|_| AudioError::MockBackend)?;
        Ok(Self::from_backend(PlayerBackend::Mock(Box::new(manager))))
    }

    pub(crate) fn process_mock_audio(&mut self, blocks: usize) {
        let manager = match &mut self.manager {
            PlayerBackend::Mock(manager) => manager,
            PlayerBackend::Default(_) => panic!("mock processing requires a mock player"),
        };
        manager.backend_mut().on_start_processing();
        for _ in 0..blocks {
            manager.backend_mut().process();
            manager.backend_mut().on_start_processing();
        }
    }
}

impl AudioPlayer {
    fn from_backend(manager: PlayerBackend) -> Self {
        Self {
            manager,
            current_sound: None,
            total_duration: None,
            current_path: None,
            paused_position: None,
            current_volume: 0.5,
            current_gain_db: 0.0,
            normalize_volume: false,
            queue: VecDeque::new(),
            history: VecDeque::new(),
            current_song_id: None,
            crossfade_duration: None,
            shuffle_enabled: false,
            repeat_mode: RepeatMode::None,
            playback_requested: false,
            gapless: None,
            scheduled_next: None,
            next_token: 1,
            completed_transitions: VecDeque::new(),
        }
    }

    pub(crate) async fn prepare_sound(
        path: String,
        normalize_volume: bool,
    ) -> Result<PreparedSound, AudioError> {
        let path_clone = path.clone();
        let (sound_data, gain_db) = tokio::task::spawn_blocking(move || {
            let gain_db = normalize_volume
                .then(|| crate::metadata::replay_gain_db(&path_clone))
                .flatten()
                .unwrap_or_default() as f32;
            super::decoder::GaplessDecoder::open(&path_clone)
                .map(|decoder| (StreamingSoundData::from_decoder(decoder), gain_db))
        })
        .await
        .map_err(AudioError::Join)?
        .map_err(|e| AudioError::Kira(Box::new(e)))?;

        Ok(PreparedSound {
            path,
            sound_data,
            gain_db,
        })
    }

    pub(crate) fn normalize_volume_enabled(&self) -> bool {
        self.normalize_volume
    }

    fn play_prepared(&mut self, prepared: PreparedSound) -> Result<(), AudioError> {
        let PreparedSound {
            path,
            sound_data,
            gain_db,
        } = prepared;

        let crossfade_duration = self
            .crossfade_duration
            .filter(|_| self.current_sound.is_some());
        let stop_tween = Tween {
            duration: crossfade_duration.unwrap_or_else(|| Tween::default().duration),
            ..Tween::default()
        };
        self.stop_sound_with_tween(stop_tween);
        self.playback_requested = false;
        let sound_data = if let Some(duration) = crossfade_duration {
            sound_data.fade_in_tween(Tween {
                duration,
                ..Tween::default()
            })
        } else {
            sound_data
        };
        self.total_duration = Some(sound_data.duration());
        self.current_path = Some(path.clone());
        self.paused_position = None;
        self.current_gain_db = gain_db;

        let volume_db = self.volume_db(gain_db);
        let (voice, sound_handle) = Voice::prepare(sound_data.volume(volume_db), self.next_token)
            .map_err(|e| AudioError::Kira(Box::new(e)))?;
        self.next_token += 1;
        let data = GaplessData::new(voice);
        let transport = match &mut self.manager {
            PlayerBackend::Default(manager) => manager
                .play(data)
                .map_err(|e| AudioError::Kira(Box::new(e)))?,
            #[cfg(test)]
            PlayerBackend::Mock(manager) => manager
                .play(data)
                .map_err(|e| AudioError::Kira(Box::new(e)))?,
        };
        self.current_sound = Some(sound_handle);
        self.gapless = Some(transport);
        self.playback_requested = true;
        Ok(())
    }

    pub async fn play(&mut self, path: String) -> Result<(), AudioError> {
        // Load before stopping the active track so a missing or invalid
        // replacement does not destroy an otherwise recoverable session.
        let prepared = Self::prepare_sound(path, self.normalize_volume).await?;
        self.play_prepared(prepared)
    }

    /// Starts a specific library track and records its identity for playback
    /// snapshots, history, and queue transitions.
    pub async fn play_song(&mut self, song_id: i64, path: String) -> Result<(), AudioError> {
        self.play(path).await?;
        self.current_song_id = Some(song_id);
        Ok(())
    }

    pub(crate) fn play_song_prepared(
        &mut self,
        song_id: i64,
        prepared: PreparedSound,
    ) -> Result<(), AudioError> {
        self.play_prepared(prepared)?;
        self.current_song_id = Some(song_id);
        Ok(())
    }

    pub fn pause(&mut self) {
        self.synchronize_gapless();
        if let Some(sound) = &mut self.current_sound {
            self.paused_position = Some(sound.position());
            sound.pause(Tween::default());
        }
    }

    pub fn resume(&mut self) {
        self.synchronize_gapless();
        if let Some(sound) = &mut self.current_sound {
            sound.resume(Tween::default());
            self.paused_position = None;
        }
    }

    fn stop_sound(&mut self) {
        self.stop_sound_with_tween(Tween::default());
    }

    fn stop_sound_with_tween(&mut self, tween: Tween) {
        self.invalidate_gapless();
        if let Some(mut sound) = self.current_sound.take() {
            sound.stop(tween);
        }
        self.total_duration = None;
        self.current_path = None;
        self.paused_position = None;
        self.current_gain_db = 0.0;
        self.gapless = None;
    }

    /// Stops the active track but preserves the upcoming queue.
    pub fn stop(&mut self) {
        self.stop_sound();
        self.current_song_id = None;
        self.playback_requested = false;
    }

    pub fn set_volume(&mut self, volume: f32) {
        self.current_volume = volume;

        self.apply_volume();
    }

    /// Enables ReplayGain track normalization for subsequently loaded tracks.
    pub fn set_volume_normalization(&mut self, enabled: bool) {
        self.invalidate_gapless();
        self.normalize_volume = enabled;
        if !enabled {
            self.current_gain_db = 0.0;
        }
        self.apply_volume();
    }

    fn apply_volume(&mut self) {
        self.synchronize_gapless();
        let volume_db = self.volume_db(self.current_gain_db);
        if let Some(sound) = &mut self.current_sound {
            sound.set_volume(volume_db, Tween::default());
        }
        let next_db = self
            .scheduled_next
            .as_ref()
            .map(|next| self.volume_db(next.gain_db));
        if let Some(next) = &mut self.scheduled_next {
            next.sound.set_volume(next_db.unwrap(), Tween::default());
        }
    }

    fn volume_db(&self, gain_db: f32) -> f32 {
        if self.current_volume > 0.00001 {
            20.0 * self.current_volume.log10() + gain_db
        } else {
            -80.0
        }
    }

    pub fn set_crossfade(&mut self, enabled: bool, duration_seconds: u32) {
        self.crossfade_duration = enabled
            .then(|| Duration::from_secs(duration_seconds as u64))
            .filter(|duration| !duration.is_zero());
    }

    pub fn is_paused(&self) -> bool {
        if self.active_sound().is_none() {
            return self.current_song_id.is_some() && self.paused_position.is_some();
        }
        self.active_sound()
            .map(|sound| {
                matches!(
                    sound.state(),
                    kira::sound::PlaybackState::Paused | kira::sound::PlaybackState::Pausing
                )
            })
            .unwrap_or(false)
    }

    pub fn is_empty(&self) -> bool {
        self.active_sound()
            .map(|sound| {
                matches!(
                    sound.state(),
                    kira::sound::PlaybackState::Stopped | kira::sound::PlaybackState::Stopping
                )
            })
            .unwrap_or(true)
    }

    pub fn get_position(&self) -> Duration {
        if let Some(paused_pos) = self.paused_position {
            return Duration::from_secs_f64(paused_pos);
        }

        self.active_sound()
            .map(|sound| Duration::from_secs_f64(sound.position()))
            .unwrap_or(Duration::ZERO)
    }

    pub fn get_duration(&self) -> Option<Duration> {
        self.activated_next()
            .map(|next| next.duration)
            .or(self.total_duration)
    }

    pub fn get_progress(&self) -> (Duration, Option<Duration>) {
        (self.get_position(), self.get_duration())
    }

    pub fn get_progress_percentage(&self) -> Option<f32> {
        if let Some(total) = self.get_duration() {
            let current = self.get_position();
            let total_secs = total.as_secs_f32();
            if total_secs > 0.0 {
                return Some((current.as_secs_f32() / total_secs).min(1.0));
            }
        }
        None
    }

    pub async fn seek_to_position(&mut self, seconds: u64) -> Result<(), AudioError> {
        self.synchronize_gapless();
        if let Some(sound) = &mut self.current_sound {
            sound.seek_to(seconds as f64);
            if self.paused_position.is_some() {
                self.paused_position = Some(seconds as f64);
            }
            Ok(())
        } else {
            Err(AudioError::NoTrackLoaded)
        }
    }

    pub async fn seek_to_percentage(&mut self, percentage: f32) -> Result<(), AudioError> {
        self.synchronize_gapless();
        if let Some(duration) = self.total_duration {
            let target_seconds = (duration.as_secs_f32() * percentage.clamp(0.0, 1.0)) as u64;
            self.seek_to_position(target_seconds).await
        } else {
            Err(AudioError::DurationNotAvailable)
        }
    }

    // Queue management methods
    pub async fn add_to_queue(&mut self, song_id: i64, path: String) -> Result<(), AudioError> {
        self.prepare_queue_append();
        if self.is_empty() && self.queue.is_empty() {
            // Nothing playing, start immediately
            self.current_song_id = Some(song_id);
            self.play(path).await?;
        } else {
            // Add to queue
            self.queue.push_back(QueueItem { song_id, path });
        }
        // A preload error must not reject a queue edit or stop active audio.
        let _ = self.prepare_gapless_next().await;
        Ok(())
    }

    pub(crate) fn enqueue(&mut self, song_id: i64, path: String) {
        self.prepare_queue_append();
        self.queue.push_back(QueueItem { song_id, path });
    }

    fn prepare_queue_append(&mut self) {
        self.synchronize_gapless();
        if self
            .scheduled_next
            .as_ref()
            .is_some_and(|next| matches!(next.plan, PlaybackPlan::RepeatAll(_)))
        {
            self.invalidate_gapless();
        }
    }

    pub(crate) fn should_start_queued_track(&self) -> bool {
        self.is_empty() && self.queue.is_empty()
    }

    fn push_history(&mut self, item: QueueItem) {
        // Repeat-all temporarily uses history to reconstruct the complete
        // cycle. It is drained back into the queue at the cycle boundary, so
        // its size remains bounded by the user-managed queue in that mode.
        if self.repeat_mode != RepeatMode::All && self.history.len() >= MAX_PLAYBACK_HISTORY_ITEMS {
            self.history.pop_front();
        }
        self.history.push_back(item);
    }

    pub(crate) fn plan_next(&self) -> Option<PlaybackPlan> {
        if self.repeat_mode == RepeatMode::One {
            return self
                .current_song_id
                .zip(self.current_path.clone())
                .map(|(song_id, path)| PlaybackPlan::RepeatCurrent(QueueItem { song_id, path }));
        }

        if !self.queue.is_empty() {
            let index = if self.shuffle_enabled {
                (std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_nanos()
                    % self.queue.len() as u128) as usize
            } else {
                0
            };
            return self
                .queue
                .get(index)
                .cloned()
                .map(|item| PlaybackPlan::Next { item, index });
        }

        if self.repeat_mode == RepeatMode::All && self.current_song_id.is_some() {
            return self
                .history
                .front()
                .cloned()
                .or_else(|| {
                    self.current_song_id
                        .zip(self.current_path.clone())
                        .map(|(song_id, path)| QueueItem { song_id, path })
                })
                .map(PlaybackPlan::RepeatAll);
        }
        None
    }

    pub(crate) fn plan_previous(&self) -> Option<PlaybackPlan> {
        self.history.back().cloned().map(PlaybackPlan::Previous)
    }

    pub(crate) fn plan_skip(&self, position: usize) -> Result<PlaybackPlan, AudioError> {
        self.queue
            .get(position)
            .cloned()
            .map(|item| PlaybackPlan::Skip { item, position })
            .ok_or(AudioError::PositionOutOfBounds)
    }

    pub(crate) fn commit_plan(
        &mut self,
        plan: PlaybackPlan,
        prepared: PreparedSound,
    ) -> Result<(), AudioError> {
        self.synchronize_gapless();
        let previous = self
            .current_song_id
            .zip(self.current_path.clone())
            .map(|(song_id, path)| QueueItem { song_id, path });
        let next_song_id = plan.song_id();
        self.play_prepared(prepared)?;
        self.apply_queue_plan(plan, previous)?;
        self.current_song_id = Some(next_song_id);
        Ok(())
    }

    fn apply_queue_plan(
        &mut self,
        plan: PlaybackPlan,
        previous: Option<QueueItem>,
    ) -> Result<(), AudioError> {
        match plan {
            PlaybackPlan::RepeatCurrent(_) => {}
            PlaybackPlan::Next { index, .. } => {
                self.queue.remove(index).ok_or(AudioError::FailedToRemove)?;
                if let Some(previous) = previous {
                    self.push_history(previous);
                }
            }
            PlaybackPlan::RepeatAll(_) => {
                if let Some(previous) = previous {
                    self.push_history(previous);
                }
                self.history.pop_front();
                self.queue.extend(self.history.drain(..));
            }
            PlaybackPlan::Previous(_) => {
                self.history.pop_back().ok_or(AudioError::FailedToRemove)?;
                if let Some(previous) = previous {
                    self.queue.push_front(previous);
                }
            }
            PlaybackPlan::Skip { position, .. } => {
                for _ in 0..position {
                    if let Some(item) = self.queue.pop_front() {
                        self.push_history(item);
                    }
                }
                self.queue.pop_front().ok_or(AudioError::FailedToRemove)?;
                if let Some(previous) = previous {
                    self.push_history(previous);
                }
            }
        }
        Ok(())
    }

    pub(crate) fn synchronize_gapless(&mut self) {
        if let Some(transport) = &mut self.gapless {
            transport.collect();
        }
        let activated = self.scheduled_next.as_ref().is_some_and(|next| {
            self.gapless.as_ref().is_some_and(|transport| {
                transport.shared.active.load(Ordering::Acquire) == next.token
            })
        });
        if !activated {
            return;
        }
        let next = self.scheduled_next.take().unwrap();
        let previous_id = self.current_song_id;
        let previous = self
            .current_song_id
            .zip(self.current_path.take())
            .map(|(song_id, path)| QueueItem { song_id, path });
        let next_id = next.plan.song_id();
        // Queue changes invalidate a pending transition before editing indices.
        self.apply_queue_plan(next.plan, previous)
            .expect("scheduled queue plan remains valid");
        self.current_sound = Some(next.sound);
        self.current_song_id = Some(next_id);
        self.current_path = Some(next.path);
        self.total_duration = Some(next.duration);
        self.current_gain_db = next.gain_db;
        self.paused_position = None;
        self.completed_transitions.push_back((previous_id, next_id));
    }

    fn invalidate_gapless(&mut self) {
        if let Some(transport) = &mut self.gapless {
            let pending = transport.shared.pending.swap(0, Ordering::AcqRel);
            // If the renderer already claimed the boundary, reconcile that
            // transition before changing queue indices. Only the control thread
            // may wait; the audio thread never takes a lock or waits for us.
            if pending & super::gapless::ACTIVATING != 0 {
                let token = pending & !super::gapless::ACTIVATING;
                while transport.shared.active.load(Ordering::Acquire) != token {
                    std::thread::yield_now();
                }
            }
        }
        self.synchronize_gapless();
        if let Some(mut next) = self.scheduled_next.take() {
            next.sound.stop(Tween {
                duration: Duration::ZERO,
                ..Default::default()
            });
        }
    }

    pub(crate) fn cancel_gapless_transition(&mut self) {
        self.invalidate_gapless();
    }

    fn activated_next(&self) -> Option<&ScheduledNext> {
        self.scheduled_next.as_ref().filter(|next| {
            self.gapless.as_ref().is_some_and(|transport| {
                transport.shared.active.load(Ordering::Acquire) == next.token
            })
        })
    }

    fn active_sound(&self) -> Option<&SoundHandle> {
        self.activated_next()
            .map(|next| &next.sound)
            .or(self.current_sound.as_ref())
    }

    pub(crate) fn gapless_plan(&self) -> Option<PlaybackPlan> {
        (self.playback_requested && self.current_sound.is_some() && self.scheduled_next.is_none())
            .then(|| self.plan_next())
            .flatten()
    }

    pub(crate) fn schedule_gapless(
        &mut self,
        plan: PlaybackPlan,
        prepared: PreparedSound,
    ) -> Result<(), AudioError> {
        if self.scheduled_next.is_some() || self.gapless.is_none() {
            return Ok(());
        }
        let duration = prepared.sound_data.duration();
        let token = self.next_token;
        self.next_token += 1;
        let volume_db = self.volume_db(prepared.gain_db);
        let (voice, sound) = Voice::prepare(prepared.sound_data.volume(volume_db), token)
            .map_err(|error| AudioError::Kira(Box::new(error)))?;
        let transport = self.gapless.as_mut().unwrap();
        transport.collect();
        transport.shared.pending.store(token, Ordering::Release);
        transport
            .incoming
            .push(voice)
            .map_err(|_| AudioError::FailedToRemove)?;
        self.scheduled_next = Some(ScheduledNext {
            plan,
            sound,
            duration,
            path: prepared.path,
            gain_db: prepared.gain_db,
            token,
        });
        Ok(())
    }

    async fn prepare_gapless_next(&mut self) -> Result<(), AudioError> {
        self.synchronize_gapless();
        if let Some(plan) = self.gapless_plan() {
            let prepared =
                Self::prepare_sound(plan.path().to_string(), self.normalize_volume).await?;
            self.schedule_gapless(plan, prepared)?;
        }
        Ok(())
    }

    pub(crate) fn pop_completed_transition(&mut self) -> Option<(Option<i64>, i64)> {
        self.completed_transitions.pop_front()
    }

    pub(crate) fn completed_playback_plan(&self) -> Option<PlaybackPlan> {
        (self.playback_requested && self.is_empty())
            .then(|| self.plan_next())
            .flatten()
    }

    pub(crate) fn restored_track(&self) -> Option<(i64, String, f64)> {
        if self.current_sound.is_some() {
            return None;
        }
        self.current_song_id
            .zip(self.current_path.clone())
            .map(|(song_id, path)| (song_id, path, self.paused_position.unwrap_or_default()))
    }

    pub fn insert_at_position(&mut self, song_id: i64, path: String, position: usize) {
        self.invalidate_gapless();
        let item = QueueItem { song_id, path };
        if position >= self.queue.len() {
            self.queue.push_back(item);
        } else {
            self.queue.insert(position, item);
        }
    }

    pub async fn play_next(&mut self) -> Result<bool, AudioError> {
        self.invalidate_gapless();
        if self.repeat_mode == RepeatMode::One {
            if let Some(path) = self.current_path.clone() {
                self.play(path).await?;
                return Ok(true);
            }
        }

        let next_item = if self.shuffle_enabled && !self.queue.is_empty() {
            let index = (std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos()
                % self.queue.len() as u128) as usize;
            self.queue.remove(index)
        } else {
            self.queue.pop_front()
        };

        if let Some(next_item) = next_item {
            // A successful transition is the only time the active item moves
            // into history. Pressing Next with an empty queue must leave the
            // current track playing and must not manufacture a history entry.
            if let (Some(song_id), Some(path)) = (self.current_song_id, &self.current_path) {
                self.push_history(QueueItem {
                    song_id,
                    path: path.clone(),
                });
            }
            self.current_song_id = Some(next_item.song_id);
            self.play(next_item.path).await?;
            Ok(true)
        } else if self.repeat_mode == RepeatMode::All
            && self.current_song_id.is_some()
            && !self.history.is_empty()
        {
            if let (Some(song_id), Some(path)) = (self.current_song_id, &self.current_path) {
                self.push_history(QueueItem {
                    song_id,
                    path: path.clone(),
                });
            }
            let next_item = self.history.pop_front().ok_or(AudioError::FailedToRemove)?;
            self.queue.extend(self.history.drain(..));
            self.current_song_id = Some(next_item.song_id);
            self.play(next_item.path).await?;
            Ok(true)
        } else {
            Ok(false)
        }
    }

    pub async fn play_previous(&mut self) -> Result<bool, AudioError> {
        self.invalidate_gapless();
        if let Some(prev_item) = self.history.pop_back() {
            // Add current song back to front of queue if playing
            if let (Some(song_id), Some(path)) = (self.current_song_id, &self.current_path) {
                self.queue.push_front(QueueItem {
                    song_id,
                    path: path.clone(),
                });
            }

            self.current_song_id = Some(prev_item.song_id);
            self.play(prev_item.path).await?;
            Ok(true)
        } else {
            Ok(false)
        }
    }

    pub async fn skip_to(&mut self, position: usize) -> Result<(), AudioError> {
        self.invalidate_gapless();
        if position >= self.queue.len() {
            return Err(AudioError::PositionOutOfBounds);
        }

        // Remove all items before the target position and add them to history
        for _ in 0..position {
            if let Some(item) = self.queue.pop_front() {
                self.push_history(item);
            }
        }

        // Play the target song
        self.play_next().await?;
        Ok(())
    }

    pub fn remove_from_queue(&mut self, position: usize) -> Result<QueueItem, AudioError> {
        self.invalidate_gapless();
        if position >= self.queue.len() {
            return Err(AudioError::PositionOutOfBounds);
        }
        self.queue
            .remove(position)
            .ok_or(AudioError::FailedToRemove)
    }

    pub fn clear_queue(&mut self) {
        self.invalidate_gapless();
        self.queue.clear();
    }

    pub fn get_queue(&self) -> Vec<(i64, String)> {
        self.queue
            .iter()
            .map(|item| (item.song_id, item.path.clone()))
            .collect()
    }

    /// Returns the presentation queue: the active track first, followed by
    /// upcoming tracks. The internal queue itself intentionally stores only
    /// upcoming tracks so advancing is an efficient pop from the front.
    pub fn get_playback_queue(&self) -> Vec<(i64, String)> {
        let mut items = Vec::with_capacity(self.queue.len() + 1);
        if let (Some(song_id), Some(path)) = (self.current_song_id, &self.current_path) {
            items.push((song_id, path.clone()));
        }
        items.extend(self.get_queue());
        items
    }

    pub fn get_current_song_id(&self) -> Option<i64> {
        self.activated_next()
            .map(|next| next.plan.song_id())
            .or(self.current_song_id)
    }

    /// Restores a persisted session without starting audio. `resume` can then
    /// load the current path and seek to the stored position on user intent.
    pub fn restore_session(
        &mut self,
        current_track: Option<(i64, String)>,
        upcoming_tracks: Vec<(i64, String)>,
        position_seconds: f64,
        shuffle_enabled: bool,
        repeat_mode: RepeatMode,
    ) {
        self.stop_sound();
        self.current_song_id = current_track.as_ref().map(|(song_id, _)| *song_id);
        self.current_path = current_track.map(|(_, path)| path);
        self.paused_position = self.current_song_id.map(|_| position_seconds.max(0.0));
        self.queue = upcoming_tracks
            .into_iter()
            .map(|(song_id, path)| QueueItem { song_id, path })
            .collect();
        self.shuffle_enabled = shuffle_enabled;
        self.repeat_mode = repeat_mode;
        self.playback_requested = false;
    }

    /// Starts a restored session from its paused position, if necessary.
    pub async fn resume_restored(&mut self) -> Result<bool, AudioError> {
        if self.current_sound.is_some() {
            self.resume();
            return Ok(true);
        }
        let Some(path) = self.current_path.clone() else {
            return Ok(false);
        };
        let position = self.paused_position.unwrap_or_default();
        self.play(path).await?;
        if position > 0.0 {
            self.seek_to_position(position as u64).await?;
        }
        Ok(true)
    }

    pub fn shuffle_enabled(&self) -> bool {
        self.shuffle_enabled
    }

    pub fn set_shuffle_enabled(&mut self, enabled: bool) {
        self.invalidate_gapless();
        self.shuffle_enabled = enabled;
    }

    pub fn repeat_mode(&self) -> RepeatMode {
        self.repeat_mode
    }

    pub fn set_repeat_mode(&mut self, mode: RepeatMode) {
        self.invalidate_gapless();
        self.repeat_mode = mode;
    }

    pub fn move_in_queue(&mut self, from: usize, to: usize) -> Result<(), AudioError> {
        self.invalidate_gapless();
        if from >= self.queue.len() || to >= self.queue.len() {
            return Err(AudioError::PositionOutOfBounds);
        }

        let item = self.queue.remove(from).ok_or(AudioError::FailedToRemove)?;
        self.queue.insert(to, item);
        Ok(())
    }

    pub async fn check_and_play_next(&mut self) -> Result<bool, AudioError> {
        self.prepare_gapless_next().await?;
        if self.pop_completed_transition().is_some() {
            return Ok(true);
        }
        if self.playback_requested && self.is_empty() {
            self.play_next().await
        } else {
            Ok(false)
        }
    }

    // Database persistence methods
    pub fn load_queue(&mut self, data: QueueData) -> Result<(), AudioError> {
        self.invalidate_gapless();
        self.queue = data.items.into_iter().collect();
        self.history.clear();
        Ok(())
    }

    pub fn load_queue_from_db_blocking(
        conn: &rusqlite::Connection,
    ) -> Result<QueueData, AudioError> {
        let mut stmt = conn.prepare(
            "SELECT q.song_id, s.file_path
             FROM queue q
             JOIN songs s ON q.song_id = s.song_id
             ORDER BY q.position ASC",
        )?;

        let items: Result<Vec<QueueItem>, _> = stmt
            .query_map([], |row| {
                Ok(QueueItem {
                    song_id: row.get(0)?,
                    path: row.get(1)?,
                })
            })?
            .collect();

        Ok(QueueData { items: items? })
    }

    pub fn queue_is_empty(&self) -> bool {
        self.queue.is_empty()
    }

    pub fn get_playback_state(&self) -> Option<kira::sound::PlaybackState> {
        self.active_sound().map(|sound| sound.state())
    }
}

#[cfg(test)]
mod tests {
    use super::{AudioPlayer, MAX_PLAYBACK_HISTORY_ITEMS, QueueItem};
    use crate::api::RepeatMode;
    use std::time::{Duration, SystemTime, UNIX_EPOCH};

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

    fn temporary_tracks(label: &str, count: usize) -> (std::path::PathBuf, Vec<String>) {
        let directory = std::env::temp_dir().join(format!(
            "durvald-gapless-{label}-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&directory).unwrap();
        let paths = (0..count)
            .map(|index| {
                let path = directory.join(format!("{index}.wav"));
                std::fs::write(&path, wav_fixture()).unwrap();
                path.to_string_lossy().into_owned()
            })
            .collect();
        (directory, paths)
    }

    #[tokio::test]
    async fn gapless_queue_reorder_cancels_the_old_successor() {
        let (directory, paths) = temporary_tracks("reorder", 3);
        let mut player = AudioPlayer::new_mock().unwrap();
        for (index, path) in paths.iter().enumerate() {
            player
                .add_to_queue(index as i64 + 1, path.clone())
                .await
                .unwrap();
        }
        player.move_in_queue(1, 0).unwrap();
        player.prepare_gapless_next().await.unwrap();
        tokio::time::sleep(Duration::from_millis(20)).await;
        player.process_mock_audio(80);
        assert_eq!(player.get_current_song_id(), Some(3));
        assert!(!player.is_empty());
        player.synchronize_gapless();
        assert_eq!(player.get_queue(), vec![(2, paths[1].clone())]);
        assert_eq!(player.history.back().map(|item| item.song_id), Some(1));
        player.stop();
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[tokio::test]
    async fn repeat_one_and_single_track_repeat_all_restart_without_a_control_poll() {
        let (directory, paths) = temporary_tracks("repeat", 1);
        for mode in [RepeatMode::One, RepeatMode::All] {
            let mut player = AudioPlayer::new_mock().unwrap();
            player.play_song(1, paths[0].clone()).await.unwrap();
            player.set_repeat_mode(mode);
            player.prepare_gapless_next().await.unwrap();
            tokio::time::sleep(Duration::from_millis(20)).await;
            player.process_mock_audio(80);
            assert!(!player.is_empty(), "repeat must already be audible");
            assert_eq!(player.get_current_song_id(), Some(1));
            player.synchronize_gapless();
            assert_eq!(player.pop_completed_transition(), Some((Some(1), 1)));
            assert!(player.queue_is_empty());
            player.stop();
        }
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[tokio::test]
    async fn removing_the_prebuffered_track_prevents_automatic_playback() {
        let (directory, paths) = temporary_tracks("remove", 2);
        let mut player = AudioPlayer::new_mock().unwrap();
        player.add_to_queue(1, paths[0].clone()).await.unwrap();
        player.add_to_queue(2, paths[1].clone()).await.unwrap();
        player.remove_from_queue(0).unwrap();
        tokio::time::sleep(Duration::from_millis(20)).await;
        player.process_mock_audio(80);
        player.synchronize_gapless();
        assert_eq!(player.get_current_song_id(), Some(1));
        assert!(player.is_empty());
        assert!(player.pop_completed_transition().is_none());
        player.stop();
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn playback_history_discards_the_oldest_items_at_its_limit() {
        let mut player = AudioPlayer::new_mock().expect("create mock player");
        for song_id in 0..=MAX_PLAYBACK_HISTORY_ITEMS as i64 {
            player.push_history(QueueItem {
                song_id,
                path: format!("/{song_id}.mp3"),
            });
        }

        assert_eq!(player.history.len(), MAX_PLAYBACK_HISTORY_ITEMS);
        assert_eq!(player.history.front().map(|item| item.song_id), Some(1));
        assert_eq!(
            player.history.back().map(|item| item.song_id),
            Some(MAX_PLAYBACK_HISTORY_ITEMS as i64)
        );
    }

    #[tokio::test]
    async fn mock_backend_plays_and_advances_queue_without_an_audio_device() {
        let directory = std::env::temp_dir().join(format!(
            "durvald-player-test-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("current time")
                .as_nanos()
        ));
        std::fs::create_dir_all(&directory).expect("create temporary test directory");
        let first = directory.join("first.wav");
        let second = directory.join("second.wav");
        std::fs::write(&first, wav_fixture()).expect("write first test audio file");
        std::fs::write(&second, wav_fixture()).expect("write second test audio file");

        let mut player = AudioPlayer::new_mock().expect("create mock player");
        player
            .add_to_queue(1, first.to_string_lossy().into_owned())
            .await
            .expect("play first item with mock backend");
        player
            .add_to_queue(2, second.to_string_lossy().into_owned())
            .await
            .expect("queue second item");

        assert_eq!(player.get_current_song_id(), Some(1));
        assert_eq!(
            player.get_queue(),
            vec![(2, second.to_string_lossy().into_owned())]
        );
        assert!(player.play_next().await.expect("advance queue"));
        assert_eq!(player.get_current_song_id(), Some(2));
        assert!(player.get_queue().is_empty());

        std::fs::remove_dir_all(directory).expect("remove temporary test directory");
    }

    #[tokio::test]
    async fn failed_replacement_keeps_the_current_track_loaded() {
        let directory = std::env::temp_dir().join(format!(
            "durvald-player-replacement-test-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("current time")
                .as_nanos()
        ));
        std::fs::create_dir_all(&directory).expect("create temporary test directory");
        let valid_file = directory.join("playing.wav");
        std::fs::write(&valid_file, wav_fixture()).expect("write test audio file");

        let mut player = AudioPlayer::new_mock().expect("create mock player");
        player
            .play_song(7, valid_file.to_string_lossy().into_owned())
            .await
            .expect("play valid track");
        let missing_file = directory.join("missing.wav").to_string_lossy().into_owned();
        assert!(player.play_song(8, missing_file).await.is_err());

        assert_eq!(player.get_current_song_id(), Some(7));
        let expected_path = valid_file.to_string_lossy().into_owned();
        assert_eq!(player.current_path.as_deref(), Some(expected_path.as_str()));
        assert!(!player.is_empty());

        std::fs::remove_dir_all(directory).expect("remove temporary test directory");
    }

    #[tokio::test]
    async fn next_with_no_queue_keeps_the_current_track_and_history_unchanged() {
        let directory = std::env::temp_dir().join(format!(
            "durvald-player-empty-next-test-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("current time")
                .as_nanos()
        ));
        std::fs::create_dir_all(&directory).expect("create temporary test directory");
        let audio_file = directory.join("playing.wav");
        std::fs::write(&audio_file, wav_fixture()).expect("write test audio file");

        let mut player = AudioPlayer::new_mock().expect("create mock player");
        player
            .play_song(1, audio_file.to_string_lossy().into_owned())
            .await
            .expect("play test track");

        assert!(!player.play_next().await.expect("attempt next"));
        assert_eq!(player.get_current_song_id(), Some(1));
        assert!(!player.is_empty());
        assert!(player.history.is_empty());

        std::fs::remove_dir_all(directory).expect("remove temporary test directory");
    }

    #[tokio::test]
    async fn completed_mock_track_advances_to_the_next_queue_item() {
        let directory = std::env::temp_dir().join(format!(
            "durvald-player-completion-test-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("current time")
                .as_nanos()
        ));
        std::fs::create_dir_all(&directory).expect("create temporary test directory");
        let first = directory.join("first.wav");
        let second = directory.join("second.wav");
        std::fs::write(&first, wav_fixture()).expect("write first test audio file");
        std::fs::write(&second, wav_fixture()).expect("write second test audio file");

        let mut player = AudioPlayer::new_mock().expect("create mock player");
        player
            .add_to_queue(1, first.to_string_lossy().into_owned())
            .await
            .expect("play first item");
        player
            .add_to_queue(2, second.to_string_lossy().into_owned())
            .await
            .expect("queue second item");

        tokio::time::sleep(Duration::from_millis(20)).await;
        player.process_mock_audio(80);
        assert!(
            !player.is_empty(),
            "successor is already playing before a control/UI poll"
        );
        assert_eq!(player.get_current_song_id(), Some(2));
        assert!(player.check_and_play_next().await.expect("advance queue"));
        assert_eq!(player.get_current_song_id(), Some(2));

        std::fs::remove_dir_all(directory).expect("remove temporary test directory");
    }

    #[tokio::test]
    async fn mock_backend_applies_pause_and_resume_commands() {
        let directory = std::env::temp_dir().join(format!(
            "durvald-player-pause-test-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("current time")
                .as_nanos()
        ));
        std::fs::create_dir_all(&directory).expect("create temporary test directory");
        let audio_file = directory.join("tone.wav");
        std::fs::write(&audio_file, wav_fixture()).expect("write test audio file");

        let mut player = AudioPlayer::new_mock().expect("create mock player");
        player
            .play_song(1, audio_file.to_string_lossy().into_owned())
            .await
            .expect("play test track");
        player.process_mock_audio(1);
        player.pause();
        player.process_mock_audio(1);
        assert!(player.is_paused());

        player.resume();
        player.process_mock_audio(1);
        assert!(!player.is_paused());
        assert!(!player.is_empty());

        std::fs::remove_dir_all(directory).expect("remove temporary test directory");
    }

    #[tokio::test]
    async fn repeat_modes_preserve_the_expected_queue_order() {
        let directory = std::env::temp_dir().join(format!(
            "durvald-player-repeat-test-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("current time")
                .as_nanos()
        ));
        std::fs::create_dir_all(&directory).expect("create temporary test directory");
        let first = directory.join("first.wav");
        let second = directory.join("second.wav");
        std::fs::write(&first, wav_fixture()).expect("write first test audio file");
        std::fs::write(&second, wav_fixture()).expect("write second test audio file");

        let mut player = AudioPlayer::new_mock().expect("create mock player");
        player
            .add_to_queue(1, first.to_string_lossy().into_owned())
            .await
            .expect("play first item");
        player
            .add_to_queue(2, second.to_string_lossy().into_owned())
            .await
            .expect("queue second item");

        player.set_repeat_mode(RepeatMode::One);
        assert!(player.play_next().await.expect("repeat current track"));
        assert_eq!(player.get_current_song_id(), Some(1));
        assert_eq!(player.get_queue().len(), 1);
        assert!(player.history.is_empty());

        player.set_repeat_mode(RepeatMode::All);
        assert!(player.play_next().await.expect("advance to second track"));
        assert_eq!(player.get_current_song_id(), Some(2));
        assert!(player.play_next().await.expect("loop back to first track"));
        assert_eq!(player.get_current_song_id(), Some(1));
        assert_eq!(
            player.get_queue(),
            vec![(2, second.to_string_lossy().into_owned())]
        );

        std::fs::remove_dir_all(directory).expect("remove temporary test directory");
    }

    #[tokio::test]
    async fn paused_seek_is_preserved_and_shuffle_consumes_one_upcoming_item() {
        let directory = std::env::temp_dir().join(format!(
            "durvald-player-seek-shuffle-test-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("current time")
                .as_nanos()
        ));
        std::fs::create_dir_all(&directory).expect("create temporary test directory");
        let first = directory.join("first.wav");
        let second = directory.join("second.wav");
        let third = directory.join("third.wav");
        for path in [&first, &second, &third] {
            std::fs::write(path, wav_fixture()).expect("write test audio file");
        }

        let mut player = AudioPlayer::new_mock().expect("create mock player");
        player
            .add_to_queue(1, first.to_string_lossy().into_owned())
            .await
            .unwrap();
        player
            .add_to_queue(2, second.to_string_lossy().into_owned())
            .await
            .unwrap();
        player
            .add_to_queue(3, third.to_string_lossy().into_owned())
            .await
            .unwrap();

        player.pause();
        player.process_mock_audio(1);
        player.seek_to_position(1).await.unwrap();
        assert_eq!(player.get_position(), Duration::from_secs(1));
        assert!(player.is_paused());

        player.set_shuffle_enabled(true);
        assert!(player.play_next().await.unwrap());
        assert!(matches!(player.get_current_song_id(), Some(2 | 3)));
        assert_eq!(player.get_queue().len(), 1);

        std::fs::remove_dir_all(directory).expect("remove temporary test directory");
    }

    #[test]
    fn crossfade_configuration_requires_a_nonzero_enabled_duration() {
        let mut player = AudioPlayer::new_mock().expect("create mock player");
        player.set_crossfade(true, 5);
        assert_eq!(player.crossfade_duration, Some(Duration::from_secs(5)));

        player.set_crossfade(false, 5);
        assert_eq!(player.crossfade_duration, None);
        player.set_crossfade(true, 0);
        assert_eq!(player.crossfade_duration, None);
    }
}
