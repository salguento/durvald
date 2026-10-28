//! Ephemeral acquisition discovery. No transfer commands or persistent source URLs.
use serde::{Deserialize, Serialize};
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct DownloadSearchSettings {
    pub enabled: bool,
    pub endpoint: String,
    pub has_api_key: bool,
    pub sharing_acknowledged: bool,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct DownloadExpectedTrack {
    pub title: String,
    pub disc: u32,
    pub position: u32,
    pub duration_seconds: Option<u64>,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct DownloadSearchRequest {
    pub query: String,
    pub expected_tracks: Vec<DownloadExpectedTrack>,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct DownloadOfferFile {
    pub filename: String,
    pub size_bytes: u64,
    pub format: String,
    pub duration_seconds: Option<u64>,
    pub bitrate_kbps: Option<u32>,
    pub sample_rate_hz: Option<u32>,
    pub bit_depth: Option<u32>,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct DownloadOfferGroup {
    pub offer_id: String,
    pub peer: String,
    pub folder: String,
    pub files: Vec<DownloadOfferFile>,
    pub total_bytes: u64,
    pub free_upload_slot: Option<bool>,
    pub queue_length: Option<u64>,
    pub upload_speed_bytes: Option<u64>,
    pub matched_tracks: u32,
    pub expected_tracks: u32,
    pub duration_matches: u32,
    pub comparison: String,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum DownloadSearchState {
    Searching,
    Completed,
    TimedOut,
    Cancelled,
    Failed,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum DownloadSearchFailure {
    Disabled,
    Configuration,
    Authentication,
    Unavailable,
    TimedOut,
    RateLimited,
    InvalidResponse,
    Cancelled,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct DownloadSearchPage {
    pub generation: u64,
    pub state: DownloadSearchState,
    pub groups: Vec<DownloadOfferGroup>,
    pub failure: Option<DownloadSearchFailure>,
    pub truncated: bool,
    pub cleanup_pending: bool,
}
