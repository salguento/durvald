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
