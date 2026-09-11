//! No network tasks or audio state are owned by this service in stage one.

use crate::api::{ArtistDetails, CoreError, CoreResult, EnrichmentSettings};
use crate::database::enrichment;
use crate::enrichment::policy::{normalize_language, normalized_settings};
use std::sync::Arc;

pub struct EnrichmentService {
    pool: Arc<r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>>,
}

impl EnrichmentService {
    pub fn new(pool: Arc<r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>>) -> Self {
        Self { pool }
    }

    async fn database<T, F>(&self, operation: F) -> CoreResult<T>
    where
        T: Send + 'static,
        F: FnOnce(&rusqlite::Connection) -> CoreResult<T> + Send + 'static,
    {
        let pool = self.pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = pool.get().map_err(|error| CoreError::Storage {
                message: error.to_string(),
            })?;
            operation(&conn)
        })
        .await
        .map_err(|error| CoreError::Storage {
            message: format!("Enrichment database task failed: {error}"),
        })?
    }

    pub async fn settings(&self) -> CoreResult<EnrichmentSettings> {
        self.database(enrichment::read_settings).await
    }

    pub async fn configure(&self, settings: EnrichmentSettings) -> CoreResult<()> {
        let settings = normalized_settings(settings)?;
        self.database(move |conn| enrichment::write_settings(conn, settings))
            .await
    }

    pub async fn artist_details(
        &self,
        artist_id: i64,
        language: String,
    ) -> CoreResult<ArtistDetails> {
        if artist_id < 0 {
            return Err(CoreError::InvalidInput {
                message: "Artist ID must be non-negative".into(),
            });
        }
        let language = normalize_language(&language)?;
        self.database(move |conn| {
            enrichment::read_artist_details(
                conn,
                artist_id,
                &language,
                chrono::Utc::now().timestamp(),
            )
        })
        .await
    }
}
