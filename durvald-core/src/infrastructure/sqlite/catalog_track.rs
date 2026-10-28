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

    pub(crate) async fn save_remote(
        &self,
        entry: crate::api::CatalogEntry,
    ) -> crate::api::CoreResult<CatalogTrack> {
        let pool = self.db_pool.clone();
        let id = tokio::task::spawn_blocking(move || {
            let mut conn = pool.get().map_err(|e| crate::api::CoreError::Storage {
                message: e.to_string(),
            })?;
            crate::database::source_catalog::save_remote(&mut conn, &entry).map_err(|e| {
                crate::api::CoreError::Storage {
                    message: e.to_string(),
                }
            })
        })
        .await
        .map_err(|e| crate::api::CoreError::Storage {
            message: e.to_string(),
        })??;
        self.find(TrackId::from_persisted(id as u64))
            .await
            .map_err(|_| crate::api::CoreError::NotFound {
                message: "Saved track disappeared".into(),
            })
    }

    pub(crate) async fn embedded_source_url(
        &self,
        track: i64,
        source: i64,
    ) -> crate::api::CoreResult<String> {
        let pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            let c = pool.get().map_err(|e| crate::api::CoreError::Storage { message: e.to_string() })?;
            let url: String = c.query_row("SELECT canonical_url FROM track_sources WHERE song_id=?1 AND source_id=?2 AND provider='soundcloud' AND enabled=1", [track, source], |r| r.get(0)).map_err(|_| crate::api::CoreError::InvalidInput { message: "Choose an enabled SoundCloud source belonging to this track".into() })?;
            crate::infrastructure::service_links::canonical_link(&url).filter(|r| r.entity().provider().as_str() == "soundcloud").map(|r| r.canonical_url().as_str().to_owned()).ok_or_else(|| crate::api::CoreError::InvalidInput { message: "Unsupported SoundCloud track URL".into() })
        }).await.map_err(|e| crate::api::CoreError::Storage { message: e.to_string() })?
    }

    pub(crate) async fn source_media_path(
        &self,
        track: i64,
        source: i64,
    ) -> crate::api::CoreResult<String> {
        let pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move||{
            let c=pool.get().map_err(|e|crate::api::CoreError::Storage{message:e.to_string()})?;
            let (path,provider,enabled)=c.query_row("SELECT local_path,provider,enabled FROM track_sources WHERE source_id=?1 AND song_id=?2",[source,track],|r|Ok((r.get::<_,Option<String>>(0)?,r.get::<_,String>(1)?,r.get::<_,bool>(2)?))).map_err(|_|crate::api::CoreError::NotFound{message:"Source does not belong to this track".into()})?;
            if provider!="local" || !enabled {return Err(crate::api::CoreError::Playback{message:"This source cannot play as native audio; open its service page instead".into()});}
            path.ok_or_else(||crate::api::CoreError::Playback{message:"Source has no local file".into()})
        }).await.map_err(|e|crate::api::CoreError::Storage{message:e.to_string()})?
    }

    pub(crate) async fn local_media_paths(
        &self,
        song_id: i64,
    ) -> crate::api::CoreResult<Vec<String>> {
        let pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = pool.get().map_err(|e| crate::api::CoreError::Storage { message:e.to_string() })?;
            let mut statement = conn.prepare("SELECT s.local_path FROM track_sources s LEFT JOIN playback_source_preferences p ON p.source_id=s.source_id AND p.song_id=s.song_id WHERE s.song_id=?1 AND s.provider='local' AND s.enabled=1 ORDER BY (p.source_id IS NOT NULL) DESC,s.priority DESC,s.is_primary_local DESC,s.source_id").map_err(|e|crate::api::CoreError::Storage {message:e.to_string()})?;
            statement.query_map([song_id], |r|r.get(0)).map_err(|e|crate::api::CoreError::Storage {message:e.to_string()})?.collect::<Result<Vec<_>,_>>().map_err(|e|crate::api::CoreError::Storage {message:e.to_string()})
        }).await.map_err(|e|crate::api::CoreError::Storage {message:e.to_string()})?
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

    pub(crate) async fn find_many(
        &self,
        track_ids: Vec<TrackId>,
    ) -> Result<Vec<CatalogTrack>, CatalogTrackLookupError> {
        let db_pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = db_pool
                .get()
                .map_err(|error| CatalogTrackLookupError::Storage(error.to_string()))?;
            let ids: Vec<u64> = track_ids
                .into_iter()
                .map(|id| id.get())
                .collect::<std::collections::BTreeSet<_>>()
                .into_iter()
                .collect();
            let mut tracks = Vec::new();
            for chunk in ids.chunks(400) {
                tracks.extend(
                    crate::database::operations::get_songs_by_ids(&conn, chunk)
                        .map_err(|error| CatalogTrackLookupError::Storage(error.to_string()))?
                        .into_iter()
                        .map(track_from_row),
                );
            }
            Ok(tracks)
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

pub(crate) fn track_from_row(row: SongItem) -> CatalogTrack {
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
        rating_half_steps: row.rating_half_steps,
        is_favorite: row.is_favorite,
        is_hidden: row.is_hidden,
        suggest_less: row.suggest_less,
        file_path: row.file_path,
    }
}
