//! Settings use-case coordination.

use std::sync::Arc;

use crate::api::{CoreError, CoreResult, Settings};
use crate::audio::AudioPlayer;

type DatabasePool = r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>;

pub(crate) struct SettingsApplication {
    db_pool: Arc<DatabasePool>,
    audio_player: Arc<tokio::sync::Mutex<AudioPlayer>>,
}

impl SettingsApplication {
    pub(crate) fn new(
        db_pool: Arc<DatabasePool>,
        audio_player: Arc<tokio::sync::Mutex<AudioPlayer>>,
    ) -> Self {
        Self {
            db_pool,
            audio_player,
        }
    }

    pub(crate) async fn settings(&self) -> CoreResult<Settings> {
        let settings = self
            .run_database(|conn| {
                crate::database::operations::get_settings(conn).map_err(|error| error.to_string())
            })
            .await?;

        Ok(Settings {
            cross_fade: settings.cross_fade,
            cross_fade_duration: normalized_cross_fade_duration(settings.cross_fade_duration),
            normalize_volume: settings.normalize_volume,
            explicit_content: settings.explicit_content,
            autoplay: settings.autoplay,
            preferred_audio_quality: normalized_audio_quality(settings.preferred_audio_quality),
            preferred_audio_source: settings.preferred_audio_source,
            download_path: settings.download_path,
            open_on_startup: settings.open_on_startup,
            minimize_on_close: settings.minimize_on_close,
            onboarding_complete: !settings.onboarding,
        })
    }

    pub(crate) async fn update_settings(&self, settings: Settings) -> CoreResult<()> {
        validate_settings(&settings)?;
        let database_settings = crate::database::models::Settings {
            settings_id: 1,
            cross_fade: settings.cross_fade,
            cross_fade_duration: settings.cross_fade_duration as i32,
            normalize_volume: settings.normalize_volume,
            explicit_content: settings.explicit_content,
            autoplay: settings.autoplay,
            preferred_audio_quality: settings.preferred_audio_quality as i32,
            preferred_audio_source: settings.preferred_audio_source,
            download_path: settings.download_path,
            open_on_startup: settings.open_on_startup,
            minimize_on_close: settings.minimize_on_close,
            onboarding: !settings.onboarding_complete,
        };

        let mut player = self.audio_player.lock().await;
        player.set_crossfade(settings.cross_fade, settings.cross_fade_duration);
        player.set_volume_normalization(settings.normalize_volume);
        drop(player);

        self.run_database(move |conn| {
            crate::database::operations::save_settings(conn, &database_settings)
                .map_err(|error| error.to_string())
        })
        .await
    }

    async fn run_database<T, F>(&self, operation: F) -> CoreResult<T>
    where
        T: Send + 'static,
        F: FnOnce(&rusqlite::Connection) -> Result<T, String> + Send + 'static,
    {
        let db_pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = db_pool.get().map_err(|error| error.to_string())?;
            operation(&conn)
        })
        .await
        .map_err(|error| CoreError::Storage {
            message: format!("Blocking database task failed: {error}"),
        })?
        .map_err(|message| CoreError::Storage { message })
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
    Ok(())
}

pub(crate) fn normalized_cross_fade_duration(value: i32) -> u32 {
    u32::try_from(value).unwrap_or_default().min(60)
}

pub(crate) fn normalized_audio_quality(value: i32) -> u32 {
    u32::try_from(value)
        .ok()
        .filter(|value| (1..=1411).contains(value))
        .unwrap_or(320)
}
