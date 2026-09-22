#![cfg(feature = "test-support")]

mod common;

use std::error::Error;
use std::path::Path;

use common::TestCore;
use durvald_core::CoreError;

#[tokio::test]
async fn scans_one_valid_audio_file() -> Result<(), Box<dyn Error + Send + Sync>> {
    let test_core = TestCore::open().await?;

    let audio_path = test_core
        .files()
        .write_silent_wav("Artist/Album/01 - Test.wav")?;

    let library_path = test_core
        .files()
        .library_dir()
        .to_string_lossy()
        .into_owned();

    let result = test_core.core().scan_library(vec![library_path]).await?;

    assert_eq!(result.paths_scanned, 1);
    assert_eq!(result.total_files_found, 1);
    assert_eq!(result.new_tracks_added, 1);
    assert_eq!(result.updated_tracks, 0);
    assert!(result.errors.is_empty());

    let tracks = test_core.core().tracks().await?;

    assert_eq!(tracks.len(), 1);
    assert!(tracks[0].id > 0);

    let indexed_path = std::fs::canonicalize(Path::new(&tracks[0].file_path))?;
    let fixture_path = std::fs::canonicalize(&audio_path)?;

    assert_eq!(indexed_path, fixture_path);

    Ok(())
}

#[tokio::test]
async fn configured_library_path_survives_restart() -> Result<(), Box<dyn Error + Send + Sync>> {
    let test_core = TestCore::open().await?;

    let library_path = test_core
        .files()
        .library_dir()
        .to_string_lossy()
        .into_owned();

    test_core
        .core()
        .add_library_path(library_path.clone())
        .await?;

    let configured = test_core.core().library_paths().await?;

    assert_eq!(configured, vec![library_path.clone()]);

    let test_core = test_core.restart().await?;

    let restored = test_core.core().library_paths().await?;

    assert_eq!(restored, vec![library_path]);

    Ok(())
}

#[tokio::test]
async fn scans_configured_library_path() -> Result<(), Box<dyn Error + Send + Sync>> {
    let test_core = TestCore::open().await?;

    let audio_path = test_core
        .files()
        .write_silent_wav("Artist/Album/01 - Configured.wav")?;

    let library_path = test_core
        .files()
        .library_dir()
        .to_string_lossy()
        .into_owned();

    test_core.core().add_library_path(library_path).await?;

    let result = test_core.core().scan_configured_library().await?;

    assert_eq!(result.paths_scanned, 1);
    assert_eq!(result.total_files_found, 1);
    assert_eq!(result.new_tracks_added, 1);
    assert!(result.errors.is_empty());

    let tracks = test_core.core().tracks().await?;

    assert_eq!(tracks.len(), 1);

    let indexed_path = std::fs::canonicalize(Path::new(&tracks[0].file_path))?;

    let expected_path = std::fs::canonicalize(audio_path)?;

    assert_eq!(indexed_path, expected_path);

    Ok(())
}

#[tokio::test]
async fn configured_scan_requires_at_least_one_path() -> Result<(), Box<dyn Error + Send + Sync>> {
    let test_core = TestCore::open().await?;

    let result = test_core.core().scan_configured_library().await;

    assert!(matches!(result, Err(CoreError::InvalidInput { .. })));

    Ok(())
}

#[tokio::test]
async fn rejects_missing_library_path() -> Result<(), Box<dyn Error + Send + Sync>> {
    let test_core = TestCore::open().await?;

    let missing_path = test_core
        .files()
        .root()
        .join("does-not-exist")
        .to_string_lossy()
        .into_owned();

    let result = test_core.core().add_library_path(missing_path).await;

    assert!(matches!(result, Err(CoreError::InvalidInput { .. })));

    assert!(test_core.core().library_paths().await?.is_empty());

    Ok(())
}

#[tokio::test]
async fn rejects_file_as_library_path() -> Result<(), Box<dyn Error + Send + Sync>> {
    let test_core = TestCore::open().await?;

    let file_path = test_core
        .files()
        .write_library_file("not-a-directory.txt", b"file")?;

    let result = test_core
        .core()
        .add_library_path(file_path.to_string_lossy().into_owned())
        .await;

    assert!(matches!(result, Err(CoreError::InvalidInput { .. })));

    assert!(test_core.core().library_paths().await?.is_empty());

    Ok(())
}

#[tokio::test]
async fn removes_configured_library_path() -> Result<(), Box<dyn Error + Send + Sync>> {
    let test_core = TestCore::open().await?;

    let library_path = test_core
        .files()
        .library_dir()
        .to_string_lossy()
        .into_owned();

    test_core
        .core()
        .add_library_path(library_path.clone())
        .await?;

    assert_eq!(
        test_core.core().library_paths().await?,
        vec![library_path.clone()],
    );

    test_core
        .core()
        .remove_library_path(library_path.clone())
        .await?;

    assert!(test_core.core().library_paths().await?.is_empty());

    let second_removal = test_core.core().remove_library_path(library_path).await;

    assert!(matches!(second_removal, Err(CoreError::NotFound { .. })));

    Ok(())
}

#[tokio::test]
async fn paginates_tracks_with_stable_offsets() -> Result<(), Box<dyn Error + Send + Sync>> {
    let test_core = TestCore::open().await?;

    test_core.files().write_silent_wav("Artist/Album/01.wav")?;

    test_core.files().write_silent_wav("Artist/Album/02.wav")?;

    test_core.files().write_silent_wav("Artist/Album/03.wav")?;

    let library_path = test_core
        .files()
        .library_dir()
        .to_string_lossy()
        .into_owned();

    let scan = test_core.core().scan_library(vec![library_path]).await?;

    assert_eq!(scan.total_files_found, 3);
    assert_eq!(scan.new_tracks_added, 3);
    assert!(scan.errors.is_empty());

    let first_page = test_core.core().tracks_page(2, 0).await?;

    assert_eq!(first_page.items.len(), 2);
    assert_eq!(first_page.next_offset, Some(2));

    let next_offset = first_page
        .next_offset
        .expect("first page must report another page");

    let second_page = test_core.core().tracks_page(2, next_offset).await?;

    assert_eq!(second_page.items.len(), 1);
    assert_eq!(second_page.next_offset, None);

    let first_ids: Vec<i64> = first_page.items.iter().map(|track| track.id).collect();

    let second_ids: Vec<i64> = second_page.items.iter().map(|track| track.id).collect();

    assert_eq!(first_ids.len(), 2);
    assert_eq!(second_ids.len(), 1);

    assert!(!first_ids.contains(&second_ids[0]));

    let all_tracks = test_core.core().tracks().await?;

    let all_ids: Vec<i64> = all_tracks.iter().map(|track| track.id).collect();

    let paginated_ids: Vec<i64> = first_page
        .items
        .iter()
        .chain(second_page.items.iter())
        .map(|track| track.id)
        .collect();

    assert_eq!(paginated_ids, all_ids);

    Ok(())
}

#[tokio::test]
async fn rejects_zero_track_page_size() -> Result<(), Box<dyn Error + Send + Sync>> {
    let test_core = TestCore::open().await?;

    let result = test_core.core().tracks_page(0, 0).await;

    assert!(matches!(result, Err(CoreError::InvalidInput { .. })));

    Ok(())
}

#[tokio::test]
async fn rejects_track_page_offset_above_sqlite_limit() -> Result<(), Box<dyn Error + Send + Sync>>
{
    let test_core = TestCore::open().await?;

    let invalid_offset = i64::MAX as u64 + 1;

    let result = test_core.core().tracks_page(10, invalid_offset).await;

    assert!(matches!(result, Err(CoreError::InvalidInput { .. })));

    Ok(())
}

#[tokio::test]
async fn finds_scanned_track_by_id() -> Result<(), Box<dyn Error + Send + Sync>> {
    let test_core = TestCore::open().await?;

    let audio_path = test_core
        .files()
        .write_silent_wav("Artist/Album/lookup.wav")?;

    let library_path = test_core
        .files()
        .library_dir()
        .to_string_lossy()
        .into_owned();

    let scan = test_core.core().scan_library(vec![library_path]).await?;

    assert_eq!(scan.new_tracks_added, 1);
    assert!(scan.errors.is_empty());

    let tracks = test_core.core().tracks().await?;

    assert_eq!(tracks.len(), 1);

    let listed_track = &tracks[0];

    let found = test_core.core().track(listed_track.id).await?;

    assert_eq!(found.id, listed_track.id);
    assert_eq!(found.title, listed_track.title);
    assert_eq!(found.artist, listed_track.artist);
    assert_eq!(found.release, listed_track.release);

    let found_path = std::fs::canonicalize(Path::new(&found.file_path))?;

    let expected_path = std::fs::canonicalize(audio_path)?;

    assert_eq!(found_path, expected_path);

    Ok(())
}

#[tokio::test]
async fn finds_scanned_track_after_restart() -> Result<(), Box<dyn Error + Send + Sync>> {
    let test_core = TestCore::open().await?;

    test_core
        .files()
        .write_silent_wav("Artist/Album/persisted.wav")?;

    let library_path = test_core
        .files()
        .library_dir()
        .to_string_lossy()
        .into_owned();

    test_core.core().scan_library(vec![library_path]).await?;

    let tracks = test_core.core().tracks().await?;

    assert_eq!(tracks.len(), 1);

    let track_id = tracks[0].id;

    let test_core = test_core.restart().await?;

    let restored = test_core.core().track(track_id).await?;

    assert_eq!(restored.id, track_id);

    Ok(())
}

#[tokio::test]
async fn rejects_negative_track_id() -> Result<(), Box<dyn Error + Send + Sync>> {
    let test_core = TestCore::open().await?;

    let result = test_core.core().track(-1).await;

    assert!(matches!(result, Err(CoreError::InvalidInput { .. })));

    Ok(())
}

#[tokio::test]
async fn reports_missing_track_id() -> Result<(), Box<dyn Error + Send + Sync>> {
    let test_core = TestCore::open().await?;

    let result = test_core.core().track(i64::MAX).await;

    assert!(matches!(result, Err(CoreError::NotFound { .. })));

    Ok(())
}

#[tokio::test]
async fn rescan_does_not_duplicate_unchanged_track() -> Result<(), Box<dyn Error + Send + Sync>> {
    let test_core = TestCore::open().await?;

    test_core
        .files()
        .write_silent_wav("Artist/Album/unchanged.wav")?;

    let library_path = test_core
        .files()
        .library_dir()
        .to_string_lossy()
        .into_owned();

    let first_scan = test_core
        .core()
        .scan_library(vec![library_path.clone()])
        .await?;

    assert_eq!(first_scan.new_tracks_added, 1);
    assert!(first_scan.errors.is_empty());

    let first_tracks = test_core.core().tracks().await?;

    assert_eq!(first_tracks.len(), 1);

    let original_id = first_tracks[0].id;

    let second_scan = test_core.core().scan_library(vec![library_path]).await?;

    assert_eq!(second_scan.total_files_found, 1);
    assert_eq!(second_scan.new_tracks_added, 0);
    assert_eq!(second_scan.updated_tracks, 0);
    assert!(second_scan.errors.is_empty());

    let second_tracks = test_core.core().tracks().await?;

    assert_eq!(second_tracks.len(), 1);
    assert_eq!(second_tracks[0].id, original_id);

    Ok(())
}

#[tokio::test]
async fn complete_rescan_removes_missing_track() -> Result<(), Box<dyn Error + Send + Sync>> {
    let test_core = TestCore::open().await?;

    let kept_path = test_core
        .files()
        .write_silent_wav("Artist/Album/01-kept.wav")?;

    test_core
        .files()
        .write_silent_wav("Artist/Album/02-removed.wav")?;

    let library_path = test_core
        .files()
        .library_dir()
        .to_string_lossy()
        .into_owned();

    let first_scan = test_core
        .core()
        .scan_library(vec![library_path.clone()])
        .await?;

    assert_eq!(first_scan.new_tracks_added, 2);
    assert!(first_scan.errors.is_empty());

    let initial_tracks = test_core.core().tracks().await?;

    assert_eq!(initial_tracks.len(), 2);

    let removed_track = initial_tracks
        .iter()
        .find(|track| track.file_path.ends_with("02-removed.wav"))
        .expect("removed fixture must be indexed");

    let removed_track_id = removed_track.id;

    test_core
        .files()
        .remove_library_file("Artist/Album/02-removed.wav")?;

    let second_scan = test_core.core().scan_library(vec![library_path]).await?;

    assert_eq!(second_scan.total_files_found, 1);
    assert_eq!(second_scan.new_tracks_added, 0);
    assert!(second_scan.errors.is_empty());

    let remaining_tracks = test_core.core().tracks().await?;

    assert_eq!(remaining_tracks.len(), 1);

    let remaining_path = std::fs::canonicalize(Path::new(&remaining_tracks[0].file_path))?;

    let expected_path = std::fs::canonicalize(kept_path)?;

    assert_eq!(remaining_path, expected_path);

    let removed_lookup = test_core.core().track(removed_track_id).await;

    assert!(matches!(removed_lookup, Err(CoreError::NotFound { .. })));

    Ok(())
}
