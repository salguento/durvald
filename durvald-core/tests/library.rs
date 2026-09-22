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
