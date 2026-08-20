use kira::sound::streaming::{StreamingSoundData, StreamingSoundHandle};
use kira::sound::FromFileError;
use kira::Tween;
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
}

pub struct AudioPlayer {
    manager: AudioManager<DefaultBackend>,
    current_sound: Option<SoundHandle>,
    total_duration: Option<Duration>,
    current_path: Option<String>,
    paused_position: Option<f64>,
    current_volume: f32,
    queue: VecDeque<QueueItem>,
    history: Vec<QueueItem>,
    current_song_id: Option<i64>,
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
        Ok(Self {
            manager,
            current_sound: None,
            total_duration: None,
            current_path: None,
            paused_position: None,
            current_volume: 0.0,
            queue: VecDeque::new(),
            history: Vec::new(),
            current_song_id: None,
        })
    }

    pub async fn play(&mut self, path: String) -> Result<(), AudioError> {
        self.stop();

        let path_clone = path.clone();

        // Load streaming sound data - starts playing immediately
        let sound_data = tokio::task::spawn_blocking(move || StreamingSoundData::from_file(&path_clone))
            .await
            .map_err(AudioError::Join)?;

        let sound_data = sound_data.map_err(|e| AudioError::Kira(Box::new(e)))?;

        self.total_duration = Some(sound_data.duration());
        self.current_path = Some(path.clone());
        self.paused_position = None;

        let sound_handle = self.manager.play(sound_data).map_err(|e| AudioError::Kira(Box::new(e)))?;
        self.current_sound = Some(sound_handle);
        self.set_volume(self.current_volume);
        Ok(())
    }

    pub fn pause(&mut self) {
        if let Some(sound) = &mut self.current_sound {
            self.paused_position = Some(sound.position());
            let _ = sound.pause(Tween::default());
        }
    }

    pub fn resume(&mut self) {
        if let Some(sound) = &mut self.current_sound {
            let _ = sound.resume(Tween::default());
            self.paused_position = None;
        }
    }

    pub fn stop(&mut self) {
        if let Some(mut sound) = self.current_sound.take() {
            let _ = sound.stop(Tween::default());
        }
        self.total_duration = None;
        self.current_path = None;
        self.paused_position = None;
    }

    pub fn set_volume(&mut self, volume: f32) {
        self.current_volume = volume;

        if let Some(sound) = &mut self.current_sound {
            let volume_db = if volume > 0.00001 {
                20.0 * volume.log10()
            } else {
                -80.0
            };

            sound.set_volume(volume_db as f32, Tween::default());
        }
    }

    pub fn is_paused(&self) -> bool {
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
        // Add current song to history if playing
        if let (Some(song_id), Some(path)) = (self.current_song_id, &self.current_path) {
            self.history.push(QueueItem {
                song_id,
                path: path.clone(),
            });
        }

        if let Some(next_item) = self.queue.pop_front() {
            self.current_song_id = Some(next_item.song_id);
            self.play(next_item.path).await?;
            Ok(true)
        } else {
            self.current_song_id = None;
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

    pub fn get_current_song_id(&self) -> Option<i64> {
        self.current_song_id
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
        if self.is_empty() && !self.queue.is_empty() {
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