//! Playback-history use-case coordination.

use crate::api::{CoreError, CoreResult, PlaybackHistoryItem, PlaybackHistoryPage};
use crate::domain::ids::PlaybackHistoryId;
use crate::domain::playback_history::PlaybackHistoryEntry;
use crate::infrastructure::sqlite::playback_history::SqlitePlaybackHistoryRepository;

pub(crate) struct HistoryApplication {
    repository: SqlitePlaybackHistoryRepository,
}

impl HistoryApplication {
    pub(crate) fn new(repository: SqlitePlaybackHistoryRepository) -> Self {
        Self { repository }
    }

    pub(crate) async fn playback_history(&self) -> CoreResult<Vec<PlaybackHistoryItem>> {
        self.repository
            .all()
            .await
            .map(|history| history.into_iter().map(history_to_api).collect())
            .map_err(storage_error)
    }

    pub(crate) async fn playback_history_page(
        &self,
        page_size: u64,
        offset: u64,
    ) -> CoreResult<PlaybackHistoryPage> {
        let (fetch_size, page_size) = pagination_window(page_size, offset)?;
        let history = self
            .repository
            .page(fetch_size, offset)
            .await
            .map_err(storage_error)?
            .into_iter()
            .map(history_to_api)
            .collect();
        let (items, next_offset) = finish_page(history, page_size, offset);
        Ok(PlaybackHistoryPage { items, next_offset })
    }

    pub(crate) async fn remove_playback_history_item(
        &self,
        history_id: PlaybackHistoryId,
    ) -> CoreResult<()> {
        let removed = self
            .repository
            .remove(history_id)
            .await
            .map_err(storage_error)?;
        if !removed {
            return Err(CoreError::NotFound {
                message: format!("Playback history item {} not found", history_id.get()),
            });
        }
        Ok(())
    }

    pub(crate) async fn clear_playback_history(&self) -> CoreResult<u64> {
        self.repository.clear().await.map_err(storage_error)
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

fn history_to_api(item: PlaybackHistoryEntry) -> PlaybackHistoryItem {
    PlaybackHistoryItem {
        id: item.id.get() as i64,
        track_id: item.track_id.get() as i64,
        played_at: item.played_at,
        duration_seconds: item.duration_seconds,
    }
}

fn storage_error(message: String) -> CoreError {
    CoreError::Storage { message }
}
