//! SQLite persistence for the last playback session.

use std::sync::Arc;

use crate::{database::models::LastSession, domain::playback_session::PlaybackSessionState};

type DatabasePool = r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>;

pub(crate) struct SqlitePlaybackSessionRepository {
    db_pool: Arc<DatabasePool>,
}

impl SqlitePlaybackSessionRepository {
    pub(crate) fn new(db_pool: Arc<DatabasePool>) -> Self {
        Self { db_pool }
    }

    pub(crate) async fn load(&self) -> Result<PlaybackSessionState, String> {
        let db_pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = db_pool.get().map_err(|error| error.to_string())?;
            crate::database::operations::get_last_session(&conn)
                .map(session_from_row)
                .map_err(|error| error.to_string())
        })
        .await
        .map_err(|error| format!("Last-session query task failed: {error}"))?
    }

    pub(crate) async fn save_preserving_source_context(
        &self,
        mut session: PlaybackSessionState,
    ) -> Result<(), String> {
        let db_pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = db_pool.get().map_err(|error| error.to_string())?;
            let previous = crate::database::operations::get_last_session(&conn)
                .map_err(|error| error.to_string())?;
            session.source_context = previous.source_context;
            let row = session_to_row(session)?;
            crate::database::operations::save_last_session(&conn, &row)
                .map_err(|error| error.to_string())
        })
        .await
        .map_err(|error| format!("Session persistence task failed: {error}"))?
    }

    pub(crate) async fn save(&self, session: PlaybackSessionState) -> Result<(), String> {
        let db_pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = db_pool.get().map_err(|error| error.to_string())?;
            let row = session_to_row(session)?;
            crate::database::operations::save_last_session(&conn, &row)
                .map_err(|error| error.to_string())
        })
        .await
        .map_err(|error| format!("Session persistence task failed: {error}"))?
    }

    pub(crate) async fn update_progress(&self, progress_seconds: f64) -> Result<(), String> {
        let db_pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = db_pool.get().map_err(|error| error.to_string())?;
            crate::database::operations::update_session_progress(&conn, progress_seconds)
                .map_err(|error| error.to_string())
        })
        .await
        .map_err(|error| format!("Session progress persistence task failed: {error}"))?
    }

    pub(crate) async fn update_volume(&self, volume: f64) -> Result<(), String> {
        let db_pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = db_pool.get().map_err(|error| error.to_string())?;
            crate::database::operations::update_session_volume(&conn, volume)
                .map_err(|error| error.to_string())
        })
        .await
        .map_err(|error| format!("Session volume persistence task failed: {error}"))?
    }
}

fn session_from_row(row: LastSession) -> PlaybackSessionState {
    PlaybackSessionState {
        current_track_id: row.current_song_id,
        progress_seconds: row.progress_seconds,
        volume: row.volume,
        shuffle_enabled: row.shuffle_enabled,
        repeat_mode: row.repeat_mode,
        queue: serde_json::from_str(&row.queue_snapshot).unwrap_or_default(),
        queue_position: row.queue_position as u64,
        source_context: row.source_context,
        updated_at: row.updated_at,
    }
}

fn session_to_row(session: PlaybackSessionState) -> Result<LastSession, String> {
    Ok(LastSession {
        current_song_id: session.current_track_id,
        progress_seconds: session.progress_seconds,
        volume: session.volume,
        shuffle_enabled: session.shuffle_enabled,
        repeat_mode: session.repeat_mode,
        queue_snapshot: serde_json::to_string(&session.queue).map_err(|error| error.to_string())?,
        queue_position: session.queue_position as i64,
        source_context: session.source_context,
        updated_at: session.updated_at,
    })
}
