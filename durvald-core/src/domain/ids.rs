//! Strongly typed identifiers used beyond the public API boundary.

macro_rules! domain_id {
    ($name:ident) => {
        #[derive(Clone, Copy, Debug, Eq, PartialEq)]
        pub(crate) struct $name(u64);

        impl $name {
            pub(crate) fn get(self) -> u64 {
                self.0
            }
        }

        impl TryFrom<i64> for $name {
            type Error = InvalidDomainId;

            fn try_from(value: i64) -> Result<Self, Self::Error> {
                u64::try_from(value).map(Self).map_err(|_| InvalidDomainId)
            }
        }
    };
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct InvalidDomainId;

domain_id!(ArtistId);
domain_id!(PlaybackHistoryId);
domain_id!(PlaylistId);
domain_id!(TrackId);
domain_id!(ReleaseId);

impl PlaybackHistoryId {
    pub(crate) fn from_persisted(value: u64) -> Self {
        Self(value)
    }
}

impl TrackId {
    pub(crate) fn from_persisted(value: u64) -> Self {
        Self(value)
    }
}

#[cfg(test)]
mod tests {
    use super::{ArtistId, PlaybackHistoryId, PlaylistId, ReleaseId, TrackId};

    #[test]
    fn catalog_ids_accept_non_negative_api_values() {
        assert_eq!(TrackId::try_from(0).unwrap().get(), 0);
        assert_eq!(ArtistId::try_from(42).unwrap().get(), 42);
        assert_eq!(PlaylistId::try_from(7).unwrap().get(), 7);
        assert_eq!(PlaybackHistoryId::try_from(9).unwrap().get(), 9);
        assert_eq!(
            ReleaseId::try_from(i64::MAX).unwrap().get(),
            i64::MAX as u64
        );
    }

    #[test]
    fn catalog_ids_reject_negative_api_values() {
        assert!(TrackId::try_from(-1).is_err());
        assert!(ArtistId::try_from(-1).is_err());
        assert!(PlaylistId::try_from(-1).is_err());
        assert!(PlaybackHistoryId::try_from(-1).is_err());
        assert!(ReleaseId::try_from(-1).is_err());
    }
}
