//! Library use-case coordination.
//!
//! Responsibilities move here incrementally while [`crate::core::DurvaldCore`]
//! remains the stable public facade.

use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};

use base64::Engine;

use crate::api::{
    Artist, CoreError, CoreResult, Playlist, Release, ReleasePage, ScanPhase, ScanProgress,
    ScanResult, SearchResults, Track, TrackPage,
};

type DatabasePool = r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>;

/// Coordinates library use cases behind the public core facade.
pub(crate) struct LibraryApplication {
    db_pool: Arc<DatabasePool>,
    covers_dir: String,
    metadata_edit_queue: Arc<tokio::sync::Mutex<()>>,
    scan_in_progress: Arc<AtomicBool>,
    scan_cancel_requested: Arc<AtomicBool>,
    scan_progress: Arc<std::sync::Mutex<Option<ScanProgress>>>,
}

impl LibraryApplication {
    pub(crate) fn new(
        db_pool: Arc<DatabasePool>,
        covers_dir: String,
        metadata_edit_queue: Arc<tokio::sync::Mutex<()>>,
    ) -> Self {
        Self {
            db_pool,
            covers_dir,
            metadata_edit_queue,
            scan_in_progress: Arc::new(AtomicBool::new(false)),
            scan_cancel_requested: Arc::new(AtomicBool::new(false)),
            scan_progress: Arc::new(std::sync::Mutex::new(None)),
        }
    }

    pub(crate) async fn scan_library(&self, paths: Vec<String>) -> CoreResult<ScanResult> {
        if self
            .scan_in_progress
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return Err(CoreError::InvalidInput {
                message: "A library scan is already in progress".to_string(),
            });
        }
        self.scan_cancel_requested.store(false, Ordering::Release);
        let _metadata_lane = self.metadata_edit_queue.lock().await;

        let mut total_files = 0_u64;
        let mut new_tracks = 0_u64;
        let mut updated_tracks = 0_u64;
        let mut errors = Vec::new();
        let mut paths_scanned = 0;

        for path in &paths {
            if self.scan_cancel_requested.load(Ordering::Acquire) {
                errors.push("Library scan cancelled".to_string());
                break;
            }
            paths_scanned += 1;
            self.update_scan_progress(ScanProgress {
                path: path.clone(),
                phase: ScanPhase::Scanning,
                total_files,
                processed_files: 0,
                new_tracks,
            });

            let db_pool = self.db_pool.clone();
            let cancellation = self.scan_cancel_requested.clone();
            let scan_path = path.clone();
            let pending = tokio::task::spawn_blocking(move || {
                let conn = db_pool.get().map_err(|error| error.to_string())?;
                crate::database::operations::prepare_database_update_with_cancel(
                    &conn,
                    scan_path,
                    Some(cancellation.as_ref()),
                )
                .map_err(|error| error.to_string())
            })
            .await;
            let pending = match pending {
                Ok(Ok(pending)) => pending,
                Ok(Err(message)) => {
                    errors.push(format!("{path}: {message}"));
                    continue;
                }
                Err(error) => {
                    errors.push(format!(
                        "{path}: Library scan preparation task failed: {error}"
                    ));
                    continue;
                }
            };
            let path_total = pending.total_files() as u64;
            let (metadata_batches, reconciliation) = pending.into_metadata_batches();
            self.update_scan_progress(ScanProgress {
                path: path.clone(),
                phase: ScanPhase::ExtractingMetadata,
                total_files: path_total,
                processed_files: 0,
                new_tracks: 0,
            });

            let progress_state = self.scan_progress.clone();
            let progress_path = path.clone();
            let metadata_progress = move |processed_files: usize| {
                if let Ok(mut progress) = progress_state.lock() {
                    *progress = Some(ScanProgress {
                        path: progress_path.clone(),
                        phase: ScanPhase::ExtractingMetadata,
                        total_files: path_total,
                        processed_files: processed_files as u64,
                        new_tracks: 0,
                    });
                }
            };
            let mut path_failed = false;
            for batch in metadata_batches {
                let mut extracted =
                    crate::database::operations::extract_metadata_batch_with_cancel(
                        batch,
                        &std::path::PathBuf::from(&self.covers_dir),
                        Some(self.scan_cancel_requested.clone()),
                        Some(&metadata_progress),
                    )
                    .await;
                errors.append(&mut extracted.errors);
                if self.scan_cancel_requested.load(Ordering::Acquire) {
                    break;
                }
                self.update_scan_progress(ScanProgress {
                    path: path.clone(),
                    phase: ScanPhase::WritingDatabase,
                    total_files: path_total,
                    processed_files: extracted.attempted_files as u64,
                    new_tracks,
                });

                let db_pool = self.db_pool.clone();
                let write_result = tokio::task::spawn_blocking(move || {
                    let conn = db_pool.get().map_err(|error| error.to_string())?;
                    crate::database::operations::persist_metadata_with_existing_ids(
                        &conn,
                        extracted.metadata,
                        extracted.mtimes,
                        extracted.existing_song_ids,
                    )
                    .map_err(|error| error.to_string())
                })
                .await;
                match write_result {
                    Ok(Ok(written)) => {
                        new_tracks += written.added_tracks as u64;
                        updated_tracks += written.updated_tracks as u64;
                    }
                    Ok(Err(error)) => {
                        errors.push(format!("{path}: {error}"));
                        path_failed = true;
                        break;
                    }
                    Err(error) => {
                        errors.push(format!(
                            "{path}: Library database write task failed: {error}"
                        ));
                        path_failed = true;
                        break;
                    }
                }
            }

            if self.scan_cancel_requested.load(Ordering::Acquire) {
                errors.push("Library scan cancelled".to_string());
                break;
            }
            if path_failed {
                continue;
            }

            if let Some(reconciliation) = reconciliation {
                let db_pool = self.db_pool.clone();
                let reconcile_result = tokio::task::spawn_blocking(move || {
                    let conn = db_pool.get().map_err(|error| error.to_string())?;
                    crate::database::operations::remove_missing_songs_in_folder(
                        &conn,
                        reconciliation,
                    )
                    .map_err(|error| error.to_string())
                })
                .await;
                if let Err(error) = reconcile_result
                    .map_err(|error| error.to_string())
                    .and_then(|result| result)
                {
                    errors.push(format!("{path}: {error}"));
                    continue;
                }
            }
            total_files += path_total;
        }

        self.scan_in_progress.store(false, Ordering::Release);
        self.update_scan_progress(ScanProgress {
            path: paths.last().cloned().unwrap_or_default(),
            phase: ScanPhase::Complete,
            total_files,
            processed_files: total_files,
            new_tracks,
        });

        Ok(ScanResult {
            paths_scanned,
            total_files_found: total_files,
            new_tracks_added: new_tracks,
            updated_tracks,
            errors,
        })
    }

    pub(crate) async fn scan_configured_library(&self) -> CoreResult<ScanResult> {
        let paths = self.library_paths().await?;
        if paths.is_empty() {
            return Err(CoreError::InvalidInput {
                message: "No library folders are configured".to_string(),
            });
        }
        self.scan_library(paths).await
    }

    pub(crate) fn scan_progress(&self) -> CoreResult<Option<ScanProgress>> {
        self.scan_progress
            .lock()
            .map(|progress| progress.clone())
            .map_err(|_| CoreError::Storage {
                message: "Library scan progress state is unavailable".to_string(),
            })
    }

    pub(crate) fn cancel_library_scan(&self) -> CoreResult<()> {
        if !self.scan_in_progress.load(Ordering::Acquire) {
            return Err(CoreError::NotFound {
                message: "No library scan is in progress".to_string(),
            });
        }
        self.scan_cancel_requested.store(true, Ordering::Release);
        Ok(())
    }

    fn update_scan_progress(&self, progress: ScanProgress) {
        if let Ok(mut current) = self.scan_progress.lock() {
            *current = Some(progress);
        }
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

    pub(crate) async fn search(&self, query: String) -> CoreResult<SearchResults> {
        if query.trim().is_empty() {
            return Err(CoreError::InvalidInput {
                message: "Search query cannot be empty".to_string(),
            });
        }

        let query = query.trim().to_owned();
        let results = self
            .run_database(move |conn| {
                crate::database::operations::search_library(conn, &query)
                    .map_err(|error| error.to_string())
            })
            .await?;

        Ok(SearchResults {
            tracks: results.tracks.into_iter().map(track_from_song).collect(),
            releases: results
                .releases
                .into_iter()
                .map(release_from_database)
                .collect(),
            artists: results
                .artists
                .into_iter()
                .map(|artist| Artist {
                    id: artist.artist_id as i64,
                    name: artist.artist_name,
                })
                .collect(),
            playlists: results
                .playlists
                .into_iter()
                .map(|playlist| Playlist {
                    id: playlist.id as i64,
                    name: playlist.name,
                    description: playlist.description,
                    artwork_id: playlist
                        .cover
                        .map(|cover| base64::engine::general_purpose::STANDARD.encode(cover)),
                    is_favorite: playlist.is_favorite,
                    suggest_less: playlist.suggest_less,
                    track_count: 0,
                    created_at: playlist.created_at,
                    updated_at: playlist.updated_at,
                })
                .collect(),
        })
    }

    pub(crate) async fn tracks(&self) -> CoreResult<Vec<Track>> {
        self.run_database(|conn| {
            crate::database::operations::get_all_tracks(conn)
                .map(|tracks| tracks.into_iter().map(track_from_song).collect())
                .map_err(|error| error.to_string())
        })
        .await
    }

    pub(crate) async fn tracks_page(&self, page_size: u64, offset: u64) -> CoreResult<TrackPage> {
        let (fetch_size, page_size) = pagination_window(page_size, offset)?;
        let tracks = self
            .run_database(move |conn| {
                crate::database::operations::get_tracks_page(conn, fetch_size, offset)
                    .map_err(|error| error.to_string())
            })
            .await?
            .into_iter()
            .map(track_from_song)
            .collect();
        let (items, next_offset) = finish_page(tracks, page_size, offset);
        Ok(TrackPage { items, next_offset })
    }

    pub(crate) async fn releases(&self) -> CoreResult<Vec<Release>> {
        self.run_database(|conn| {
            crate::database::operations::get_all_releases(conn)
                .map(|releases| releases.into_iter().map(release_from_database).collect())
                .map_err(|error| error.to_string())
        })
        .await
    }

    pub(crate) async fn releases_page(
        &self,
        page_size: u64,
        offset: u64,
    ) -> CoreResult<ReleasePage> {
        let (fetch_size, page_size) = pagination_window(page_size, offset)?;
        let releases = self
            .run_database(move |conn| {
                crate::database::operations::get_releases_page(conn, fetch_size, offset)
                    .map_err(|error| error.to_string())
            })
            .await?
            .into_iter()
            .map(release_from_database)
            .collect();
        let (items, next_offset) = finish_page(releases, page_size, offset);
        Ok(ReleasePage { items, next_offset })
    }

    pub(crate) async fn artists(&self) -> CoreResult<Vec<Artist>> {
        self.run_database(|conn| {
            crate::database::operations::get_all_artists(conn)
                .map(|artists| {
                    artists
                        .into_iter()
                        .map(|artist| Artist {
                            id: artist.artist_id as i64,
                            name: artist.artist_name,
                        })
                        .collect()
                })
                .map_err(|error| error.to_string())
        })
        .await
    }

    pub(crate) async fn artist(&self, artist_id: i64) -> CoreResult<Artist> {
        let artist_id = non_negative_id(artist_id, "Artist ID")?;
        self.run_database_core(move |conn| {
            crate::database::operations::get_artist_by_id(conn, &artist_id.to_string())
                .map(|artist| Artist {
                    id: artist.artist_id as i64,
                    name: artist.artist_name,
                })
                .map_err(|error| lookup_error(error, "Artist", artist_id))
        })
        .await
    }

    pub(crate) async fn artist_releases(&self, artist_id: i64) -> CoreResult<Vec<Release>> {
        let artist_id = non_negative_id(artist_id, "Artist ID")?;
        self.run_database(move |conn| {
            crate::database::operations::get_releases_by_artist_id(conn, &artist_id.to_string())
                .map(|releases| releases.into_iter().map(release_from_database).collect())
                .map_err(|error| error.to_string())
        })
        .await
    }

    pub(crate) async fn artist_tracks(&self, artist_id: i64) -> CoreResult<Vec<Track>> {
        let artist_id = non_negative_id(artist_id, "Artist ID")?;
        self.run_database(move |conn| {
            crate::database::operations::get_songs_by_artist_id(conn, &artist_id.to_string())
                .map(|tracks| tracks.into_iter().map(track_from_song).collect())
                .map_err(|error| error.to_string())
        })
        .await
    }

    pub(crate) async fn track(&self, track_id: i64) -> CoreResult<Track> {
        let track_id = non_negative_id(track_id, "Track ID")?;
        self.run_database_core(move |conn| {
            crate::database::operations::get_song_by_id(conn, &track_id.to_string())
                .map_err(|error| CoreError::Storage {
                    message: error.to_string(),
                })?
                .into_iter()
                .next()
                .map(track_from_song)
                .ok_or_else(|| CoreError::NotFound {
                    message: format!("Track {track_id} not found"),
                })
        })
        .await
    }

    pub(crate) async fn release(&self, release_id: i64) -> CoreResult<Release> {
        let release_id = non_negative_id(release_id, "Release ID")?;
        self.run_database_core(move |conn| {
            crate::database::operations::get_release_by_id(conn, &release_id.to_string())
                .map(release_from_database)
                .map_err(|error| lookup_error(error, "Release", release_id))
        })
        .await
    }

    pub(crate) async fn release_tracks(&self, release_id: i64) -> CoreResult<Vec<Track>> {
        let release_id = non_negative_id(release_id, "Release ID")?;
        self.run_database(move |conn| {
            crate::database::operations::get_songs_by_release_id(conn, &release_id.to_string())
                .map(|tracks| tracks.into_iter().map(track_from_song).collect())
                .map_err(|error| error.to_string())
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

const MAX_LIBRARY_PAGE_SIZE: u64 = 200;

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
    let page_size = page_size.min(MAX_LIBRARY_PAGE_SIZE);
    Ok((page_size + 1, page_size as usize))
}

fn finish_page<T>(mut items: Vec<T>, page_size: usize, offset: u64) -> (Vec<T>, Option<u64>) {
    let has_more = items.len() > page_size;
    items.truncate(page_size);
    let next_offset = has_more.then(|| offset.saturating_add(page_size as u64));
    (items, next_offset)
}

fn non_negative_id(value: i64, label: &str) -> CoreResult<u64> {
    u64::try_from(value).map_err(|_| CoreError::InvalidInput {
        message: format!("{label} must not be negative"),
    })
}

fn lookup_error(
    error: crate::database::operations::DatabaseError,
    resource: &str,
    id: u64,
) -> CoreError {
    if matches!(
        &error,
        crate::database::operations::DatabaseError::Rusqlite(rusqlite::Error::QueryReturnedNoRows)
    ) {
        CoreError::NotFound {
            message: format!("{resource} {id} not found"),
        }
    } else {
        CoreError::Storage {
            message: error.to_string(),
        }
    }
}

pub(crate) fn track_from_song(track: crate::database::models::SongItem) -> Track {
    Track {
        id: track.song_id as i64,
        title: track.title,
        artist: track.artist_name,
        artist_id: track.artist_id as i64,
        release: track.release_title,
        release_id: track.release_id as i64,
        track_number: track.track_number,
        disc_number: track.disc_number,
        duration_seconds: track.duration as f64,
        file_path: track.file_path,
        artwork_id: (!track.artwork.is_empty()).then_some(track.artwork),
        bitrate: track.bitrate,
        sample_rate: track.sample_rate,
        bit_depth: track.bit_depth,
        play_count: track.play_count,
        last_played: track.last_played,
        rating: track.rating,
        is_favorite: track.is_favorite,
        is_hidden: track.is_hidden,
        suggest_less: track.suggest_less,
    }
}

fn release_from_database(release: crate::database::models::Releases) -> Release {
    Release {
        id: release.release_id as i64,
        title: release.title,
        artist: release.artist_name,
        artist_id: release.artist_id as i64,
        release_date: (!release.release_date.is_empty()).then_some(release.release_date),
        genres: release.genres,
        composers: release.composers,
        producers: release.producers,
        total_tracks: release.total_tracks,
        total_discs: release.total_discs,
        duration_seconds: release.duration,
        artwork_id: (!release.artwork.is_empty()).then_some(release.artwork),
        is_favorite: release.is_favorite,
        is_hidden: release.is_hidden,
        suggest_less: release.suggest_less,
        rating: release.rating,
    }
}
