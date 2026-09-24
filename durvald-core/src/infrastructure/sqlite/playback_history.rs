//! SQLite persistence for playback history.

use std::sync::Arc;

use crate::domain::{
    ids::{PlaybackHistoryId, TrackId},
    playback_history::PlaybackHistoryEntry,
};

type DatabasePool = r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>;

pub(crate) struct SqlitePlaybackHistoryRepository {
    db_pool: Arc<DatabasePool>,
}

impl SqlitePlaybackHistoryRepository {
    pub(crate) fn new(db_pool: Arc<DatabasePool>) -> Self {
        Self { db_pool }
    }

    pub(crate) async fn all(&self) -> Result<Vec<PlaybackHistoryEntry>, String> {
        self.run(move |conn| {
            crate::database::operations::get_play_history(conn)
                .map(|items| items.into_iter().map(entry_from_row).collect())
                .map_err(|error| error.to_string())
        })
        .await
    }

    pub(crate) async fn page(
        &self,
        limit: u64,
        offset: u64,
    ) -> Result<Vec<PlaybackHistoryEntry>, String> {
        self.run(move |conn| {
            crate::database::operations::get_play_history_page(conn, limit, offset)
                .map(|items| items.into_iter().map(entry_from_row).collect())
                .map_err(|error| error.to_string())
        })
        .await
    }

    pub(crate) async fn remove(&self, id: PlaybackHistoryId) -> Result<bool, String> {
        self.run(move |conn| {
            crate::database::operations::remove_song_from_history(conn, id.get())
                .map_err(|error| error.to_string())
        })
        .await
    }

    pub(crate) async fn clear(&self) -> Result<u64, String> {
        self.run(move |conn| {
            crate::database::operations::clear_play_history(conn).map_err(|error| error.to_string())
        })
        .await
    }

    pub(crate) async fn record_completed(
        &self,
        track_id: TrackId,
        duration_seconds: u64,
    ) -> Result<bool, String> {
        self.run(move |conn| {
            crate::database::operations::record_completed_playback(
                conn,
                track_id.get(),
                duration_seconds,
            )
            .map_err(|error| error.to_string())
        })
        .await
    }

    async fn run<T, F>(&self, operation: F) -> Result<T, String>
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
        .map_err(|error| format!("Blocking database task failed: {error}"))?
    }
}

fn entry_from_row(row: crate::database::models::PlayHistory) -> PlaybackHistoryEntry {
    PlaybackHistoryEntry {
        id: PlaybackHistoryId::from_persisted(row.history_id),
        track_id: TrackId::from_persisted(row.song_id),
        played_at: row.played_at,
        duration_seconds: row.duration,
    }
}
