use std::{fmt, path::PathBuf};

use super::{
    ContractError,
    identity::{CatalogEntityRef, ExternalEntityKind, ExternalEntityRef, ProviderId},
};

/// Persistent page URL, never a resolved stream or an identity key.
/// Adapters must remove signed tokens/cookies; generic URL parsing cannot identify them.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct CanonicalMediaUrl(url::Url);

impl CanonicalMediaUrl {
    pub(crate) fn new(value: &str) -> Result<Self, ContractError> {
        let url = url::Url::parse(value).map_err(|_| ContractError::InvalidCanonicalUrl)?;
        if !matches!(url.scheme(), "https" | "http")
            || url.host_str().is_none()
            || !url.username().is_empty()
            || url.password().is_some()
            || value.trim() != value
            || value.chars().any(char::is_control)
        {
            return Err(ContractError::InvalidCanonicalUrl);
        }
        Ok(Self(url))
    }

    pub(crate) fn as_str(&self) -> &str {
        self.0.as_str()
    }
}

/// An artist/profile/recording reference alone is not playable media.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct RemoteMediaRef {
    entity: ExternalEntityRef,
    canonical_url: CanonicalMediaUrl,
}

/// Source ownership is unique by provider/item, independently of page URL or kind.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub(crate) struct RemoteSourceKey {
    provider: ProviderId,
    external_id: String,
}

impl RemoteSourceKey {
    pub(crate) fn provider(&self) -> &ProviderId {
        &self.provider
    }

    pub(crate) fn external_id(&self) -> &str {
        &self.external_id
    }
}

impl RemoteMediaRef {
    pub(crate) fn new(
        entity: ExternalEntityRef,
        canonical_url: CanonicalMediaUrl,
    ) -> Result<Self, ContractError> {
        if !matches!(
            entity.kind(),
            ExternalEntityKind::AudioTrack | ExternalEntityKind::Video
        ) {
            return Err(ContractError::NotPlayableEntity);
        }
        Ok(Self {
            entity,
            canonical_url,
        })
    }

    pub(crate) fn entity(&self) -> &ExternalEntityRef {
        &self.entity
    }

    pub(crate) fn canonical_url(&self) -> &CanonicalMediaUrl {
        &self.canonical_url
    }

    pub(crate) fn key(&self) -> RemoteSourceKey {
        RemoteSourceKey {
            provider: self.entity.provider().clone(),
            external_id: self.entity.external_id().to_owned(),
        }
    }
}

/// Absolute path representation only: no filesystem access or universal case folding.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct LocalMediaPath(PathBuf);

impl LocalMediaPath {
    pub(crate) fn new(path: PathBuf) -> Result<Self, ContractError> {
        if !path.is_absolute() || path.to_string_lossy().contains('\0') {
            return Err(ContractError::InvalidLocalPath);
        }
        Ok(Self(path))
    }

    pub(crate) fn as_path(&self) -> &std::path::Path {
        &self.0
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum SourceReference {
    Local(LocalMediaPath),
    Remote(RemoteMediaRef),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum SourceAvailability {
    Unknown,
    Available,
    PreviewOnly,
    AuthenticationRequired,
    RegionRestricted,
    Unavailable,
    TemporaryFailure,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum PlaybackMode {
    NativeAudio,
    EmbeddedPlayer,
    ExternalOpen,
}

/// Observed for this mode/item; a page URL alone does not grant any capability.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct PlaybackCapability {
    pub(crate) mode: PlaybackMode,
    pub(crate) seek: bool,
    pub(crate) known_duration: bool,
    pub(crate) preload: bool,
    pub(crate) observable_progress: bool,
    pub(crate) observable_end: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct SourceCapabilities {
    pub(crate) playback: Vec<PlaybackCapability>,
    pub(crate) authentication_required: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct SourceSearchRequest {
    pub(crate) target: CatalogEntityRef,
}

/// Unattached result. Applying this to the library requires an explicit command.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct SourceCandidate {
    pub(crate) reference: RemoteMediaRef,
    pub(crate) title: String,
    pub(crate) uploader: Option<String>,
    pub(crate) version_label: Option<String>,
    pub(crate) duration_seconds: Option<u64>,
    pub(crate) availability: SourceAvailability,
    pub(crate) capabilities: SourceCapabilities,
}

/// Execution-only values: deliberately no Serialize/Deserialize or derived Debug.
/// Header values and expiring URLs must never reach session/cache DTOs or logs.
pub(crate) enum ResolvedLocation {
    LocalFile(LocalMediaPath),
    NativeAudio {
        url: url::Url,
        headers: Vec<(String, String)>,
    },
    EmbeddedPlayer(CanonicalMediaUrl),
    ExternalOpen(CanonicalMediaUrl),
}

pub(crate) struct ResolvedMedia {
    pub(crate) source: SourceReference,
    pub(crate) location: ResolvedLocation,
    pub(crate) expires_at_unix_seconds: Option<u64>,
}

impl fmt::Debug for ResolvedMedia {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ResolvedMedia")
            .field("location", &"[redacted]")
            .field("expires_at_unix_seconds", &self.expires_at_unix_seconds)
            .finish_non_exhaustive()
    }
}
