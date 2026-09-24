//! SQLite-backed persistence for library scans.

use std::sync::{Arc, atomic::AtomicBool};

use crate::{
    database::operations::{PendingDatabaseUpdate, PersistedMetadata},
    metadata::AudioMetadata,
};

type DatabasePool = r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>;

pub(crate) struct SqliteLibraryScanRepository {
    db_pool: Arc<DatabasePool>,
}

impl SqliteLibraryScanRepository {
    pub(crate) fn new(db_pool: Arc<DatabasePool>) -> Self {
        Self { db_pool }
    }

    pub(crate) async fn prepare(
        &self,
        path: String,
        cancellation: Arc<AtomicBool>,
    ) -> Result<PendingDatabaseUpdate, String> {
        let db_pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = db_pool.get().map_err(|error| error.to_string())?;
            crate::database::operations::prepare_database_update_with_cancel(
                &conn,
                path,
                Some(cancellation.as_ref()),
            )
            .map_err(|error| error.to_string())
        })
        .await
        .map_err(|error| format!("Library scan preparation task failed: {error}"))?
    }

    pub(crate) async fn persist_metadata(
        &self,
        metadata: Vec<AudioMetadata>,
        mtimes: Vec<i64>,
        existing_song_ids: Vec<Option<i64>>,
    ) -> Result<PersistedMetadata, String> {
        let db_pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = db_pool.get().map_err(|error| error.to_string())?;
            crate::database::operations::persist_metadata_with_existing_ids(
                &conn,
                metadata,
                mtimes,
                existing_song_ids,
            )
            .map_err(|error| error.to_string())
        })
        .await
        .map_err(|error| format!("Library database write task failed: {error}"))?
    }
}
