//! SQLite-backed catalog search.

use std::sync::Arc;

use crate::database::operations::LibrarySearchResults;

type DatabasePool = r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>;

pub(crate) struct SqliteCatalogSearchQuery {
    db_pool: Arc<DatabasePool>,
}

impl SqliteCatalogSearchQuery {
    pub(crate) fn new(db_pool: Arc<DatabasePool>) -> Self {
        Self { db_pool }
    }

    pub(crate) async fn search(&self, query: String) -> Result<LibrarySearchResults, String> {
        let db_pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = db_pool.get().map_err(|error| error.to_string())?;
            crate::database::operations::search_library(&conn, &query)
                .map_err(|error| error.to_string())
        })
        .await
        .map_err(|error| format!("Blocking database task failed: {error}"))?
    }
}
