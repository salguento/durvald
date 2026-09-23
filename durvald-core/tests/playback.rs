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

async fn core_with_tracks(count: usize) -> TestResult<(TestCore, Vec<Track>)> {
    let test_core = TestCore::open().await?;

    for index in 1..=count {
        let relative_path = format!("Artist/Album/{index:02}.wav");

        test_core.files().write_silent_wav(relative_path)?;
    }

    let library_path = test_core
        .files()
        .library_dir()
        .to_string_lossy()
        .into_owned();

    let scan = test_core.core().scan_library(vec![library_path]).await?;

    assert_eq!(scan.new_tracks_added, count as u64);
    assert!(scan.errors.is_empty());

    let mut tracks = test_core.core().tracks().await?;

    assert_eq!(tracks.len(), count);

    tracks.sort_by_key(|track| track.id);

    Ok((test_core, tracks))
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

#[tokio::test]
async fn stop_clears_active_playback_and_persists_session() -> TestResult<()> {
    let (test_core, track) = core_with_one_track().await?;

    test_core.core().play(track.id).await?;
    test_core.process_mock_audio(1).await;

    let playing = test_core.core().playback().await;

    assert_eq!(
        playing.current_track.as_ref().map(|item| item.id),
        Some(track.id),
    );
    assert!(playing.is_playing);

    test_core.core().stop().await?;
    test_core.process_mock_audio(1).await;

    let stopped = test_core.core().playback().await;

    assert!(stopped.current_track.is_none());
    assert!(!stopped.is_playing);
    assert!(!stopped.is_paused);
    assert_eq!(stopped.position_seconds, 0.0);
    assert!(stopped.duration_seconds.is_none());
    assert!(stopped.queue.is_empty());

    let session = test_core.core().last_session().await?;

    assert!(session.current_track_id.is_none());
    assert_eq!(session.progress_seconds, 0.0);
    assert!(session.queue.is_empty());

    Ok(())
}

#[tokio::test]
async fn seek_updates_position_without_resuming_paused_track() -> TestResult<()> {
    let (test_core, track) = core_with_one_track().await?;

    test_core.core().play(track.id).await?;
    test_core.process_mock_audio(1).await;

    test_core.core().pause().await?;
    test_core.process_mock_audio(1).await;

    test_core.core().seek(1).await?;

    let playback = test_core.core().playback().await;

    assert_eq!(
        playback.current_track.as_ref().map(|item| item.id),
        Some(track.id),
    );
    assert_eq!(playback.position_seconds, 1.0);
    assert!(!playback.is_playing);
    assert!(playback.is_paused);

    let session = test_core.core().last_session().await?;

    assert_eq!(session.current_track_id, Some(track.id));
    assert_eq!(session.progress_seconds, 1.0);

    Ok(())
}

#[tokio::test]
async fn seek_reports_when_no_track_is_loaded() -> TestResult<()> {
    let test_core = TestCore::open().await?;

    let result = test_core.core().seek(1).await;

    assert!(matches!(result, Err(CoreError::Playback { .. })));

    let playback = test_core.core().playback().await;

    assert!(playback.current_track.is_none());
    assert_eq!(playback.position_seconds, 0.0);
    assert!(!playback.is_playing);
    assert!(!playback.is_paused);

    Ok(())
}

#[tokio::test]
async fn set_volume_updates_playback_and_session() -> TestResult<()> {
    let test_core = TestCore::open().await?;

    test_core.core().set_volume(0.25).await?;

    let playback = test_core.core().playback().await;

    assert_eq!(playback.volume, 0.25);

    let session = test_core.core().last_session().await?;

    assert_eq!(session.volume, 0.25);

    Ok(())
}

#[tokio::test]
async fn set_volume_clamps_finite_values_to_supported_range() -> TestResult<()> {
    let test_core = TestCore::open().await?;

    test_core.core().set_volume(-0.5).await?;

    let minimum = test_core.core().playback().await;

    assert_eq!(minimum.volume, 0.0);

    test_core.core().set_volume(1.5).await?;

    let maximum = test_core.core().playback().await;

    assert_eq!(maximum.volume, 1.0);

    let session = test_core.core().last_session().await?;

    assert_eq!(session.volume, 1.0);

    Ok(())
}

#[tokio::test]
async fn set_volume_rejects_non_finite_values() -> TestResult<()> {
    let test_core = TestCore::open().await?;

    let initial = test_core.core().playback().await;

    for invalid_volume in [f32::NAN, f32::INFINITY, f32::NEG_INFINITY] {
        let result = test_core.core().set_volume(invalid_volume).await;

        assert!(matches!(result, Err(CoreError::InvalidInput { .. })));
    }

    let playback = test_core.core().playback().await;

    assert_eq!(playback.volume, initial.volume);

    let session = test_core.core().last_session().await?;

    assert_eq!(session.volume, initial.volume);

    Ok(())
}

#[tokio::test]
async fn add_to_queue_appends_track_after_active_track() -> TestResult<()> {
    let (test_core, tracks) = core_with_tracks(2).await?;

    let first = &tracks[0];
    let second = &tracks[1];

    test_core.core().play(first.id).await?;
    test_core.process_mock_audio(1).await;

    test_core.core().add_to_queue(second.id).await?;

    let playback = test_core.core().playback().await;

    assert_eq!(
        playback.current_track.as_ref().map(|item| item.id),
        Some(first.id),
    );

    assert_eq!(playback.queue.len(), 2);

    assert_eq!(playback.queue[0].track_id, first.id);
    assert_eq!(playback.queue[0].position, 0);

    assert_eq!(playback.queue[1].track_id, second.id);
    assert_eq!(playback.queue[1].position, 1);

    let queue = test_core.core().queue().await?;

    assert_eq!(queue, playback.queue);

    let session = test_core.core().last_session().await?;

    assert_eq!(session.current_track_id, Some(first.id));
    assert_eq!(session.queue, vec![first.id, second.id]);

    Ok(())
}

#[tokio::test]
async fn add_to_empty_queue_starts_added_track() -> TestResult<()> {
    let (test_core, track) = core_with_one_track().await?;

    test_core.core().add_to_queue(track.id).await?;
    test_core.process_mock_audio(1).await;

    let playback = test_core.core().playback().await;

    assert_eq!(
        playback.current_track.as_ref().map(|item| item.id),
        Some(track.id),
    );

    assert!(playback.is_playing);
    assert!(!playback.is_paused);

    assert_eq!(playback.queue.len(), 1);
    assert_eq!(playback.queue[0].track_id, track.id);
    assert_eq!(playback.queue[0].position, 0);

    let session = test_core.core().last_session().await?;

    assert_eq!(session.current_track_id, Some(track.id));
    assert_eq!(session.queue, vec![track.id]);

    Ok(())
}

#[tokio::test]
async fn next_track_advances_queue_and_persists_session() -> TestResult<()> {
    let (test_core, tracks) = core_with_tracks(3).await?;

    let first = &tracks[0];
    let second = &tracks[1];
    let third = &tracks[2];

    test_core.core().play(first.id).await?;
    test_core.process_mock_audio(1).await;

    test_core.core().add_to_queue(second.id).await?;
    test_core.core().add_to_queue(third.id).await?;

    let advanced = test_core.core().next_track().await?;
    test_core.process_mock_audio(1).await;

    assert_eq!(
        advanced.current_track.as_ref().map(|item| item.id),
        Some(second.id),
    );

    assert!(advanced.is_playing);
    assert!(!advanced.is_paused);

    assert_eq!(advanced.queue.len(), 2);

    assert_eq!(advanced.queue[0].track_id, second.id);
    assert_eq!(advanced.queue[0].position, 0);

    assert_eq!(advanced.queue[1].track_id, third.id);
    assert_eq!(advanced.queue[1].position, 1);

    let observed = test_core.core().playback().await;

    assert_eq!(
        observed.current_track.as_ref().map(|item| item.id),
        Some(second.id),
    );
    assert_eq!(observed.queue, advanced.queue);

    let session = test_core.core().last_session().await?;

    assert_eq!(session.current_track_id, Some(second.id));
    assert_eq!(session.queue, vec![second.id, third.id]);

    Ok(())
}

#[tokio::test]
async fn next_track_reports_when_queue_has_no_upcoming_track() -> TestResult<()> {
    let (test_core, track) = core_with_one_track().await?;

    test_core.core().play(track.id).await?;
    test_core.process_mock_audio(1).await;

    let result = test_core.core().next_track().await;

    assert!(matches!(result, Err(CoreError::NotFound { .. })));

    let playback = test_core.core().playback().await;

    assert_eq!(
        playback.current_track.as_ref().map(|item| item.id),
        Some(track.id),
    );

    assert!(playback.is_playing);
    assert_eq!(playback.queue.len(), 1);
    assert_eq!(playback.queue[0].track_id, track.id);

    let session = test_core.core().last_session().await?;

    assert_eq!(session.current_track_id, Some(track.id));
    assert_eq!(session.queue, vec![track.id]);

    Ok(())
}

#[tokio::test]
async fn previous_track_restores_navigation_history_and_queue() -> TestResult<()> {
    let (test_core, tracks) = core_with_tracks(3).await?;

    let first = &tracks[0];
    let second = &tracks[1];
    let third = &tracks[2];

    test_core.core().play(first.id).await?;
    test_core.process_mock_audio(1).await;

    test_core.core().add_to_queue(second.id).await?;
    test_core.core().add_to_queue(third.id).await?;

    test_core.core().next_track().await?;
    test_core.process_mock_audio(1).await;

    let before_previous = test_core.core().playback().await;

    assert_eq!(
        before_previous.current_track.as_ref().map(|item| item.id),
        Some(second.id),
    );
    assert_eq!(before_previous.queue.len(), 2);
    assert_eq!(before_previous.queue[0].track_id, second.id);
    assert_eq!(before_previous.queue[1].track_id, third.id);

    let returned = test_core.core().previous_track().await?;
    test_core.process_mock_audio(1).await;

    assert_eq!(
        returned.current_track.as_ref().map(|item| item.id),
        Some(first.id),
    );

    assert!(returned.is_playing);
    assert!(!returned.is_paused);

    assert_eq!(returned.queue.len(), 3);

    assert_eq!(returned.queue[0].track_id, first.id);
    assert_eq!(returned.queue[0].position, 0);

    assert_eq!(returned.queue[1].track_id, second.id);
    assert_eq!(returned.queue[1].position, 1);

    assert_eq!(returned.queue[2].track_id, third.id);
    assert_eq!(returned.queue[2].position, 2);

    let observed = test_core.core().playback().await;

    assert_eq!(
        observed.current_track.as_ref().map(|item| item.id),
        Some(first.id),
    );
    assert_eq!(observed.queue, returned.queue);

    let session = test_core.core().last_session().await?;

    assert_eq!(session.current_track_id, Some(first.id));
    assert_eq!(session.queue, vec![first.id, second.id, third.id]);

    Ok(())
}

#[tokio::test]
async fn previous_track_reports_when_navigation_history_is_empty() -> TestResult<()> {
    let (test_core, tracks) = core_with_tracks(2).await?;

    let first = &tracks[0];
    let second = &tracks[1];

    test_core.core().play(first.id).await?;
    test_core.process_mock_audio(1).await;

    test_core.core().add_to_queue(second.id).await?;

    let result = test_core.core().previous_track().await;

    assert!(matches!(result, Err(CoreError::NotFound { .. })));

    let playback = test_core.core().playback().await;

    assert_eq!(
        playback.current_track.as_ref().map(|item| item.id),
        Some(first.id),
    );

    assert!(playback.is_playing);

    assert_eq!(playback.queue.len(), 2);
    assert_eq!(playback.queue[0].track_id, first.id);
    assert_eq!(playback.queue[1].track_id, second.id);

    let session = test_core.core().last_session().await?;

    assert_eq!(session.current_track_id, Some(first.id));
    assert_eq!(session.queue, vec![first.id, second.id]);

    Ok(())
}

#[tokio::test]
async fn play_queue_item_starts_track_at_public_queue_position() -> TestResult<()> {
    let (test_core, tracks) = core_with_tracks(3).await?;

    let first = &tracks[0];
    let second = &tracks[1];
    let third = &tracks[2];

    test_core.core().play(first.id).await?;
    test_core.process_mock_audio(1).await;

    test_core.core().add_to_queue(second.id).await?;
    test_core.core().add_to_queue(third.id).await?;

    let selected = test_core.core().play_queue_item(2).await?;
    test_core.process_mock_audio(1).await;

    assert_eq!(
        selected.current_track.as_ref().map(|item| item.id),
        Some(third.id),
    );

    assert!(selected.is_playing);
    assert!(!selected.is_paused);

    assert_eq!(selected.queue.len(), 1);
    assert_eq!(selected.queue[0].track_id, third.id);
    assert_eq!(selected.queue[0].position, 0);

    let observed = test_core.core().playback().await;

    assert_eq!(
        observed.current_track.as_ref().map(|item| item.id),
        Some(third.id),
    );
    assert_eq!(observed.queue, selected.queue);

    let session = test_core.core().last_session().await?;

    assert_eq!(session.current_track_id, Some(third.id));
    assert_eq!(session.queue, vec![third.id]);

    Ok(())
}

#[tokio::test]
async fn play_queue_item_rejects_active_and_out_of_bounds_positions() -> TestResult<()> {
    let (test_core, tracks) = core_with_tracks(3).await?;

    let first = &tracks[0];
    let second = &tracks[1];
    let third = &tracks[2];

    test_core.core().play(first.id).await?;
    test_core.process_mock_audio(1).await;

    test_core.core().add_to_queue(second.id).await?;
    test_core.core().add_to_queue(third.id).await?;

    for invalid_position in [0, 3] {
        let result = test_core.core().play_queue_item(invalid_position).await;

        assert!(matches!(result, Err(CoreError::InvalidInput { .. })));
    }

    let playback = test_core.core().playback().await;

    assert_eq!(
        playback.current_track.as_ref().map(|item| item.id),
        Some(first.id),
    );

    assert!(playback.is_playing);

    assert_eq!(playback.queue.len(), 3);
    assert_eq!(playback.queue[0].track_id, first.id);
    assert_eq!(playback.queue[1].track_id, second.id);
    assert_eq!(playback.queue[2].track_id, third.id);

    let session = test_core.core().last_session().await?;

    assert_eq!(session.current_track_id, Some(first.id));
    assert_eq!(session.queue, vec![first.id, second.id, third.id]);

    Ok(())
}

#[tokio::test]
async fn remove_from_queue_removes_future_track_and_reindexes_queue() -> TestResult<()> {
    let (test_core, tracks) = core_with_tracks(4).await?;

    let first = &tracks[0];
    let second = &tracks[1];
    let third = &tracks[2];
    let fourth = &tracks[3];

    test_core.core().play(first.id).await?;
    test_core.process_mock_audio(1).await;

    test_core.core().add_to_queue(second.id).await?;
    test_core.core().add_to_queue(third.id).await?;
    test_core.core().add_to_queue(fourth.id).await?;

    test_core.core().remove_from_queue(2).await?;

    let playback = test_core.core().playback().await;

    assert_eq!(
        playback.current_track.as_ref().map(|item| item.id),
        Some(first.id),
    );

    assert!(playback.is_playing);

    assert_eq!(playback.queue.len(), 3);

    assert_eq!(playback.queue[0].track_id, first.id);
    assert_eq!(playback.queue[0].position, 0);

    assert_eq!(playback.queue[1].track_id, second.id);
    assert_eq!(playback.queue[1].position, 1);

    assert_eq!(playback.queue[2].track_id, fourth.id);
    assert_eq!(playback.queue[2].position, 2);

    assert!(playback.queue.iter().all(|item| item.track_id != third.id));

    let session = test_core.core().last_session().await?;

    assert_eq!(session.current_track_id, Some(first.id));
    assert_eq!(session.queue, vec![first.id, second.id, fourth.id]);

    Ok(())
}

#[tokio::test]
async fn remove_from_queue_rejects_active_track_position() -> TestResult<()> {
    let (test_core, tracks) = core_with_tracks(2).await?;

    let first = &tracks[0];
    let second = &tracks[1];

    test_core.core().play(first.id).await?;
    test_core.process_mock_audio(1).await;

    test_core.core().add_to_queue(second.id).await?;

    let result = test_core.core().remove_from_queue(0).await;

    assert!(matches!(result, Err(CoreError::InvalidInput { .. })));

    let playback = test_core.core().playback().await;

    assert_eq!(
        playback.current_track.as_ref().map(|item| item.id),
        Some(first.id),
    );

    assert!(playback.is_playing);

    assert_eq!(playback.queue.len(), 2);
    assert_eq!(playback.queue[0].track_id, first.id);
    assert_eq!(playback.queue[1].track_id, second.id);

    let session = test_core.core().last_session().await?;

    assert_eq!(session.current_track_id, Some(first.id));
    assert_eq!(session.queue, vec![first.id, second.id]);

    Ok(())
}

#[tokio::test]
async fn remove_from_queue_rejects_out_of_bounds_position() -> TestResult<()> {
    let (test_core, tracks) = core_with_tracks(2).await?;

    let first = &tracks[0];
    let second = &tracks[1];

    test_core.core().play(first.id).await?;
    test_core.process_mock_audio(1).await;

    test_core.core().add_to_queue(second.id).await?;

    let result = test_core.core().remove_from_queue(2).await;

    assert!(matches!(result, Err(CoreError::InvalidInput { .. })));

    let playback = test_core.core().playback().await;

    assert_eq!(
        playback.current_track.as_ref().map(|item| item.id),
        Some(first.id),
    );

    assert_eq!(playback.queue.len(), 2);
    assert_eq!(playback.queue[0].track_id, first.id);
    assert_eq!(playback.queue[1].track_id, second.id);

    Ok(())
}

#[tokio::test]
async fn move_queue_item_reorders_future_tracks_and_persists_queue() -> TestResult<()> {
    let (test_core, tracks) = core_with_tracks(4).await?;

    let first = &tracks[0];
    let second = &tracks[1];
    let third = &tracks[2];
    let fourth = &tracks[3];

    test_core.core().play(first.id).await?;
    test_core.process_mock_audio(1).await;

    test_core.core().add_to_queue(second.id).await?;
    test_core.core().add_to_queue(third.id).await?;
    test_core.core().add_to_queue(fourth.id).await?;

    test_core.core().move_queue_item(3, 1).await?;

    let playback = test_core.core().playback().await;

    assert_eq!(
        playback.current_track.as_ref().map(|item| item.id),
        Some(first.id),
    );

    assert!(playback.is_playing);

    assert_eq!(playback.queue.len(), 4);

    assert_eq!(playback.queue[0].track_id, first.id);
    assert_eq!(playback.queue[0].position, 0);

    assert_eq!(playback.queue[1].track_id, fourth.id);
    assert_eq!(playback.queue[1].position, 1);

    assert_eq!(playback.queue[2].track_id, second.id);
    assert_eq!(playback.queue[2].position, 2);

    assert_eq!(playback.queue[3].track_id, third.id);
    assert_eq!(playback.queue[3].position, 3);

    let session = test_core.core().last_session().await?;

    assert_eq!(session.current_track_id, Some(first.id));
    assert_eq!(
        session.queue,
        vec![first.id, fourth.id, second.id, third.id],
    );

    Ok(())
}

#[tokio::test]
async fn move_queue_item_rejects_active_and_out_of_bounds_positions() -> TestResult<()> {
    let (test_core, tracks) = core_with_tracks(4).await?;

    let first = &tracks[0];
    let second = &tracks[1];
    let third = &tracks[2];
    let fourth = &tracks[3];

    test_core.core().play(first.id).await?;
    test_core.process_mock_audio(1).await;

    test_core.core().add_to_queue(second.id).await?;
    test_core.core().add_to_queue(third.id).await?;
    test_core.core().add_to_queue(fourth.id).await?;

    for (from, to) in [(0, 1), (1, 0), (4, 1), (1, 4)] {
        let result = test_core.core().move_queue_item(from, to).await;

        assert!(matches!(result, Err(CoreError::InvalidInput { .. })));
    }

    let playback = test_core.core().playback().await;

    assert_eq!(
        playback.current_track.as_ref().map(|item| item.id),
        Some(first.id),
    );

    assert!(playback.is_playing);

    assert_eq!(playback.queue.len(), 4);
    assert_eq!(playback.queue[0].track_id, first.id);
    assert_eq!(playback.queue[1].track_id, second.id);
    assert_eq!(playback.queue[2].track_id, third.id);
    assert_eq!(playback.queue[3].track_id, fourth.id);

    let session = test_core.core().last_session().await?;

    assert_eq!(
        session.queue,
        vec![first.id, second.id, third.id, fourth.id],
    );

    Ok(())
}

#[tokio::test]
async fn clear_queue_removes_future_tracks_but_preserves_active_track() -> TestResult<()> {
    let (test_core, tracks) = core_with_tracks(3).await?;

    let first = &tracks[0];
    let second = &tracks[1];
    let third = &tracks[2];

    test_core.core().play(first.id).await?;
    test_core.process_mock_audio(1).await;

    test_core.core().add_to_queue(second.id).await?;
    test_core.core().add_to_queue(third.id).await?;

    let before_clear = test_core.core().playback().await;

    assert_eq!(before_clear.queue.len(), 3);
    assert_eq!(before_clear.queue[0].track_id, first.id);
    assert_eq!(before_clear.queue[1].track_id, second.id);
    assert_eq!(before_clear.queue[2].track_id, third.id);

    test_core.core().clear_queue().await?;

    let cleared = test_core.core().playback().await;

    assert_eq!(
        cleared.current_track.as_ref().map(|item| item.id),
        Some(first.id),
    );

    assert!(cleared.is_playing);
    assert!(!cleared.is_paused);

    assert_eq!(cleared.queue.len(), 1);
    assert_eq!(cleared.queue[0].track_id, first.id);
    assert_eq!(cleared.queue[0].position, 0);

    let queue = test_core.core().queue().await?;

    assert_eq!(queue, cleared.queue);

    let session = test_core.core().last_session().await?;

    assert_eq!(session.current_track_id, Some(first.id));
    assert_eq!(session.queue, vec![first.id]);

    Ok(())
}

#[tokio::test]
async fn clear_queue_is_idempotent_when_no_future_tracks_exist() -> TestResult<()> {
    let (test_core, track) = core_with_one_track().await?;

    test_core.core().play(track.id).await?;
    test_core.process_mock_audio(1).await;

    test_core.core().clear_queue().await?;
    test_core.core().clear_queue().await?;

    let playback = test_core.core().playback().await;

    assert_eq!(
        playback.current_track.as_ref().map(|item| item.id),
        Some(track.id),
    );

    assert!(playback.is_playing);
    assert_eq!(playback.queue.len(), 1);
    assert_eq!(playback.queue[0].track_id, track.id);

    let session = test_core.core().last_session().await?;

    assert_eq!(session.current_track_id, Some(track.id));
    assert_eq!(session.queue, vec![track.id]);

    Ok(())
}

#[tokio::test]
async fn set_shuffle_enabled_updates_snapshot_without_reordering_queue() -> TestResult<()> {
    let (test_core, tracks) = core_with_tracks(3).await?;

    let first = &tracks[0];
    let second = &tracks[1];
    let third = &tracks[2];

    test_core.core().play(first.id).await?;
    test_core.process_mock_audio(1).await;

    test_core.core().add_to_queue(second.id).await?;
    test_core.core().add_to_queue(third.id).await?;

    let before_shuffle = test_core.core().playback().await;

    assert!(!before_shuffle.shuffle_enabled);

    let enabled = test_core.core().set_shuffle_enabled(true).await?;

    assert!(enabled.shuffle_enabled);

    assert_eq!(
        enabled.current_track.as_ref().map(|item| item.id),
        Some(first.id),
    );

    assert!(enabled.is_playing);
    assert_eq!(enabled.queue, before_shuffle.queue);

    let observed_enabled = test_core.core().playback().await;

    assert!(observed_enabled.shuffle_enabled);
    assert_eq!(observed_enabled.queue, before_shuffle.queue);

    let enabled_session = test_core.core().last_session().await?;

    assert!(enabled_session.shuffle_enabled);
    assert_eq!(enabled_session.queue, vec![first.id, second.id, third.id],);

    let disabled = test_core.core().set_shuffle_enabled(false).await?;

    assert!(!disabled.shuffle_enabled);

    assert_eq!(
        disabled.current_track.as_ref().map(|item| item.id),
        Some(first.id),
    );

    assert!(disabled.is_playing);
    assert_eq!(disabled.queue, before_shuffle.queue);

    let disabled_session = test_core.core().last_session().await?;

    assert!(!disabled_session.shuffle_enabled);
    assert_eq!(disabled_session.queue, vec![first.id, second.id, third.id],);

    Ok(())
}

#[tokio::test]
async fn set_repeat_mode_updates_snapshot_and_persisted_session() -> TestResult<()> {
    let (test_core, tracks) = core_with_tracks(3).await?;

    let first = &tracks[0];
    let second = &tracks[1];
    let third = &tracks[2];

    test_core.core().play(first.id).await?;
    test_core.process_mock_audio(1).await;

    test_core.core().add_to_queue(second.id).await?;
    test_core.core().add_to_queue(third.id).await?;

    let initial = test_core.core().playback().await;

    assert_eq!(initial.repeat_mode, RepeatMode::None);

    let expected_queue = initial.queue.clone();
    let expected_ids = vec![first.id, second.id, third.id];

    for mode in [RepeatMode::One, RepeatMode::All, RepeatMode::None] {
        let returned = test_core.core().set_repeat_mode(mode).await?;

        assert_eq!(returned.repeat_mode, mode);

        assert_eq!(
            returned.current_track.as_ref().map(|item| item.id),
            Some(first.id),
        );

        assert!(returned.is_playing);
        assert_eq!(returned.queue, expected_queue);

        let observed = test_core.core().playback().await;

        assert_eq!(observed.repeat_mode, mode);

        assert_eq!(
            observed.current_track.as_ref().map(|item| item.id),
            Some(first.id),
        );

        assert_eq!(observed.queue, expected_queue);

        let session = test_core.core().last_session().await?;

        assert_eq!(session.repeat_mode, mode);
        assert_eq!(session.current_track_id, Some(first.id));
        assert_eq!(session.queue, expected_ids);
    }

    Ok(())
}

#[tokio::test]
async fn next_track_with_shuffle_consumes_exactly_one_future_track() -> TestResult<()> {
    let (test_core, tracks) = core_with_tracks(4).await?;

    let first = &tracks[0];
    let second = &tracks[1];
    let third = &tracks[2];
    let fourth = &tracks[3];

    test_core.core().play(first.id).await?;
    test_core.process_mock_audio(1).await;

    test_core.core().add_to_queue(second.id).await?;
    test_core.core().add_to_queue(third.id).await?;
    test_core.core().add_to_queue(fourth.id).await?;

    test_core.core().set_shuffle_enabled(true).await?;

    let advanced = test_core.core().next_track().await?;
    test_core.process_mock_audio(1).await;

    assert!(advanced.shuffle_enabled);
    assert!(advanced.is_playing);
    assert!(!advanced.is_paused);

    let selected_id = advanced
        .current_track
        .as_ref()
        .map(|item| item.id)
        .expect("shuffle navigation must select a current track");

    let future_ids = vec![second.id, third.id, fourth.id];

    assert!(future_ids.contains(&selected_id));

    assert_eq!(advanced.queue.len(), 3);
    assert_eq!(advanced.queue[0].track_id, selected_id);
    assert_eq!(advanced.queue[0].position, 0);

    let remaining_ids: Vec<i64> = advanced
        .queue
        .iter()
        .skip(1)
        .map(|item| item.track_id)
        .collect();

    assert_eq!(remaining_ids.len(), 2);
    assert!(!remaining_ids.contains(&selected_id));
    assert!(!remaining_ids.contains(&first.id));

    let mut accounted_for = vec![selected_id];
    accounted_for.extend(remaining_ids.iter().copied());
    accounted_for.sort_unstable();

    let mut expected_future_ids = future_ids;
    expected_future_ids.sort_unstable();

    assert_eq!(accounted_for, expected_future_ids);

    let observed = test_core.core().playback().await;

    assert_eq!(
        observed.current_track.as_ref().map(|item| item.id),
        Some(selected_id),
    );
    assert_eq!(observed.queue, advanced.queue);
    assert!(observed.shuffle_enabled);

    let session = test_core.core().last_session().await?;

    let persisted_ids: Vec<i64> = advanced.queue.iter().map(|item| item.track_id).collect();

    assert_eq!(session.current_track_id, Some(selected_id));
    assert_eq!(session.queue, persisted_ids);
    assert!(session.shuffle_enabled);

    Ok(())
}

#[tokio::test]
async fn next_track_with_repeat_one_restarts_active_track() -> TestResult<()> {
    let (test_core, tracks) = core_with_tracks(3).await?;

    let first = &tracks[0];
    let second = &tracks[1];
    let third = &tracks[2];

    test_core.core().play(first.id).await?;
    test_core.process_mock_audio(1).await;

    test_core.core().add_to_queue(second.id).await?;
    test_core.core().add_to_queue(third.id).await?;

    let configured = test_core.core().set_repeat_mode(RepeatMode::One).await?;

    let expected_queue = configured.queue.clone();

    let repeated = test_core.core().next_track().await?;

    assert_eq!(
        repeated.current_track.as_ref().map(|item| item.id),
        Some(first.id),
    );

    assert!(repeated.is_playing);
    assert!(!repeated.is_paused);
    assert_eq!(repeated.repeat_mode, RepeatMode::One);
    assert_eq!(repeated.position_seconds, 0.0);

    assert_eq!(repeated.queue, expected_queue);
    assert_eq!(repeated.queue.len(), 3);

    assert_eq!(repeated.queue[0].track_id, first.id);
    assert_eq!(repeated.queue[1].track_id, second.id);
    assert_eq!(repeated.queue[2].track_id, third.id);

    test_core.process_mock_audio(1).await;

    let observed = test_core.core().playback().await;

    assert_eq!(
        observed.current_track.as_ref().map(|item| item.id),
        Some(first.id),
    );
    assert_eq!(observed.repeat_mode, RepeatMode::One);
    assert_eq!(observed.queue, expected_queue);

    let session = test_core.core().last_session().await?;

    assert_eq!(session.current_track_id, Some(first.id));
    assert_eq!(session.progress_seconds, 0.0);
    assert_eq!(session.repeat_mode, RepeatMode::One);
    assert_eq!(session.queue, vec![first.id, second.id, third.id]);

    let previous_result = test_core.core().previous_track().await;

    assert!(matches!(previous_result, Err(CoreError::NotFound { .. })));

    Ok(())
}

#[tokio::test]
async fn next_track_with_repeat_all_restarts_complete_queue_cycle() -> TestResult<()> {
    let (test_core, tracks) = core_with_tracks(3).await?;

    let first = &tracks[0];
    let second = &tracks[1];
    let third = &tracks[2];

    test_core.core().play(first.id).await?;
    test_core.process_mock_audio(1).await;

    test_core.core().add_to_queue(second.id).await?;
    test_core.core().add_to_queue(third.id).await?;

    test_core.core().set_repeat_mode(RepeatMode::All).await?;

    let second_active = test_core.core().next_track().await?;
    test_core.process_mock_audio(1).await;

    assert_eq!(
        second_active.current_track.as_ref().map(|item| item.id),
        Some(second.id),
    );

    assert_eq!(second_active.repeat_mode, RepeatMode::All);
    assert_eq!(second_active.queue.len(), 2);
    assert_eq!(second_active.queue[0].track_id, second.id);
    assert_eq!(second_active.queue[1].track_id, third.id);

    let third_active = test_core.core().next_track().await?;
    test_core.process_mock_audio(1).await;

    assert_eq!(
        third_active.current_track.as_ref().map(|item| item.id),
        Some(third.id),
    );

    assert_eq!(third_active.repeat_mode, RepeatMode::All);
    assert_eq!(third_active.queue.len(), 1);
    assert_eq!(third_active.queue[0].track_id, third.id);

    let restarted = test_core.core().next_track().await?;

    assert_eq!(
        restarted.current_track.as_ref().map(|item| item.id),
        Some(first.id),
    );

    assert!(restarted.is_playing);
    assert!(!restarted.is_paused);
    assert_eq!(restarted.repeat_mode, RepeatMode::All);
    assert_eq!(restarted.position_seconds, 0.0);

    assert_eq!(restarted.queue.len(), 3);

    assert_eq!(restarted.queue[0].track_id, first.id);
    assert_eq!(restarted.queue[0].position, 0);

    assert_eq!(restarted.queue[1].track_id, second.id);
    assert_eq!(restarted.queue[1].position, 1);

    assert_eq!(restarted.queue[2].track_id, third.id);
    assert_eq!(restarted.queue[2].position, 2);

    test_core.process_mock_audio(1).await;

    let observed = test_core.core().playback().await;

    assert_eq!(
        observed.current_track.as_ref().map(|item| item.id),
        Some(first.id),
    );
    assert_eq!(observed.repeat_mode, RepeatMode::All);
    assert_eq!(observed.queue, restarted.queue);

    let session = test_core.core().last_session().await?;

    assert_eq!(session.current_track_id, Some(first.id));
    assert_eq!(session.repeat_mode, RepeatMode::All);
    assert_eq!(session.queue, vec![first.id, second.id, third.id]);

    Ok(())
}
