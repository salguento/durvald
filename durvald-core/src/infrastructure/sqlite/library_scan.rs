//! SQLite-backed persistence for library scans.

use std::sync::{Arc, atomic::AtomicBool};

use crate::database::operations::PendingDatabaseUpdate;

type DatabasePool = r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>;

pub(crate) struct SqliteLibraryScanRepository {
    db_pool: Arc<DatabasePool>,
}

impl SqliteLibraryScanRepository {
    pub(crate) fn new(db_pool: Arc<DatabasePool>) -> Self {
        Self { db_pool }
    }

    pub(crate) async fn prepare(
        &self,
        path: String,
        cancellation: Arc<AtomicBool>,
    ) -> Result<PendingDatabaseUpdate, String> {
        let db_pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = db_pool.get().map_err(|error| error.to_string())?;
            crate::database::operations::prepare_database_update_with_cancel(
                &conn,
                path,
                Some(cancellation.as_ref()),
            )
            .map_err(|error| error.to_string())
        })
        .await
        .map_err(|error| format!("Library scan preparation task failed: {error}"))?
    }
}
