//! SQLite lookup for an individual catalog track.

use std::sync::Arc;

use crate::{database::models::SongItem, domain::ids::TrackId};

type DatabasePool = r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>;

pub(crate) enum CatalogTrackLookupError {
    NotFound,
    Storage(String),
}

pub(crate) struct SqliteCatalogTrackQuery {
    db_pool: Arc<DatabasePool>,
}

impl SqliteCatalogTrackQuery {
    pub(crate) fn new(db_pool: Arc<DatabasePool>) -> Self {
        Self { db_pool }
    }

    pub(crate) async fn find(
        &self,
        track_id: TrackId,
    ) -> Result<SongItem, CatalogTrackLookupError> {
        let db_pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = db_pool
                .get()
                .map_err(|error| CatalogTrackLookupError::Storage(error.to_string()))?;
            crate::database::operations::get_song_by_id(&conn, &track_id.get().to_string())
                .map_err(|error| CatalogTrackLookupError::Storage(error.to_string()))?
                .into_iter()
                .next()
                .ok_or(CatalogTrackLookupError::NotFound)
        })
        .await
        .map_err(|error| {
            CatalogTrackLookupError::Storage(format!("Blocking database task failed: {error}"))
        })?
    }

    pub(crate) async fn all(&self) -> Result<Vec<SongItem>, CatalogTrackLookupError> {
        let db_pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = db_pool
                .get()
                .map_err(|error| CatalogTrackLookupError::Storage(error.to_string()))?;
            crate::database::operations::get_all_tracks(&conn)
                .map_err(|error| CatalogTrackLookupError::Storage(error.to_string()))
        })
        .await
        .map_err(|error| {
            CatalogTrackLookupError::Storage(format!("Blocking database task failed: {error}"))
        })?
    }

    pub(crate) async fn page(
        &self,
        fetch_size: u64,
        offset: u64,
    ) -> Result<Vec<SongItem>, CatalogTrackLookupError> {
        let db_pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = db_pool
                .get()
                .map_err(|error| CatalogTrackLookupError::Storage(error.to_string()))?;
            crate::database::operations::get_tracks_page(&conn, fetch_size, offset)
                .map_err(|error| CatalogTrackLookupError::Storage(error.to_string()))
        })
        .await
        .map_err(|error| {
            CatalogTrackLookupError::Storage(format!("Blocking database task failed: {error}"))
        })?
    }
}
