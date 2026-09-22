#![cfg(feature = "test-support")]

mod common;

use std::error::Error;
use std::path::Path;

use common::TestCore;

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
