use crate::api::RepeatMode;
use kira::Tween;
use kira::sound::FromFileError;
use kira::sound::streaming::{StreamingSoundData, StreamingSoundHandle};
use kira::{AudioManager, AudioManagerSettings, DefaultBackend};
use std::collections::VecDeque;
use std::time::Duration;
use thiserror::Error;

type SoundHandle = StreamingSoundHandle<FromFileError>;

#[derive(Debug, Clone)]
pub struct QueueItem {
    pub song_id: i64,
    pub path: String,
}

#[derive(Debug, Clone)]
pub struct QueueData {
    pub items: Vec<QueueItem>,
    pub history: Vec<QueueItem>,
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
    history: Vec<QueueItem>,
    current_song_id: Option<i64>,
    crossfade_duration: Option<Duration>,
    shuffle_enabled: bool,
    repeat_mode: RepeatMode,
    playback_requested: bool,
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
            history: Vec::new(),
            current_song_id: None,
            crossfade_duration: None,
            shuffle_enabled: false,
            repeat_mode: RepeatMode::None,
            playback_requested: false,
        }
    }

    pub async fn play(&mut self, path: String) -> Result<(), AudioError> {
        // Replacing a track keeps the logical current-song identity set by the
        // queue transition that initiated playback.
        let path_clone = path.clone();

        // Load before stopping the active track so a missing or invalid
        // replacement does not destroy an otherwise recoverable session.
        let normalize_volume = self.normalize_volume;
        let (sound_data, gain_db) = tokio::task::spawn_blocking(move || {
            let gain_db = normalize_volume
                .then(|| crate::metadata::replay_gain_db(&path_clone))
                .flatten()
                .unwrap_or_default() as f32;
            StreamingSoundData::from_file(&path_clone).map(|sound_data| (sound_data, gain_db))
        })
        .await
        .map_err(AudioError::Join)?
        .map_err(|e| AudioError::Kira(Box::new(e)))?;

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

        let sound_handle = match &mut self.manager {
            PlayerBackend::Default(manager) => manager
                .play(sound_data)
                .map_err(|e| AudioError::Kira(Box::new(e)))?,
            #[cfg(test)]
            PlayerBackend::Mock(manager) => manager
                .play(sound_data)
                .map_err(|e| AudioError::Kira(Box::new(e)))?,
        };
        self.current_sound = Some(sound_handle);
        self.set_volume(self.current_volume);
        self.playback_requested = true;
        Ok(())
    }

    /// Starts a specific library track and records its identity for playback
    /// snapshots, history, and queue transitions.
    pub async fn play_song(&mut self, song_id: i64, path: String) -> Result<(), AudioError> {
        self.play(path).await?;
        self.current_song_id = Some(song_id);
        Ok(())
    }

    pub fn pause(&mut self) {
        if let Some(sound) = &mut self.current_sound {
            self.paused_position = Some(sound.position());
            sound.pause(Tween::default());
        }
    }

    pub fn resume(&mut self) {
        if let Some(sound) = &mut self.current_sound {
            sound.resume(Tween::default());
            self.paused_position = None;
        }
    }

    fn stop_sound(&mut self) {
        self.stop_sound_with_tween(Tween::default());
    }

    fn stop_sound_with_tween(&mut self, tween: Tween) {
        if let Some(mut sound) = self.current_sound.take() {
            sound.stop(tween);
        }
        self.total_duration = None;
        self.current_path = None;
        self.paused_position = None;
        self.current_gain_db = 0.0;
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
        self.normalize_volume = enabled;
        if !enabled {
            self.current_gain_db = 0.0;
        }
        self.apply_volume();
    }

    fn apply_volume(&mut self) {
        if let Some(sound) = &mut self.current_sound {
            let volume_db = if self.current_volume > 0.00001 {
                20.0 * self.current_volume.log10() + self.current_gain_db
            } else {
                -80.0
            };

            sound.set_volume(volume_db, Tween::default());
        }
    }

    pub fn set_crossfade(&mut self, enabled: bool, duration_seconds: u32) {
        self.crossfade_duration = enabled
            .then(|| Duration::from_secs(duration_seconds as u64))
            .filter(|duration| !duration.is_zero());
    }

    pub fn is_paused(&self) -> bool {
        if self.current_sound.is_none() {
            return self.current_song_id.is_some() && self.paused_position.is_some();
        }
        self.current_sound
            .as_ref()
            .map(|sound| {
                matches!(
                    sound.state(),
                    kira::sound::PlaybackState::Paused | kira::sound::PlaybackState::Pausing
                )
            })
            .unwrap_or(false)
    }

    pub fn is_empty(&self) -> bool {
        self.current_sound
            .as_ref()
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

        self.current_sound
            .as_ref()
            .map(|sound| Duration::from_secs_f64(sound.position()))
            .unwrap_or(Duration::ZERO)
    }

    pub fn get_duration(&self) -> Option<Duration> {
        self.total_duration
    }

    pub fn get_progress(&self) -> (Duration, Option<Duration>) {
        (self.get_position(), self.get_duration())
    }

    pub fn get_progress_percentage(&self) -> Option<f32> {
        if let Some(total) = self.total_duration {
            let current = self.get_position();
            let total_secs = total.as_secs_f32();
            if total_secs > 0.0 {
                return Some((current.as_secs_f32() / total_secs).min(1.0));
            }
        }
        None
    }

    pub async fn seek_to_position(&mut self, seconds: u64) -> Result<(), AudioError> {
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
        if let Some(duration) = self.total_duration {
            let target_seconds = (duration.as_secs_f32() * percentage.clamp(0.0, 1.0)) as u64;
            self.seek_to_position(target_seconds).await
        } else {
            Err(AudioError::DurationNotAvailable)
        }
    }

    // Queue management methods
    pub async fn add_to_queue(&mut self, song_id: i64, path: String) -> Result<(), AudioError> {
        if self.is_empty() && self.queue.is_empty() {
            // Nothing playing, start immediately
            self.current_song_id = Some(song_id);
            self.play(path).await?;
        } else {
            // Add to queue
            self.queue.push_back(QueueItem { song_id, path });
        }
        Ok(())
    }

    pub fn insert_at_position(&mut self, song_id: i64, path: String, position: usize) {
        let item = QueueItem { song_id, path };
        if position >= self.queue.len() {
            self.queue.push_back(item);
        } else {
            self.queue.insert(position, item);
        }
    }

    pub async fn play_next(&mut self) -> Result<bool, AudioError> {
        if self.repeat_mode == RepeatMode::One {
            if let Some(path) = self.current_path.clone() {
                self.play(path).await?;
                return Ok(true);
            }
        }

        // Add current song to history if playing
        if let (Some(song_id), Some(path)) = (self.current_song_id, &self.current_path) {
            self.history.push(QueueItem {
                song_id,
                path: path.clone(),
            });
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
            self.current_song_id = Some(next_item.song_id);
            self.play(next_item.path).await?;
            Ok(true)
        } else if self.repeat_mode == RepeatMode::All && !self.history.is_empty() {
            let next_item = self.history.remove(0);
            self.queue.extend(self.history.drain(..));
            self.current_song_id = Some(next_item.song_id);
            self.play(next_item.path).await?;
            Ok(true)
        } else {
            self.stop();
            Ok(false)
        }
    }

    pub async fn play_previous(&mut self) -> Result<bool, AudioError> {
        if let Some(prev_item) = self.history.pop() {
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
        if position >= self.queue.len() {
            return Err(AudioError::PositionOutOfBounds);
        }

        // Remove all items before the target position and add them to history
        for _ in 0..position {
            if let Some(item) = self.queue.pop_front() {
                self.history.push(item);
            }
        }

        // Play the target song
        self.play_next().await?;
        Ok(())
    }

    pub fn remove_from_queue(&mut self, position: usize) -> Result<QueueItem, AudioError> {
        if position >= self.queue.len() {
            return Err(AudioError::PositionOutOfBounds);
        }
        self.queue
            .remove(position)
            .ok_or(AudioError::FailedToRemove)
    }

    pub fn clear_queue(&mut self) {
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
        self.current_song_id
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
        self.shuffle_enabled = enabled;
    }

    pub fn repeat_mode(&self) -> RepeatMode {
        self.repeat_mode
    }

    pub fn set_repeat_mode(&mut self, mode: RepeatMode) {
        self.repeat_mode = mode;
    }

    pub fn move_in_queue(&mut self, from: usize, to: usize) -> Result<(), AudioError> {
        if from >= self.queue.len() || to >= self.queue.len() {
            return Err(AudioError::PositionOutOfBounds);
        }

        let item = self.queue.remove(from).ok_or(AudioError::FailedToRemove)?;
        self.queue.insert(to, item);
        Ok(())
    }

    pub async fn check_and_play_next(&mut self) -> Result<bool, AudioError> {
        if self.playback_requested && self.is_empty() {
            self.play_next().await
        } else {
            Ok(false)
        }
    }

    // Database persistence methods
    pub fn get_queue_data_for_db(&self) -> QueueData {
        QueueData {
            items: self.queue.iter().cloned().collect(),
            history: self.history.clone(),
        }
    }

    pub fn load_queue(&mut self, data: QueueData) -> Result<(), AudioError> {
        self.queue = data.items.into_iter().collect();
        self.history = data.history;
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

        Ok(QueueData {
            items: items?,
            history: Vec::new(), // History not persisted in DB
        })
    }

    pub fn save_queue_to_db_blocking(
        conn: &mut rusqlite::Connection,
        data: &QueueData,
    ) -> Result<(), AudioError> {
        let tx = conn.transaction()?;

        // Clear existing queue
        tx.execute("DELETE FROM queue", ())?;

        // Insert current queue
        for (position, item) in data.items.iter().enumerate() {
            tx.execute(
                "INSERT INTO queue (song_id, position) VALUES (?1, ?2)",
                (item.song_id, position as i64),
            )?;
        }

        tx.commit()?;
        Ok(())
    }

    pub fn queue_is_empty(&self) -> bool {
        self.queue.is_empty()
    }

    pub fn get_playback_state(&self) -> Option<kira::sound::PlaybackState> {
        self.current_sound.as_ref().map(|sound| sound.state())
    }
}

#[cfg(test)]
mod tests {
    use super::AudioPlayer;
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
        assert!(player.is_empty());
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
