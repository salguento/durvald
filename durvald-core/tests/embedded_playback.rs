#![cfg(feature = "test-support")]
mod common;
use common::TestCore;
use durvald_core::*;
use std::{
    error::Error,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};
type Result<T = ()> = std::result::Result<T, Box<dyn Error + Send + Sync>>;
#[derive(Clone, Default)]
struct Host {
    commands: Arc<Mutex<Vec<EmbeddedPlaybackCommand>>>,
    refuse_stop: Arc<AtomicBool>,
    load_gate: Option<Arc<(Mutex<bool>, std::sync::Condvar)>>,
    entered: Arc<AtomicBool>,
}
impl EmbeddedPlaybackHost for Host {
    fn execute(&self, command: EmbeddedPlaybackCommand) -> bool {
        if command.kind == EmbeddedCommandKind::Load {
            if let Some(gate) = &self.load_gate {
                self.entered.store(true, Ordering::SeqCst);
                let (lock, signal) = &**gate;
                let mut allowed = lock.lock().unwrap();
                while !*allowed {
                    allowed = signal.wait(allowed).unwrap();
                }
            }
        }
        let refused =
            command.kind == EmbeddedCommandKind::Stop && self.refuse_stop.load(Ordering::SeqCst);
        self.commands.lock().unwrap().push(command);
        !refused
    }
}
async fn remote(app: &TestCore) -> Result<TrackSource> {
    let session = app.core().source_search_session();
    let page = session
        .search(
            "service-links".into(),
            CatalogEntry {
                reference: CatalogReference {
                    provider: "test".into(),
                    kind: CatalogItemKind::Recording,
                    id: "embedded-fixture".into(),
                },
                title: "Fixture".into(),
                artist_credit: None,
                version_label: None,
                duration_seconds: Some(999),
                canonical_url: None,
            },
            Some("https://soundcloud.com/fixture/song".into()),
            1,
        )
        .await?;
    Ok(session
        .attach_candidate(page.candidates[0].candidate_id.clone(), None, true)
        .await?)
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
async fn event(
    app: &TestCore,
    generation: &str,
    sequence: u64,
    kind: EmbeddedEventKind,
    position: f64,
    duration: Option<f64>,
) -> Result {
    app.core()
        .report_embedded_playback_event(EmbeddedPlaybackEvent {
            generation: generation.into(),
            sequence,
            kind,
            position_seconds: position,
            duration_seconds: duration,
        })
        .await?;
    Ok(())
}
#[tokio::test]
async fn host_is_required_and_only_enabled_owned_soundcloud_sources_can_start() -> Result {
    let app = TestCore::open().await?;
    let source = remote(&app).await?;
    assert!(
        app.core()
            .play_embedded_track_source(source.track_id, source.source_id)
            .await
            .is_err()
    );
    let host = Host::default();
    app.core()
        .set_embedded_playback_host(Box::new(host.clone()))
        .await?;
    assert!(
        app.core()
            .play_embedded_track_source(source.track_id + 1, source.source_id)
            .await
            .is_err()
    );
    app.core()
        .set_track_source_enabled(source.track_id, source.source_id, false)
        .await?;
    assert!(
        app.core()
            .play_embedded_track_source(source.track_id, source.source_id)
            .await
            .is_err()
    );
    assert!(host.commands.lock().unwrap().is_empty());
    Ok(())
}
#[tokio::test]
async fn commands_wait_for_observed_state_and_stale_events_cannot_change_new_session() -> Result {
    let app = TestCore::open().await?;
    let source = remote(&app).await?;
    let host = Host::default();
    app.core()
        .set_embedded_playback_host(Box::new(host.clone()))
        .await?;
    let snapshot = app
        .core()
        .play_embedded_track_source(source.track_id, source.source_id)
        .await?;
    assert!(!snapshot.is_playing);
    assert_eq!(snapshot.duration_seconds, None);
    let first = app.core().embedded_playback().await.unwrap().generation;
    event(&app, &first, 1, EmbeddedEventKind::Ready, 0.0, Some(90.0)).await?;
    event(&app, &first, 2, EmbeddedEventKind::Playing, 0.0, None).await?;
    app.core().pause().await?;
    assert!(app.core().playback().await.is_playing); // command is not a synthetic PAUSE
    event(&app, &first, 3, EmbeddedEventKind::Paused, 2.0, None).await?;
    assert!(app.core().playback().await.is_paused);
    app.core().seek(12).await?;
    app.core().resume().await?;
    app.core().set_volume(0.3).await?;
    assert_eq!(app.core().playback().await.position_seconds, 2.0);
    assert!(app.core().seek(91).await.is_err());
    event(&app, &first, 2, EmbeddedEventKind::Playing, 0.0, None).await?;
    assert!(app.core().playback().await.is_paused);
    app.core()
        .play_embedded_track_source(source.track_id, source.source_id)
        .await?;
    event(
        &app,
        &first,
        100,
        EmbeddedEventKind::Playing,
        80.0,
        Some(90.0),
    )
    .await?;
    let next = app.core().playback().await;
    assert!(!next.is_playing);
    assert_eq!(next.position_seconds, 0.0);
    assert!(
        event(
            &app,
            &first,
            101,
            EmbeddedEventKind::Progress,
            f64::NAN,
            None
        )
        .await
        .is_err()
    );
    app.core().stop().await?;
    let kinds: Vec<_> = host
        .commands
        .lock()
        .unwrap()
        .iter()
        .map(|c| c.kind)
        .collect();
    assert_eq!(
        kinds,
        vec![
            EmbeddedCommandKind::Load,
            EmbeddedCommandKind::Pause,
            EmbeddedCommandKind::Seek,
            EmbeddedCommandKind::Play,
            EmbeddedCommandKind::Volume,
            EmbeddedCommandKind::Stop,
            EmbeddedCommandKind::Load,
            EmbeddedCommandKind::Stop
        ]
    );
    Ok(())
}
#[tokio::test]
async fn native_switch_requires_stop_ack_and_preserves_duplicate_upcoming_occurrences() -> Result {
    let app = TestCore::open().await?;
    let local = local(&app).await?;
    let source = remote(&app).await?;
    let host = Host::default();
    app.core()
        .set_embedded_playback_host(Box::new(host.clone()))
        .await?;
    app.core().play(local.id).await?;
    app.core().add_to_queue(local.id).await?;
    app.core().add_to_queue(local.id).await?;
    app.core()
        .play_embedded_track_source(source.track_id, source.source_id)
        .await?;
    let queue = app.core().queue().await?;
    assert_eq!(queue.len(), 3);
    assert_ne!(queue[1].occurrence_id, queue[2].occurrence_id);
    app.core().add_to_queue(local.id).await?;
    assert_eq!(
        app.core().playback().await.current_track.unwrap().id,
        source.track_id
    );
    assert!(app.core().remove_from_queue(0).await.is_err());
    assert!(app.core().move_queue_item(0, 1).await.is_err());
    app.core().move_queue_item(1, 2).await?;
    app.core().remove_from_queue(3).await?;
    host.refuse_stop.store(true, Ordering::SeqCst);
    assert!(app.core().play(local.id).await.is_err());
    assert!(app.core().embedded_playback().await.is_some());
    host.refuse_stop.store(false, Ordering::SeqCst);
    let next = app.core().next_track().await?;
    assert_eq!(next.current_track.unwrap().id, local.id);
    assert_eq!(next.queue.len(), 2);
    assert!(app.core().embedded_playback().await.is_none());
    Ok(())
}
#[tokio::test]
async fn actual_observed_duration_is_recorded_once_and_finish_advances_to_local() -> Result {
    let app = TestCore::open().await?;
    let source = remote(&app).await?;
    let local = local(&app).await?;
    app.core()
        .set_embedded_playback_host(Box::new(Host::default()))
        .await?;
    app.core()
        .play_embedded_track_source(source.track_id, source.source_id)
        .await?;
    app.core().add_to_queue(local.id).await?;
    let generation = app.core().embedded_playback().await.unwrap().generation;
    event(
        &app,
        &generation,
        1,
        EmbeddedEventKind::Ready,
        0.0,
        Some(2.0),
    )
    .await?;
    event(&app, &generation, 2, EmbeddedEventKind::Playing, 0.0, None).await?;
    tokio::time::sleep(Duration::from_millis(1100)).await;
    event(&app, &generation, 3, EmbeddedEventKind::Progress, 1.1, None).await?;
    event(&app, &generation, 4, EmbeddedEventKind::Ended, 2.0, None).await?;
    event(&app, &generation, 5, EmbeddedEventKind::Ended, 2.0, None).await?;
    assert_eq!(
        app.core().playback().await.current_track.unwrap().id,
        local.id
    );
    let history = app.core().playback_history_page(20, 0).await?;
    assert_eq!(history.items.len(), 1);
    assert_eq!(history.items[0].duration_seconds, 1);
    assert_eq!(history.items[0].effective_duration_seconds, Some(2));
    assert_eq!(history.items[0].source_id, Some(source.source_id));
    Ok(())
}
#[tokio::test]
async fn seeking_failures_and_short_sessions_do_not_manufacture_history_or_replays() -> Result {
    let app = TestCore::open().await?;
    let source = remote(&app).await?;
    let host = Host::default();
    app.core()
        .set_embedded_playback_host(Box::new(host.clone()))
        .await?;
    app.core()
        .play_embedded_track_source(source.track_id, source.source_id)
        .await?;
    let generation = app.core().embedded_playback().await.unwrap().generation;
    event(
        &app,
        &generation,
        1,
        EmbeddedEventKind::Ready,
        0.0,
        Some(180.0),
    )
    .await?;
    event(&app, &generation, 2, EmbeddedEventKind::Playing, 0.0, None).await?;
    event(&app, &generation, 3, EmbeddedEventKind::Seeked, 179.0, None).await?;
    event(&app, &generation, 4, EmbeddedEventKind::Ended, 180.0, None).await?;
    assert!(
        app.core()
            .playback_history_page(20, 0)
            .await?
            .items
            .is_empty()
    );
    app.core().resume().await?;
    let fresh = app.core().embedded_playback().await.unwrap().generation;
    assert_ne!(generation, fresh);
    event(&app, &fresh, 1, EmbeddedEventKind::Failed, 0.0, None).await?;
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
    app.core().detach_embedded_playback_host().await?;
    assert!(app.core().embedded_playback().await.is_none());
    Ok(())
}

#[tokio::test]
async fn repeat_reloads_a_new_generation_without_counting_a_short_listen() -> Result {
    let app = TestCore::open().await?;
    let source = remote(&app).await?;
    let host = Host::default();
    app.core()
        .set_embedded_playback_host(Box::new(host.clone()))
        .await?;
    app.core()
        .play_embedded_track_source(source.track_id, source.source_id)
        .await?;
    app.core().set_repeat_mode(RepeatMode::One).await?;
    let first = app.core().embedded_playback().await.unwrap().generation;
    event(&app, &first, 1, EmbeddedEventKind::Ready, 0.0, Some(180.0)).await?;
    event(&app, &first, 2, EmbeddedEventKind::Ended, 180.0, None).await?;
    let second = app.core().embedded_playback().await.unwrap().generation;
    assert_ne!(first, second);
    event(&app, &first, 3, EmbeddedEventKind::Ended, 180.0, None).await?;
    assert_eq!(
        app.core().embedded_playback().await.unwrap().generation,
        second
    );
    assert_eq!(
        host.commands
            .lock()
            .unwrap()
            .iter()
            .filter(|c| c.kind == EmbeddedCommandKind::Load)
            .count(),
        2
    );
    assert!(
        app.core()
            .playback_history_page(20, 0)
            .await?
            .items
            .is_empty()
    );
    app.core().stop().await?;
    Ok(())
}

#[tokio::test]
async fn loading_timeout_silences_the_host_and_does_not_create_history() -> Result {
    let app = TestCore::open().await?;
    let source = remote(&app).await?;
    let host = Host::default();
    app.core()
        .set_embedded_playback_host(Box::new(host.clone()))
        .await?;
    app.core()
        .play_embedded_track_source(source.track_id, source.source_id)
        .await?;
    tokio::time::pause();
    tokio::time::advance(Duration::from_secs(31)).await;
    tokio::time::resume();
    for _ in 0..40 {
        if app.core().embedded_playback().await.unwrap().state == EmbeddedPlaybackState::Failed {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert_eq!(
        app.core().embedded_playback().await.unwrap().state,
        EmbeddedPlaybackState::Failed
    );
    assert!(!app.core().playback().await.is_playing);
    assert!(
        host.commands
            .lock()
            .unwrap()
            .iter()
            .any(|c| c.kind == EmbeddedCommandKind::Stop)
    );
    assert!(
        app.core()
            .playback_history_page(20, 0)
            .await?
            .items
            .is_empty()
    );
    app.core()
        .set_track_source_enabled(source.track_id, source.source_id, false)
        .await?;
    assert!(app.core().resume().await.is_err());
    app.core().detach_embedded_playback_host().await?;
    Ok(())
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cancelled_open_cannot_deliver_a_late_load_after_native_replacement() -> Result {
    let app = TestCore::open().await?;
    let source = remote(&app).await?;
    let local = local(&app).await?;
    let gate = Arc::new((Mutex::new(false), std::sync::Condvar::new()));
    let host = Host {
        load_gate: Some(gate.clone()),
        ..Host::default()
    };
    app.core()
        .set_embedded_playback_host(Box::new(host.clone()))
        .await?;
    let core = app.core().clone();
    let open = tokio::spawn(async move {
        core.play_embedded_track_source(source.track_id, source.source_id)
            .await
    });
    for _ in 0..100 {
        if host.entered.load(Ordering::SeqCst) {
            break;
        }
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    assert!(host.entered.load(Ordering::SeqCst));
    open.abort();
    let core = app.core().clone();
    let native = tokio::spawn(async move { core.play(local.id).await });
    tokio::time::sleep(Duration::from_millis(50)).await;
    let waited = !native.is_finished();
    let (lock, signal) = &*gate;
    *lock.lock().unwrap() = true;
    signal.notify_all();
    let _ = open.await;
    let playback = native.await??;
    assert!(
        waited,
        "Native playback must wait for the in-flight platform handoff"
    );
    assert_eq!(playback.current_track.unwrap().id, local.id);
    assert!(app.core().embedded_playback().await.is_none());
    let kinds: Vec<_> = host
        .commands
        .lock()
        .unwrap()
        .iter()
        .map(|c| c.kind)
        .collect();
    assert_eq!(
        kinds,
        vec![EmbeddedCommandKind::Load, EmbeddedCommandKind::Stop]
    );
    Ok(())
}

#[tokio::test]
async fn repeated_play_notifications_do_not_extend_a_stalled_transport_deadline() -> Result {
    let app = TestCore::open().await?;
    let source = remote(&app).await?;
    let next = local(&app).await?;
    let host = Host::default();
    app.core()
        .set_embedded_playback_host(Box::new(host.clone()))
        .await?;
    app.core()
        .play_collection(
            vec![source.track_id, next.id, next.id],
            vec!["remote".into(), "next".into(), "duplicate".into()],
            Some(0),
            Some(false),
        )
        .await?;
    let initial = app.core().playback().await;
    let generation = app.core().embedded_playback().await.unwrap().generation;
    event(
        &app,
        &generation,
        1,
        EmbeddedEventKind::Ready,
        0.,
        Some(180.),
    )
    .await?;
    event(&app, &generation, 2, EmbeddedEventKind::Playing, 0., None).await?;
    event(&app, &generation, 3, EmbeddedEventKind::Seeked, 179., None).await?;
    tokio::time::pause();
    tokio::time::advance(Duration::from_secs(29)).await;
    event(&app, &generation, 4, EmbeddedEventKind::Playing, 179., None).await?;
    tokio::time::advance(Duration::from_secs(2)).await;
    tokio::time::resume();
    for _ in 0..40 {
        if app.core().embedded_playback().await.unwrap().state == EmbeddedPlaybackState::Failed {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert_eq!(
        app.core().embedded_playback().await.unwrap().state,
        EmbeddedPlaybackState::Failed
    );
    assert!(
        host.commands
            .lock()
            .unwrap()
            .iter()
            .any(|c| c.kind == EmbeddedCommandKind::Stop)
    );
    let failed = app.core().playback().await;
    assert!(!failed.is_playing);
    assert_eq!(failed.queue, initial.queue);
    assert!(
        app.core()
            .playback_history_page(20, 0)
            .await?
            .items
            .is_empty()
    );
    // Even a late real FINISH cannot complete an attempt already failed/stopped.
    event(&app, &generation, 5, EmbeddedEventKind::Ended, 180., None).await?;
    assert_eq!(app.core().playback().await.queue, initial.queue);
    assert!(
        app.core()
            .playback_history_page(20, 0)
            .await?
            .items
            .is_empty()
    );
    app.core().resume().await?;
    let retry = app.core().embedded_playback().await.unwrap();
    assert_ne!(retry.generation, generation);
    assert_eq!(retry.state, EmbeddedPlaybackState::Loading);
    app.core().detach_embedded_playback_host().await?;
    Ok(())
}
