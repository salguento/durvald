//! SQLite lookup for an individual catalog artist.

use std::sync::Arc;

use crate::{
    database::models::ArtistItem,
    domain::{
        catalog::{CatalogRelease, CatalogTrack},
        ids::ArtistId,
    },
    infrastructure::sqlite::catalog_release::release_from_row,
    infrastructure::sqlite::catalog_track::track_from_row,
};

type DatabasePool = r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>;

pub(crate) enum CatalogArtistLookupError {
    NotFound,
    Storage(String),
}

pub(crate) struct SqliteCatalogArtistQuery {
    db_pool: Arc<DatabasePool>,
}

impl SqliteCatalogArtistQuery {
    pub(crate) fn new(db_pool: Arc<DatabasePool>) -> Self {
        Self { db_pool }
    }

    pub(crate) async fn find(
        &self,
        artist_id: ArtistId,
    ) -> Result<ArtistItem, CatalogArtistLookupError> {
        let db_pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = db_pool
                .get()
                .map_err(|error| CatalogArtistLookupError::Storage(error.to_string()))?;
            crate::database::operations::get_artist_by_id(&conn, &artist_id.get().to_string())
                .map_err(|error| {
                    if matches!(
                        &error,
                        crate::database::operations::DatabaseError::Rusqlite(
                            rusqlite::Error::QueryReturnedNoRows
                        )
                    ) {
                        CatalogArtistLookupError::NotFound
                    } else {
                        CatalogArtistLookupError::Storage(error.to_string())
                    }
                })
        })
        .await
        .map_err(|error| {
            CatalogArtistLookupError::Storage(format!("Blocking database task failed: {error}"))
        })?
    }

    pub(crate) async fn releases(
        &self,
        artist_id: ArtistId,
    ) -> Result<Vec<CatalogRelease>, CatalogArtistLookupError> {
        let db_pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = db_pool
                .get()
                .map_err(|error| CatalogArtistLookupError::Storage(error.to_string()))?;
            crate::database::operations::get_releases_by_artist_id(
                &conn,
                &artist_id.get().to_string(),
            )
            .map(|releases| releases.into_iter().map(release_from_row).collect())
            .map_err(|error| CatalogArtistLookupError::Storage(error.to_string()))
        })
        .await
        .map_err(|error| {
            CatalogArtistLookupError::Storage(format!("Blocking database task failed: {error}"))
        })?
    }

    pub(crate) async fn tracks(
        &self,
        artist_id: ArtistId,
    ) -> Result<Vec<CatalogTrack>, CatalogArtistLookupError> {
        let db_pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = db_pool
                .get()
                .map_err(|error| CatalogArtistLookupError::Storage(error.to_string()))?;
            crate::database::operations::get_songs_by_artist_id(&conn, &artist_id.get().to_string())
                .map(|tracks| tracks.into_iter().map(track_from_row).collect())
                .map_err(|error| CatalogArtistLookupError::Storage(error.to_string()))
        })
        .await
        .map_err(|error| {
            CatalogArtistLookupError::Storage(format!("Blocking database task failed: {error}"))
        })?
    }

    pub(crate) async fn all(&self) -> Result<Vec<ArtistItem>, CatalogArtistLookupError> {
        let db_pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = db_pool
                .get()
                .map_err(|error| CatalogArtistLookupError::Storage(error.to_string()))?;
            crate::database::operations::get_all_artists(&conn)
                .map_err(|error| CatalogArtistLookupError::Storage(error.to_string()))
        })
        .await
        .map_err(|error| {
            CatalogArtistLookupError::Storage(format!("Blocking database task failed: {error}"))
        })?
    }
}
