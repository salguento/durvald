#![cfg(feature = "test-support")]

mod common;

use common::TestCore;
use durvald_core::{CoreError, Settings};
use std::error::Error;

async fn current_settings(test_core: &TestCore) -> Settings {
    test_core
        .core()
        .settings()
        .await
        .expect("read current settings")
}

#[tokio::test]
async fn valid_settings_persist_and_update_audio_runtime()
-> Result<(), Box<dyn Error + Send + Sync>> {
    let test_core = TestCore::open().await?;
    let mut settings = current_settings(&test_core).await;
    settings.cross_fade = true;
    settings.cross_fade_duration = 12;
    settings.normalize_volume = true;
    settings.explicit_content = false;
    settings.autoplay = false;
    settings.preferred_audio_quality = 1_411;
    settings.preferred_audio_source = "local".into();
    settings.download_path = "/tmp/durvald-downloads".into();
    settings.open_on_startup = true;
    settings.minimize_on_close = true;
    settings.onboarding_complete = true;

    test_core.core().update_settings(settings.clone()).await?;

    assert_eq!(current_settings(&test_core).await, settings);
    assert_eq!(
        durvald_core::test_support::audio_settings(test_core.core()).await,
        durvald_core::test_support::AudioSettingsSnapshot {
            crossfade_duration_seconds: Some(12),
            normalize_volume: true,
        }
    );

    Ok(())
}

#[tokio::test]
async fn persisted_audio_settings_are_reapplied_after_restart()
-> Result<(), Box<dyn Error + Send + Sync>> {
    let test_core = TestCore::open().await?;
    let mut settings = current_settings(&test_core).await;
    settings.cross_fade = true;
    settings.cross_fade_duration = 9;
    settings.normalize_volume = true;
    test_core.core().update_settings(settings.clone()).await?;

    let test_core = test_core.restart().await?;

    assert_eq!(current_settings(&test_core).await, settings);
    assert_eq!(
        durvald_core::test_support::audio_settings(test_core.core()).await,
        durvald_core::test_support::AudioSettingsSnapshot {
            crossfade_duration_seconds: Some(9),
            normalize_volume: true,
        }
    );

    Ok(())
}

#[tokio::test]
async fn disabled_or_zero_crossfade_is_applied_without_reopening()
-> Result<(), Box<dyn Error + Send + Sync>> {
    let test_core = TestCore::open().await?;
    let mut settings = current_settings(&test_core).await;
    settings.cross_fade = true;
    settings.cross_fade_duration = 0;
    settings.normalize_volume = false;

    test_core.core().update_settings(settings).await?;

    assert_eq!(
        durvald_core::test_support::audio_settings(test_core.core()).await,
        durvald_core::test_support::AudioSettingsSnapshot {
            crossfade_duration_seconds: None,
            normalize_volume: false,
        }
    );

    Ok(())
}

#[tokio::test]
async fn invalid_settings_return_invalid_input_without_mutating_state()
-> Result<(), Box<dyn Error + Send + Sync>> {
    let test_core = TestCore::open().await?;
    let original = current_settings(&test_core).await;
    let original_runtime = durvald_core::test_support::audio_settings(test_core.core()).await;

    let mut invalid_values = Vec::new();

    let mut invalid = original.clone();
    invalid.cross_fade_duration = 61;
    invalid_values.push(invalid);

    let mut invalid = original.clone();
    invalid.preferred_audio_quality = 0;
    invalid_values.push(invalid);

    let mut invalid = original.clone();
    invalid.preferred_audio_quality = 1_412;
    invalid_values.push(invalid);

    let mut invalid = original.clone();
    invalid.preferred_audio_source = "local\nremote".into();
    invalid_values.push(invalid);

    let mut invalid = original.clone();
    invalid.preferred_audio_source = "s".repeat(101);
    invalid_values.push(invalid);

    let mut invalid = original.clone();
    invalid.download_path = "invalid\0path".into();
    invalid_values.push(invalid);

    let mut invalid = original.clone();
    invalid.download_path = "d".repeat(4_097);
    invalid_values.push(invalid);

    for invalid in invalid_values {
        assert!(matches!(
            test_core.core().update_settings(invalid).await,
            Err(CoreError::InvalidInput { .. })
        ));
        assert_eq!(current_settings(&test_core).await, original);
        assert_eq!(
            durvald_core::test_support::audio_settings(test_core.core()).await,
            original_runtime
        );
    }

    Ok(())
}
