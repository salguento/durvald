//! Playlist domain values shared across application and infrastructure.

use crate::domain::ids::{PlaylistId, TrackId};

pub(crate) struct PlaylistTrackEntry {
    pub(crate) playlist_id: PlaylistId,
    pub(crate) track_id: TrackId,
    pub(crate) position: u64,
    pub(crate) added_at: String,
}
