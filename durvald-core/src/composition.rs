use crate::api::{CoreConfig, CoreError, CoreResult, RepeatMode};
use std::sync::Arc;

pub(crate) type DatabasePool = r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>;

pub(crate) struct PlaybackBootstrap {
    pub(crate) volume: f64,
    pub(crate) current_track: Option<(i64, String)>,
    pub(crate) upcoming_tracks: Vec<(i64, String)>,
    pub(crate) progress_seconds: f64,
    pub(crate) shuffle_enabled: bool,
    pub(crate) repeat_mode: RepeatMode,
}

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

pub(crate) fn restore_playback(pool: &DatabasePool) -> CoreResult<PlaybackBootstrap> {
    let connection = pool.get().map_err(storage_error)?;
    let saved_session =
        crate::database::operations::get_last_session(&connection).map_err(storage_error)?;
    let queue_ids =
        serde_json::from_str::<Vec<i64>>(&saved_session.queue_snapshot).unwrap_or_default();
    let track_path = |track_id: i64| {
        crate::database::operations::get_song_by_id(&connection, &track_id.to_string())
            .ok()
            .and_then(|tracks| tracks.into_iter().next())
            .map(|track| (track_id, track.file_path))
    };
    let current_track = saved_session.current_song_id.and_then(track_path);
    let mut skipped_current = false;
    let upcoming_tracks = queue_ids
        .into_iter()
        .filter_map(|track_id| {
            if !skipped_current && Some(track_id) == saved_session.current_song_id {
                skipped_current = true;
                None
            } else {
                track_path(track_id)
            }
        })
        .collect();

    Ok(PlaybackBootstrap {
        volume: saved_session.volume,
        current_track,
        upcoming_tracks,
        progress_seconds: saved_session.progress_seconds,
        shuffle_enabled: saved_session.shuffle_enabled,
        repeat_mode: repeat_mode_from_string(&saved_session.repeat_mode),
    })
}

fn repeat_mode_from_string(mode: &str) -> RepeatMode {
    match mode {
        "one" => RepeatMode::One,
        "all" => RepeatMode::All,
        _ => RepeatMode::None,
    }
}

fn storage_error(error: impl std::fmt::Display) -> CoreError {
    CoreError::Storage {
        message: error.to_string(),
    }
}
