//! SQLite persistence for configured library paths.

use std::sync::Arc;

type DatabasePool = r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>;

pub(crate) struct SqliteLibraryPathsRepository {
    db_pool: Arc<DatabasePool>,
}

impl SqliteLibraryPathsRepository {
    pub(crate) fn new(db_pool: Arc<DatabasePool>) -> Self {
        Self { db_pool }
    }

    pub(crate) async fn add(&self, path: String) -> Result<(), String> {
        self.run(move |conn| {
            crate::database::operations::add_library_path(conn, path)
                .map_err(|error| error.to_string())
        })
        .await
    }

    pub(crate) async fn all(&self) -> Result<Vec<String>, String> {
        self.run(|conn| {
            crate::database::operations::get_library_paths(conn)
                .map(|paths| paths.into_iter().map(|path| path.path).collect())
                .map_err(|error| error.to_string())
        })
        .await
    }

    pub(crate) async fn remove(&self, path: String) -> Result<bool, String> {
        self.run(move |conn| {
            crate::database::operations::remove_library_path(conn, &path)
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
