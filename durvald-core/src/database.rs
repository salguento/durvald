//! Database module - core data models and operations without Tauri dependencies

pub mod enrichment;
pub(crate) mod local_sources;
pub mod migrations;
pub mod models;
pub mod operations;
pub(crate) mod replay_description;
pub(crate) mod retrospective_playlists;
pub(crate) mod source_catalog;

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

pub(crate) mod ratings;

pub(crate) mod album_collections;
pub(crate) mod artist_news;
pub(crate) mod classification;
pub(crate) mod recommendations;
pub(crate) mod user_tags;

pub(crate) mod listen_list;
