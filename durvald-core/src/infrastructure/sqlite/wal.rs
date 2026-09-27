//! Non-blocking WAL maintenance for large background write batches.

use std::{path::PathBuf, time::Duration};

/// Keep routine interactive writes below SQLite's normal auto-checkpoint path.
/// Large background batches get an additional passive opportunity only after
/// the WAL has grown well beyond the measured ~1 MiB baseline.
pub(crate) const LARGE_BATCH_WAL_BYTES: u64 = 8 * 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct WalCheckpointMetrics {
    pub(crate) wal_bytes_before: u64,
    pub(crate) busy: bool,
    pub(crate) log_frames: u64,
    pub(crate) checkpointed_frames: u64,
    pub(crate) elapsed: Duration,
}

/// Measures the WAL first and runs a PASSIVE checkpoint only above `min_bytes`.
/// PASSIVE never waits for readers or writers; an incomplete checkpoint is a
/// successful measurement and will be retried after a future background batch.
pub(crate) fn passive_checkpoint_if_large(
    conn: &rusqlite::Connection,
    min_bytes: u64,
) -> rusqlite::Result<Option<WalCheckpointMetrics>> {
    let database_path: String = conn.query_row(
        "SELECT file FROM pragma_database_list WHERE name = 'main'",
        [],
        |row| row.get(0),
    )?;
    if database_path.is_empty() {
        return Ok(None);
    }
    let wal_path = PathBuf::from(format!("{database_path}-wal"));
    let wal_bytes_before = match std::fs::metadata(wal_path) {
        Ok(metadata) => metadata.len(),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(rusqlite::Error::ToSqlConversionFailure(Box::new(error))),
    };
    if wal_bytes_before < min_bytes {
        return Ok(None);
    }

    let started = std::time::Instant::now();
    let (busy, log_frames, checkpointed_frames) =
        conn.query_row("PRAGMA wal_checkpoint(PASSIVE)", [], |row| {
            Ok((
                row.get::<_, u64>(0)? != 0,
                row.get::<_, u64>(1)?,
                row.get::<_, u64>(2)?,
            ))
        })?;
    Ok(Some(WalCheckpointMetrics {
        wal_bytes_before,
        busy,
        log_frames,
        checkpointed_frames,
        elapsed: started.elapsed(),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn skips_in_memory_and_small_wals() {
        let memory = rusqlite::Connection::open_in_memory().unwrap();
        assert!(passive_checkpoint_if_large(&memory, 0).unwrap().is_none());

        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("small.sqlite");
        let file = rusqlite::Connection::open(path).unwrap();
        file.execute_batch("PRAGMA journal_mode = WAL; CREATE TABLE sample(id INTEGER);")
            .unwrap();
        assert!(
            passive_checkpoint_if_large(&file, u64::MAX)
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn reports_passive_checkpoint_measurements() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("measured.sqlite");
        let file = rusqlite::Connection::open(path).unwrap();
        file.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA wal_autocheckpoint = 0;
             CREATE TABLE sample(id INTEGER);
             INSERT INTO sample VALUES (1);",
        )
        .unwrap();

        let metrics = passive_checkpoint_if_large(&file, 0).unwrap().unwrap();
        assert!(metrics.wal_bytes_before > 0);
        assert!(!metrics.busy);
        assert!(metrics.log_frames > 0);
        assert_eq!(metrics.checkpointed_frames, metrics.log_frames);
        assert!(metrics.elapsed <= Duration::from_secs(5));
    }
}
