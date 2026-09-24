//! Playlist domain values shared across application and infrastructure.

use crate::domain::ids::{PlaylistId, TrackId};

pub(crate) struct PlaylistDetails {
    pub(crate) id: PlaylistId,
    pub(crate) name: String,
    pub(crate) artwork: Option<Vec<u8>>,
    pub(crate) description: String,
    pub(crate) is_favorite: bool,
    pub(crate) suggest_less: bool,
    pub(crate) created_at: String,
    pub(crate) updated_at: String,
}

pub(crate) struct PlaylistSummary {
    pub(crate) playlist: PlaylistDetails,
    pub(crate) track_count: u64,
}

pub(crate) struct PlaylistTrackEntry {
    pub(crate) playlist_id: PlaylistId,
    pub(crate) track_id: TrackId,
    pub(crate) position: u64,
    pub(crate) added_at: String,
}
