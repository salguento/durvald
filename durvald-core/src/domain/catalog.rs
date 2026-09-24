//! Catalog domain models independent from SQLite rows and public DTOs.

use crate::domain::ids::{ArtistId, ReleaseId, TrackId};

pub(crate) struct CatalogTrack {
    pub(crate) id: TrackId,
    pub(crate) title: String,
    pub(crate) artwork: String,
    pub(crate) artist_id: ArtistId,
    pub(crate) artist_name: String,
    pub(crate) release_id: ReleaseId,
    pub(crate) release_title: String,
    pub(crate) track_number: u8,
    pub(crate) disc_number: u8,
    pub(crate) duration_seconds: u64,
    pub(crate) bitrate: Option<u32>,
    pub(crate) sample_rate: Option<u32>,
    pub(crate) bit_depth: Option<u8>,
    pub(crate) play_count: u64,
    pub(crate) last_played: Option<String>,
    pub(crate) rating: Option<u8>,
    pub(crate) is_favorite: bool,
    pub(crate) is_hidden: bool,
    pub(crate) suggest_less: bool,
    pub(crate) file_path: String,
}
