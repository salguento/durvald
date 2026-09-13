//! Database module - core data models and operations without Tauri dependencies

pub mod enrichment;
pub mod migrations;
pub mod models;
pub mod operations;

pub use models::*;
pub use operations::*;

pub mod identity;

pub(crate) fn storage_error(
    context: &'static str,
    error: impl std::fmt::Display + 'static,
) -> crate::api::CoreError {
    let any = &error as &dyn std::any::Any;
    if let Some(rusqlite::Error::SqliteFailure(sqlite, _)) = any.downcast_ref::<rusqlite::Error>() {
        // Do not include SQL, bound values, paths, or provider payloads in the
        // diagnostic consumed by the retry coordinator.
        return crate::api::CoreError::Storage {
            message: format!(
                "{context}: SQLite failure (code={:?}, extended_code={})",
                sqlite.code, sqlite.extended_code
            ),
        };
    }
    crate::api::CoreError::Storage {
        message: format!("{context}: {error}"),
    }
}

pub(crate) fn sqlite_busy_extended_code(error: &crate::api::CoreError) -> Option<i32> {
    let crate::api::CoreError::Storage { message } = error else {
        return None;
    };
    if !(message.contains("code=DatabaseBusy") || message.contains("code=DatabaseLocked")) {
        return None;
    }
    let value = message.split("extended_code=").nth(1)?.strip_suffix(')')?;
    value.parse().ok()
}
