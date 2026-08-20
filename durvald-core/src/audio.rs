//! Audio playback module using kira

pub mod player;

pub use player::{AudioPlayer, QueueData, QueueItem};

/// File extensions accepted by library scanning for this MVP. They map exactly
/// to the Kira/Symphonia decoder features enabled in `Cargo.toml`: MP3, WAV,
/// FLAC, and Ogg Vorbis (whose conventional extensions are `.ogg` and `.oga`).
/// Do not add an extension here without enabling and exercising its decoder.
pub(crate) const SUPPORTED_AUDIO_EXTENSIONS: &[&str] = &["mp3", "wav", "flac", "ogg", "oga"];
