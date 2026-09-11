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
}
