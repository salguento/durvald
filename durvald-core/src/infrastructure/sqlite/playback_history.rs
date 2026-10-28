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

    pub(crate) async fn revision(&self) -> Result<u64, String> {
        self.run(|conn| {
            crate::database::operations::get_playback_history_revision(conn)
                .map_err(|error| error.to_string())
        })
        .await
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
        source_id: Option<i64>,
        session_id: String,
        heard_seconds: u64,
        effective_duration_seconds: u64,
    ) -> Result<bool, String> {
        self.run(move |conn| {
            let tx = conn.unchecked_transaction().map_err(|e| e.to_string())?;
            let exists: bool = tx.query_row("SELECT EXISTS(SELECT 1 FROM songs WHERE song_id=?1)", [track_id.get()], |r| r.get(0)).map_err(|e| e.to_string())?;
            if !exists { return Ok(false); }
            let inserted = tx.execute("INSERT OR IGNORE INTO playback_completion_receipts(session_id,song_id) VALUES(?1,?2)", rusqlite::params![session_id,track_id.get()]).map_err(|e|e.to_string())?;
            if inserted == 0 { return Ok(false); }
            let source_id = if let Some(id) = source_id { tx.query_row("SELECT source_id FROM track_sources WHERE source_id=?1 AND song_id=?2",rusqlite::params![id,track_id.get()],|r|r.get::<_,i64>(0)).ok() } else { None };
            tx.execute("INSERT INTO play_history(song_id,played_at,play_duration,source_id,effective_duration_seconds,session_id) VALUES(?1,?2,?3,?4,?5,?6)",rusqlite::params![track_id.get(),chrono::Utc::now().to_rfc3339(),heard_seconds,source_id,effective_duration_seconds,session_id]).map_err(|e|e.to_string())?;
            tx.execute("UPDATE songs SET play_count=play_count+1,last_played=CURRENT_TIMESTAMP,updated_at=CURRENT_TIMESTAMP WHERE song_id=?1",[track_id.get()]).map_err(|e|e.to_string())?;
            tx.commit().map_err(|e|e.to_string())?;
            Ok(true)
        }).await
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
        source_id: row.source_id,
        effective_duration_seconds: row.effective_duration_seconds,
        id: PlaybackHistoryId::from_persisted(row.history_id),
        track_id: TrackId::from_persisted(row.song_id),
        played_at: row.played_at,
        duration_seconds: row.duration,
    }
}

pub(crate) const SCHEMA: &str = r#"
ALTER TABLE play_history ADD COLUMN source_id INTEGER;
ALTER TABLE play_history ADD COLUMN effective_duration_seconds INTEGER;
ALTER TABLE play_history ADD COLUMN session_id TEXT;
CREATE UNIQUE INDEX play_history_session ON play_history(session_id) WHERE session_id IS NOT NULL;
CREATE TABLE playback_completion_receipts(session_id TEXT PRIMARY KEY,song_id INTEGER NOT NULL REFERENCES songs(song_id) ON DELETE CASCADE);
"#;
