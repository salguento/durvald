//! SQLite lookup for an individual catalog track.

use std::sync::Arc;

use crate::{
    database::models::SongItem,
    domain::{
        catalog::CatalogTrack,
        ids::{ArtistId, ReleaseId, TrackId},
    },
};

type DatabasePool = r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>;

pub(crate) enum CatalogTrackLookupError {
    NotFound,
    Storage(String),
}

pub(crate) struct SqliteCatalogTrackQuery {
    db_pool: Arc<DatabasePool>,
}

impl SqliteCatalogTrackQuery {
    pub(crate) fn new(db_pool: Arc<DatabasePool>) -> Self {
        Self { db_pool }
    }

    pub(crate) async fn find(
        &self,
        track_id: TrackId,
    ) -> Result<CatalogTrack, CatalogTrackLookupError> {
        let db_pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = db_pool
                .get()
                .map_err(|error| CatalogTrackLookupError::Storage(error.to_string()))?;
            crate::database::operations::get_song_by_id(&conn, &track_id.get().to_string())
                .map_err(|error| CatalogTrackLookupError::Storage(error.to_string()))?
                .into_iter()
                .next()
                .map(track_from_row)
                .ok_or(CatalogTrackLookupError::NotFound)
        })
        .await
        .map_err(|error| {
            CatalogTrackLookupError::Storage(format!("Blocking database task failed: {error}"))
        })?
    }

    pub(crate) async fn all(&self) -> Result<Vec<CatalogTrack>, CatalogTrackLookupError> {
        let db_pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = db_pool
                .get()
                .map_err(|error| CatalogTrackLookupError::Storage(error.to_string()))?;
            crate::database::operations::get_all_tracks(&conn)
                .map(|tracks| tracks.into_iter().map(track_from_row).collect())
                .map_err(|error| CatalogTrackLookupError::Storage(error.to_string()))
        })
        .await
        .map_err(|error| {
            CatalogTrackLookupError::Storage(format!("Blocking database task failed: {error}"))
        })?
    }

    pub(crate) async fn page(
        &self,
        fetch_size: u64,
        offset: u64,
    ) -> Result<Vec<CatalogTrack>, CatalogTrackLookupError> {
        let db_pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = db_pool
                .get()
                .map_err(|error| CatalogTrackLookupError::Storage(error.to_string()))?;
            crate::database::operations::get_tracks_page(&conn, fetch_size, offset)
                .map(|tracks| tracks.into_iter().map(track_from_row).collect())
                .map_err(|error| CatalogTrackLookupError::Storage(error.to_string()))
        })
        .await
        .map_err(|error| {
            CatalogTrackLookupError::Storage(format!("Blocking database task failed: {error}"))
        })?
    }
}

fn track_from_row(row: SongItem) -> CatalogTrack {
    CatalogTrack {
        id: TrackId::from_persisted(row.song_id),
        title: row.title,
        artwork: row.artwork,
        artist_id: ArtistId::from_persisted(row.artist_id),
        artist_name: row.artist_name,
        release_id: ReleaseId::from_persisted(row.release_id),
        release_title: row.release_title,
        track_number: row.track_number,
        disc_number: row.disc_number,
        duration_seconds: row.duration,
        bitrate: row.bitrate,
        sample_rate: row.sample_rate,
        bit_depth: row.bit_depth,
        play_count: row.play_count,
        last_played: row.last_played,
        rating: row.rating,
        is_favorite: row.is_favorite,
        is_hidden: row.is_hidden,
        suggest_less: row.suggest_less,
        file_path: row.file_path,
    }
}
