#![cfg(feature = "test-support")]
mod common;
use common::TestCore;
use durvald_core::*;
use std::{
    error::Error,
    sync::{Arc, Mutex},
    time::Duration,
};
type Result<T = ()> = std::result::Result<T, Box<dyn Error + Send + Sync>>;
#[derive(Clone, Default)]
struct Host(Arc<Mutex<Vec<EmbeddedPlaybackCommand>>>);
impl EmbeddedPlaybackHost for Host {
    fn execute(&self, c: EmbeddedPlaybackCommand) -> bool {
        self.0.lock().unwrap().push(c);
        true
    }
}
async fn remote(app: &TestCore, slug: &str) -> Result<Track> {
    Ok(app
        .core()
        .save_remote_track(CatalogEntry {
            reference: CatalogReference {
                provider: "soundcloud".into(),
                kind: CatalogItemKind::AudioTrack,
                id: format!("fixture/{slug}"),
            },
            title: slug.into(),
            artist_credit: Some("Fixture Artist".into()),
            version_label: None,
            duration_seconds: Some(999),
            canonical_url: Some(format!("https://soundcloud.com/fixture/{slug}")),
        })
        .await?)
}
async fn local(app: &TestCore) -> Result<Track> {
    app.files()
        .write_silent_wav_with_duration("native.wav", 3)?;
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
async fn event(
    app: &TestCore,
    g: &str,
    sequence: u64,
    kind: EmbeddedEventKind,
    position: f64,
    duration: f64,
) -> Result {
    app.core()
        .report_embedded_playback_event(EmbeddedPlaybackEvent {
            generation: g.into(),
            sequence,
            kind,
            position_seconds: position,
            duration_seconds: Some(duration),
        })
        .await?;
    Ok(())
}
async fn end(app: &TestCore) -> Result {
    let s = app.core().embedded_playback().await.unwrap();
    event(app, &s.generation, 1, EmbeddedEventKind::Ended, 2.0, 2.0).await
}
async fn listen(app: &TestCore) -> Result {
    let g = app.core().embedded_playback().await.unwrap().generation;
    event(app, &g, 1, EmbeddedEventKind::Ready, 0.0, 2.0).await?;
    event(app, &g, 2, EmbeddedEventKind::Playing, 0.0, 2.0).await?;
    tokio::time::sleep(Duration::from_millis(1100)).await;
    event(app, &g, 3, EmbeddedEventKind::Progress, 1.1, 2.0).await?;
    event(app, &g, 4, EmbeddedEventKind::Ended, 2.0, 2.0).await
}
#[tokio::test]
async fn mixed_collection_repeat_shuffle_previous_and_duplicate_occurrences_keep_contexts() -> Result
{
    let app = TestCore::open().await?;
    let a = remote(&app, "a").await?;
    let b = remote(&app, "b").await?;
    let l = local(&app).await?;
    app.core()
        .set_embedded_playback_host(Box::new(Host::default()))
        .await?;
    let initial = app
        .core()
        .play_collection(
            vec![a.id, l.id, a.id, b.id],
            vec![
                "playlist:7#0".into(),
                "playlist:7#1".into(),
                "playlist:7#2".into(),
                "playlist:7#3".into(),
            ],
            Some(3),
            Some(false),
        )
        .await?;
    assert_eq!(initial.queue.len(), 1);
    assert_eq!(initial.source_context, "playlist:7#3");
    app.core().set_repeat_mode(RepeatMode::All).await?;
    end(&app).await?;
    let cycle = app.core().playback().await;
    assert_eq!(
        cycle.queue.iter().map(|q| q.track_id).collect::<Vec<_>>(),
        vec![a.id, l.id, a.id, b.id]
    );
    assert_eq!(cycle.source_context, "playlist:7#0");
    assert_ne!(cycle.queue[0].occurrence_id, cycle.queue[2].occurrence_id);
    app.core().set_shuffle_enabled(true).await?;
    let ordered = app.core().set_shuffle_enabled(false).await?;
    assert_eq!(ordered.queue, cycle.queue);
    let native = app.core().next_track().await?;
    assert_eq!(native.current_track.unwrap().id, l.id);
    assert_eq!(native.source_context, "playlist:7#1");
    let previous = app.core().previous_track().await?;
    assert_eq!(previous.current_track.unwrap().id, a.id);
    assert_eq!(previous.source_context, "playlist:7#0");
    assert_eq!(
        previous.queue[0].occurrence_id,
        cycle.queue[0].occurrence_id
    );
    app.core().move_queue_item(3, 1).await?;
    app.core().remove_from_queue(2).await?;
    let edited = app.core().playback().await;
    assert_eq!(
        edited.queue.iter().map(|q| q.track_id).collect::<Vec<_>>(),
        vec![a.id, b.id, a.id]
    );
    let restored = app.restart().await?;
    assert_eq!(restored.core().playback().await.queue, edited.queue);
    assert!(restored.core().embedded_playback().await.is_none());
    Ok(())
}
#[tokio::test]
async fn remote_restore_is_offline_paused_revalidates_the_chosen_source_and_seeks_only_after_ready()
-> Result {
    let app = TestCore::open().await?;
    let a = remote(&app, "restore").await?;
    let b = remote(&app, "next").await?;
    app.core()
        .set_embedded_playback_host(Box::new(Host::default()))
        .await?;
    app.core()
        .play_collection(
            vec![a.id, b.id, a.id],
            vec![
                "playlist:8#0".into(),
                "playlist:8#1".into(),
                "playlist:8#2".into(),
            ],
            Some(0),
            Some(false),
        )
        .await?;
    let source = app.core().track_sources(a.id).await?[0].clone();
    app.core()
        .play_embedded_track_source(a.id, source.source_id)
        .await?;
    app.core()
        .set_track_rating_half_steps(a.id, Some(7))
        .await?;
    app.core().set_track_favorite(a.id, true).await?;
    let g = app.core().embedded_playback().await.unwrap().generation;
    event(&app, &g, 1, EmbeddedEventKind::Ready, 0.0, 100.0).await?;
    event(&app, &g, 2, EmbeddedEventKind::Seeked, 20.0, 100.0).await?;
    event(&app, &g, 3, EmbeddedEventKind::Paused, 20.0, 100.0).await?;
    let queue = app.core().playback().await.queue;
    let saved = app.core().last_session().await?;
    assert_eq!(saved.progress_seconds, 20.0);
    assert!(!saved.source_context.contains("https://"));
    let app = app.restart().await?;
    assert!(app.core().embedded_playback().await.is_none());
    let state = app.core().playback().await;
    assert!(state.is_paused);
    assert!(!state.is_playing);
    assert_eq!(state.queue, queue);
    assert_eq!(state.source_context, "playlist:8#0");
    let host = Host::default();
    app.core()
        .set_embedded_playback_host(Box::new(host.clone()))
        .await?;
    app.core()
        .set_track_source_enabled(a.id, source.source_id, false)
        .await?;
    assert!(app.core().resume().await.is_err());
    assert!(host.0.lock().unwrap().is_empty());
    assert_eq!(app.core().playback().await.queue, queue);
    app.core()
        .set_track_source_enabled(a.id, source.source_id, true)
        .await?;
    app.core().resume().await?;
    assert_eq!(
        host.0
            .lock()
            .unwrap()
            .iter()
            .filter(|c| c.kind == EmbeddedCommandKind::Seek)
            .count(),
        0
    );
    let g = app.core().embedded_playback().await.unwrap().generation;
    event(&app, &g, 1, EmbeddedEventKind::Ready, 0.0, 100.0).await?;
    assert!(
        host.0
            .lock()
            .unwrap()
            .iter()
            .any(|c| c.kind == EmbeddedCommandKind::Seek && c.value == 20.0)
    );
    assert_eq!(app.core().playback().await.queue, queue);
    let track = app.core().track(a.id).await?;
    assert_eq!(track.rating_half_steps, Some(7));
    assert!(track.is_favorite);
    assert_eq!(app.all_tracks_via_pages().await?.len(), 2);
    Ok(())
}
#[tokio::test]
async fn remote_history_uses_observed_duration_and_retry_receipts_survive_deletion_and_restart()
-> Result {
    let app = TestCore::open().await?;
    let track = remote(&app, "history").await?;
    let source = app.core().track_sources(track.id).await?[0].clone();
    app.core()
        .set_embedded_playback_host(Box::new(Host::default()))
        .await?;
    app.core()
        .play_embedded_track_source(track.id, source.source_id)
        .await?;
    listen(&app).await?;
    let history = app.core().playback_history().await?;
    assert_eq!(history.len(), 1);
    assert_eq!(history[0].source_id, Some(source.source_id));
    assert_eq!(history[0].effective_duration_seconds, Some(2));
    assert_eq!(history[0].duration_seconds, 1);
    let smart = app
        .core()
        .create_smart_playlist(
            "Remote plays".into(),
            "".into(),
            SmartPlaylistDefinition {
                match_all: true,
                rules: vec![SmartPlaylistRule {
                    field: "play_count".into(),
                    comparison: "greater".into(),
                    value: "0".into(),
                }],
                limit: None,
                sort_by: "play_count".into(),
                descending: true,
            },
        )
        .await?;
    assert_eq!(app.core().playlist_tracks(smart.id).await?[0].id, track.id);
    let now = chrono::Utc::now().timestamp();
    let replay = app
        .core()
        .replay_preview(ReplayRequest {
            period: ReplayPeriod::Daily,
            start_at: now - 3600,
            end_at: now + 3600,
        })
        .await?;
    assert_eq!(replay.eligible_count, 1);
    app.core().resume().await?;
    listen(&app).await?;
    assert_eq!(app.core().playback_history().await?.len(), 1);
    assert_eq!(app.core().track(track.id).await?.play_count, 1);
    app.core().clear_playback_history().await?;
    let app = app.restart().await?;
    app.core()
        .set_embedded_playback_host(Box::new(Host::default()))
        .await?;
    app.core().resume().await?;
    listen(&app).await?;
    assert!(app.core().playback_history().await?.is_empty());
    assert_eq!(app.core().track(track.id).await?.play_count, 1);
    app.core().set_repeat_mode(RepeatMode::One).await?;
    app.core().resume().await?;
    listen(&app).await?;
    let first = app.core().embedded_playback().await.unwrap().generation;
    listen(&app).await?;
    assert_ne!(
        app.core().embedded_playback().await.unwrap().generation,
        first
    );
    assert_eq!(app.core().track(track.id).await?.play_count, 2);
    Ok(())
}
#[tokio::test]
async fn final_native_track_records_once_and_seek_to_the_end_does_not_manufacture_a_listen()
-> Result {
    let app = TestCore::open().await?;
    let track = local(&app).await?;
    app.core().play(track.id).await?;
    app.process_mock_audio(600).await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    let history = app.core().playback_history().await?;
    assert_eq!(history.len(), 1);
    assert_eq!(history[0].effective_duration_seconds, Some(3));
    assert!(history[0].source_id.is_some());
    app.core().resume().await?;
    app.process_mock_audio(600).await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(app.core().playback_history().await?.len(), 1);
    app.core().play(track.id).await?;
    app.core().seek(2).await?;
    app.process_mock_audio(600).await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(app.core().playback_history().await?.len(), 1);
    assert_eq!(app.core().track(track.id).await?.play_count, 1);
    Ok(())
}

#[tokio::test]
async fn legacy_events_remain_readable_and_missing_collection_tracks_leave_a_recoverable_queue()
-> Result {
    let app = TestCore::open().await?;
    let a = remote(&app, "first").await?;
    let b = remote(&app, "removed").await?;
    let c = remote(&app, "last").await?;
    app.core()
        .set_embedded_playback_host(Box::new(Host::default()))
        .await?;
    app.core()
        .play_collection(
            vec![a.id, b.id, c.id, a.id],
            vec![
                "playlist:9#0".into(),
                "playlist:9#1".into(),
                "playlist:9#2".into(),
                "playlist:9#3".into(),
            ],
            Some(0),
            Some(false),
        )
        .await?;
    let before = app.core().playback().await.queue;
    {
        let db = rusqlite::Connection::open(app.files().database_path())?;
        db.pragma_update(None, "foreign_keys", true)?;
        // This external fixture connection only contains remote (NULL-path)
        // sources; install the nullable path function required by delete triggers.
        db.create_scalar_function(
            "durvald_local_path_key",
            1,
            rusqlite::functions::FunctionFlags::SQLITE_DETERMINISTIC
                | rusqlite::functions::FunctionFlags::SQLITE_INNOCUOUS,
            |c| c.get::<Option<String>>(0),
        )?;
        db.execute("INSERT INTO play_history(song_id,played_at,play_duration) VALUES(?1,'2026-01-01T00:00:00Z',180)",[a.id])?;
        db.execute("DELETE FROM songs WHERE song_id=?1", [b.id])?;
    }
    let app = app.restart().await?;
    let state = app.core().playback().await;
    assert_eq!(
        state
            .queue
            .iter()
            .map(|q| q.occurrence_id.clone())
            .collect::<Vec<_>>(),
        vec![
            before[0].occurrence_id.clone(),
            before[2].occurrence_id.clone(),
            before[3].occurrence_id.clone()
        ]
    );
    assert!(state.is_paused);
    let legacy = app.core().playback_history().await?;
    assert_eq!(legacy[0].duration_seconds, 180);
    assert_eq!(legacy[0].source_id, None);
    assert_eq!(legacy[0].effective_duration_seconds, None);
    app.core()
        .set_embedded_playback_host(Box::new(Host::default()))
        .await?;
    app.core().resume().await?;
    let next = app.core().next_track().await?;
    assert_eq!(next.current_track.unwrap().id, c.id);
    assert_eq!(next.source_context, "playlist:9#2");
    let app = app.restart().await?;
    app.core()
        .set_embedded_playback_host(Box::new(Host::default()))
        .await?;
    app.core().resume().await?;
    let previous = app.core().previous_track().await?;
    assert_eq!(previous.current_track.unwrap().id, a.id);
    assert_eq!(previous.source_context, "playlist:9#0");
    assert_eq!(previous.queue[0].occurrence_id, before[0].occurrence_id);
    Ok(())
}

#[tokio::test]
async fn pre_audio_fallback_from_a_preview_to_a_local_file_records_the_actual_origin() -> Result {
    struct RefuseLoad;
    impl EmbeddedPlaybackHost for RefuseLoad {
        fn execute(&self, c: EmbeddedPlaybackCommand) -> bool {
            c.kind != EmbeddedCommandKind::Load
        }
    }
    let app = TestCore::open().await?;
    let track = local(&app).await?;
    let local_source = app.core().track_sources(track.id).await?[0].source_id;
    let search = app.core().source_search_session();
    let page = search
        .search(
            "service-links".into(),
            CatalogEntry {
                reference: CatalogReference {
                    provider: "library".into(),
                    kind: CatalogItemKind::Track,
                    id: track.id.to_string(),
                },
                title: track.title.clone(),
                artist_credit: Some(track.artist.clone()),
                version_label: None,
                duration_seconds: Some(3),
                canonical_url: None,
            },
            Some("https://soundcloud.com/fixture/preview-fallback".into()),
            1,
        )
        .await?;
    let source = search
        .attach_candidate(
            page.candidates[0].candidate_id.clone(),
            Some(track.id),
            true,
        )
        .await?;
    app.core()
        .prefer_track_source(track.id, Some(source.source_id))
        .await?;
    let db = rusqlite::Connection::open(app.files().database_path())?;
    db.execute("INSERT INTO service_media_policy(provider,external_id,preview_only,finite_video,verified_at) VALUES('soundcloud','fixture/preview-fallback',1,0,?1)",[chrono::Utc::now().timestamp()])?;
    app.core()
        .set_embedded_playback_host(Box::new(RefuseLoad))
        .await?;
    app.core().play(track.id).await?;
    let status = app.core().playback_source_status().await.unwrap();
    assert_eq!(status.source_id, Some(local_source));
    assert_eq!(status.preferred_source_id, Some(source.source_id));
    assert!(status.message.is_some());
    app.process_mock_audio(600).await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    let history = app.core().playback_history().await?;
    assert_eq!(history.len(), 1);
    assert_eq!(history[0].source_id, Some(local_source));
    assert_eq!(history[0].effective_duration_seconds, Some(3));
    assert_eq!(app.all_tracks_via_pages().await?.len(), 1);
    Ok(())
}
