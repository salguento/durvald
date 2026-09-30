//! Settings use-case coordination.

use std::sync::Arc;

use crate::api::{AudioOutputState, CoreError, CoreResult, Settings};
use crate::audio::AudioPlayer;
use crate::domain::settings::ApplicationSettings;
use crate::infrastructure::sqlite::settings::SqliteSettingsRepository;

pub(crate) struct SettingsApplication {
    repository: SqliteSettingsRepository,
    audio_player: Arc<tokio::sync::Mutex<AudioPlayer>>,
}

impl SettingsApplication {
    pub(crate) fn new(
        repository: SqliteSettingsRepository,
        audio_player: Arc<tokio::sync::Mutex<AudioPlayer>>,
    ) -> Self {
        Self {
            repository,
            audio_player,
        }
    }

    pub(crate) async fn settings(&self) -> CoreResult<Settings> {
        let settings = self.repository.get().await.map_err(storage_error)?;

        Ok(Settings {
            cross_fade: settings.cross_fade,
            cross_fade_duration: settings.cross_fade_duration,
            normalize_volume: settings.normalize_volume,
            explicit_content: settings.explicit_content,
            autoplay: settings.autoplay,
            preferred_audio_quality: settings.preferred_audio_quality,
            preferred_audio_source: settings.preferred_audio_source,
            download_path: settings.download_path,
            open_on_startup: settings.open_on_startup,
            minimize_on_close: settings.minimize_on_close,
            onboarding_complete: settings.onboarding_complete,
            preferred_output_device_id: settings.preferred_output_device_id,
            equalizer: settings.equalizer,
        })
    }

    pub(crate) async fn update_settings(&self, settings: Settings) -> CoreResult<()> {
        validate_settings(&settings)?;
        let persisted_settings = ApplicationSettings {
            cross_fade: settings.cross_fade,
            cross_fade_duration: settings.cross_fade_duration,
            normalize_volume: settings.normalize_volume,
            explicit_content: settings.explicit_content,
            autoplay: settings.autoplay,
            preferred_audio_quality: settings.preferred_audio_quality,
            preferred_audio_source: settings.preferred_audio_source,
            download_path: settings.download_path,
            open_on_startup: settings.open_on_startup,
            minimize_on_close: settings.minimize_on_close,
            onboarding_complete: settings.onboarding_complete,
            preferred_output_device_id: settings.preferred_output_device_id.clone(),
            equalizer: settings.equalizer.clone(),
        };

        let mut player = self.audio_player.lock().await;
        player.set_crossfade(settings.cross_fade, settings.cross_fade_duration);
        player.set_volume_normalization(settings.normalize_volume);
        player
            .apply_equalizer(settings.equalizer.clone())
            .await
            .map_err(|error| CoreError::Playback {
                message: error.to_string(),
            })?;
        player
            .reconcile_output_device(settings.preferred_output_device_id.clone())
            .await
            .map_err(|error| CoreError::Playback {
                message: error.to_string(),
            })?;
        drop(player);

        self.repository
            .save(persisted_settings)
            .await
            .map_err(storage_error)
    }

    pub(crate) async fn audio_output_state(&self) -> CoreResult<AudioOutputState> {
        let settings = self.repository.get().await.map_err(storage_error)?;
        self.audio_player
            .lock()
            .await
            .reconcile_output_device(settings.preferred_output_device_id)
            .await
            .map_err(|error| CoreError::Playback {
                message: error.to_string(),
            })
    }

    pub(crate) async fn select_audio_output_device(
        &self,
        device_id: Option<String>,
    ) -> CoreResult<AudioOutputState> {
        if device_id
            .as_ref()
            .is_some_and(|id| id.len() > 512 || id.chars().any(char::is_control))
        {
            return Err(CoreError::InvalidInput {
                message: "Invalid audio output device identifier".into(),
            });
        }
        let normalized = device_id.filter(|id| !id.is_empty());
        let state = self
            .audio_player
            .lock()
            .await
            .reconcile_output_device(normalized.clone())
            .await
            .map_err(|error| CoreError::Playback {
                message: error.to_string(),
            })?;
        let mut settings = self.repository.get().await.map_err(storage_error)?;
        settings.preferred_output_device_id = normalized;
        self.repository
            .save(settings)
            .await
            .map_err(storage_error)?;
        Ok(state)
    }
}

pub(crate) fn validate_settings(settings: &Settings) -> CoreResult<()> {
    if settings.cross_fade_duration > 60 {
        return Err(CoreError::InvalidInput {
            message: "Cross-fade duration must be between 0 and 60 seconds".to_string(),
        });
    }
    if !(1..=1411).contains(&settings.preferred_audio_quality) {
        return Err(CoreError::InvalidInput {
            message: "Preferred audio quality must be between 1 and 1411 kbps".to_string(),
        });
    }
    for (name, value, maximum_length) in [
        (
            "Preferred audio source",
            &settings.preferred_audio_source,
            100,
        ),
        ("Download path", &settings.download_path, 4096),
    ] {
        if value.len() > maximum_length || value.chars().any(char::is_control) {
            return Err(CoreError::InvalidInput {
                message: format!("{name} contains invalid text"),
            });
        }
    }
    if settings
        .preferred_output_device_id
        .as_ref()
        .is_some_and(|value| value.len() > 512 || value.chars().any(char::is_control))
    {
        return Err(CoreError::InvalidInput {
            message: "Audio output device contains invalid text".into(),
        });
    }
    if settings.equalizer.band_gains_db.len() != 10 {
        return Err(CoreError::InvalidInput {
            message: "Equalizer must contain exactly 10 bands".into(),
        });
    }
    if !settings.equalizer.preamp_db.is_finite()
        || !(-12.0..=12.0).contains(&settings.equalizer.preamp_db)
        || settings
            .equalizer
            .band_gains_db
            .iter()
            .any(|gain| !gain.is_finite() || !(-12.0..=12.0).contains(gain))
    {
        return Err(CoreError::InvalidInput {
            message: "Equalizer gains must be finite values between -12 and 12 dB".into(),
        });
    }
    if settings.equalizer.preset.len() > 64
        || settings.equalizer.preset.chars().any(char::is_control)
    {
        return Err(CoreError::InvalidInput {
            message: "Equalizer preset contains invalid text".into(),
        });
    }
    Ok(())
}

#[cfg(test)]
pub(crate) fn normalized_cross_fade_duration(value: i32) -> u32 {
    crate::domain::settings::normalized_cross_fade_duration(value)
}

#[cfg(test)]
pub(crate) fn normalized_audio_quality(value: i32) -> u32 {
    crate::domain::settings::normalized_audio_quality(value)
}

fn storage_error(message: String) -> CoreError {
    CoreError::Storage { message }
}
