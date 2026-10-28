#![cfg(feature = "test-support")]
mod common;
use common::TestCore;
use durvald_core::{
    CatalogEntry, CatalogFailure, CatalogItemKind, CatalogReference, SourceCapability,
};
use std::error::Error;
type Result<T = ()> = std::result::Result<T, Box<dyn Error + Send + Sync>>;
fn entry(id: &str) -> CatalogEntry {
    CatalogEntry {
        reference: CatalogReference {
            provider: "test".into(),
            kind: CatalogItemKind::Recording,
            id: id.into(),
        },
        title: "Selected recording".into(),
        artist_credit: Some("Artist".into()),
        version_label: Some("Studio".into()),
        duration_seconds: Some(180),
        canonical_url: None,
    }
}
const LINK: &str = "https://youtu.be/abcdefghijk?list=discard&token=discard";

#[tokio::test]
async fn discovery_is_ephemeral_reviewed_idempotent_and_owned() -> Result {
    let app = TestCore::open().await?;
    let session = app.core().source_search_session();
    let page = session
        .search("service-links".into(), entry("one"), Some(LINK.into()), 1)
        .await?;
    assert!(page.failure.is_none());
    assert!(app.all_tracks_via_pages().await?.is_empty());
    let candidate = &page.candidates[0];
    assert_eq!(candidate.capability, SourceCapability::ExternalOpen);
    assert_eq!(
        candidate.canonical_url,
        "https://www.youtube.com/watch?v=abcdefghijk"
    );
    assert!(
        session
            .attach_candidate(candidate.candidate_id.clone(), None, false)
            .await
            .is_err()
    );
    let saved = session
        .attach_candidate(candidate.candidate_id.clone(), None, true)
        .await?;
    assert_eq!(
        saved.source_id,
        session
            .attach_candidate(candidate.candidate_id.clone(), None, true)
            .await?
            .source_id
    );
    assert_eq!(app.all_tracks_via_pages().await?.len(), 1);
    let other = app.core().save_remote_track(entry("two")).await?;
    assert!(
        session
            .attach_candidate(candidate.candidate_id.clone(), Some(other.id), true)
            .await
            .is_err()
    );
    assert!(
        app.core()
            .remove_track_source(other.id, saved.source_id)
            .await
            .is_err()
    );
    assert!(
        app.core()
            .prefer_track_source(other.id, Some(saved.source_id))
            .await
            .is_err()
    );
    assert!(
        app.core()
            .play_track_source(saved.track_id, saved.source_id)
            .await
            .is_err()
    );
    let result = app
        .core()
        .test_track_source(saved.track_id, saved.source_id)
        .await?;
    assert_eq!(result.source.availability, "unknown");
    assert_eq!(result.source.capability, SourceCapability::ExternalOpen);
    assert_eq!(
        app.core()
            .track_source_open_url(saved.track_id, saved.source_id)
            .await?,
        candidate.canonical_url
    );
    Ok(())
}

#[tokio::test]
async fn generations_closed_sessions_and_disabled_providers_reject_candidates() -> Result {
    let app = TestCore::open().await?;
    let session = app.core().source_search_session();
    let page = session
        .search("service-links".into(), entry("one"), Some(LINK.into()), 1)
        .await?;
    let old = page.candidates[0].candidate_id.clone();
    assert!(
        session
            .search("service-links".into(), entry("two"), Some(LINK.into()), 1)
            .await
            .is_err()
    );
    let newer = session
        .search("service-links".into(), entry("two"), Some(LINK.into()), 2)
        .await?;
    assert!(session.attach_candidate(old, None, true).await.is_err());
    assert_eq!(
        session
            .search("service-links".into(), entry("one"), Some(LINK.into()), 1)
            .await?
            .failure,
        Some(CatalogFailure::Cancelled)
    );
    app.core()
        .set_source_provider_enabled("service-links".into(), false)
        .await?;
    assert!(
        session
            .attach_candidate(newer.candidates[0].candidate_id.clone(), None, true)
            .await
            .is_err()
    );
    assert_eq!(
        session
            .search("service-links".into(), entry("two"), Some(LINK.into()), 3)
            .await?
            .failure,
        Some(CatalogFailure::Disabled)
    );
    app.core()
        .set_source_provider_enabled("service-links".into(), true)
        .await?;
    session.close().await;
    assert_eq!(
        session
            .search("service-links".into(), entry("two"), Some(LINK.into()), 4)
            .await?
            .failure,
        Some(CatalogFailure::Cancelled)
    );
    assert!(app.all_tracks_via_pages().await?.is_empty());
    Ok(())
}

#[tokio::test]
async fn sources_preferences_and_personal_values_survive_restart_and_removal() -> Result {
    let app = TestCore::open().await?;
    let session = app.core().source_search_session();
    let page = session
        .search("service-links".into(), entry("one"), Some(LINK.into()), 1)
        .await?;
    let remote = session
        .attach_candidate(page.candidates[0].candidate_id.clone(), None, true)
        .await?;
    let path = app.files().write_silent_wav("attached.wav")?;
    let local = app
        .core()
        .attach_local_track_source(remote.track_id, path.to_string_lossy().into())
        .await?;
    assert_eq!(
        app.core()
            .test_track_source(local.track_id, local.source_id)
            .await?
            .source
            .capability,
        SourceCapability::FullAudio
    );
    app.core().set_track_favorite(remote.track_id, true).await?;
    app.core()
        .set_track_rating_half_steps(remote.track_id, Some(9))
        .await?;
    app.core()
        .prefer_track_source(remote.track_id, Some(remote.source_id))
        .await?;
    // A one-off local selection does not overwrite the saved remote preference.
    app.core()
        .play_track_source(local.track_id, local.source_id)
        .await?;
    assert!(
        app.core()
            .track_sources(remote.track_id)
            .await?
            .iter()
            .find(|s| s.source_id == remote.source_id)
            .unwrap()
            .preferred
    );
    app.core()
        .set_track_source_enabled(local.track_id, local.source_id, false)
        .await?;
    assert!(
        app.core()
            .play_track_source(local.track_id, local.source_id)
            .await
            .is_err()
    );
    session.close().await;
    drop(session);
    let app = app.restart().await?;
    let sources = app.core().track_sources(remote.track_id).await?;
    assert_eq!(sources.len(), 2);
    assert!(
        sources
            .iter()
            .any(|s| s.preferred && s.source_id == remote.source_id)
    );
    app.core()
        .remove_track_source(remote.track_id, remote.source_id)
        .await?;
    app.core()
        .remove_track_source(local.track_id, local.source_id)
        .await?;
    assert!(app.core().track_sources(remote.track_id).await?.is_empty());
    let track = app.core().track(remote.track_id).await?;
    assert!(track.is_favorite);
    assert_eq!(track.rating_half_steps, Some(9));
    let c = rusqlite::Connection::open(app.files().database_path())?;
    assert_eq!(
        c.query_row(
            "SELECT COUNT(*) FROM playback_source_preferences",
            [],
            |r| r.get::<_, i64>(0)
        )?,
        0
    );
    assert_eq!(
        c.query_row("SELECT COUNT(*) FROM track_source_observations", [], |r| {
            r.get::<_, i64>(0)
        })?,
        0
    );
    assert!(!c.prepare("PRAGMA foreign_key_check")?.exists([])?);
    Ok(())
}
