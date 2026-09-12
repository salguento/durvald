use crate::api::{ArtistProfile, EnrichmentProvider};

/// Conditional-request metadata stays internal to Rust.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
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
