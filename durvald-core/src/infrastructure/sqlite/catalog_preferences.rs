//! SQLite persistence for track and release preferences.

use std::sync::Arc;

use crate::domain::ids::{ReleaseId, TrackId};

type DatabasePool = r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>;

pub(crate) struct SqliteCatalogPreferencesRepository {
    db_pool: Arc<DatabasePool>,
}

impl SqliteCatalogPreferencesRepository {
    pub(crate) fn new(db_pool: Arc<DatabasePool>) -> Self {
        Self { db_pool }
    }

    pub(crate) async fn set_track_favorite(
        &self,
        id: TrackId,
        value: bool,
    ) -> Result<bool, String> {
        self.update(move |conn| {
            crate::database::operations::set_track_favorite(conn, id.get(), value)
        })
        .await
    }

    pub(crate) async fn set_release_favorite(
        &self,
        id: ReleaseId,
        value: bool,
    ) -> Result<bool, String> {
        self.update(move |conn| {
            crate::database::operations::set_release_favorite(conn, id.get(), value)
        })
        .await
    }

    pub(crate) async fn set_track_hidden(&self, id: TrackId, value: bool) -> Result<bool, String> {
        self.update(move |conn| {
            crate::database::operations::set_track_hidden(conn, id.get(), value)
        })
        .await
    }

    pub(crate) async fn set_release_hidden(
        &self,
        id: ReleaseId,
        value: bool,
    ) -> Result<bool, String> {
        self.update(move |conn| {
            crate::database::operations::set_release_hidden(conn, id.get(), value)
        })
        .await
    }

    pub(crate) async fn set_track_suggest_less(
        &self,
        id: TrackId,
        value: bool,
    ) -> Result<bool, String> {
        self.update(move |conn| {
            crate::database::operations::set_track_suggest_less(conn, id.get(), value)
        })
        .await
    }

    pub(crate) async fn set_release_suggest_less(
        &self,
        id: ReleaseId,
        value: bool,
    ) -> Result<bool, String> {
        self.update(move |conn| {
            crate::database::operations::set_release_suggest_less(conn, id.get(), value)
        })
        .await
    }

    pub(crate) async fn set_track_rating(
        &self,
        id: TrackId,
        rating: Option<u8>,
    ) -> Result<bool, String> {
        self.update(move |conn| {
            crate::database::operations::set_track_rating(conn, id.get(), rating)
        })
        .await
    }

    pub(crate) async fn set_release_rating(
        &self,
        id: ReleaseId,
        rating: Option<u8>,
    ) -> Result<bool, String> {
        self.update(move |conn| {
            crate::database::operations::set_release_rating(conn, id.get(), rating)
        })
        .await
    }

    async fn update<F>(&self, operation: F) -> Result<bool, String>
    where
        F: FnOnce(&rusqlite::Connection) -> crate::database::operations::DatabaseResult<bool>
            + Send
            + 'static,
    {
        let db_pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = db_pool.get().map_err(|error| error.to_string())?;
            operation(&conn).map_err(|error| error.to_string())
        })
        .await
        .map_err(|error| format!("Blocking database task failed: {error}"))?
    }
}
