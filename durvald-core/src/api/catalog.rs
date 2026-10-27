//! Additive catalog search API. External results are not library adoption.
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum CatalogProvider {
    Library,
    MusicBrainz,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum CatalogScope {
    Library,
    Explore,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum CatalogFilter {
    All,
    Artists,
    Releases,
    Tracks,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum CatalogItemKind {
    Artist,
    ReleaseGroup,
    ReleaseEdition,
    Recording,
    Track,
    Playlist,
    ReleaseTrack,
    ServiceProfile,
    AudioTrack,
    Video,
    AlbumVideo,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum CatalogFailure {
    Disabled,
    Unavailable,
    InvalidQuery,
    RateLimited,
    TimedOut,
    Cancelled,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct CatalogQuery {
    pub query: String,
    pub scope: CatalogScope,
    pub filter: CatalogFilter,
    pub language: String,
    pub page_size: u16,
    pub cursor: Option<String>,
    pub generation: u64,
    pub cache_only: bool,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct CatalogItem {
    pub provider: CatalogProvider,
    pub kind: CatalogItemKind,
    pub id: String,
    pub local_id: Option<i64>,
    pub title: String,
    pub artist_credit: Option<String>,
    pub version_label: Option<String>,
    pub duration_seconds: Option<u64>,
    pub canonical_url: Option<String>,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct CatalogPage {
    pub provider: CatalogProvider,
    pub generation: u64,
    pub items: Vec<CatalogItem>,
    pub next_cursor: Option<String>,
    pub failure: Option<CatalogFailure>,
    pub retry_after_seconds: Option<u64>,
    pub from_cache: bool,
}

/// Identity remains provider-scoped, including provisional references without MBID.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct CatalogReference {
    pub provider: String,
    pub kind: CatalogItemKind,
    pub id: String,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct CatalogEntry {
    pub reference: CatalogReference,
    pub title: String,
    pub artist_credit: Option<String>,
    pub version_label: Option<String>,
    pub duration_seconds: Option<u64>,
    pub canonical_url: Option<String>,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct CatalogSelection {
    pub entry: CatalogEntry,
    pub local_artist_id: Option<i64>,
    pub saved_at: i64,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum CatalogDetailSection {
    Basic,
    Cover,
    Profile,
    Editions,
    Tracklist,
    Discography,
    Similar,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct CatalogDetailRequest {
    pub reference: CatalogReference,
    pub section: CatalogDetailSection,
    pub language: String,
    pub cursor: Option<String>,
    pub generation: u64,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct CatalogDetailPage {
    pub reference: CatalogReference,
    pub section: CatalogDetailSection,
    pub generation: u64,
    pub items: Vec<CatalogEntry>,
    pub profile: Option<super::ArtistProfile>,
    pub image: Option<Vec<u8>>,
    pub attribution: Option<super::EnrichmentAttribution>,
    pub next_cursor: Option<String>,
    pub failure: Option<CatalogFailure>,
    pub retry_after_seconds: Option<u64>,
    pub from_cache: bool,
}
