#![cfg(feature = "test-support")]

mod common;

use std::error::Error;

use common::TestCore;
use durvald_core::{CoreError, RepeatMode, Track};

type TestResult<T> = Result<T, Box<dyn Error + Send + Sync>>;

async fn core_with_one_track() -> TestResult<(TestCore, Track)> {
    let test_core = TestCore::open().await?;

    test_core
        .files()
        .write_silent_wav("Artist/Album/playback.wav")?;

    let library_path = test_core
        .files()
        .library_dir()
        .to_string_lossy()
        .into_owned();

    let scan = test_core.core().scan_library(vec![library_path]).await?;

    assert_eq!(scan.new_tracks_added, 1);
    assert!(scan.errors.is_empty());

    let mut tracks = test_core.core().tracks().await?;

    assert_eq!(tracks.len(), 1);

    let track = tracks.remove(0);

    Ok((test_core, track))
}

#[tokio::test]
async fn plays_valid_track_without_adding_it_to_queue() -> TestResult<()> {
    let (test_core, track) = core_with_one_track().await?;

    let snapshot = test_core.core().play(track.id).await?;

    let current = snapshot
        .current_track
        .as_ref()
        .expect("played track must become current");

    assert_eq!(current.id, track.id);
    assert!(snapshot.is_playing);
    assert!(!snapshot.is_paused);
    assert_eq!(snapshot.queue.len(), 1);
    assert_eq!(snapshot.queue[0].track_id, track.id);
    assert_eq!(snapshot.queue[0].position, 0);
    assert_eq!(snapshot.queue_position, 0);

    let occurrences = snapshot
        .queue
        .iter()
        .filter(|item| item.track_id == track.id)
        .count();

    assert_eq!(occurrences, 1);
    assert_eq!(snapshot.volume, 0.5);
    assert!(!snapshot.shuffle_enabled);
    assert_eq!(snapshot.repeat_mode, RepeatMode::None);

    Ok(())
}

#[tokio::test]
async fn playback_snapshot_reflects_active_track() -> TestResult<()> {
    let (test_core, track) = core_with_one_track().await?;

    let started = test_core.core().play(track.id).await?;

    let observed = test_core.core().playback().await;

    assert_eq!(
        started.current_track.as_ref().map(|item| item.id),
        Some(track.id),
    );

    assert_eq!(
        observed.current_track.as_ref().map(|item| item.id),
        Some(track.id),
    );

    assert!(observed.is_playing);
    assert!(!observed.is_paused);

    assert_eq!(observed.queue.len(), 1);
    assert_eq!(observed.queue[0].track_id, track.id);
    assert_eq!(observed.queue[0].position, 0);
    assert_eq!(observed.queue_position, 0);
    assert_eq!(observed.queue, started.queue);

    assert_eq!(observed.volume, started.volume);
    assert_eq!(observed.shuffle_enabled, started.shuffle_enabled,);
    assert_eq!(observed.repeat_mode, started.repeat_mode,);

    Ok(())
}

#[tokio::test]
async fn playing_track_updates_last_session() -> TestResult<()> {
    let (test_core, track) = core_with_one_track().await?;

    test_core.core().play(track.id).await?;

    let session = test_core.core().last_session().await?;

    assert_eq!(session.current_track_id, Some(track.id),);

    assert_eq!(session.volume, 0.5);
    assert!(!session.shuffle_enabled);
    assert_eq!(session.repeat_mode, RepeatMode::None);

    Ok(())
}

#[tokio::test]
async fn play_rejects_negative_track_id() -> TestResult<()> {
    let test_core = TestCore::open().await?;

    let result = test_core.core().play(-1).await;

    assert!(matches!(result, Err(CoreError::InvalidInput { .. })));

    let playback = test_core.core().playback().await;

    assert!(playback.current_track.is_none());
    assert!(!playback.is_playing);
    assert!(playback.queue.is_empty());

    Ok(())
}

#[tokio::test]
async fn play_reports_missing_track_id() -> TestResult<()> {
    let test_core = TestCore::open().await?;

    let result = test_core.core().play(i64::MAX).await;

    assert!(matches!(result, Err(CoreError::NotFound { .. })));

    let playback = test_core.core().playback().await;

    assert!(playback.current_track.is_none());
    assert!(!playback.is_playing);
    assert!(playback.queue.is_empty());

    Ok(())
}

#[tokio::test]
async fn pause_preserves_active_track_and_updates_state() -> TestResult<()> {
    let (test_core, track) = core_with_one_track().await?;

    test_core.core().play(track.id).await?;
    test_core.process_mock_audio(1).await;

    test_core.core().pause().await?;
    test_core.process_mock_audio(1).await;

    let playback = test_core.core().playback().await;

    assert_eq!(
        playback.current_track.as_ref().map(|item| item.id),
        Some(track.id),
    );

    assert!(!playback.is_playing);
    assert!(playback.is_paused);
    assert_eq!(
        playback.current_track.as_ref().map(|item| item.id),
        Some(track.id),
    );
    assert_eq!(playback.queue.len(), 1);
    assert_eq!(playback.queue[0].track_id, track.id);
    assert_eq!(playback.queue[0].position, 0);
    assert_eq!(playback.queue_position, 0);

    let session = test_core.core().last_session().await?;

    assert_eq!(session.current_track_id, Some(track.id),);

    assert_eq!(session.queue, vec![track.id]);

    Ok(())
}

#[tokio::test]
async fn resume_continues_paused_track() -> TestResult<()> {
    let (test_core, track) = core_with_one_track().await?;

    test_core.core().play(track.id).await?;
    test_core.process_mock_audio(1).await;

    test_core.core().pause().await?;
    test_core.process_mock_audio(1).await;

    let paused = test_core.core().playback().await;
    assert!(paused.is_paused);
    assert!(!paused.is_playing);

    test_core.core().resume().await?;
    test_core.process_mock_audio(1).await;

    let resumed = test_core.core().playback().await;
    assert!(resumed.is_playing);
    assert!(!resumed.is_paused);
    assert_eq!(
        resumed.current_track.as_ref().map(|item| item.id),
        Some(track.id),
    );

    Ok(())
}
