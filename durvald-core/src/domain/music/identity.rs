use super::ContractError;
use crate::domain::ids::{ArtistId, ReleaseId, TrackId};

/// Stable adapter namespace, including future project-maintained providers.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub(crate) struct ProviderId(String);

impl ProviderId {
    pub(crate) fn new(value: impl Into<String>) -> Result<Self, ContractError> {
        let value = value.into();
        if value.is_empty()
            || value.len() > 128
            || !value.bytes().all(|c| {
                c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, b'.' | b'_' | b'-')
            })
            || !value.as_bytes()[0].is_ascii_alphanumeric()
        {
            return Err(ContractError::InvalidProvider);
        }
        Ok(Self(value))
    }

    pub(crate) fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub(crate) enum ExternalEntityKind {
    Artist,
    ReleaseGroup,
    ReleaseEdition,
    Recording,
    /// Occurrence on a particular edition; not the recording itself.
    ReleaseTrack,
    ServiceProfile,
    AudioTrack,
    Video,
    /// A whole album/video needs its own handling, never a synthetic single track.
    AlbumVideo,
    Playlist,
    DownloadOffer,
}

/// Equality includes provider AND entity kind. Opaque IDs retain case.
/// Provider-specific normalization (e.g. MBID validation) belongs in the adapter.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub(crate) struct ExternalEntityRef {
    provider: ProviderId,
    kind: ExternalEntityKind,
    external_id: String,
}

impl ExternalEntityRef {
    pub(crate) fn new(
        provider: ProviderId,
        kind: ExternalEntityKind,
        external_id: impl Into<String>,
    ) -> Result<Self, ContractError> {
        let external_id = external_id.into();
        validate_opaque_id(&external_id)?;
        Ok(Self {
            provider,
            kind,
            external_id,
        })
    }

    pub(crate) fn provider(&self) -> &ProviderId {
        &self.provider
    }

    pub(crate) fn kind(&self) -> ExternalEntityKind {
        self.kind
    }

    pub(crate) fn external_id(&self) -> &str {
        &self.external_id
    }
}

pub(super) fn validate_opaque_id(value: &str) -> Result<(), ContractError> {
    if value.is_empty() || value.trim() != value || value.chars().any(char::is_control) {
        return Err(ContractError::InvalidIdentifier);
    }
    Ok(())
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum LocalEntityRef {
    Artist(ArtistId),
    Release(ReleaseId),
    Track(TrackId),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum CatalogEntityRef {
    Local(LocalEntityRef),
    External(ExternalEntityRef),
}

/// A durable catalog record can exist only for history, without library adoption.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum LibraryMembership {
    NotInLibrary,
    InLibrary,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct CatalogTrackIdentity {
    pub(crate) track_id: TrackId,
    pub(crate) membership: LibraryMembership,
}

/// Linking evidence must cover the recording AND its edition/version context.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum AssociationEvidence {
    VerifiedIdentityAndContext,
    UserConfirmed,
    MetadataSimilarity,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum AssociationDecision {
    Attach,
    AlreadyAttached,
    NeedsReview,
    Conflict { existing_track_id: TrackId },
}

/// Pure policy; caller looks up the owner by persistent provider/item identity.
/// This never moves an existing source or merges two catalog tracks.
pub(crate) fn assess_association(
    target: TrackId,
    existing_owner: Option<TrackId>,
    evidence: AssociationEvidence,
) -> AssociationDecision {
    match existing_owner {
        Some(owner) if owner == target => AssociationDecision::AlreadyAttached,
        Some(owner) => AssociationDecision::Conflict {
            existing_track_id: owner,
        },
        None if evidence == AssociationEvidence::MetadataSimilarity => {
            AssociationDecision::NeedsReview
        }
        None => AssociationDecision::Attach,
    }
}
