//! Playback-session state independent from its SQLite representation.

pub(crate) struct PlaybackSessionState {
    pub(crate) current_track_id: Option<i64>,
    pub(crate) progress_seconds: f64,
    pub(crate) volume: f64,
    pub(crate) shuffle_enabled: bool,
    pub(crate) repeat_mode: String,
    pub(crate) queue: Vec<i64>,
    pub(crate) queue_position: u64,
    pub(crate) source_context: String,
    pub(crate) updated_at: String,
}
