//! SQLite persistence for playlists.

use std::sync::Arc;

use crate::{
    database::models::{Playlist, PlaylistWithTrackCount, SongItem},
    domain::ids::PlaylistId,
};

type DatabasePool = r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>;

pub(crate) enum PlaylistLookupError {
    NotFound,
    Storage(String),
}

pub(crate) enum PlaylistMutationError {
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

    pub(crate) async fn create(
        &self,
        name: String,
        artwork_base64: String,
        description: String,
    ) -> Result<Playlist, String> {
        let db_pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = db_pool.get().map_err(|error| error.to_string())?;
            crate::database::operations::create_playlist(&conn, name, artwork_base64, description)
                .map_err(|error| error.to_string())
        })
        .await
        .map_err(|error| format!("Playlist creation task failed: {error}"))?
    }

    pub(crate) async fn update(
        &self,
        playlist_id: PlaylistId,
        name: String,
        description: String,
        artwork_base64: String,
    ) -> Result<(), PlaylistMutationError> {
        let db_pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = db_pool
                .get()
                .map_err(|error| PlaylistMutationError::Storage(error.to_string()))?;
            let updated = crate::database::operations::update_playlist(
                &conn,
                playlist_id.get(),
                name,
                description,
                artwork_base64,
            )
            .map_err(|error| PlaylistMutationError::Storage(error.to_string()))?;
            if !updated {
                return Err(PlaylistMutationError::NotFound);
            }
            Ok(())
        })
        .await
        .map_err(|error| {
            PlaylistMutationError::Storage(format!("Playlist update task failed: {error}"))
        })?
    }

    pub(crate) async fn find(
        &self,
        playlist_id: PlaylistId,
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

    pub(crate) async fn tracks(&self, playlist_id: PlaylistId) -> Result<Vec<SongItem>, String> {
        let db_pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = db_pool.get().map_err(|error| error.to_string())?;
            crate::database::operations::get_playlist_tracks(&conn, playlist_id.get())
                .map_err(|error| error.to_string())
        })
        .await
        .map_err(|error| format!("Playlist tracks query task failed: {error}"))?
    }

    pub(crate) async fn artwork(&self, playlist_id: PlaylistId) -> Result<Option<Vec<u8>>, String> {
        let db_pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = db_pool.get().map_err(|error| error.to_string())?;
            crate::database::operations::get_playlist_by_id(&conn, playlist_id.get())
                .map(|playlist| playlist.cover)
                .map_err(|error| error.to_string())
        })
        .await
        .map_err(|error| format!("Playlist artwork query task failed: {error}"))?
    }
}
