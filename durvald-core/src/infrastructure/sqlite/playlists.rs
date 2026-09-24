//! SQLite persistence for playlists.

use std::sync::Arc;

use crate::database::models::PlaylistWithTrackCount;

type DatabasePool = r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>;

pub(crate) enum PlaylistLookupError {
    NotFound,
    Storage(String),
}

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

    pub(crate) async fn find(
        &self,
        playlist_id: crate::domain::ids::PlaylistId,
    ) -> Result<PlaylistWithTrackCount, PlaylistLookupError> {
        let db_pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = db_pool
                .get()
                .map_err(|error| PlaylistLookupError::Storage(error.to_string()))?;
            let playlist_id = playlist_id.get();
            let playlist = crate::database::operations::get_playlist_by_id(&conn, playlist_id)
                .map_err(|error| {
                    if matches!(
                        &error,
                        crate::database::operations::DatabaseError::Rusqlite(
                            rusqlite::Error::QueryReturnedNoRows
                        )
                    ) {
                        PlaylistLookupError::NotFound
                    } else {
                        PlaylistLookupError::Storage(error.to_string())
                    }
                })?;
            let track_count =
                crate::database::operations::get_playlist_track_count(&conn, playlist_id)
                    .map_err(|error| PlaylistLookupError::Storage(error.to_string()))?;
            Ok(PlaylistWithTrackCount {
                playlist,
                track_count,
            })
        })
        .await
        .map_err(|error| {
            PlaylistLookupError::Storage(format!("Playlist query task failed: {error}"))
        })?
    }
}
