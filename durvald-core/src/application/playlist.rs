//! Playlist use-case coordination.

use std::sync::Arc;

use base64::Engine;

use crate::{
    api::{CoreError, CoreResult, Playlist, PlaylistTrack, Track},
    application::library::track_from_song,
};

type DatabasePool = r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>;

pub(crate) struct PlaylistApplication {
    db_pool: Arc<DatabasePool>,
}

impl PlaylistApplication {
    pub(crate) fn new(db_pool: Arc<DatabasePool>) -> Self {
        Self { db_pool }
    }

    pub(crate) async fn playlists(&self) -> CoreResult<Vec<Playlist>> {
        self.run_database(|conn| {
            let summaries = crate::database::operations::get_all_playlists_with_track_counts(conn)
                .map_err(|error| error.to_string())?;
            Ok(summaries
                .into_iter()
                .map(|summary| playlist_from_database(summary.playlist, summary.track_count))
                .collect())
        })
        .await
    }

    pub(crate) async fn create_playlist(
        &self,
        name: String,
        description: String,
        artwork_base64: Option<String>,
    ) -> CoreResult<Playlist> {
        if name.trim().is_empty() {
            return Err(CoreError::InvalidInput {
                message: "Playlist name cannot be empty".to_string(),
            });
        }
        self.run_database(move |conn| {
            crate::database::operations::create_playlist(
                conn,
                name,
                artwork_base64.unwrap_or_default(),
                description,
            )
            .map(|playlist| playlist_from_database(playlist, 0))
            .map_err(|error| error.to_string())
        })
        .await
    }

    pub(crate) async fn playlist(&self, playlist_id: i64) -> CoreResult<Playlist> {
        let playlist_id = non_negative_id(playlist_id, "Playlist ID")?;
        self.run_database_core(move |conn| {
            let playlist = crate::database::operations::get_playlist_by_id(conn, playlist_id)
                .map_err(|error| lookup_error(error, "Playlist", playlist_id))?;
            let track_count =
                crate::database::operations::get_playlist_track_count(conn, playlist_id).map_err(
                    |error| CoreError::Storage {
                        message: error.to_string(),
                    },
                )?;
            Ok(playlist_from_database(playlist, track_count))
        })
        .await
    }

    pub(crate) async fn update_playlist(
        &self,
        playlist_id: i64,
        name: String,
        description: String,
        artwork_base64: Option<String>,
    ) -> CoreResult<()> {
        if name.trim().is_empty() {
            return Err(CoreError::InvalidInput {
                message: "Playlist name cannot be empty".to_string(),
            });
        }
        let playlist_id = non_negative_id(playlist_id, "Playlist ID")?;
        self.run_entity_update("Playlist", playlist_id, move |conn| {
            crate::database::operations::update_playlist(
                conn,
                playlist_id,
                name,
                description,
                artwork_base64.unwrap_or_default(),
            )
        })
        .await
    }

    pub(crate) async fn delete_playlist(&self, playlist_id: i64) -> CoreResult<()> {
        let playlist_id = non_negative_id(playlist_id, "Playlist ID")?;
        self.run_entity_update("Playlist", playlist_id, move |conn| {
            crate::database::operations::delete_playlist(conn, playlist_id)
        })
        .await
    }

    pub(crate) async fn playlist_tracks(&self, playlist_id: i64) -> CoreResult<Vec<Track>> {
        let playlist_id = non_negative_id(playlist_id, "Playlist ID")?;
        self.run_database(move |conn| {
            crate::database::operations::get_playlist_tracks(conn, playlist_id)
                .map(|tracks| tracks.into_iter().map(track_from_song).collect())
                .map_err(|error| error.to_string())
        })
        .await
    }

    pub(crate) async fn add_track_to_playlist(
        &self,
        playlist_id: i64,
        track_id: i64,
        position: u64,
    ) -> CoreResult<PlaylistTrack> {
        let playlist_id = non_negative_id(playlist_id, "Playlist ID")?;
        let track_id = non_negative_id(track_id, "Track ID")?;
        self.run_database(move |conn| {
            crate::database::operations::add_track_to_playlist_songs(
                conn,
                playlist_id,
                track_id,
                position,
            )
            .map(|entry| PlaylistTrack {
                playlist_id: entry.playlist_id as i64,
                track_id: entry.song_id as i64,
                position: entry.position,
                added_at: entry.added_at,
            })
            .map_err(|error| error.to_string())
        })
        .await
    }

    pub(crate) async fn remove_track_from_playlist(
        &self,
        playlist_id: i64,
        track_id: i64,
        position: u64,
    ) -> CoreResult<()> {
        let playlist_id = non_negative_id(playlist_id, "Playlist ID")?;
        let track_id = non_negative_id(track_id, "Track ID")?;
        self.run_database(move |conn| {
            crate::database::operations::remove_track_from_playlist(
                conn,
                playlist_id,
                track_id,
                position,
            )
            .map_err(|error| error.to_string())
        })
        .await
    }

    pub(crate) async fn move_playlist_track(
        &self,
        playlist_id: i64,
        from: u64,
        to: u64,
    ) -> CoreResult<()> {
        let playlist_id = non_negative_id(playlist_id, "Playlist ID")?;
        self.run_database(move |conn| {
            crate::database::operations::move_playlist_track(conn, playlist_id, from, to)
                .map_err(|error| error.to_string())
        })
        .await
    }

    pub(crate) async fn playlist_artwork_bytes(
        &self,
        playlist_id: i64,
    ) -> CoreResult<Option<Vec<u8>>> {
        let playlist_id = non_negative_id(playlist_id, "Playlist ID")?;
        self.run_database(move |conn| {
            crate::database::operations::get_playlist_by_id(conn, playlist_id)
                .map(|playlist| playlist.cover)
                .map_err(|error| error.to_string())
        })
        .await
    }

    async fn run_database<T, F>(&self, operation: F) -> CoreResult<T>
    where
        T: Send + 'static,
        F: FnOnce(&rusqlite::Connection) -> Result<T, String> + Send + 'static,
    {
        let db_pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = db_pool.get().map_err(|error| error.to_string())?;
            operation(&conn)
        })
        .await
        .map_err(|error| CoreError::Storage {
            message: format!("Blocking database task failed: {error}"),
        })?
        .map_err(|message| CoreError::Storage { message })
    }

    async fn run_database_core<T, F>(&self, operation: F) -> CoreResult<T>
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

    async fn run_entity_update<F>(
        &self,
        entity: &'static str,
        id: u64,
        operation: F,
    ) -> CoreResult<()>
    where
        F: FnOnce(&rusqlite::Connection) -> crate::database::operations::DatabaseResult<bool>
            + Send
            + 'static,
    {
        self.run_database_core(move |conn| {
            if !operation(conn).map_err(|error| CoreError::Storage {
                message: error.to_string(),
            })? {
                return Err(CoreError::NotFound {
                    message: format!("{entity} {id} not found"),
                });
            }
            Ok(())
        })
        .await
    }
}

fn playlist_from_database(
    playlist: crate::database::models::Playlist,
    track_count: u64,
) -> Playlist {
    Playlist {
        id: playlist.id as i64,
        name: playlist.name,
        description: playlist.description,
        artwork_id: playlist
            .cover
            .map(|cover| base64::engine::general_purpose::STANDARD.encode(cover)),
        is_favorite: playlist.is_favorite,
        suggest_less: playlist.suggest_less,
        track_count,
        created_at: playlist.created_at,
        updated_at: playlist.updated_at,
    }
}

fn non_negative_id(value: i64, label: &str) -> CoreResult<u64> {
    u64::try_from(value).map_err(|_| CoreError::InvalidInput {
        message: format!("{label} must not be negative"),
    })
}

fn lookup_error(
    error: crate::database::operations::DatabaseError,
    resource: &str,
    id: u64,
) -> CoreError {
    if matches!(
        &error,
        crate::database::operations::DatabaseError::Rusqlite(rusqlite::Error::QueryReturnedNoRows)
    ) {
        CoreError::NotFound {
            message: format!("{resource} {id} not found"),
        }
    } else {
        CoreError::Storage {
            message: error.to_string(),
        }
    }
}
