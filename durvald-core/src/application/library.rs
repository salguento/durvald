//! Library use-case coordination.
//!
//! Responsibilities move here incrementally while [`crate::core::DurvaldCore`]
//! remains the stable public facade.

use std::sync::Arc;

use crate::api::{CoreError, CoreResult};

type DatabasePool = r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>;

/// Coordinates library use cases behind the public core facade.
pub(crate) struct LibraryApplication {
    db_pool: Arc<DatabasePool>,
}

impl LibraryApplication {
    pub(crate) fn new(db_pool: Arc<DatabasePool>) -> Self {
        Self { db_pool }
    }

    pub(crate) async fn add_library_path(&self, path: String) -> CoreResult<()> {
        self.run_database_core(move |conn| {
            if !std::path::Path::new(&path).is_dir() {
                return Err(CoreError::InvalidInput {
                    message: format!("Library path is not a directory: {path}"),
                });
            }
            crate::database::operations::add_library_path(conn, path).map_err(|error| {
                CoreError::Storage {
                    message: error.to_string(),
                }
            })
        })
        .await
    }

    pub(crate) async fn library_paths(&self) -> CoreResult<Vec<String>> {
        self.run_database(|conn| {
            crate::database::operations::get_library_paths(conn)
                .map(|paths| paths.into_iter().map(|path| path.path).collect())
                .map_err(|error| error.to_string())
        })
        .await
    }

    pub(crate) async fn remove_library_path(&self, path: String) -> CoreResult<()> {
        self.run_database_core(move |conn| {
            let removed =
                crate::database::operations::remove_library_path(conn, &path).map_err(|error| {
                    CoreError::Storage {
                        message: error.to_string(),
                    }
                })?;
            if !removed {
                return Err(CoreError::NotFound {
                    message: format!("Library path is not configured: {path}"),
                });
            }
            Ok(())
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
}
