//! Platform-hosted, visible playback. Commands and events are scoped to one generation.
use serde::{Deserialize, Serialize};
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum EmbeddedPlaybackState {
    Loading,
    Playing,
    Paused,
    Ended,
    Failed,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum EmbeddedCommandKind {
    Load,
    Play,
    Pause,
    Seek,
    Volume,
    Stop,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct EmbeddedPlaybackCommand {
    pub generation: String,
    pub kind: EmbeddedCommandKind,
    pub url: Option<String>,
    pub value: f64,
}
/// Stop must synchronously destroy/silence the old player before returning true.
/// Other commands acknowledge delivery; only subsequent events confirm playback.
#[cfg_attr(feature = "uniffi", uniffi::export(callback_interface))]
pub trait EmbeddedPlaybackHost: Send + Sync {
    fn execute(&self, command: EmbeddedPlaybackCommand) -> bool;
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum EmbeddedEventKind {
    Ready,
    Playing,
    Paused,
    Progress,
    Seeked,
    Ended,
    Failed,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct EmbeddedPlaybackEvent {
    pub generation: String,
    pub sequence: u64,
    pub kind: EmbeddedEventKind,
    pub position_seconds: f64,
    pub duration_seconds: Option<f64>,
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct EmbeddedPlaybackSnapshot {
    pub generation: String,
    pub track_id: Option<i64>,
    pub source_id: Option<i64>,
    pub canonical_url: String,
    pub title: String,
    pub artist: Option<String>,
    pub state: EmbeddedPlaybackState,
    pub seek_available: bool,
    pub message: Option<String>,
}

/// Current source selection, including a visible pre-playback fallback notice.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct PlaybackSourceStatus {
    pub source_id: Option<i64>,
    pub provider: String,
    pub message: Option<String>,
}
