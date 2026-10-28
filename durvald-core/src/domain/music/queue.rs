//! Provider-neutral queue references. Adopted remote tracks use catalog IDs;
//! external entries remain a separate contract for future provider playback.

use super::{
    ContractError,
    identity::{CatalogTrackIdentity, validate_opaque_id},
    sources::RemoteMediaRef,
};

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub(crate) struct PlaybackSessionId(String);

impl PlaybackSessionId {
    pub(crate) fn new(value: impl Into<String>) -> Result<Self, ContractError> {
        let value = value.into();
        validate_opaque_id(&value)?;
        Ok(Self(value))
    }
}

/// Allocated once per queue insertion, not an index to recompute after reorder.
/// The session owner must never reuse a sequence number within the same session.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct QueueOccurrenceRef {
    pub(crate) session_id: PlaybackSessionId,
    pub(crate) sequence: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum QueueTarget {
    Catalog(CatalogTrackIdentity),
    /// Can be listened to without implying library adoption or a fake file path.
    External(RemoteMediaRef),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct MusicQueueEntry {
    pub(crate) occurrence: QueueOccurrenceRef,
    pub(crate) target: QueueTarget,
    /// Album/playlist/search navigation context; not the media provider.
    pub(crate) source_context: String,
}
