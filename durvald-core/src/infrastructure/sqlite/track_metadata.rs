//! SQLite-backed access for serialized track metadata edits.

use std::{path::PathBuf, sync::Arc};

use crate::{
    api::{CoreError, CoreResult, TrackInfo, TrackMetadataEdit},
    domain::ids::TrackId,
};

type DatabasePool = r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>;

pub(crate) struct SqliteTrackMetadataRepository {
    db_pool: Arc<DatabasePool>,
}

impl SqliteTrackMetadataRepository {
    pub(crate) fn new(db_pool: Arc<DatabasePool>) -> Self {
        Self { db_pool }
    }

    pub(crate) async fn info(&self, track_id: TrackId) -> CoreResult<TrackInfo> {
        self.run(move |conn| {
            let track_id = track_id.get() as i64;
            crate::metadata_edit::ensure_cached(conn, track_id)?;
            crate::metadata_edit::info(conn, track_id)
        })
        .await
    }

    pub(crate) async fn save(
        &self,
        track_id: TrackId,
        metadata: TrackMetadataEdit,
        write_to_file: bool,
        backup_dir: PathBuf,
    ) -> CoreResult<TrackInfo> {
        self.run(move |conn| {
            let track_id = track_id.get() as i64;
            crate::metadata_edit::ensure_cached(conn, track_id)?;
            crate::metadata_edit::save(conn, track_id, metadata, write_to_file, &backup_dir)
        })
        .await
    }

    pub(crate) async fn undo(&self, track_id: TrackId) -> CoreResult<TrackInfo> {
        self.run(move |conn| crate::metadata_edit::undo(conn, track_id.get() as i64))
            .await
    }

    async fn run<T, F>(&self, operation: F) -> CoreResult<T>
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
