//! Playback-history domain model.

use crate::domain::ids::{PlaybackHistoryId, TrackId};

pub(crate) struct PlaybackHistoryEntry {
    pub(crate) source_id: Option<i64>,
    pub(crate) effective_duration_seconds: Option<u64>,
    pub(crate) id: PlaybackHistoryId,
    pub(crate) track_id: TrackId,
    pub(crate) played_at: String,
    pub(crate) duration_seconds: u64,
}
