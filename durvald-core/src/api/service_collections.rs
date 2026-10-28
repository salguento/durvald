//! Explicit service metadata imports; never streams, purchased files or account cookies.
use serde::{Deserialize, Serialize};
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum ServiceProvider {
    Bandcamp,
    SoundCloud,
    YouTube,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct ServiceImportSettings {
    pub provider: ServiceProvider,
    pub enabled: bool,
    pub has_credential: bool,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum ServiceMediaAccess {
    Unknown,
    StreamObserved,
    Preview,
    Restricted,
    Unavailable,
    UnsupportedLive,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum ServiceImportFailure {
    Disabled,
    Authentication,
    Restricted,
    NotFound,
    TimedOut,
    RateLimited,
    Unavailable,
    InvalidResponse,
    ChangedCollection,
    Cancelled,
    LimitReached,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct ServiceCollectionItem {
    pub occurrence_id: String,
    pub position: u32,
    pub entry: Option<super::CatalogEntry>,
    pub access: ServiceMediaAccess,
    pub saved_track_id: Option<i64>,
    pub failure: Option<ServiceImportFailure>,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct ServiceCollectionJob {
    pub job_id: String,
    pub provider: ServiceProvider,
    pub canonical_url: String,
    pub title: String,
    pub is_collection: bool,
    pub items: Vec<ServiceCollectionItem>,
    pub next_cursor: Option<String>,
    pub loaded_pages: u32,
    pub complete: bool,
    pub truncated: bool,
    pub from_cache: bool,
    pub cancelled: bool,
    pub playlist_id: Option<i64>,
    pub failure: Option<ServiceImportFailure>,
}
