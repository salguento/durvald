//! Volatile, bounded diagnostics. No queries, URLs, credentials or item identities.
use serde::{Deserialize, Serialize};
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum IntegrationOperation {
    CatalogSearch,
    Metadata,
    SourceSearch,
    PlaybackResolution,
    DownloadSearch,
    DownloadTransfer,
    CollectionRead,
    Other,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum IntegrationOutcome {
    Succeeded,
    Cancelled,
    TimedOut,
    RateLimited,
    Authentication,
    Disabled,
    Busy,
    Unavailable,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct IntegrationMeasurement {
    pub operation: IntegrationOperation,
    pub active: u64,
    pub completed: u64,
    pub succeeded: u64,
    pub cancelled: u64,
    pub failed: u64,
    pub sample_count: u32,
    pub p95_elapsed_ms: u64,
    pub p95_queue_ms: u64,
    pub last_outcome: Option<IntegrationOutcome>,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct IntegrationDiagnostic {
    pub provider: String,
    pub adapter_version: String,
    pub enabled: bool,
    pub measurements: Vec<IntegrationMeasurement>,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct IntegrationDiagnostics {
    pub preferences_available: bool,
    pub providers: Vec<IntegrationDiagnostic>,
}
