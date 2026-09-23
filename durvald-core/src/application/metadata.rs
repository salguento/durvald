//! Metadata use-case coordination.

use std::sync::Arc;

use crate::api::{AudioMetadata, CoreError, CoreResult, KeyValuePair, TrackInfo};

type DatabasePool = r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>;

pub(crate) struct MetadataApplication {
    db_pool: Arc<DatabasePool>,
    covers_dir: String,
}

impl MetadataApplication {
    pub(crate) fn new(db_pool: Arc<DatabasePool>, covers_dir: String) -> Self {
        Self {
            db_pool,
            covers_dir,
        }
    }

    pub(crate) async fn track_info(&self, track_id: i64) -> CoreResult<TrackInfo> {
        non_negative_id(track_id, "Track ID")?;
        self.run_database_core(move |conn| {
            crate::metadata_edit::ensure_cached(conn, track_id)?;
            crate::metadata_edit::info(conn, track_id)
        })
        .await
    }

    pub(crate) async fn extract_metadata(&self, file_path: String) -> CoreResult<AudioMetadata> {
        let covers_dir = std::path::PathBuf::from(&self.covers_dir);
        let metadata = tokio::task::spawn_blocking(move || {
            crate::metadata::extract_metadata_blocking(&file_path, &covers_dir).map_err(|error| {
                CoreError::Storage {
                    message: error.to_string(),
                }
            })
        })
        .await
        .map_err(|error| CoreError::Storage {
            message: format!("Metadata extraction task failed: {error}"),
        })??;
        Ok(metadata_to_api(metadata))
    }

    async fn run_database_core<T, F>(&self, operation: F) -> CoreResult<T>
    where
        T: Send + 'static,
        F: FnOnce(&rusqlite::Connection) -> CoreResult<T> + Send + 'static,
    {
        let db_pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = db_pool.get().map_err(|error| CoreError::Storage {
                message: error.to_string(),
            })?;
            operation(&conn)
        })
        .await
        .map_err(|error| CoreError::Storage {
            message: format!("Blocking database task failed: {error}"),
        })?
    }
}

fn non_negative_id(value: i64, label: &str) -> CoreResult<u64> {
    u64::try_from(value).map_err(|_| CoreError::InvalidInput {
        message: format!("{label} must not be negative"),
    })
}

fn metadata_to_api(metadata: crate::metadata::AudioMetadata) -> AudioMetadata {
    AudioMetadata {
        title: metadata.title,
        artist: metadata.artist,
        release: metadata.release,
        genre: metadata.genre,
        year: metadata.year,
        track: metadata.track,
        disc: metadata.disc,
        duration_seconds: metadata.duration,
        bitrate: metadata.bitrate,
        sample_rate: metadata.sample_rate,
        bit_depth: metadata.bit_depth,
        channels: metadata.channels,
        cover_artwork_id: metadata.cover_path,
        all_fields: metadata
            .all_fields
            .into_iter()
            .map(|(key, value)| KeyValuePair { key, value })
            .collect(),
        file_path: metadata.file_path,
    }
}
