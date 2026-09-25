use crate::api::{CoreConfig, CoreError, CoreResult};
use std::sync::Arc;

pub(crate) type DatabasePool = r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>;

pub(crate) fn prepare_filesystem(config: &CoreConfig) -> CoreResult<()> {
    std::fs::create_dir_all(&config.app_support_dir).map_err(storage_error)?;
    std::fs::create_dir_all(&config.covers_dir).map_err(storage_error)?;
    Ok(())
}

pub(crate) fn open_database(config: &CoreConfig) -> CoreResult<Arc<DatabasePool>> {
    let manager = r2d2_sqlite::SqliteConnectionManager::file(&config.database_path).with_init(
        |connection: &mut rusqlite::Connection| {
            connection.execute_batch(
                "PRAGMA journal_mode = WAL;\n PRAGMA busy_timeout = 5000;\n PRAGMA foreign_keys = ON;",
            )?;
            Ok(())
        },
    );
    let pool = r2d2::Pool::new(manager).map_err(storage_error)?;

    {
        let mut connection = pool.get().map_err(storage_error)?;
        crate::database::operations::create_tables(&connection).map_err(storage_error)?;
        crate::database::migrations::migrate_enrichment(&mut connection).map_err(storage_error)?;
        crate::database::operations::initiate_settings(&connection).map_err(storage_error)?;
        crate::database::operations::initiate_last_session(&connection).map_err(storage_error)?;
    }

    Ok(Arc::new(pool))
}

fn storage_error(error: impl std::fmt::Display) -> CoreError {
    CoreError::Storage {
        message: error.to_string(),
    }
}
