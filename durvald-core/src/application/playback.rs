//! Playback use-case coordination.
//!
//! Responsibilities move here incrementally while [`crate::core::DurvaldCore`]
//! remains the stable public facade.

use std::sync::Arc;

use crate::{audio::AudioPlayer, lastfm::LastFmClient};

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
}
