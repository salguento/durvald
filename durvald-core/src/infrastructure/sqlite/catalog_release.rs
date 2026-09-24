//! SQLite lookup for an individual catalog release.

use std::sync::Arc;

use crate::{
    database::models::Releases,
    domain::{catalog::CatalogTrack, ids::ReleaseId},
    infrastructure::sqlite::catalog_track::track_from_row,
};

type DatabasePool = r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>;

pub(crate) enum CatalogReleaseLookupError {
    NotFound,
    Storage(String),
}

pub(crate) struct SqliteCatalogReleaseQuery {
    db_pool: Arc<DatabasePool>,
}

impl SqliteCatalogReleaseQuery {
    pub(crate) fn new(db_pool: Arc<DatabasePool>) -> Self {
        Self { db_pool }
    }

    pub(crate) async fn find(
        &self,
        release_id: ReleaseId,
    ) -> Result<Releases, CatalogReleaseLookupError> {
        let db_pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = db_pool
                .get()
                .map_err(|error| CatalogReleaseLookupError::Storage(error.to_string()))?;
            crate::database::operations::get_release_by_id(&conn, &release_id.get().to_string())
                .map_err(|error| {
                    if matches!(
                        &error,
                        crate::database::operations::DatabaseError::Rusqlite(
                            rusqlite::Error::QueryReturnedNoRows
                        )
                    ) {
                        CatalogReleaseLookupError::NotFound
                    } else {
                        CatalogReleaseLookupError::Storage(error.to_string())
                    }
                })
        })
        .await
        .map_err(|error| {
            CatalogReleaseLookupError::Storage(format!("Blocking database task failed: {error}"))
        })?
    }

    pub(crate) async fn tracks(
        &self,
        release_id: ReleaseId,
    ) -> Result<Vec<CatalogTrack>, CatalogReleaseLookupError> {
        let db_pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = db_pool
                .get()
                .map_err(|error| CatalogReleaseLookupError::Storage(error.to_string()))?;
            crate::database::operations::get_songs_by_release_id(
                &conn,
                &release_id.get().to_string(),
            )
            .map(|tracks| tracks.into_iter().map(track_from_row).collect())
            .map_err(|error| CatalogReleaseLookupError::Storage(error.to_string()))
        })
        .await
        .map_err(|error| {
            CatalogReleaseLookupError::Storage(format!("Blocking database task failed: {error}"))
        })?
    }

    pub(crate) async fn all(&self) -> Result<Vec<Releases>, CatalogReleaseLookupError> {
        let db_pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = db_pool
                .get()
                .map_err(|error| CatalogReleaseLookupError::Storage(error.to_string()))?;
            crate::database::operations::get_all_releases(&conn)
                .map_err(|error| CatalogReleaseLookupError::Storage(error.to_string()))
        })
        .await
        .map_err(|error| {
            CatalogReleaseLookupError::Storage(format!("Blocking database task failed: {error}"))
        })?
    }

    pub(crate) async fn page(
        &self,
        fetch_size: u64,
        offset: u64,
    ) -> Result<Vec<Releases>, CatalogReleaseLookupError> {
        let db_pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = db_pool
                .get()
                .map_err(|error| CatalogReleaseLookupError::Storage(error.to_string()))?;
            crate::database::operations::get_releases_page(&conn, fetch_size, offset)
                .map_err(|error| CatalogReleaseLookupError::Storage(error.to_string()))
        })
        .await
        .map_err(|error| {
            CatalogReleaseLookupError::Storage(format!("Blocking database task failed: {error}"))
        })?
    }
}
