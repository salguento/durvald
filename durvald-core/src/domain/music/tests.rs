use super::{
    ContractError,
    catalog::{CatalogSearchRequest, SearchEntityFilter, SearchScope},
    identity::{
        AssociationDecision, AssociationEvidence, CatalogTrackIdentity, ExternalEntityKind,
        ExternalEntityRef, LibraryMembership, ProviderId, assess_association,
    },
    queue::{MusicQueueEntry, PlaybackSessionId, QueueOccurrenceRef, QueueTarget},
    sources::{
        CanonicalMediaUrl, LocalMediaPath, RemoteMediaRef, ResolvedLocation, ResolvedMedia,
        SourceReference,
    },
};
use crate::domain::ids::TrackId;

fn external(provider: &str, kind: ExternalEntityKind, id: &str) -> ExternalEntityRef {
    ExternalEntityRef::new(ProviderId::new(provider).unwrap(), kind, id).unwrap()
}

fn remote(id: &str) -> RemoteMediaRef {
    RemoteMediaRef::new(
        external("example", ExternalEntityKind::AudioTrack, id),
        CanonicalMediaUrl::new("https://example.test/track/1").unwrap(),
    )
    .unwrap()
}

fn track(id: i64) -> TrackId {
    TrackId::try_from(id).unwrap()
}

#[test]
fn external_identity_includes_provider_and_entity_kind_and_preserves_case() {
    let recording = external("musicbrainz", ExternalEntityKind::Recording, "AbC");
    assert_eq!(recording.provider().as_str(), "musicbrainz");
    assert_eq!(recording.external_id(), "AbC");
    for other in [
        external("another", ExternalEntityKind::Recording, "AbC"),
        external("musicbrainz", ExternalEntityKind::ReleaseTrack, "AbC"),
        external("musicbrainz", ExternalEntityKind::ReleaseEdition, "AbC"),
        external("musicbrainz", ExternalEntityKind::ReleaseGroup, "AbC"),
        external("musicbrainz", ExternalEntityKind::Recording, "abc"),
    ] {
        assert_ne!(recording, other);
    }
    assert_eq!(
        recording,
        external("musicbrainz", ExternalEntityKind::Recording, "AbC")
    );
}

#[test]
fn invalid_identifiers_are_rejected_without_silent_normalization() {
    for value in [
        "",
        " example",
        "Example",
        "https://example.test",
        "a/b",
        "a\nb",
    ] {
        assert_eq!(ProviderId::new(value), Err(ContractError::InvalidProvider));
    }
    for value in ["", " ", " leading", "trailing ", "x\0y", "x\ny"] {
        assert_eq!(
            ExternalEntityRef::new(
                ProviderId::new("example").unwrap(),
                ExternalEntityKind::AudioTrack,
                value,
            ),
            Err(ContractError::InvalidIdentifier)
        );
        assert_eq!(
            PlaybackSessionId::new(value),
            Err(ContractError::InvalidIdentifier)
        );
    }
}

#[test]
fn profile_artist_recording_and_album_video_are_not_individual_media_sources() {
    for kind in [
        ExternalEntityKind::Artist,
        ExternalEntityKind::ServiceProfile,
        ExternalEntityKind::Recording,
        ExternalEntityKind::ReleaseGroup,
        ExternalEntityKind::ReleaseEdition,
        ExternalEntityKind::ReleaseTrack,
        ExternalEntityKind::AlbumVideo,
        ExternalEntityKind::Playlist,
        ExternalEntityKind::DownloadOffer,
    ] {
        assert_eq!(
            RemoteMediaRef::new(
                external("example", kind, "1"),
                CanonicalMediaUrl::new("https://example.test/item/1").unwrap(),
            ),
            Err(ContractError::NotPlayableEntity)
        );
    }
    assert!(
        RemoteMediaRef::new(
            external("example", ExternalEntityKind::Video, "1"),
            CanonicalMediaUrl::new("https://example.test/watch?v=1").unwrap(),
        )
        .is_ok()
    );
}

#[test]
fn canonical_url_and_local_path_are_distinct_and_validate_without_io() {
    for url in [
        "file:///tmp/song.flac",
        "javascript:alert(1)",
        "https://user:secret@example.test/track",
        "https://example.test/track\n",
        " https://example.test/track",
        "not a URL",
    ] {
        assert_eq!(
            CanonicalMediaUrl::new(url),
            Err(ContractError::InvalidCanonicalUrl)
        );
    }
    assert_eq!(
        LocalMediaPath::new("https://example.test/track".into()),
        Err(ContractError::InvalidLocalPath)
    );
    let path = LocalMediaPath::new(std::env::temp_dir().join("absent-song.flac")).unwrap();
    assert!(path.as_path().is_absolute());
    assert_eq!(
        remote("1").canonical_url().as_str(),
        "https://example.test/track/1"
    );
}

#[test]
fn media_identity_does_not_depend_on_a_canonical_page_url() {
    let first = remote("1");
    let different_page = RemoteMediaRef::new(
        first.entity().clone(),
        CanonicalMediaUrl::new("https://example.test/new-page").unwrap(),
    )
    .unwrap();
    assert_eq!(first.entity(), different_page.entity());
    assert_eq!(first.key(), different_page.key());
    assert_ne!(first.entity(), remote("2").entity());
    assert_ne!(first.key(), remote("2").key());
    let video = RemoteMediaRef::new(
        external("example", ExternalEntityKind::Video, "1"),
        first.canonical_url().clone(),
    )
    .unwrap();
    assert_eq!(first.key(), video.key());
}

#[test]
fn similarity_requires_review_and_cannot_move_an_existing_source() {
    use AssociationDecision::*;
    use AssociationEvidence::*;
    assert_eq!(
        assess_association(track(1), None, MetadataSimilarity),
        NeedsReview
    );
    for evidence in [
        MetadataSimilarity,
        UserConfirmed,
        VerifiedIdentityAndContext,
    ] {
        assert_eq!(
            assess_association(track(1), Some(track(2)), evidence),
            Conflict {
                existing_track_id: track(2)
            }
        );
        assert_eq!(
            assess_association(track(1), Some(track(1)), evidence),
            AlreadyAttached
        );
    }
    for evidence in [UserConfirmed, VerifiedIdentityAndContext] {
        assert_eq!(assess_association(track(1), None, evidence), Attach);
    }
}

#[test]
fn search_requests_validate_page_bounds_and_keep_opaque_cursors() {
    let request = CatalogSearchRequest::new(
        "  Björk  ",
        SearchScope::Explore,
        SearchEntityFilter::Artists,
        200,
        Some("CaseSensitive+/=".into()),
    )
    .unwrap();
    assert_eq!(request.query(), "Björk");
    assert_eq!(request.page_size(), 200);
    assert_eq!(request.cursor(), Some("CaseSensitive+/="));
    for (query, page_size, cursor) in [
        (" ", 10, None),
        ("artist", 0, None),
        ("artist", 201, None),
        ("artist\nname", 10, None),
        ("artist", 10, Some("".into())),
        ("artist", 10, Some("cursor\0".into())),
    ] {
        assert_eq!(
            CatalogSearchRequest::new(
                query,
                SearchScope::Library,
                SearchEntityFilter::All,
                page_size,
                cursor,
            ),
            Err(ContractError::InvalidSearch)
        );
    }
}

#[test]
fn queue_identity_distinguishes_repeats_and_sessions_without_a_local_track() {
    let entry = MusicQueueEntry {
        occurrence: QueueOccurrenceRef {
            session_id: PlaybackSessionId::new("session-1").unwrap(),
            sequence: 0,
        },
        target: QueueTarget::External(remote("1")),
        source_context: "search:example".into(),
    };
    let mut repeated = entry.clone();
    repeated.occurrence.sequence = 1;
    assert_eq!(entry.target, repeated.target);
    assert_ne!(entry.occurrence, repeated.occurrence);
    let mut another_session = entry.clone();
    another_session.occurrence.session_id = PlaybackSessionId::new("session-2").unwrap();
    assert_ne!(entry.occurrence, another_session.occurrence);
    // Reordering moves entries, not occurrence identities or navigation contexts.
    let mut queue = [entry.clone(), repeated];
    queue.swap(0, 1);
    assert_eq!(queue[1], entry);
}

#[test]
fn durable_history_identity_does_not_imply_library_membership() {
    let history_only = CatalogTrackIdentity {
        track_id: track(42),
        membership: LibraryMembership::NotInLibrary,
    };
    let adopted = CatalogTrackIdentity {
        membership: LibraryMembership::InLibrary,
        ..history_only
    };
    assert_eq!(history_only.track_id, adopted.track_id);
    assert_ne!(history_only.membership, adopted.membership);
}

#[test]
fn resolved_media_debug_never_exposes_temporary_urls_headers_or_source_details() {
    let resolved = ResolvedMedia {
        source: SourceReference::Remote(remote("1")),
        location: ResolvedLocation::NativeAudio {
            url: url::Url::parse("https://cdn.example.test/audio?token=secret-token").unwrap(),
            headers: vec![("Authorization".into(), "Bearer secret-header".into())],
        },
        expires_at_unix_seconds: Some(123),
    };
    let debug = format!("{resolved:?}");
    for private in [
        "secret-token",
        "secret-header",
        "cdn.example.test",
        "example.test",
    ] {
        assert!(!debug.contains(private));
    }
    assert!(debug.contains("[redacted]"));
}
