//! SQLite persistence for application settings.

use std::sync::Arc;

use crate::domain::settings::{
    ApplicationSettings, normalized_audio_quality, normalized_cross_fade_duration,
};

type DatabasePool = r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>;

pub(crate) struct SqliteSettingsRepository {
    db_pool: Arc<DatabasePool>,
}

impl SqliteSettingsRepository {
    pub(crate) fn new(db_pool: Arc<DatabasePool>) -> Self {
        Self { db_pool }
    }

    pub(crate) async fn get(&self) -> Result<ApplicationSettings, String> {
        self.run(|conn| {
            crate::database::operations::get_settings(conn)
                .map(settings_from_row)
                .map_err(|error| error.to_string())
        })
        .await
    }

    pub(crate) async fn save(&self, settings: ApplicationSettings) -> Result<(), String> {
        self.run(move |conn| {
            let row = settings_to_row(settings);
            crate::database::operations::save_settings(conn, &row)
                .map_err(|error| error.to_string())
        })
        .await
    }

    async fn run<T, F>(&self, operation: F) -> Result<T, String>
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
        .map_err(|error| format!("Blocking database task failed: {error}"))?
    }
}

fn settings_from_row(row: crate::database::models::Settings) -> ApplicationSettings {
    ApplicationSettings {
        cross_fade: row.cross_fade,
        cross_fade_duration: normalized_cross_fade_duration(row.cross_fade_duration),
        normalize_volume: row.normalize_volume,
        explicit_content: row.explicit_content,
        autoplay: row.autoplay,
        preferred_audio_quality: normalized_audio_quality(row.preferred_audio_quality),
        preferred_audio_source: row.preferred_audio_source,
        download_path: row.download_path,
        open_on_startup: row.open_on_startup,
        minimize_on_close: row.minimize_on_close,
        onboarding_complete: !row.onboarding,
        preferred_output_device_id: row.preferred_output_device_id,
        equalizer: serde_json::from_str(&row.equalizer_json).unwrap_or_default(),
    }
}

fn settings_to_row(settings: ApplicationSettings) -> crate::database::models::Settings {
    crate::database::models::Settings {
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
        preferred_output_device_id: settings.preferred_output_device_id,
        equalizer_json: serde_json::to_string(&settings.equalizer)
            .unwrap_or_else(|_| "{}".to_string()),
    }
}
