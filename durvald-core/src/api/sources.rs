//! Persistent sources and ephemeral discovery; never resolved stream URLs.
use serde::{Deserialize, Serialize};
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum SourceCapability {
    Unknown,
    FullAudio,
    Preview,
    EmbeddedPlayer,
    ExternalOpen,
    Unavailable,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct SourceCandidate {
    pub candidate_id: String,
    pub provider: String,
    pub external_id: String,
    pub canonical_url: String,
    pub title: String,
    pub uploader: Option<String>,
    pub version_label: Option<String>,
    pub duration_seconds: Option<u64>,
    pub capability: SourceCapability,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct SourceSearchPage {
    pub provider: String,
    pub generation: u64,
    pub candidates: Vec<SourceCandidate>,
    pub failure: Option<super::CatalogFailure>,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct SourceProvider {
    pub id: String,
    pub name: String,
    pub enabled: bool,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct TrackSource {
    pub source_id: i64,
    pub track_id: i64,
    pub provider: String,
    pub external_id: Option<String>,
    pub canonical_url: Option<String>,
    pub local_path: Option<String>,
    pub title: Option<String>,
    pub uploader: Option<String>,
    pub version_label: Option<String>,
    pub duration_seconds: Option<u64>,
    pub capability: SourceCapability,
    pub availability: String,
    pub enabled: bool,
    pub preferred: bool,
    pub priority: i32,
    pub last_checked_at: Option<String>,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct SourceTestResult {
    pub source: TrackSource,
    pub message: String,
}
