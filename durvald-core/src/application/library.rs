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
use crate::domain::ids::{ArtistId, ReleaseId, TrackId};
use crate::infrastructure::metadata_extraction::LocalMetadataExtractor;
use crate::infrastructure::sqlite::catalog_artist::{
    CatalogArtistLookupError, SqliteCatalogArtistQuery,
};
use crate::infrastructure::sqlite::catalog_preferences::SqliteCatalogPreferencesRepository;
use crate::infrastructure::sqlite::catalog_release::{
    CatalogReleaseLookupError, SqliteCatalogReleaseQuery,
};
use crate::infrastructure::sqlite::catalog_search::SqliteCatalogSearchQuery;
use crate::infrastructure::sqlite::catalog_track::{
    CatalogTrackLookupError, SqliteCatalogTrackQuery,
};
use crate::infrastructure::sqlite::library_paths::SqliteLibraryPathsRepository;
use crate::infrastructure::sqlite::library_scan::SqliteLibraryScanRepository;

/// Coordinates library use cases behind the public core facade.
pub(crate) struct LibraryApplication {
    persistence: LibraryPersistence,
    metadata_extractor: LocalMetadataExtractor,
    covers_dir: String,
    metadata_edit_queue: Arc<tokio::sync::Mutex<()>>,
    scan_in_progress: Arc<AtomicBool>,
    scan_cancel_requested: Arc<AtomicBool>,
    scan_progress: Arc<std::sync::Mutex<Option<ScanProgress>>>,
}

pub(crate) struct LibraryPersistence {
    catalog_artist_query: SqliteCatalogArtistQuery,
    catalog_preferences_repository: SqliteCatalogPreferencesRepository,
    catalog_release_query: SqliteCatalogReleaseQuery,
    catalog_search_query: SqliteCatalogSearchQuery,
    catalog_track_query: SqliteCatalogTrackQuery,
    library_paths_repository: SqliteLibraryPathsRepository,
    library_scan_repository: SqliteLibraryScanRepository,
}

impl LibraryPersistence {
    pub(crate) fn new(
        catalog_artist_query: SqliteCatalogArtistQuery,
        catalog_preferences_repository: SqliteCatalogPreferencesRepository,
        catalog_release_query: SqliteCatalogReleaseQuery,
        catalog_search_query: SqliteCatalogSearchQuery,
        catalog_track_query: SqliteCatalogTrackQuery,
        library_paths_repository: SqliteLibraryPathsRepository,
        library_scan_repository: SqliteLibraryScanRepository,
    ) -> Self {
        Self {
            catalog_artist_query,
            catalog_preferences_repository,
            catalog_release_query,
            catalog_search_query,
            catalog_track_query,
            library_paths_repository,
            library_scan_repository,
        }
    }
}

impl LibraryApplication {
    pub(crate) fn new(
        persistence: LibraryPersistence,
        metadata_extractor: LocalMetadataExtractor,
        covers_dir: String,
        metadata_edit_queue: Arc<tokio::sync::Mutex<()>>,
    ) -> Self {
        Self {
            persistence,
            metadata_extractor,
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

            let cancellation = self.scan_cancel_requested.clone();
            let scan_path = path.clone();
            let pending = match self
                .persistence
                .library_scan_repository
                .prepare(scan_path, cancellation)
                .await
            {
                Ok(pending) => pending,
                Err(message) => {
                    errors.push(format!("{path}: {message}"));
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
                let mut extracted = self
                    .metadata_extractor
                    .extract(
                        batch,
                        std::path::Path::new(&self.covers_dir),
                        self.scan_cancel_requested.clone(),
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

                match self
                    .persistence
                    .library_scan_repository
                    .persist_metadata(
                        extracted.metadata,
                        extracted.mtimes,
                        extracted.existing_song_ids,
                    )
                    .await
                {
                    Ok(written) => {
                        new_tracks += written.added_tracks as u64;
                        updated_tracks += written.updated_tracks as u64;
                    }
                    Err(error) => {
                        errors.push(format!("{path}: {error}"));
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
                if let Err(error) = self
                    .persistence
                    .library_scan_repository
                    .reconcile(reconciliation)
                    .await
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
        if !std::path::Path::new(&path).is_dir() {
            return Err(CoreError::InvalidInput {
                message: format!("Library path is not a directory: {path}"),
            });
        }
        self.persistence
            .library_paths_repository
            .add(path)
            .await
            .map_err(storage_error)
    }

    pub(crate) async fn library_paths(&self) -> CoreResult<Vec<String>> {
        self.persistence
            .library_paths_repository
            .all()
            .await
            .map_err(storage_error)
    }

    pub(crate) async fn remove_library_path(&self, path: String) -> CoreResult<()> {
        let removed = self
            .persistence
            .library_paths_repository
            .remove(path.clone())
            .await
            .map_err(storage_error)?;
        if !removed {
            return Err(CoreError::NotFound {
                message: format!("Library path is not configured: {path}"),
            });
        }
        Ok(())
    }

    pub(crate) async fn search(&self, query: String) -> CoreResult<SearchResults> {
        if query.trim().is_empty() {
            return Err(CoreError::InvalidInput {
                message: "Search query cannot be empty".to_string(),
            });
        }

        let query = query.trim().to_owned();
        let results = self
            .persistence
            .catalog_search_query
            .search(query)
            .await
            .map_err(storage_error)?;

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
        self.persistence
            .catalog_track_query
            .all()
            .await
            .map(|tracks| tracks.into_iter().map(track_from_catalog).collect())
            .map_err(catalog_track_storage_error)
    }

    pub(crate) async fn tracks_page(&self, page_size: u64, offset: u64) -> CoreResult<TrackPage> {
        let (fetch_size, page_size) = pagination_window(page_size, offset)?;
        let tracks = self
            .persistence
            .catalog_track_query
            .page(fetch_size, offset)
            .await
            .map_err(catalog_track_storage_error)?
            .into_iter()
            .map(track_from_catalog)
            .collect();
        let (items, next_offset) = finish_page(tracks, page_size, offset);
        Ok(TrackPage { items, next_offset })
    }

    pub(crate) async fn releases(&self) -> CoreResult<Vec<Release>> {
        self.persistence
            .catalog_release_query
            .all()
            .await
            .map(|releases| releases.into_iter().map(release_from_database).collect())
            .map_err(catalog_release_storage_error)
    }

    pub(crate) async fn releases_page(
        &self,
        page_size: u64,
        offset: u64,
    ) -> CoreResult<ReleasePage> {
        let (fetch_size, page_size) = pagination_window(page_size, offset)?;
        let releases = self
            .persistence
            .catalog_release_query
            .page(fetch_size, offset)
            .await
            .map_err(catalog_release_storage_error)?
            .into_iter()
            .map(release_from_database)
            .collect();
        let (items, next_offset) = finish_page(releases, page_size, offset);
        Ok(ReleasePage { items, next_offset })
    }

    pub(crate) async fn artists(&self) -> CoreResult<Vec<Artist>> {
        self.persistence
            .catalog_artist_query
            .all()
            .await
            .map(|artists| {
                artists
                    .into_iter()
                    .map(|artist| Artist {
                        id: artist.artist_id as i64,
                        name: artist.artist_name,
                    })
                    .collect()
            })
            .map_err(catalog_artist_storage_error)
    }

    pub(crate) async fn artist(&self, artist_id: ArtistId) -> CoreResult<Artist> {
        self.persistence
            .catalog_artist_query
            .find(artist_id)
            .await
            .map(|artist| Artist {
                id: artist.artist_id as i64,
                name: artist.artist_name,
            })
            .map_err(|error| catalog_artist_error(error, artist_id))
    }

    pub(crate) async fn artist_releases(&self, artist_id: ArtistId) -> CoreResult<Vec<Release>> {
        self.persistence
            .catalog_artist_query
            .releases(artist_id)
            .await
            .map(|releases| releases.into_iter().map(release_from_database).collect())
            .map_err(|error| catalog_artist_error(error, artist_id))
    }

    pub(crate) async fn artist_tracks(&self, artist_id: ArtistId) -> CoreResult<Vec<Track>> {
        self.persistence
            .catalog_artist_query
            .tracks(artist_id)
            .await
            .map(|tracks| tracks.into_iter().map(track_from_song).collect())
            .map_err(|error| catalog_artist_error(error, artist_id))
    }

    pub(crate) async fn track(&self, track_id: TrackId) -> CoreResult<Track> {
        self.persistence
            .catalog_track_query
            .find(track_id)
            .await
            .map(track_from_catalog)
            .map_err(|error| catalog_track_error(error, track_id))
    }

    pub(crate) async fn release(&self, release_id: ReleaseId) -> CoreResult<Release> {
        self.persistence
            .catalog_release_query
            .find(release_id)
            .await
            .map(release_from_database)
            .map_err(|error| catalog_release_error(error, release_id))
    }

    pub(crate) async fn release_tracks(&self, release_id: ReleaseId) -> CoreResult<Vec<Track>> {
        self.persistence
            .catalog_release_query
            .tracks(release_id)
            .await
            .map(|tracks| tracks.into_iter().map(track_from_song).collect())
            .map_err(|error| catalog_release_error(error, release_id))
    }

    pub(crate) async fn set_track_favorite(
        &self,
        track_id: TrackId,
        favorite: bool,
    ) -> CoreResult<()> {
        entity_update_result(
            self.persistence
                .catalog_preferences_repository
                .set_track_favorite(track_id, favorite)
                .await,
            "Track",
            track_id.get(),
        )
    }

    pub(crate) async fn set_release_favorite(
        &self,
        release_id: ReleaseId,
        favorite: bool,
    ) -> CoreResult<()> {
        entity_update_result(
            self.persistence
                .catalog_preferences_repository
                .set_release_favorite(release_id, favorite)
                .await,
            "Release",
            release_id.get(),
        )
    }

    pub(crate) async fn set_track_hidden(&self, track_id: TrackId, hidden: bool) -> CoreResult<()> {
        entity_update_result(
            self.persistence
                .catalog_preferences_repository
                .set_track_hidden(track_id, hidden)
                .await,
            "Track",
            track_id.get(),
        )
    }

    pub(crate) async fn set_release_hidden(
        &self,
        release_id: ReleaseId,
        hidden: bool,
    ) -> CoreResult<()> {
        entity_update_result(
            self.persistence
                .catalog_preferences_repository
                .set_release_hidden(release_id, hidden)
                .await,
            "Release",
            release_id.get(),
        )
    }

    pub(crate) async fn set_track_suggest_less(
        &self,
        track_id: TrackId,
        suggest_less: bool,
    ) -> CoreResult<()> {
        entity_update_result(
            self.persistence
                .catalog_preferences_repository
                .set_track_suggest_less(track_id, suggest_less)
                .await,
            "Track",
            track_id.get(),
        )
    }

    pub(crate) async fn set_release_suggest_less(
        &self,
        release_id: ReleaseId,
        suggest_less: bool,
    ) -> CoreResult<()> {
        entity_update_result(
            self.persistence
                .catalog_preferences_repository
                .set_release_suggest_less(release_id, suggest_less)
                .await,
            "Release",
            release_id.get(),
        )
    }

    pub(crate) async fn set_track_rating(
        &self,
        track_id: TrackId,
        rating: Option<u8>,
    ) -> CoreResult<()> {
        validate_rating(rating)?;
        entity_update_result(
            self.persistence
                .catalog_preferences_repository
                .set_track_rating(track_id, rating)
                .await,
            "Track",
            track_id.get(),
        )
    }

    pub(crate) async fn set_release_rating(
        &self,
        release_id: ReleaseId,
        rating: Option<u8>,
    ) -> CoreResult<()> {
        validate_rating(rating)?;
        entity_update_result(
            self.persistence
                .catalog_preferences_repository
                .set_release_rating(release_id, rating)
                .await,
            "Release",
            release_id.get(),
        )
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

fn validate_rating(rating: Option<u8>) -> CoreResult<()> {
    if rating.is_some_and(|value| value > 5) {
        return Err(CoreError::InvalidInput {
            message: "Rating must be between 0 and 5".to_string(),
        });
    }
    Ok(())
}

fn storage_error(message: String) -> CoreError {
    CoreError::Storage { message }
}

fn catalog_artist_error(error: CatalogArtistLookupError, artist_id: ArtistId) -> CoreError {
    match error {
        CatalogArtistLookupError::NotFound => CoreError::NotFound {
            message: format!("Artist {} not found", artist_id.get()),
        },
        CatalogArtistLookupError::Storage(message) => CoreError::Storage { message },
    }
}

fn catalog_artist_storage_error(error: CatalogArtistLookupError) -> CoreError {
    match error {
        CatalogArtistLookupError::NotFound => CoreError::Storage {
            message: "Unexpected missing artist while listing catalog".to_string(),
        },
        CatalogArtistLookupError::Storage(message) => CoreError::Storage { message },
    }
}

fn catalog_track_error(error: CatalogTrackLookupError, track_id: TrackId) -> CoreError {
    match error {
        CatalogTrackLookupError::NotFound => CoreError::NotFound {
            message: format!("Track {} not found", track_id.get()),
        },
        CatalogTrackLookupError::Storage(message) => CoreError::Storage { message },
    }
}

fn catalog_track_storage_error(error: CatalogTrackLookupError) -> CoreError {
    match error {
        CatalogTrackLookupError::NotFound => CoreError::Storage {
            message: "Unexpected missing track while listing catalog".to_string(),
        },
        CatalogTrackLookupError::Storage(message) => CoreError::Storage { message },
    }
}

fn catalog_release_error(error: CatalogReleaseLookupError, release_id: ReleaseId) -> CoreError {
    match error {
        CatalogReleaseLookupError::NotFound => CoreError::NotFound {
            message: format!("Release {} not found", release_id.get()),
        },
        CatalogReleaseLookupError::Storage(message) => CoreError::Storage { message },
    }
}

fn catalog_release_storage_error(error: CatalogReleaseLookupError) -> CoreError {
    match error {
        CatalogReleaseLookupError::NotFound => CoreError::Storage {
            message: "Unexpected missing release while listing catalog".to_string(),
        },
        CatalogReleaseLookupError::Storage(message) => CoreError::Storage { message },
    }
}

fn entity_update_result(result: Result<bool, String>, entity: &str, id: u64) -> CoreResult<()> {
    if !result.map_err(storage_error)? {
        return Err(CoreError::NotFound {
            message: format!("{entity} {id} not found"),
        });
    }
    Ok(())
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

pub(crate) fn track_from_catalog(track: crate::domain::catalog::CatalogTrack) -> Track {
    Track {
        id: track.id.get() as i64,
        title: track.title,
        artist: track.artist_name,
        artist_id: track.artist_id.get() as i64,
        release: track.release_title,
        release_id: track.release_id.get() as i64,
        track_number: track.track_number,
        disc_number: track.disc_number,
        duration_seconds: track.duration_seconds as f64,
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
