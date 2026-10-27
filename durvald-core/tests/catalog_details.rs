#![cfg(feature = "test-support")]
mod common;
use common::TestCore;
use durvald_core::*;
const ARTIST: &str = "11111111-1111-4111-8111-111111111111";
const GROUP: &str = "22222222-2222-4222-8222-222222222222";
fn entry(provider: &str, kind: CatalogItemKind, id: &str) -> CatalogEntry {
    CatalogEntry {
        reference: CatalogReference {
            provider: provider.into(),
            kind,
            id: id.into(),
        },
        title: "Same Name".into(),
        artist_credit: None,
        version_label: None,
        duration_seconds: None,
        canonical_url: None,
    }
}
#[tokio::test]
async fn explicit_saves_are_concurrent_idempotent_and_survive_restart() {
    let core = TestCore::open().await.unwrap();
    let artist = entry("musicbrainz", CatalogItemKind::Artist, ARTIST);
    let (a, b) = tokio::join!(
        core.core().save_catalog_selection(artist.clone()),
        core.core().save_catalog_selection(artist.clone())
    );
    let a = a.unwrap();
    assert_eq!(a, b.unwrap());
    assert!(a.local_artist_id.is_some());
    let other = core
        .core()
        .save_catalog_selection(entry("musicbrainz", CatalogItemKind::Artist, GROUP))
        .await
        .unwrap();
    assert_ne!(a.local_artist_id, other.local_artist_id);
    assert_eq!(core.core().catalog_selections().await.unwrap().len(), 2);
    let core = core.restart().await.unwrap();
    assert_eq!(
        core.core()
            .catalog_selection(artist.reference)
            .await
            .unwrap(),
        Some(a)
    );
    assert!(core.all_tracks_via_pages().await.unwrap().is_empty());
}
#[tokio::test]
async fn release_and_provisional_service_references_save_without_synthetic_musicbrainz_ids() {
    let core = TestCore::open().await.unwrap();
    let group = entry("musicbrainz", CatalogItemKind::ReleaseGroup, GROUP);
    let saved = core.core().save_catalog_selection(group).await.unwrap();
    assert!(saved.local_artist_id.is_none());
    for (provider, kind, id) in [
        ("soundcloud", CatalogItemKind::AudioTrack, "OpaqueCase-ID"),
        (
            "soundcloud",
            CatalogItemKind::ServiceProfile,
            "OpaqueCase-ID",
        ),
        ("other", CatalogItemKind::AudioTrack, "OpaqueCase-ID"),
        ("soundcloud", CatalogItemKind::AudioTrack, "opaquecase-id"),
    ] {
        let input = entry(provider, kind, id);
        let saved = core
            .core()
            .save_catalog_selection(input.clone())
            .await
            .unwrap();
        assert_eq!(saved.entry, input);
        assert!(saved.local_artist_id.is_none());
    }
    assert_eq!(core.core().catalog_selections().await.unwrap().len(), 5);
    assert!(core.core().artists().await.unwrap().is_empty());
    assert!(core.all_tracks_via_pages().await.unwrap().is_empty());
}
#[tokio::test]
async fn detail_read_cancel_and_provider_failure_do_not_adopt_library_items() {
    let core = TestCore::open().await.unwrap();
    core.core()
        .set_catalog_provider_enabled(false)
        .await
        .unwrap();
    let session = core.core().catalog_search_session();
    let request = CatalogDetailRequest {
        reference: entry("musicbrainz", CatalogItemKind::Artist, ARTIST).reference,
        section: CatalogDetailSection::Basic,
        language: "pt-BR".into(),
        cursor: None,
        generation: 1,
    };
    assert_eq!(
        session
            .detail_section(request.clone())
            .await
            .unwrap()
            .failure,
        Some(CatalogFailure::Disabled)
    );
    session.cancel(1).await;
    assert_eq!(
        session
            .detail_section(request.clone())
            .await
            .unwrap()
            .failure,
        Some(CatalogFailure::Cancelled)
    );
    let other = core.core().catalog_search_session();
    assert_eq!(
        other.detail_section(request.clone()).await.unwrap().failure,
        Some(CatalogFailure::Disabled)
    );
    let mut changed = request.clone();
    changed.reference.id = GROUP.into();
    assert!(session.detail_section(changed).await.is_err());
    session.close().await;
    let mut newer = request;
    newer.generation = 2;
    assert_eq!(
        session.detail_section(newer).await.unwrap().failure,
        Some(CatalogFailure::Cancelled)
    );
    assert!(core.core().catalog_selections().await.unwrap().is_empty());
    assert!(core.core().artists().await.unwrap().is_empty());
    assert!(core.core().playback_history().await.unwrap().is_empty());
    assert!(core.core().listen_list().await.unwrap().is_empty());
}
#[tokio::test]
async fn follow_and_listen_intent_use_existing_features_without_creating_playable_tracks() {
    let core = TestCore::open().await.unwrap();
    let artist = entry("musicbrainz", CatalogItemKind::Artist, ARTIST);
    let followed = core
        .core()
        .follow_catalog_artist(artist.clone(), true)
        .await
        .unwrap();
    assert_eq!(
        core.core().followed_artists().await.unwrap()[0].artist.id,
        followed.local_artist_id.unwrap()
    );
    let group = entry("musicbrainz", CatalogItemKind::ReleaseGroup, GROUP);
    let a = core
        .core()
        .add_catalog_to_listen_list(group.clone(), artist.clone())
        .await
        .unwrap();
    let b = core
        .core()
        .add_catalog_to_listen_list(group, artist.clone())
        .await
        .unwrap();
    assert_eq!(a.id, b.id);
    assert_eq!(core.core().listen_list().await.unwrap().len(), 1);
    core.core()
        .follow_catalog_artist(artist, false)
        .await
        .unwrap();
    assert!(core.core().followed_artists().await.unwrap().is_empty());
    assert!(core.all_tracks_via_pages().await.unwrap().is_empty());
}
#[tokio::test]
async fn invalid_references_are_rejected_before_persistence_and_provisional_artist_reuses_materialization()
 {
    let core = TestCore::open().await.unwrap();
    for bad in [
        entry("MusicBrainz", CatalogItemKind::Artist, ARTIST),
        entry("musicbrainz", CatalogItemKind::Artist, "invalid"),
        entry("musicbrainz", CatalogItemKind::Track, ARTIST),
        entry("soundcloud", CatalogItemKind::AudioTrack, " leading"),
    ] {
        assert!(core.core().save_catalog_selection(bad).await.is_err());
    }
    assert!(core.core().catalog_selections().await.unwrap().is_empty());
    let input = entry(
        "last_fm",
        CatalogItemKind::Artist,
        "https://www.last.fm/music/OpaqueName",
    );
    let saved = core
        .core()
        .save_catalog_selection(input.clone())
        .await
        .unwrap();
    let legacy = core
        .core()
        .materialize_remote_artist(RemoteArtistSelection {
            name: input.title,
            provider: input.reference.provider,
            external_id: input.reference.id,
            musicbrainz_id: None,
        })
        .await
        .unwrap();
    assert_eq!(Some(legacy.id), saved.local_artist_id);
    assert!(
        core.core()
            .artist_identity(legacy.id)
            .await
            .unwrap()
            .musicbrainz_id
            .is_none()
    );
}
