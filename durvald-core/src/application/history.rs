//! Playback-history use-case coordination.

use std::sync::Arc;

use crate::api::{CoreError, CoreResult, PlaybackHistoryItem, PlaybackHistoryPage};

type DatabasePool = r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>;

pub(crate) struct HistoryApplication {
    db_pool: Arc<DatabasePool>,
}

impl HistoryApplication {
    pub(crate) fn new(db_pool: Arc<DatabasePool>) -> Self {
        Self { db_pool }
    }

    pub(crate) async fn playback_history(&self) -> CoreResult<Vec<PlaybackHistoryItem>> {
        self.run_database(|conn| {
            crate::database::operations::get_play_history(conn)
                .map(|history| history.into_iter().map(history_from_database).collect())
                .map_err(|error| error.to_string())
        })
        .await
    }

    pub(crate) async fn playback_history_page(
        &self,
        page_size: u64,
        offset: u64,
    ) -> CoreResult<PlaybackHistoryPage> {
        let (fetch_size, page_size) = pagination_window(page_size, offset)?;
        let history = self
            .run_database(move |conn| {
                crate::database::operations::get_play_history_page(conn, fetch_size, offset)
                    .map_err(|error| error.to_string())
            })
            .await?
            .into_iter()
            .map(history_from_database)
            .collect();
        let (items, next_offset) = finish_page(history, page_size, offset);
        Ok(PlaybackHistoryPage { items, next_offset })
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
}

const MAX_HISTORY_PAGE_SIZE: u64 = 200;

fn pagination_window(page_size: u64, offset: u64) -> CoreResult<(u64, usize)> {
    if page_size == 0 {
        return Err(CoreError::InvalidInput {
            message: "Page size must be greater than zero".to_string(),
        });
    }
    if offset > i64::MAX as u64 {
        return Err(CoreError::InvalidInput {
            message: "Page offset is too large".to_string(),
        });
    }
    let page_size = page_size.min(MAX_HISTORY_PAGE_SIZE);
    Ok((page_size + 1, page_size as usize))
}

fn finish_page<T>(mut items: Vec<T>, page_size: usize, offset: u64) -> (Vec<T>, Option<u64>) {
    let has_more = items.len() > page_size;
    items.truncate(page_size);
    let next_offset = has_more.then(|| offset.saturating_add(page_size as u64));
    (items, next_offset)
}

fn history_from_database(item: crate::database::models::PlayHistory) -> PlaybackHistoryItem {
    PlaybackHistoryItem {
        id: item.history_id as i64,
        track_id: item.song_id as i64,
        played_at: item.played_at,
        duration_seconds: item.duration,
    }
}
