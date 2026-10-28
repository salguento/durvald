#![cfg(feature = "test-support")]
mod common;
use common::TestCore;
use durvald_core::*;
use std::{
    error::Error,
    sync::{Arc, Mutex},
};
type Result<T = ()> = std::result::Result<T, Box<dyn Error + Send + Sync>>;
#[derive(Default, Clone)]
struct Host(Arc<Mutex<Vec<EmbeddedPlaybackCommand>>>);
impl EmbeddedPlaybackHost for Host {
    fn execute(&self, c: EmbeddedPlaybackCommand) -> bool {
        self.0.lock().unwrap().push(c);
        true
    }
}
fn entry() -> CatalogEntry {
    CatalogEntry {
        reference: CatalogReference {
            provider: "test".into(),
            kind: CatalogItemKind::Recording,
            id: "selected-recording".into(),
        },
        title: "Reviewed track".into(),
        artist_credit: Some("Artist".into()),
        version_label: None,
        duration_seconds: Some(180),
        canonical_url: None,
    }
}
async fn search(app: &TestCore) -> Result<(Arc<SourceSearchSession>, String)> {
    let session = app.core().source_search_session();
    let page = session
        .search(
            "service-links".into(),
            entry(),
            Some("https://soundcloud.com/forss/flickermood?tracking=discard".into()),
            1,
        )
        .await?;
    Ok((session, page.candidates[0].candidate_id.clone()))
}
async fn event(
    app: &TestCore,
    generation: &str,
    seq: u64,
    kind: EmbeddedEventKind,
    pos: f64,
) -> Result {
    app.core()
        .report_embedded_playback_event(EmbeddedPlaybackEvent {
            generation: generation.into(),
            sequence: seq,
            kind,
            position_seconds: pos,
            duration_seconds: Some(180.0),
        })
        .await?;
    Ok(())
}
async fn local(app: &TestCore) -> Result<Track> {
    app.files()
        .write_silent_wav_with_duration("local.wav", 30)?;
    app.core()
        .scan_library(vec![app.files().library_dir().to_string_lossy().into()])
        .await?;
    Ok(app
        .all_tracks_via_pages()
        .await?
        .into_iter()
        .find(|t| t.file_path.is_some())
        .unwrap())
}
#[tokio::test]
async fn listen_then_save_is_explicit_idempotent_and_keeps_the_active_generation() -> Result {
    let app = TestCore::open().await?;
    app.core()
        .set_embedded_playback_host(Box::new(Host::default()))
        .await?;
    let (session, id) = search(&app).await?;
    session.preview_candidate(id).await?;
    session.close().await;
    let status = app.core().embedded_playback().await.unwrap();
    assert_eq!(status.track_id, None);
    assert_eq!(status.source_id, None);
    assert!(app.all_tracks_via_pages().await?.is_empty());
    assert!(app.core().playback().await.current_track.is_none());
    assert!(!status.canonical_url.contains("discard"));
    assert!(
        app.core()
            .save_listening_source(status.generation.clone(), None, false)
            .await
            .is_err()
    );
    assert!(
        app.core()
            .save_listening_source("old-generation".into(), None, true)
            .await
            .is_err()
    );
    let saved = app
        .core()
        .save_listening_source(status.generation.clone(), None, true)
        .await?;
    assert_eq!(
        saved.source_id,
        app.core()
            .save_listening_source(status.generation.clone(), None, true)
            .await?
            .source_id
    );
    assert_eq!(app.all_tracks_via_pages().await?.len(), 1);
    assert_eq!(
        app.core().embedded_playback().await.unwrap().generation,
        status.generation
    );
    assert_eq!(
        app.core().playback().await.current_track.unwrap().id,
        saved.track_id
    );
    assert!(
        app.core()
            .playback_history_page(20, 0)
            .await?
            .items
            .is_empty()
    );
    app.core().set_track_favorite(saved.track_id, true).await?;
    assert!(
        app.core()
            .playback()
            .await
            .current_track
            .unwrap()
            .is_favorite
    );
    app.core()
        .set_track_rating_half_steps(saved.track_id, Some(7))
        .await?;
    app.core().stop().await?;
    drop(session);
    let app = app.restart().await?;
    app.core()
        .set_embedded_playback_host(Box::new(Host::default()))
        .await?;
    let playback = app.core().play(saved.track_id).await?;
    assert!(playback.current_track.unwrap().is_favorite);
    assert_eq!(
        app.core().track(saved.track_id).await?.rating_half_steps,
        Some(7)
    );
    Ok(())
}
#[tokio::test]
async fn preferred_remote_falls_back_before_audio_but_never_after_playing() -> Result {
    let app = TestCore::open().await?;
    let local = local(&app).await?;
    let (session, id) = search(&app).await?;
    let source = session.attach_candidate(id, Some(local.id), true).await?;
    app.core()
        .prefer_track_source(local.id, Some(source.source_id))
        .await?;
    app.core()
        .set_embedded_playback_host(Box::new(Host::default()))
        .await?;
    app.core().play(local.id).await?;
    let first = app.core().embedded_playback().await.unwrap();
    assert_eq!(first.source_id, Some(source.source_id));
    event(&app, &first.generation, 1, EmbeddedEventKind::Failed, 0.0).await?;
    assert!(app.core().embedded_playback().await.is_none());
    assert!(app.core().playback().await.is_playing);
    let selected = app.core().playback_source_status().await.unwrap();
    assert_eq!(selected.provider, "local");
    assert!(selected.message.is_some());
    assert!(
        app.core()
            .track_sources(local.id)
            .await?
            .iter()
            .any(|s| s.source_id == source.source_id && s.preferred)
    );
    app.core().play(local.id).await?;
    let second = app.core().embedded_playback().await.unwrap();
    event(&app, &second.generation, 1, EmbeddedEventKind::Playing, 0.0).await?;
    event(&app, &second.generation, 2, EmbeddedEventKind::Failed, 5.0).await?;
    assert_eq!(
        app.core().embedded_playback().await.unwrap().state,
        EmbeddedPlaybackState::Failed
    );
    assert!(!app.core().playback().await.is_playing);
    assert!(
        app.core()
            .playback_history_page(20, 0)
            .await?
            .items
            .is_empty()
    );
    Ok(())
}
#[tokio::test]
async fn explicit_selection_never_falls_back_and_plugin_disable_is_persistent() -> Result {
    let app = TestCore::open().await?;
    let local = local(&app).await?;
    let (session, id) = search(&app).await?;
    let source = session.attach_candidate(id, Some(local.id), true).await?;
    app.core()
        .set_embedded_playback_host(Box::new(Host::default()))
        .await?;
    app.core()
        .play_track_source(local.id, source.source_id)
        .await?;
    let state = app.core().embedded_playback().await.unwrap();
    event(&app, &state.generation, 1, EmbeddedEventKind::Failed, 0.0).await?;
    assert!(app.core().embedded_playback().await.is_some());
    assert!(!app.core().playback().await.is_playing);
    app.core().set_soundcloud_playback_enabled(false).await?;
    assert!(app.core().embedded_playback().await.is_none());
    assert!(
        app.core()
            .play_embedded_track_source(local.id, source.source_id)
            .await
            .is_err()
    );
    assert!(app.core().play(local.id).await?.is_playing);
    session.close().await;
    drop(session);
    let app = app.restart().await?;
    assert!(!app.core().soundcloud_playback_enabled().await);
    Ok(())
}
#[tokio::test]
async fn temporary_session_never_writes_history_and_rejects_stale_or_disabled_candidates() -> Result
{
    let app = TestCore::open().await?;
    let (session, id) = search(&app).await?;
    app.core()
        .set_embedded_playback_host(Box::new(Host::default()))
        .await?;
    session.preview_candidate(id.clone()).await?;
    let status = app.core().embedded_playback().await.unwrap();
    event(&app, &status.generation, 1, EmbeddedEventKind::Playing, 0.0).await?;
    event(
        &app,
        &status.generation,
        2,
        EmbeddedEventKind::Seeked,
        179.0,
    )
    .await?;
    event(&app, &status.generation, 3, EmbeddedEventKind::Ended, 180.0).await?;
    assert!(app.all_tracks_via_pages().await?.is_empty());
    assert!(
        app.core()
            .playback_history_page(20, 0)
            .await?
            .items
            .is_empty()
    );
    app.core().set_soundcloud_playback_enabled(false).await?;
    assert!(session.preview_candidate(id.clone()).await.is_err());
    app.core().set_soundcloud_playback_enabled(true).await?;
    session.close().await;
    assert!(session.preview_candidate(id).await.is_err());
    Ok(())
}
#[tokio::test]
async fn queue_and_collection_resolve_only_the_selected_remote_occurrence() -> Result {
    let app = TestCore::open().await?;
    let local = local(&app).await?;
    let (session, id) = search(&app).await?;
    let remote = session.attach_candidate(id, None, true).await?;
    let host = Host::default();
    app.core()
        .set_embedded_playback_host(Box::new(host.clone()))
        .await?;
    let snapshot = app
        .core()
        .play_collection(
            vec![local.id, remote.track_id, remote.track_id],
            vec![
                "playlist:1#0".into(),
                "playlist:1#1".into(),
                "playlist:1#2".into(),
            ],
            Some(0),
            Some(false),
        )
        .await?;
    assert!(snapshot.is_playing);
    assert!(host.0.lock().unwrap().is_empty());
    let next = app.core().next_track().await?;
    assert_eq!(next.current_track.unwrap().id, remote.track_id);
    assert_eq!(next.source_context, "playlist:1#1");
    assert_ne!(next.queue[0].occurrence_id, next.queue[1].occurrence_id);
    assert_eq!(
        host.0
            .lock()
            .unwrap()
            .iter()
            .filter(|c| c.kind == EmbeddedCommandKind::Load)
            .count(),
        1
    );
    Ok(())
}

#[tokio::test]
async fn a_loading_timeout_can_fallback_but_observed_progress_blocks_it() -> Result {
    let app = TestCore::open().await?;
    let local = local(&app).await?;
    let (session, id) = search(&app).await?;
    let source = session.attach_candidate(id, Some(local.id), true).await?;
    app.core()
        .prefer_track_source(local.id, Some(source.source_id))
        .await?;
    app.core()
        .set_embedded_playback_host(Box::new(Host::default()))
        .await?;
    app.core().play(local.id).await?;
    tokio::time::pause();
    tokio::time::advance(std::time::Duration::from_secs(31)).await;
    tokio::time::resume();
    for _ in 0..40 {
        if app.core().embedded_playback().await.is_none() {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    assert!(app.core().embedded_playback().await.is_none());
    assert_eq!(
        app.core().playback_source_status().await.unwrap().provider,
        "local"
    );
    app.core().play(local.id).await?;
    let state = app.core().embedded_playback().await.unwrap();
    event(&app, &state.generation, 1, EmbeddedEventKind::Progress, 1.0).await?;
    event(&app, &state.generation, 2, EmbeddedEventKind::Failed, 1.0).await?;
    assert_eq!(
        app.core().embedded_playback().await.unwrap().state,
        EmbeddedPlaybackState::Failed
    );
    assert!(
        app.core()
            .playback_history_page(20, 0)
            .await?
            .items
            .is_empty()
    );
    Ok(())
}

#[tokio::test]
async fn natural_native_completion_can_resolve_the_next_remote_source() -> Result {
    let app = TestCore::open().await?;
    app.files().write_silent_wav_with_duration("short.wav", 1)?;
    app.core()
        .scan_library(vec![app.files().library_dir().to_string_lossy().into()])
        .await?;
    let local = app.all_tracks_via_pages().await?.remove(0);
    let (session, id) = search(&app).await?;
    let source = session.attach_candidate(id, None, true).await?;
    let host = Host::default();
    app.core()
        .set_embedded_playback_host(Box::new(host.clone()))
        .await?;
    app.core().play(local.id).await?;
    app.core().add_to_queue(source.track_id).await?;
    assert!(host.0.lock().unwrap().is_empty());
    for _ in 0..80 {
        app.process_mock_audio(32).await;
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        if app.core().embedded_playback().await.is_some() {
            break;
        }
    }
    assert_eq!(
        app.core().embedded_playback().await.unwrap().track_id,
        Some(source.track_id)
    );
    assert_eq!(
        host.0
            .lock()
            .unwrap()
            .iter()
            .filter(|c| c.kind == EmbeddedCommandKind::Load)
            .count(),
        1
    );
    Ok(())
}

#[tokio::test]
async fn preview_queue_has_no_fake_track_and_association_preserves_occurrences() -> Result {
    let app = TestCore::open().await?;
    let local = local(&app).await?;
    app.core()
        .set_embedded_playback_host(Box::new(Host::default()))
        .await?;
    let (session, id) = search(&app).await?;
    session.preview_candidate(id).await?;
    let generation = app.core().embedded_playback().await.unwrap().generation;
    app.core().add_to_queue(local.id).await?;
    app.core().add_to_queue(local.id).await?;
    let before = app.core().queue().await?;
    assert_eq!(before.len(), 2);
    assert_eq!(before[0].position, 0);
    assert_ne!(before[0].occurrence_id, before[1].occurrence_id);
    app.core().remove_from_queue(0).await?;
    let upcoming = app.core().queue().await?[0].occurrence_id.clone();
    app.core()
        .save_listening_source(generation, Some(local.id), true)
        .await?;
    let after = app.core().queue().await?;
    assert_eq!(after.len(), 2);
    assert_eq!(after[1].occurrence_id, upcoming);
    assert_ne!(after[0].occurrence_id, upcoming);
    assert!(app.core().remove_from_queue(0).await.is_err());
    assert_eq!(app.all_tracks_via_pages().await?.len(), 1);
    Ok(())
}

#[tokio::test]
async fn soundcloud_link_validation_keeps_metadata_and_reports_the_actual_invalid_field() -> Result
{
    let app = TestCore::open().await?;
    let entry = app
        .core()
        .resolve_soundcloud_link_entry(
            "https://soundcloud.com/goldlip/snooze-this-on?si=discard".into(),
            " Snooze This On ".into(),
            Some(" Gold Lip ".into()),
        )
        .await?;
    assert_eq!(entry.title, "Snooze This On");
    assert_eq!(entry.artist_credit.as_deref(), Some("Gold Lip"));
    assert_eq!(entry.reference.id, "goldlip/snooze-this-on");
    assert_eq!(
        entry.canonical_url.as_deref(),
        Some("https://soundcloud.com/goldlip/snooze-this-on")
    );
    let bad_name = app
        .core()
        .resolve_soundcloud_link_entry("https://on.soundcloud.com/shared".into(), " ".into(), None)
        .await
        .unwrap_err();
    assert!(matches!(bad_name,CoreError::InvalidInput {message} if message.contains("nome")));
    assert!(
        app.core()
            .resolve_soundcloud_link_entry(
                "https://soundcloud.com/goldlip".into(),
                "Track".into(),
                None
            )
            .await
            .is_err()
    );
    // Expansion respects the same provider lifecycle as source search, before HTTP.
    app.core()
        .set_source_provider_enabled("service-links".into(), false)
        .await?;
    let disabled = app
        .core()
        .resolve_soundcloud_link_entry(
            "https://on.soundcloud.com/shared".into(),
            "Track".into(),
            None,
        )
        .await
        .unwrap_err();
    assert!(matches!(disabled,CoreError::InvalidInput {message} if message.contains("desativada")));
    assert!(app.all_tracks_via_pages().await?.is_empty());
    Ok(())
}
