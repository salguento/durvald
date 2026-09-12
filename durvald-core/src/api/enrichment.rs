//! Additive, offline-readable enrichment records. Provider JSON never crosses FFI.

use super::Artist;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum EnrichmentProvider {
    MusicBrainz,
    Wikidata,
    Wikipedia,
    Commons,
    CoverArtArchive,
    TheAudioDb,
    YouTube,
}

/// Disabled on first launch. Offline also prevents future refresh requests.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct EnrichmentSettings {
    pub enabled: bool,
    pub offline: bool,
    pub preferred_language: String,
}

impl Default for EnrichmentSettings {
    fn default() -> Self {
        Self {
            enabled: false,
            offline: false,
            preferred_language: "pt".into(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum ArtistIdentityStatus {
    Unresolved,
    Ambiguous,
    Resolved,
    NotFound,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum ArtistEntityKind {
    Person,
    Group,
    Other,
    Unknown,
}

/// Absent month/day preserve the precision supplied by the source.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct ArtistPartialDate {
    pub year: i32,
    pub month: Option<u8>,
    pub day: Option<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct EnrichmentAttribution {
    pub source_url: String,
    pub author: Option<String>,
    pub license_name: Option<String>,
    pub license_url: Option<String>,
    pub revision: Option<String>,
}

/// A normalized source snapshot, not yet a cross-provider editorial selection.
/// Factual snapshots use language "und"; text uses its actual language.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct ArtistProfile {
    pub entity_kind: ArtistEntityKind,
    pub birth_date: Option<ArtistPartialDate>,
    pub birth_place: Option<String>,
    pub formation_date: Option<ArtistPartialDate>,
    pub formation_place: Option<String>,
    pub origin_place: Option<String>,
    pub biography: Option<String>,
    pub attribution: EnrichmentAttribution,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct ArtistProfileSource {
    pub provider: EnrichmentProvider,
    pub language: String,
    pub profile: ArtistProfile,
    /// UTC Unix seconds. Expiry means eligible for refresh, not deleted.
    pub fetched_at: i64,
    pub expires_at: i64,
    pub stale: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct ArtistImageReference {
    pub provider: EnrichmentProvider,
    /// Stable provider identifier, currently the Commons file title.
    pub provider_id: String,
    pub source_url: String,
    /// Absolute path inside the core-managed covers directory.
    pub managed_path: String,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub attribution: EnrichmentAttribution,
    pub fetched_at: i64,
    pub expires_at: i64,
    pub stale: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum ArtistProfileField {
    EntityKind,
    BirthDate,
    BirthPlace,
    FormationDate,
    FormationPlace,
    OriginPlace,
    Biography,
}

/// `value = None` explicitly clears the selected field. Dates use YYYY,
/// YYYY-MM or YYYY-MM-DD; entity kind uses person/group/other/unknown.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct ArtistFieldOverride {
    pub field: ArtistProfileField,
    pub language: String,
    pub value: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct ArtistDetails {
    pub artist: Artist,
    pub identity_status: ArtistIdentityStatus,
    pub musicbrainz_id: Option<String>,
    pub identity_generation: u64,
    pub requested_language: String,
    /// Exact requested language plus "und"; language fallback arrives with providers.
    pub sources: Vec<ArtistProfileSource>,
    pub portrait: Option<ArtistImageReference>,
    pub overrides: Vec<ArtistFieldOverride>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum ArtistIdentityOrigin {
    Tag,
    Manual,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct ArtistIdentity {
    pub artist_id: i64,
    pub status: ArtistIdentityStatus,
    pub musicbrainz_id: Option<String>,
    pub generation: u64,
    pub origin: Option<ArtistIdentityOrigin>,
    /// Retained even when conflicting tags block enrichment.
    pub confirmed_musicbrainz_id: Option<String>,
    pub conflicting_tags: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct ArtistIdentityCandidate {
    pub musicbrainz_id: String,
    pub name: String,
    pub aliases: Vec<String>,
    pub entity_kind: ArtistEntityKind,
    pub disambiguation: String,
    pub evidence: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum ArtistIdentityLookupStatus {
    Updated,
    Disabled,
    Offline,
    Unavailable,
    RateLimited,
    Superseded,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct ArtistIdentityCandidates {
    pub identity: ArtistIdentity,
    pub candidates: Vec<ArtistIdentityCandidate>,
    pub lookup_status: ArtistIdentityLookupStatus,
    pub retry_after_seconds: Option<u64>,
    pub truncated: bool,
}

/// Sections are explicit so later discography/video work can extend refreshes
/// without changing the semantics of the phase-3 profile request.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum ArtistRefreshSection {
    Profile,
    Portrait,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct ArtistRefreshRequest {
    pub sections: Vec<ArtistRefreshSection>,
    pub language: String,
    /// Revalidate expired or still-fresh cache entries. Provider cooldowns and
    /// operation deadlines continue to apply.
    pub force: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum ArtistRefreshStatus {
    Updated,
    Unchanged,
    NotFound,
    NeedsIdentity,
    Unavailable,
    RateLimited,
    Disabled,
    Offline,
    Superseded,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct ArtistRefreshSectionResult {
    pub section: ArtistRefreshSection,
    pub status: ArtistRefreshStatus,
    pub retry_after_seconds: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct ArtistRefreshResult {
    pub artist_id: i64,
    pub identity_generation: u64,
    pub sections: Vec<ArtistRefreshSectionResult>,
}
