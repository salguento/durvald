//! SQLite persistence for playlists.

use std::sync::Arc;

use crate::database::models::PlaylistWithTrackCount;

type DatabasePool = r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>;

pub(crate) struct SqlitePlaylistRepository {
    db_pool: Arc<DatabasePool>,
}

impl SqlitePlaylistRepository {
    pub(crate) fn new(db_pool: Arc<DatabasePool>) -> Self {
        Self { db_pool }
    }

    pub(crate) async fn all(&self) -> Result<Vec<PlaylistWithTrackCount>, String> {
        let db_pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = db_pool.get().map_err(|error| error.to_string())?;
            crate::database::operations::get_all_playlists_with_track_counts(&conn)
                .map_err(|error| error.to_string())
        })
        .await
        .map_err(|error| format!("Playlist query task failed: {error}"))?
    }
}
