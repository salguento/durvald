use crate::api::{
    ArtistPartialDate, ArtistPopularTrack, ArtistProfile, EnrichmentAttribution, EnrichmentProvider,
};

/// Conditional-request metadata stays internal to Rust.
#[derive(Debug, Clone, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct CacheValidators {
    pub etag: Option<String>,
    pub last_modified: Option<String>,
}

#[derive(Debug)]
pub enum ProviderResponse<T> {
    Modified {
        value: T,
        validators: CacheValidators,
    },
    NotModified {
        validators: CacheValidators,
    },
}

/// Fully validated source snapshot; an upsert replaces it, including removed fields.
#[derive(Debug, Clone)]
pub struct ProfileSnapshot {
    pub artist_id: i64,
    pub identity_generation: u64,
    pub provider: EnrichmentProvider,
    pub language: String,
    pub profile: ArtistProfile,
    pub fetched_at: i64,
    pub expires_at: i64,
    pub validators: CacheValidators,
}

#[derive(Debug, Clone)]
pub struct AssetSnapshot {
    pub artist_id: i64,
    pub identity_generation: u64,
    pub provider: EnrichmentProvider,
    pub provider_id: String,
    pub source_url: String,
    pub managed_path: String,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub attribution: crate::api::EnrichmentAttribution,
    pub fetched_at: i64,
    pub expires_at: i64,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ReleaseGroupSnapshot {
    pub musicbrainz_id: String,
    pub title: String,
    pub primary_type: Option<String>,
    pub secondary_types: Vec<String>,
    pub first_release_date: Option<ArtistPartialDate>,
    #[serde(default)]
    pub genres: Vec<String>,
    #[serde(default)]
    pub composers: Vec<String>,
    #[serde(default)]
    pub producers: Vec<String>,
    pub attribution: EnrichmentAttribution,
}

#[derive(Debug, Clone)]
pub struct ExternalReleaseDetailsSnapshot {
    pub artist_id: i64,
    pub identity_generation: u64,
    pub details: crate::api::ExternalReleaseDetails,
    pub fetched_at: i64,
    pub expires_at: i64,
    pub validators: CacheValidators,
}

#[derive(Debug, Clone)]
pub struct PopularTracksSnapshot {
    pub artist_id: i64,
    pub identity_generation: u64,
    pub items: Vec<ArtistPopularTrack>,
    pub fetched_at: i64,
    pub expires_at: i64,
    pub validators: CacheValidators,
}

#[derive(Debug, Clone)]
pub struct LocalReleaseTrackContext {
    pub title: String,
    pub disc_number: u8,
    pub track_number: u8,
    pub duration_seconds: u64,
}

#[derive(Debug, Clone)]
pub struct LocalReleaseMatchContext {
    pub release_id: i64,
    pub artist_id: i64,
    pub artist_mbid: String,
    pub artist_name: String,
    pub title: String,
    pub tagged_release_mbid: Option<String>,
    pub tagged_release_group_mbid: Option<String>,
    pub candidate_release_groups: Vec<ReleaseGroupSnapshot>,
    pub tracks: Vec<LocalReleaseTrackContext>,
}

#[derive(Debug, Clone)]
pub struct MatchedReleaseMetadata {
    pub release_id: i64,
    pub artist_id: i64,
    pub identity_generation: u64,
    pub release_group_mbid: String,
    pub release_mbid: Option<String>,
    pub release_date: Option<String>,
    pub genres: Vec<String>,
    pub composers: Vec<String>,
    pub producers: Vec<String>,
    pub source_url: String,
    pub fetched_at: i64,
}

#[derive(Debug, Clone)]
pub struct ReleaseGroupPage {
    pub provider_offset: u64,
    pub remote_total: u64,
    pub groups: Vec<ReleaseGroupSnapshot>,
    pub remote_next_offset: Option<u64>,
    pub remote_exhausted: bool,
}

#[derive(Debug, Clone)]
pub struct DiscographyBatch {
    pub pages: Vec<ReleaseGroupPage>,
    pub remote_total: u64,
    pub remote_next_offset: Option<u64>,
    pub remote_exhausted: bool,
    pub page_limit_reached: bool,
    pub time_budget_reached: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiscographyBuildState {
    pub catalog_generation: u64,
    pub next_offset: u64,
    pub remote_total: Option<u64>,
    pub validators: CacheValidators,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiscographyRefreshState {
    pub active_generation: u64,
    pub active_expires_at: Option<i64>,
    pub active_validators: CacheValidators,
    pub building: Option<DiscographyBuildState>,
}

/// One validated provider page written into a non-visible catalog generation.
/// Only a page marked `remote_exhausted` publishes that generation.
#[derive(Debug, Clone)]
pub struct DiscographyPageSnapshot {
    pub artist_id: i64,
    pub identity_generation: u64,
    pub catalog_generation: u64,
    pub provider_offset: u64,
    pub groups: Vec<ReleaseGroupSnapshot>,
    pub remote_total: u64,
    pub remote_next_offset: Option<u64>,
    pub remote_exhausted: bool,
    pub fetched_at: i64,
    pub expires_at: i64,
    pub validators: CacheValidators,
}

/// Validated Cover Art Archive metadata. Image bytes are fetched separately
/// so callers can decide when persistence and content-addressing should occur.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CoverArtCandidate {
    pub provider_id: String,
    pub release_group_mbid: String,
    pub source_release_mbid: String,
    pub exact_release_mbid: Option<String>,
    pub scope: crate::api::ExternalArtworkScope,
    pub download_url: String,
    pub source_url: String,
    pub attribution: EnrichmentAttribution,
}

#[derive(Debug)]
pub struct DownloadedCoverArt {
    pub candidate: CoverArtCandidate,
    pub bytes: Vec<u8>,
    pub width: u32,
    pub height: u32,
}

#[derive(Debug, Clone)]
pub struct ExternalArtworkSnapshot {
    pub artist_id: i64,
    pub identity_generation: u64,
    pub release_group_mbid: String,
    pub exact_release_mbid: Option<String>,
    pub scope: crate::api::ExternalArtworkScope,
    pub provider_id: String,
    pub source_url: String,
    pub managed_path: String,
    pub width: u32,
    pub height: u32,
    pub attribution: EnrichmentAttribution,
    pub fetched_at: i64,
    pub expires_at: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExternalArtworkStoreOutcome {
    pub stored: bool,
    /// A replaced managed path that no database row or local artwork uses.
    pub orphaned_path: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExternalArtworkNegativeResult {
    NotFound,
    InvalidImage,
    TemporaryFailure,
}

impl ExternalArtworkNegativeResult {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::NotFound => "not_found",
            Self::InvalidImage => "invalid_image",
            Self::TemporaryFailure => "temporary_failure",
        }
    }
}

#[derive(Debug, Clone)]
pub struct ExternalArtworkNegativeSnapshot {
    pub artist_id: i64,
    pub identity_generation: u64,
    pub catalog_generation: u64,
    pub release_group_mbid: String,
    pub exact_release_mbid: Option<String>,
    pub result: ExternalArtworkNegativeResult,
    /// Sanitized bounded category only; never a URL, payload or raw error.
    pub last_error: String,
    pub recorded_at: i64,
    pub expires_at: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExternalArtworkRefreshTarget {
    pub catalog_generation: u64,
    pub catalog_key: String,
    pub release_group_mbid: String,
    pub exact_release_mbid: Option<String>,
    pub attempt_count: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExternalArtworkRefreshPlan {
    pub targets: Vec<ExternalArtworkRefreshTarget>,
    pub catalog_pending: bool,
    pub queue_has_more: bool,
    pub progress: crate::api::CoverRefreshProgress,
}

/// Sanitized persistent suppression for a permanent provider response.
/// `resource_key` is a digest, never a URL, query or provider payload.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProviderFailureSnapshot {
    pub artist_id: i64,
    pub identity_generation: u64,
    pub provider: EnrichmentProvider,
    pub operation: String,
    pub resource_key: String,
    pub error_code: String,
    pub retry_after_seconds: Option<u64>,
    pub recorded_at: i64,
    pub expires_at: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CachedProviderFailure {
    pub error_code: String,
    pub retry_after_seconds: Option<u64>,
}
