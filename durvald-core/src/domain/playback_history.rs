//! Playback-history domain model.

use crate::domain::ids::{PlaybackHistoryId, TrackId};

pub(crate) struct PlaybackHistoryEntry {
    pub(crate) id: PlaybackHistoryId,
    pub(crate) track_id: TrackId,
    pub(crate) played_at: String,
    pub(crate) duration_seconds: u64,
}
