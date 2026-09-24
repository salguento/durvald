//! SQLite persistence for the last playback session.

use std::sync::Arc;

use crate::database::models::LastSession;

type DatabasePool = r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>;

pub(crate) struct SqlitePlaybackSessionRepository {
    db_pool: Arc<DatabasePool>,
}

impl SqlitePlaybackSessionRepository {
    pub(crate) fn new(db_pool: Arc<DatabasePool>) -> Self {
        Self { db_pool }
    }

    pub(crate) async fn load(&self) -> Result<LastSession, String> {
        let db_pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = db_pool.get().map_err(|error| error.to_string())?;
            crate::database::operations::get_last_session(&conn).map_err(|error| error.to_string())
        })
        .await
        .map_err(|error| format!("Last-session query task failed: {error}"))?
    }

    pub(crate) async fn save_preserving_source_context(
        &self,
        mut session: LastSession,
    ) -> Result<(), String> {
        let db_pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = db_pool.get().map_err(|error| error.to_string())?;
            let previous = crate::database::operations::get_last_session(&conn)
                .map_err(|error| error.to_string())?;
            session.source_context = previous.source_context;
            crate::database::operations::save_last_session(&conn, &session)
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
