#![cfg(feature = "test-support")]

mod common;

use std::error::Error;

use common::TestCore;

#[tokio::test]
async fn opens_new_core_in_isolated_environment() -> Result<(), Box<dyn Error + Send + Sync>> {
    let test_core = TestCore::open().await?;

    assert!(test_core.files().database_path().is_file());
    assert!(test_core.files().app_support_dir().is_dir());
    assert!(test_core.files().covers_dir().is_dir());

    let settings = test_core.core().settings().await?;
    let session = test_core.core().last_session().await?;

    assert_eq!(settings.cross_fade_duration, 5);
    assert_eq!(session.volume, 0.5);

    Ok(())
}

#[tokio::test]
async fn reopens_existing_installation() -> Result<(), Box<dyn Error + Send + Sync>> {
    let test_core = TestCore::open().await?;

    let database_path = test_core.files().database_path().to_path_buf();

    assert!(database_path.is_file());

    let test_core = test_core.restart().await?;

    assert!(database_path.is_file());
    assert!(test_core.files().database_path().is_file());

    let settings = test_core.core().settings().await?;
    let session = test_core.core().last_session().await?;

    assert_eq!(settings.cross_fade_duration, 5);
    assert_eq!(session.volume, 0.5);

    Ok(())
}

#[tokio::test]
async fn settings_survive_restart() -> Result<(), Box<dyn Error + Send + Sync>> {
    let test_core = TestCore::open().await?;

    let mut settings = test_core.core().settings().await?;

    settings.cross_fade = true;
    settings.cross_fade_duration = 7;
    settings.open_on_startup = true;

    test_core.core().update_settings(settings).await?;

    let test_core = test_core.restart().await?;

    let restored = test_core.core().settings().await?;

    assert!(restored.cross_fade);
    assert_eq!(restored.cross_fade_duration, 7);
    assert!(restored.open_on_startup);

    Ok(())
}

#[tokio::test]
async fn session_volume_survives_restart() -> Result<(), Box<dyn Error + Send + Sync>> {
    let test_core = TestCore::open().await?;

    test_core.core().set_volume(0.25).await?;

    let session = test_core.core().last_session().await?;

    assert_eq!(session.volume, 0.25);

    let test_core = test_core.restart().await?;

    let restored = test_core.core().last_session().await?;

    assert_eq!(restored.volume, 0.25);

    Ok(())
}
