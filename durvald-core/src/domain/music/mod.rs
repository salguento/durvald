//! Integration vocabulary. No storage, network, player or public-DTO dependency.
//!
//! Discovery never implies library membership; provider IDs never replace local IDs.

pub(crate) mod catalog;
pub(crate) mod identity;
pub(crate) mod queue;
pub(crate) mod sources;

#[derive(Clone, Copy, Debug, PartialEq, Eq, thiserror::Error)]
pub(crate) enum ContractError {
    #[error("invalid provider identifier")]
    InvalidProvider,
    #[error("invalid external or session identifier")]
    InvalidIdentifier,
    #[error("invalid canonical HTTP(S) URL")]
    InvalidCanonicalUrl,
    #[error("entity does not identify an individual playable item")]
    NotPlayableEntity,
    #[error("invalid local path")]
    InvalidLocalPath,
    #[error("invalid search query or pagination")]
    InvalidSearch,
}

/// Machine-readable failures; adapter diagnostics must not contain credentials.
/// No automatic retry policy is inferred from an arbitrary error message.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum IntegrationError {
    InvalidInput(ContractError),
    UnsupportedCapability,
    Disabled,
    AuthenticationRequired,
    AccessDenied,
    RegionRestricted,
    NotFound,
    RateLimited { retry_after_seconds: Option<u64> },
    TemporarilyUnavailable,
    ExpiredMedia,
    Timeout,
    Cancelled,
    InvalidResponse,
}

#[cfg(test)]
mod tests;
