//! durvald-core: Core business logic for the durvald music player.
//!
//! This crate contains all domain logic without any Tauri dependencies.
//! The public API is defined in the `api` module and exposed through
//! the `DurvaldCore` facade in the `core` module.

use crate::api::*;
use crate::application::history::HistoryApplication;
use crate::application::library::LibraryApplication;
pub(crate) use crate::application::library::track_from_song;
use crate::application::metadata::MetadataApplication;
#[cfg(test)]
use crate::application::metadata::artwork_path_in_covers_dir;
use crate::application::playback::PlaybackApplication;
#[cfg(test)]
use crate::application::playback::scrobble_eligible;
use crate::application::playlist::PlaylistApplication;
use crate::application::settings::{SettingsApplication, normalized_cross_fade_duration};
#[cfg(test)]
use crate::application::settings::{normalized_audio_quality, validate_settings};
use crate::lastfm::{LastFmClient, LastFmError};
use crate::secure_store::SecureStore;
use std::sync::Arc;

/// Opaque core engine - the main entry point for all operations.
///
/// Internally owns the database pool, audio player, secure storage,
/// and Last.fm client. All state is encapsulated here.
#[cfg_attr(feature = "uniffi", derive(uniffi::Object))]
pub struct DurvaldCore {
    db_pool: Arc<r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>>,
    history_application: HistoryApplication,
    library_application: LibraryApplication,
    metadata_application: MetadataApplication,
    playback_application: Arc<PlaybackApplication>,
    playlist_application: PlaylistApplication,
    settings_application: SettingsApplication,
    lastfm: Arc<LastFmClient>,
    enrichment: crate::enrichment::service::EnrichmentService,
    covers_dir: String,
}

impl DurvaldCore {
    // Internal accessor methods for Tauri integration (not exported to UniFFI)
    pub fn db_pool(&self) -> &Arc<r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>> {
        &self.db_pool
    }

    pub fn audio_player(&self) -> &Arc<tokio::sync::Mutex<crate::audio::AudioPlayer>> {
        self.playback_application.audio_player()
    }

    pub fn lastfm(&self) -> &Arc<LastFmClient> {
        &self.lastfm
    }

    pub fn covers_dir(&self) -> &String {
        &self.covers_dir
    }

    /// Variant for queries that need to preserve domain errors such as
    /// `NotFound` instead of flattening every failure into `Storage`.
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

    async fn run_entity_update<F>(
        &self,
        entity: &'static str,
        id: u64,
        operation: F,
    ) -> CoreResult<()>
    where
        F: FnOnce(&rusqlite::Connection) -> crate::database::operations::DatabaseResult<bool>
            + Send
            + 'static,
    {
        self.run_database_core(move |conn| {
            if !operation(conn).map_err(|error| CoreError::Storage {
                message: error.to_string(),
            })? {
                return Err(CoreError::NotFound {
                    message: format!("{entity} {id} not found"),
                });
            }
            Ok(())
        })
        .await
    }
}

/// Type alias for the core handle used in UniFFI
pub type DurvaldCoreHandle = Arc<DurvaldCore>;

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

#[cfg(test)]
fn finish_page<T>(mut items: Vec<T>, page_size: usize, offset: u64) -> (Vec<T>, Option<u64>) {
    let has_more = items.len() > page_size;
    items.truncate(page_size);
    let next_offset = has_more.then(|| offset.saturating_add(page_size as u64));
    (items, next_offset)
}

/// Converts legacy 0–100 persisted values and normalized API values to the
/// single 0.0–1.0 scale used by the audio engine and Swift bindings.
fn normalized_volume(volume: f64) -> f32 {
    if !volume.is_finite() {
        return 0.5;
    }
    let normalized = if volume > 1.0 { volume / 100.0 } else { volume };
    normalized.clamp(0.0, 1.0) as f32
}

fn non_negative_id(value: i64, label: &str) -> CoreResult<u64> {
    u64::try_from(value).map_err(|_| CoreError::InvalidInput {
        message: format!("{label} must not be negative"),
    })
}

fn validate_rating(rating: Option<u8>) -> CoreResult<()> {
    if rating.is_some_and(|value| value > 5) {
        return Err(CoreError::InvalidInput {
            message: "Rating must be between 0 and 5".to_string(),
        });
    }
    Ok(())
}

fn repeat_mode_from_string(mode: &str) -> RepeatMode {
    match mode {
        "one" => RepeatMode::One,
        "all" => RepeatMode::All,
        _ => RepeatMode::None,
    }
}

fn lastfm_error(error: LastFmError) -> CoreError {
    let message = error.to_string();
    match error {
        LastFmError::Network(_) | LastFmError::RateLimit(_) => CoreError::Network { message },
        LastFmError::NotConnected | LastFmError::Api { .. } => {
            CoreError::Authentication { message }
        }
        LastFmError::SecureStore(_) => CoreError::Storage { message },
        _ => CoreError::Network { message },
    }
}

impl DurvaldCore {
    /// Creates a new core engine with the given configuration.
    /// Initializes database, audio, storage, and services.
    pub async fn open(config: CoreConfig) -> CoreResult<Arc<Self>> {
        let runtime = tokio::runtime::Handle::current();
        tokio::task::spawn_blocking(move || {
            runtime.block_on(Self::open_with_audio_player(
                config,
                crate::audio::AudioPlayer::new,
            ))
        })
        .await
        .map_err(|error| CoreError::Storage {
            message: format!("Core initialization task failed: {error}"),
        })?
    }

    #[cfg(any(test, feature = "test-support"))]
    pub(crate) async fn open_with_mock_audio(config: CoreConfig) -> CoreResult<Arc<Self>> {
        Self::open_with_audio_player(config, crate::audio::AudioPlayer::new_mock).await
    }

    async fn open_with_audio_player<F>(
        config: CoreConfig,
        create_audio_player: F,
    ) -> CoreResult<Arc<Self>>
    where
        F: FnOnce() -> Result<crate::audio::AudioPlayer, crate::audio::player::AudioError>,
    {
        // Create directories
        std::fs::create_dir_all(&config.app_support_dir).map_err(|e| CoreError::Storage {
            message: e.to_string(),
        })?;
        std::fs::create_dir_all(&config.covers_dir).map_err(|e| CoreError::Storage {
            message: e.to_string(),
        })?;

        // Initialize database
        let manager = r2d2_sqlite::SqliteConnectionManager::file(&config.database_path).with_init(|conn: &mut rusqlite::Connection| {
            conn.execute_batch(
                "PRAGMA journal_mode = WAL;\n PRAGMA busy_timeout = 5000;\n PRAGMA foreign_keys = ON;",
            )?;
            Ok(())
        });
        let pool = r2d2::Pool::new(manager).map_err(|e| CoreError::Storage {
            message: e.to_string(),
        })?;

        let (saved_session, crossfade, current_track, upcoming_tracks) = {
            // Create tables and resolve the saved queue while the connection
            // is scoped to this synchronous initialization block.
            let mut conn = pool.get().map_err(|e| CoreError::Storage {
                message: e.to_string(),
            })?;
            crate::database::operations::create_tables(&conn).map_err(|e| CoreError::Storage {
                message: e.to_string(),
            })?;
            crate::database::migrations::migrate_enrichment(&mut conn).map_err(|e| {
                CoreError::Storage {
                    message: e.to_string(),
                }
            })?;
            crate::database::operations::initiate_settings(&conn).map_err(|e| {
                CoreError::Storage {
                    message: e.to_string(),
                }
            })?;
            crate::database::operations::initiate_last_session(&conn).map_err(|e| {
                CoreError::Storage {
                    message: e.to_string(),
                }
            })?;
            let saved_session =
                crate::database::operations::get_last_session(&conn).map_err(|e| {
                    CoreError::Storage {
                        message: e.to_string(),
                    }
                })?;
            let settings = crate::database::operations::get_settings(&conn).map_err(|e| {
                CoreError::Storage {
                    message: e.to_string(),
                }
            })?;
            let queue_ids =
                serde_json::from_str::<Vec<i64>>(&saved_session.queue_snapshot).unwrap_or_default();
            let song_path = |song_id: i64| {
                crate::database::operations::get_song_by_id(&conn, &song_id.to_string())
                    .ok()
                    .and_then(|tracks| tracks.into_iter().next())
                    .map(|track| (song_id, track.file_path))
            };
            let current_track = saved_session.current_song_id.and_then(song_path);
            let mut skipped_current = false;
            let upcoming_tracks = queue_ids
                .into_iter()
                .filter_map(|song_id| {
                    if !skipped_current && Some(song_id) == saved_session.current_song_id {
                        skipped_current = true;
                        None
                    } else {
                        song_path(song_id)
                    }
                })
                .collect();
            (
                saved_session,
                (
                    settings.cross_fade,
                    normalized_cross_fade_duration(settings.cross_fade_duration),
                    settings.normalize_volume,
                ),
                current_track,
                upcoming_tracks,
            )
        };

        // Initialize audio player
        let mut audio_player = create_audio_player().map_err(|e| CoreError::Playback {
            message: e.to_string(),
        })?;
        audio_player.set_volume(normalized_volume(saved_session.volume));
        audio_player.set_crossfade(crossfade.0, crossfade.1);
        audio_player.set_volume_normalization(crossfade.2);
        audio_player.restore_session(
            current_track,
            upcoming_tracks,
            saved_session.progress_seconds,
            saved_session.shuffle_enabled,
            repeat_mode_from_string(&saved_session.repeat_mode),
        );
        // Initialize secure store
        let secure_store = SecureStore::new(
            config.app_support_dir.clone().into(),
            config.keychain_service.clone(),
        )
        .map_err(|e| CoreError::Storage {
            message: e.to_string(),
        })?;

        // Initialize Last.fm client (clones the secure store)
        let lastfm = Arc::new(
            LastFmClient::new(Arc::new(tokio::sync::Mutex::new(secure_store.clone())))
                .map_err(lastfm_error)?,
        );

        let db_pool = Arc::new(pool);
        let metadata_edit_queue = Arc::new(tokio::sync::Mutex::new(()));
        let playback_application = Arc::new(PlaybackApplication::new(
            db_pool.clone(),
            audio_player,
            lastfm.clone(),
        ));
        let core = Self {
            enrichment: crate::enrichment::service::EnrichmentService::new(
                db_pool.clone(),
                config.covers_dir.clone(),
                lastfm.clone(),
            ),
            db_pool: db_pool.clone(),
            history_application: HistoryApplication::new(db_pool.clone()),
            library_application: LibraryApplication::new(
                db_pool.clone(),
                config.covers_dir.clone(),
                metadata_edit_queue.clone(),
            ),
            metadata_application: MetadataApplication::new(
                db_pool.clone(),
                config.covers_dir.clone(),
                metadata_edit_queue.clone(),
            ),
            settings_application: SettingsApplication::new(
                db_pool.clone(),
                playback_application.audio_player().clone(),
            ),
            playback_application,
            playlist_application: PlaylistApplication::new(db_pool.clone()),
            lastfm,
            covers_dir: config.covers_dir.clone(),
        };

        let core = Arc::new(core);

        core.playback_application.start_automatic_coordination();

        Ok(core)
    }
}

#[cfg_attr(feature = "uniffi", uniffi::export(async_runtime = "tokio"))]
impl DurvaldCore {
    /// Scans the library at the given paths.
    pub async fn scan_library(&self, paths: Vec<String>) -> CoreResult<ScanResult> {
        self.library_application.scan_library(paths).await
    }

    /// Returns phase-level progress for the current or most recent library scan.
    pub fn scan_progress(&self) -> CoreResult<Option<ScanProgress>> {
        self.library_application.scan_progress()
    }

    /// Requests cancellation of the active library scan.
    pub fn cancel_library_scan(&self) -> CoreResult<()> {
        self.library_application.cancel_library_scan()
    }

    /// Adds an existing folder to the configured library locations.
    pub async fn add_library_path(&self, path: String) -> CoreResult<()> {
        self.library_application.add_library_path(path).await
    }

    /// Lists configured library folders.
    pub async fn library_paths(&self) -> CoreResult<Vec<String>> {
        self.library_application.library_paths().await
    }

    /// Scans every configured library folder.
    pub async fn scan_configured_library(&self) -> CoreResult<ScanResult> {
        self.library_application.scan_configured_library().await
    }

    /// Removes a configured library folder.
    pub async fn remove_library_path(&self, path: String) -> CoreResult<()> {
        self.library_application.remove_library_path(path).await
    }

    /// Searches tracks, releases, artists, and playlists by text.
    pub async fn search(&self, query: String) -> CoreResult<SearchResults> {
        self.library_application.search(query).await
    }

    /// Returns all tracks in the library.
    pub async fn tracks(&self) -> CoreResult<Vec<Track>> {
        self.library_application.tracks().await
    }

    /// Returns a bounded page of tracks ordered by their stable database ID.
    pub async fn tracks_page(&self, page_size: u64, offset: u64) -> CoreResult<TrackPage> {
        self.library_application
            .tracks_page(page_size, offset)
            .await
    }

    /// Returns all releases in the library.
    pub async fn releases(&self) -> CoreResult<Vec<Release>> {
        self.library_application.releases().await
    }

    /// Returns a bounded page of releases ordered by their stable database ID.
    pub async fn releases_page(&self, page_size: u64, offset: u64) -> CoreResult<ReleasePage> {
        self.library_application
            .releases_page(page_size, offset)
            .await
    }

    /// Returns all artists in the library.
    pub async fn artists(&self) -> CoreResult<Vec<Artist>> {
        self.library_application.artists().await
    }

    /// Gets an artist by ID.
    pub async fn artist(&self, artist_id: i64) -> CoreResult<Artist> {
        self.library_application.artist(artist_id).await
    }

    /// Reads the local enrichment cache, even when enrichment is disabled/offline.
    /// Never resolves identities or makes an HTTP request.
    pub async fn artist_details(
        &self,
        artist_id: i64,
        language: String,
    ) -> CoreResult<ArtistDetails> {
        self.enrichment.artist_details(artist_id, language).await
    }

    /// Reads one network-free page of the locally persisted external catalog.
    pub async fn artist_discography(
        &self,
        artist_id: i64,
        page_size: u64,
        offset: u64,
    ) -> CoreResult<ArtistDiscographyPage> {
        non_negative_id(artist_id, "Artist ID")?;
        let (_, page_size) = pagination_window(page_size, offset)?;
        self.enrichment
            .artist_discography(artist_id, page_size as u64, offset)
            .await
    }

    /// Reads the locally persisted Last.fm ranking without performing network I/O.
    pub async fn artist_popular_tracks(
        &self,
        artist_id: i64,
    ) -> CoreResult<Option<ArtistPopularTracks>> {
        non_negative_id(artist_id, "Artist ID")?;
        self.enrichment.artist_popular_tracks(artist_id).await
    }

    /// Loads track and edition metadata for one online-only MusicBrainz item.
    pub async fn external_release_details(
        &self,
        artist_id: i64,
        release_group_mbid: String,
    ) -> CoreResult<ExternalReleaseDetails> {
        non_negative_id(artist_id, "Artist ID")?;
        self.enrichment
            .external_release_details(artist_id, release_group_mbid)
            .await
    }

    pub async fn artist_identity(&self, artist_id: i64) -> CoreResult<ArtistIdentity> {
        self.enrichment.artist_identity(artist_id).await
    }

    pub async fn resolve_artist_candidates(
        &self,
        artist_id: i64,
    ) -> CoreResult<ArtistIdentityCandidates> {
        self.enrichment.resolve_artist_candidates(artist_id).await
    }

    pub async fn confirm_artist_identity(
        &self,
        artist_id: i64,
        musicbrainz_id: String,
    ) -> CoreResult<ArtistIdentity> {
        self.enrichment
            .confirm_artist_identity(artist_id, Some(musicbrainz_id))
            .await
    }

    pub async fn clear_artist_identity(&self, artist_id: i64) -> CoreResult<()> {
        self.enrichment
            .confirm_artist_identity(artist_id, None)
            .await
            .map(|_| ())
    }

    pub async fn enrichment_settings(&self) -> CoreResult<EnrichmentSettings> {
        self.enrichment.settings().await
    }

    /// Persists optional enrichment preferences; does not start network work.
    pub async fn configure_enrichment(&self, settings: EnrichmentSettings) -> CoreResult<()> {
        self.enrichment.configure(settings).await
    }

    /// Removes only the selected provider's cached enrichment snapshots,
    /// failures and managed assets. Other providers and local metadata remain.
    pub async fn clear_enrichment_provider_data(
        &self,
        provider: EnrichmentProvider,
    ) -> CoreResult<()> {
        self.enrichment.clear_provider_data(provider).await
    }

    /// Explicitly refreshes the requested remote sections. Local reads remain
    /// network-free and scanning/playback never call this method implicitly.
    pub async fn refresh_artist(
        &self,
        artist_id: i64,
        request: ArtistRefreshRequest,
    ) -> CoreResult<ArtistRefreshResult> {
        self.enrichment.refresh_artist(artist_id, request).await
    }

    /// Applies metadata from the artist's cached MusicBrainz catalog to local
    /// releases and returns the refreshed local collection without network I/O.
    pub async fn sync_artist_release_metadata(&self, artist_id: i64) -> CoreResult<Vec<Release>> {
        non_negative_id(artist_id, "Artist ID")?;
        self.enrichment
            .sync_local_release_metadata(artist_id)
            .await?;
        self.artist_releases(artist_id).await
    }

    pub async fn set_artist_override(
        &self,
        artist_id: i64,
        value: ArtistFieldOverride,
    ) -> CoreResult<()> {
        self.enrichment.set_artist_override(artist_id, value).await
    }

    pub async fn clear_artist_override(
        &self,
        artist_id: i64,
        field: ArtistProfileField,
        language: String,
    ) -> CoreResult<()> {
        self.enrichment
            .clear_artist_override(artist_id, field, language)
            .await
    }

    /// Returns releases by an artist.
    pub async fn artist_releases(&self, artist_id: i64) -> CoreResult<Vec<Release>> {
        self.library_application.artist_releases(artist_id).await
    }

    /// Returns tracks by an artist.
    pub async fn artist_tracks(&self, artist_id: i64) -> CoreResult<Vec<Track>> {
        self.library_application.artist_tracks(artist_id).await
    }

    /// Returns all playlists.
    pub async fn playlists(&self) -> CoreResult<Vec<Playlist>> {
        self.playlist_application.playlists().await
    }

    /// Creates a playlist. Artwork is optional base64 or a data URL.
    pub async fn create_playlist(
        &self,
        name: String,
        description: String,
        artwork_base64: Option<String>,
    ) -> CoreResult<Playlist> {
        self.playlist_application
            .create_playlist(name, description, artwork_base64)
            .await
    }

    /// Gets one playlist by ID.
    pub async fn playlist(&self, playlist_id: i64) -> CoreResult<Playlist> {
        self.playlist_application.playlist(playlist_id).await
    }

    /// Updates a playlist's name, description, and optional artwork.
    pub async fn update_playlist(
        &self,
        playlist_id: i64,
        name: String,
        description: String,
        artwork_base64: Option<String>,
    ) -> CoreResult<()> {
        self.playlist_application
            .update_playlist(playlist_id, name, description, artwork_base64)
            .await
    }

    /// Deletes a playlist and its track entries.
    pub async fn delete_playlist(&self, playlist_id: i64) -> CoreResult<()> {
        self.playlist_application.delete_playlist(playlist_id).await
    }

    /// Returns tracks in playlist order.
    pub async fn playlist_tracks(&self, playlist_id: i64) -> CoreResult<Vec<Track>> {
        self.playlist_application.playlist_tracks(playlist_id).await
    }

    /// Loads persisted track or release artwork as bytes for Swift `Data`.
    /// The supplied artwork identifier must resolve inside the covers directory.
    pub async fn artwork_bytes(&self, artwork_id: String) -> CoreResult<Option<Vec<u8>>> {
        self.metadata_application.artwork_bytes(artwork_id).await
    }

    /// Loads a playlist's artwork blob as bytes for Swift `Data`.
    pub async fn playlist_artwork_bytes(&self, playlist_id: i64) -> CoreResult<Option<Vec<u8>>> {
        self.playlist_application
            .playlist_artwork_bytes(playlist_id)
            .await
    }

    /// Sets whether a track is favorited.
    pub async fn set_track_favorite(&self, track_id: i64, favorite: bool) -> CoreResult<()> {
        let track_id = non_negative_id(track_id, "Track ID")?;
        self.run_entity_update("Track", track_id, move |conn| {
            crate::database::operations::set_track_favorite(conn, track_id, favorite)
        })
        .await
    }

    /// Sets whether a release is favorited.
    pub async fn set_release_favorite(&self, release_id: i64, favorite: bool) -> CoreResult<()> {
        let release_id = non_negative_id(release_id, "Release ID")?;
        self.run_entity_update("Release", release_id, move |conn| {
            crate::database::operations::set_release_favorite(conn, release_id, favorite)
        })
        .await
    }

    /// Sets whether a track is hidden from normal library views.
    pub async fn set_track_hidden(&self, track_id: i64, hidden: bool) -> CoreResult<()> {
        let track_id = non_negative_id(track_id, "Track ID")?;
        self.run_entity_update("Track", track_id, move |conn| {
            crate::database::operations::set_track_hidden(conn, track_id, hidden)
        })
        .await
    }

    /// Sets whether a release is hidden from normal library views.
    pub async fn set_release_hidden(&self, release_id: i64, hidden: bool) -> CoreResult<()> {
        let release_id = non_negative_id(release_id, "Release ID")?;
        self.run_entity_update("Release", release_id, move |conn| {
            crate::database::operations::set_release_hidden(conn, release_id, hidden)
        })
        .await
    }

    /// Sets whether recommendations should de-emphasize a track.
    pub async fn set_track_suggest_less(
        &self,
        track_id: i64,
        suggest_less: bool,
    ) -> CoreResult<()> {
        let track_id = non_negative_id(track_id, "Track ID")?;
        self.run_entity_update("Track", track_id, move |conn| {
            crate::database::operations::set_track_suggest_less(conn, track_id, suggest_less)
        })
        .await
    }

    /// Sets whether recommendations should de-emphasize a release.
    pub async fn set_release_suggest_less(
        &self,
        release_id: i64,
        suggest_less: bool,
    ) -> CoreResult<()> {
        let release_id = non_negative_id(release_id, "Release ID")?;
        self.run_entity_update("Release", release_id, move |conn| {
            crate::database::operations::set_release_suggest_less(conn, release_id, suggest_less)
        })
        .await
    }

    /// Sets whether a playlist is favorited.
    pub async fn set_playlist_favorite(&self, playlist_id: i64, favorite: bool) -> CoreResult<()> {
        self.playlist_application
            .set_playlist_favorite(playlist_id, favorite)
            .await
    }

    /// Sets whether recommendations should de-emphasize a playlist.
    pub async fn set_playlist_suggest_less(
        &self,
        playlist_id: i64,
        suggest_less: bool,
    ) -> CoreResult<()> {
        self.playlist_application
            .set_playlist_suggest_less(playlist_id, suggest_less)
            .await
    }

    /// Sets or clears a track rating on the 0–5 scale.
    pub async fn set_track_rating(&self, track_id: i64, rating: Option<u8>) -> CoreResult<()> {
        validate_rating(rating)?;
        let track_id = non_negative_id(track_id, "Track ID")?;
        self.run_entity_update("Track", track_id, move |conn| {
            crate::database::operations::set_track_rating(conn, track_id, rating)
        })
        .await
    }

    /// Sets or clears a release rating on the 0–5 scale.
    pub async fn set_release_rating(&self, release_id: i64, rating: Option<u8>) -> CoreResult<()> {
        validate_rating(rating)?;
        let release_id = non_negative_id(release_id, "Release ID")?;
        self.run_entity_update("Release", release_id, move |conn| {
            crate::database::operations::set_release_rating(conn, release_id, rating)
        })
        .await
    }

    /// Adds a track at a playlist position.
    pub async fn add_track_to_playlist(
        &self,
        playlist_id: i64,
        track_id: i64,
        position: u64,
    ) -> CoreResult<PlaylistTrack> {
        self.playlist_application
            .add_track_to_playlist(playlist_id, track_id, position)
            .await
    }

    /// Removes a track entry at a playlist position.
    pub async fn remove_track_from_playlist(
        &self,
        playlist_id: i64,
        track_id: i64,
        position: u64,
    ) -> CoreResult<()> {
        self.playlist_application
            .remove_track_from_playlist(playlist_id, track_id, position)
            .await
    }

    /// Moves a track entry to another zero-based playlist position.
    pub async fn move_playlist_track(
        &self,
        playlist_id: i64,
        from: u64,
        to: u64,
    ) -> CoreResult<()> {
        self.playlist_application
            .move_playlist_track(playlist_id, from, to)
            .await
    }

    /// Starts playback of a track.
    pub async fn play(&self, track_id: i64) -> CoreResult<PlaybackSnapshot> {
        self.playback_application.play(track_id).await
    }

    /// Returns the current playback state.
    pub async fn playback(&self) -> PlaybackSnapshot {
        self.playback_application.playback().await
    }
}

// Keep test-only helpers outside the UniFFI-exported impl. Attribute macros
// inspect the impl body before method-level cfg attributes are eliminated.
#[cfg(feature = "test-support")]
impl DurvaldCore {
    pub(crate) async fn process_mock_audio(&self, blocks: usize) {
        let mut player = self.playback_application.audio_player().lock().await;
        player.process_mock_audio(blocks);
    }
}

#[cfg_attr(feature = "uniffi", uniffi::export(async_runtime = "tokio"))]
impl DurvaldCore {
    /// Pauses playback.
    pub async fn pause(&self) -> CoreResult<()> {
        self.playback_application.pause().await
    }

    /// Resumes playback.
    pub async fn resume(&self) -> CoreResult<()> {
        self.playback_application.resume().await
    }

    /// Stops playback.
    pub async fn stop(&self) -> CoreResult<()> {
        self.playback_application.stop().await
    }

    /// Seeks to a position in seconds.
    pub async fn seek(&self, seconds: u64) -> CoreResult<()> {
        self.playback_application.seek(seconds).await
    }

    /// Sets volume (0.0 - 1.0).
    pub async fn set_volume(&self, volume: f32) -> CoreResult<()> {
        self.playback_application.set_volume(volume).await
    }

    /// Enables or disables randomized selection when advancing the queue.
    pub async fn set_shuffle_enabled(&self, enabled: bool) -> CoreResult<PlaybackSnapshot> {
        self.playback_application.set_shuffle_enabled(enabled).await
    }

    /// Sets whether playback stops, repeats one track, or repeats the queue.
    pub async fn set_repeat_mode(&self, mode: RepeatMode) -> CoreResult<PlaybackSnapshot> {
        self.playback_application.set_repeat_mode(mode).await
    }

    /// Returns Last.fm connection status.
    pub async fn lastfm_status(&self) -> CoreResult<LastFmStatus> {
        let connected = self.lastfm.is_connected().await;
        let username = if connected {
            self.lastfm.username().await.map_err(lastfm_error)?
        } else {
            None
        };
        Ok(LastFmStatus {
            connected,
            username,
        })
    }

    /// Stores Last.fm API credentials in the secure store.
    pub async fn configure_lastfm(&self, api_key: String, api_secret: String) -> CoreResult<()> {
        if api_key.trim().is_empty() || api_secret.trim().is_empty() {
            return Err(CoreError::InvalidInput {
                message: "Last.fm API key and secret cannot be empty".to_string(),
            });
        }
        self.lastfm
            .initialize_lastfm(api_key, api_secret)
            .await
            .map_err(lastfm_error)?;
        self.enrichment
            .clear_provider_failures(EnrichmentProvider::LastFm)
            .await
    }

    /// Starts browser-based Last.fm authorization and returns its approval URL.
    pub async fn lastfm_auth_token(&self) -> CoreResult<AuthTokenResponse> {
        self.lastfm
            .get_auth_token()
            .await
            .map(|response| AuthTokenResponse {
                token: response.token,
                auth_url: response.auth_url,
            })
            .map_err(lastfm_error)
    }

    /// Completes Last.fm authorization after the user approved the token.
    pub async fn complete_lastfm_auth(&self, token: String) -> CoreResult<SessionResponse> {
        if token.trim().is_empty() {
            return Err(CoreError::InvalidInput {
                message: "Last.fm authorization token cannot be empty".to_string(),
            });
        }
        self.lastfm
            .poll_session(token)
            .await
            .map(|response| SessionResponse {
                username: response.username,
            })
            .map_err(lastfm_error)
    }

    /// Ends the Last.fm integration and removes its credentials and cached
    /// metadata without affecting snapshots from other providers.
    pub async fn disconnect_lastfm(&self) -> CoreResult<()> {
        self.lastfm
            .disconnect_lastfm()
            .await
            .map_err(lastfm_error)?;
        self.playback_application.clear_lastfm_tracking().await;
        self.enrichment
            .clear_provider_data(EnrichmentProvider::LastFm)
            .await
    }

    /// Returns the last session state.
    pub async fn last_session(&self) -> CoreResult<LastSession> {
        self.playback_application.last_session().await
    }

    /// Returns completed playback events, newest-first as stored by the core.
    pub async fn playback_history(&self) -> CoreResult<Vec<PlaybackHistoryItem>> {
        self.history_application.playback_history().await
    }

    /// Returns a bounded page of completed playback events, newest first.
    pub async fn playback_history_page(
        &self,
        page_size: u64,
        offset: u64,
    ) -> CoreResult<PlaybackHistoryPage> {
        self.history_application
            .playback_history_page(page_size, offset)
            .await
    }

    /// Removes a single completed-playback event.
    pub async fn remove_playback_history_item(&self, history_id: i64) -> CoreResult<()> {
        self.history_application
            .remove_playback_history_item(history_id)
            .await
    }

    /// Deletes every completed-playback event and returns the number removed.
    pub async fn clear_playback_history(&self) -> CoreResult<u64> {
        self.history_application.clear_playback_history().await
    }

    /// Saves the current session state.
    pub async fn save_session(&self, session: LastSession) -> CoreResult<()> {
        self.playback_application.save_session(session).await
    }

    /// Returns application settings.
    pub async fn settings(&self) -> CoreResult<Settings> {
        self.settings_application.settings().await
    }

    /// Updates application settings.
    pub async fn update_settings(&self, settings: Settings) -> CoreResult<()> {
        self.settings_application.update_settings(settings).await
    }

    /// Adds a track to the playback queue.
    pub async fn add_to_queue(&self, track_id: i64) -> CoreResult<()> {
        self.playback_application.add_to_queue(track_id).await
    }

    /// Advances to the next queued track.
    pub async fn next_track(&self) -> CoreResult<PlaybackSnapshot> {
        self.playback_application.next_track().await
    }

    /// Returns to the previously played track, when one exists.
    pub async fn previous_track(&self) -> CoreResult<PlaybackSnapshot> {
        self.playback_application.previous_track().await
    }

    /// Starts the upcoming track at the given queue position.
    pub async fn play_queue_item(&self, position: u64) -> CoreResult<PlaybackSnapshot> {
        self.playback_application.play_queue_item(position).await
    }

    /// Removes an upcoming queue item.
    pub async fn remove_from_queue(&self, position: u64) -> CoreResult<()> {
        self.playback_application.remove_from_queue(position).await
    }

    /// Moves an upcoming queue item to a new queue position.
    pub async fn move_queue_item(&self, from: u64, to: u64) -> CoreResult<()> {
        self.playback_application.move_queue_item(from, to).await
    }

    /// Clears every upcoming queue item while leaving the active track alone.
    pub async fn clear_queue(&self) -> CoreResult<()> {
        self.playback_application.clear_queue().await
    }

    /// Returns the current queue.
    pub async fn queue(&self) -> CoreResult<Vec<QueueItem>> {
        self.playback_application.queue().await
    }

    /// Gets a track by ID.
    pub async fn track(&self, track_id: i64) -> CoreResult<Track> {
        self.library_application.track(track_id).await
    }

    /// Reads indexed metadata, backfilling older libraries once when necessary.
    pub async fn track_info(&self, track_id: i64) -> CoreResult<TrackInfo> {
        self.metadata_application.track_info(track_id).await
    }

    pub async fn save_track_metadata(
        &self,
        track_id: i64,
        metadata: TrackMetadataEdit,
        write_to_file: bool,
    ) -> CoreResult<TrackInfo> {
        self.metadata_application
            .save_track_metadata(track_id, metadata, write_to_file)
            .await
    }

    pub async fn undo_track_metadata(&self, track_id: i64) -> CoreResult<TrackInfo> {
        self.metadata_application
            .undo_track_metadata(track_id)
            .await
    }

    /// Gets a release by ID.
    pub async fn release(&self, release_id: i64) -> CoreResult<Release> {
        self.library_application.release(release_id).await
    }

    /// Gets tracks for a release.
    pub async fn release_tracks(&self, release_id: i64) -> CoreResult<Vec<Track>> {
        self.library_application.release_tracks(release_id).await
    }

    /// Extracts metadata from an audio file (for preview/import).
    pub async fn extract_metadata(&self, file_path: String) -> CoreResult<AudioMetadata> {
        self.metadata_application.extract_metadata(file_path).await
    }
}

/// Opens a new core engine. Exported to FFI as the factory for `DurvaldCore` handles.
#[cfg(feature = "uniffi")]
#[uniffi::export(async_runtime = "tokio")]
pub async fn open(config: CoreConfig) -> CoreResult<Arc<DurvaldCore>> {
    DurvaldCore::open(config).await
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temporary_directory(label: &str) -> std::path::PathBuf {
        std::env::temp_dir().join(format!(
            "durvald-{label}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("current time")
                .as_nanos()
        ))
    }

    fn wav_fixture() -> Vec<u8> {
        let sample_rate = 8_000u32;
        let data_len = sample_rate * 2; // mono, 16-bit, one second
        let mut wav = Vec::with_capacity(44 + data_len as usize);
        wav.extend_from_slice(b"RIFF");
        wav.extend_from_slice(&(36 + data_len).to_le_bytes());
        wav.extend_from_slice(b"WAVEfmt ");
        wav.extend_from_slice(&16u32.to_le_bytes());
        wav.extend_from_slice(&1u16.to_le_bytes());
        wav.extend_from_slice(&1u16.to_le_bytes());
        wav.extend_from_slice(&sample_rate.to_le_bytes());
        wav.extend_from_slice(&(sample_rate * 2).to_le_bytes());
        wav.extend_from_slice(&2u16.to_le_bytes());
        wav.extend_from_slice(&16u16.to_le_bytes());
        wav.extend_from_slice(b"data");
        wav.extend_from_slice(&data_len.to_le_bytes());
        wav.resize(44 + data_len as usize, 0);
        wav
    }

    fn settings() -> Settings {
        Settings {
            cross_fade: true,
            cross_fade_duration: 5,
            normalize_volume: true,
            explicit_content: true,
            autoplay: true,
            preferred_audio_quality: 320,
            preferred_audio_source: "local".to_string(),
            download_path: String::new(),
            open_on_startup: false,
            minimize_on_close: false,
            onboarding_complete: false,
        }
    }

    #[tokio::test]
    async fn enrichment_foundation_is_offline_and_survives_reopening() {
        let directory = temporary_directory("enrichment-lifecycle");
        let config = CoreConfig::new(
            directory.to_string_lossy().into_owned(),
            format!("durvald-enrichment-test-{}", std::process::id()),
        );
        // Simulate a library produced before enrichment existed.
        std::fs::create_dir_all(&directory).unwrap();
        {
            let conn = rusqlite::Connection::open(&config.database_path).unwrap();
            crate::database::operations::create_tables(&conn).unwrap();
            conn.execute(
                "INSERT INTO artists (artist_id, name) VALUES (73, 'Existing artist')",
                [],
            )
            .unwrap();
        }
        let core = DurvaldCore::open_with_mock_audio(config.clone())
            .await
            .unwrap();
        assert_eq!(
            core.enrichment_settings().await.unwrap(),
            EnrichmentSettings::default()
        );
        let settings = EnrichmentSettings {
            enabled: true,
            offline: true,
            preferred_language: "EN-us".into(),
        };
        core.configure_enrichment(settings).await.unwrap();

        // Cache reads must not touch the audio mutex, even while it is held.
        let player = core.playback_application.audio_player().lock().await;
        let details = tokio::time::timeout(
            std::time::Duration::from_secs(2),
            core.artist_details(73, "en-US".into()),
        )
        .await
        .unwrap()
        .unwrap();
        assert_eq!(details.artist.name, "Existing artist");
        assert_eq!(details.identity_status, ArtistIdentityStatus::Unresolved);
        assert!(details.sources.is_empty());
        assert_eq!(details.requested_language, "en-us");
        let discography = core.artist_discography(73, 50, 0).await.unwrap();
        assert_eq!(discography.artist_id, 73);
        assert!(discography.items.is_empty());
        assert!(!discography.remote_exhausted);
        assert_eq!(discography.remote_next_offset, Some(0));
        assert_eq!(discography.remote_total, None);
        let refresh = core
            .refresh_artist(
                73,
                ArtistRefreshRequest {
                    sections: vec![
                        ArtistRefreshSection::Discography,
                        ArtistRefreshSection::Covers,
                    ],
                    language: "en-US".into(),
                    force: false,
                },
            )
            .await
            .unwrap();
        assert!(
            refresh
                .sections
                .iter()
                .all(|result| result.status == ArtistRefreshStatus::Offline)
        );
        drop(player);
        assert_eq!(core.artist(73).await.unwrap(), details.artist);
        assert!(matches!(
            core.artist_details(-1, "en".into()).await,
            Err(CoreError::InvalidInput { .. })
        ));
        assert!(matches!(
            core.artist_details(999, "en".into()).await,
            Err(CoreError::NotFound { .. })
        ));
        assert!(matches!(
            core.artist_discography(73, 0, 0).await,
            Err(CoreError::InvalidInput { .. })
        ));
        let confirmed = core
            .confirm_artist_identity(73, "11111111-1111-4111-8111-111111111111".into())
            .await
            .unwrap();
        drop(core);

        let reopened = DurvaldCore::open_with_mock_audio(config).await.unwrap();
        assert_eq!(reopened.artist_identity(73).await.unwrap(), confirmed);
        assert_eq!(
            reopened.enrichment_settings().await.unwrap(),
            EnrichmentSettings {
                enabled: true,
                offline: true,
                preferred_language: "en-us".into()
            }
        );
        assert_eq!(reopened.artist(73).await.unwrap().name, "Existing artist");
        assert!(reopened.tracks().await.unwrap().is_empty());
        drop(reopened);
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[tokio::test]
    async fn core_opens_with_mock_audio_and_persists_settings() {
        let directory = temporary_directory("core-lifecycle-test");
        let config = CoreConfig::new(
            directory.to_string_lossy().into_owned(),
            format!("durvald-core-test-{}", std::process::id()),
        );
        let core = DurvaldCore::open_with_mock_audio(config.clone())
            .await
            .expect("open core with mock audio");

        assert!(std::path::Path::new(&config.database_path).is_file());
        assert!(std::path::Path::new(&config.covers_dir).is_dir());
        assert!(
            !std::path::Path::new(&config.covers_dir)
                .join(".thumbs_done")
                .exists()
        );
        assert_eq!(
            core.last_session()
                .await
                .expect("read initial session")
                .volume,
            0.5
        );

        let mut updated = core.settings().await.expect("read default settings");
        updated.autoplay = false;
        updated.preferred_audio_source = "local".to_string();
        core.update_settings(updated.clone())
            .await
            .expect("persist settings");
        assert_eq!(
            core.settings().await.expect("read persisted settings"),
            updated
        );

        let music_directory = directory.join("music");
        std::fs::create_dir_all(&music_directory).expect("create music directory");
        std::fs::write(music_directory.join("tone.wav"), wav_fixture())
            .expect("write test audio file");
        let scan = core
            .scan_library(vec![music_directory.to_string_lossy().into_owned()])
            .await
            .expect("scan test library");
        assert_eq!(scan.new_tracks_added, 1);
        let tracks = core.tracks().await.expect("read scanned tracks");
        assert_eq!(tracks.len(), 1);

        drop(core);
        tokio::time::sleep(std::time::Duration::from_millis(25)).await;
        std::fs::remove_dir_all(directory).expect("remove temporary core directory");
    }

    #[tokio::test]
    async fn completed_playback_advances_the_queue_and_records_history() {
        let directory = temporary_directory("completion-lifecycle-test");
        let config = CoreConfig::new(
            directory.to_string_lossy().into_owned(),
            format!("durvald-completion-test-{}", std::process::id()),
        );
        let core = DurvaldCore::open_with_mock_audio(config).await.unwrap();
        let music_directory = directory.join("music");
        std::fs::create_dir_all(&music_directory).unwrap();
        std::fs::write(music_directory.join("first.wav"), wav_fixture()).unwrap();
        std::fs::write(music_directory.join("second.wav"), wav_fixture()).unwrap();
        core.scan_library(vec![music_directory.to_string_lossy().into_owned()])
            .await
            .unwrap();
        let tracks = core.tracks().await.unwrap();
        assert_eq!(tracks.len(), 2);
        core.add_to_queue(tracks[0].id).await.unwrap();
        core.add_to_queue(tracks[1].id).await.unwrap();

        {
            let mut player = core.playback_application.audio_player().lock().await;
            player.process_mock_audio(80);
        }
        tokio::time::sleep(std::time::Duration::from_millis(650)).await;

        let history = core.playback_history().await.unwrap();
        assert_eq!(history.len(), 1);
        assert_eq!(history[0].track_id, tracks[0].id);
        let player = core.playback_application.audio_player().lock().await;
        assert_eq!(player.get_current_song_id(), Some(tracks[1].id));
        drop(player);

        drop(core);
        tokio::time::sleep(std::time::Duration::from_millis(25)).await;
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[tokio::test]
    async fn repeated_track_completion_records_each_listen() {
        let directory = temporary_directory("repeat-history-test");
        let config = CoreConfig::new(
            directory.to_string_lossy().into_owned(),
            format!("durvald-repeat-history-test-{}", std::process::id()),
        );
        let core = DurvaldCore::open_with_mock_audio(config).await.unwrap();
        let music_directory = directory.join("music");
        std::fs::create_dir_all(&music_directory).unwrap();
        std::fs::write(music_directory.join("loop.wav"), wav_fixture()).unwrap();
        core.scan_library(vec![music_directory.to_string_lossy().into_owned()])
            .await
            .unwrap();
        let track_id = core.tracks().await.unwrap()[0].id;
        core.add_to_queue(track_id).await.unwrap();
        core.set_repeat_mode(RepeatMode::One).await.unwrap();

        {
            let mut player = core.playback_application.audio_player().lock().await;
            player.process_mock_audio(80);
        }
        tokio::time::sleep(std::time::Duration::from_millis(650)).await;

        let history = core.playback_history().await.unwrap();
        assert_eq!(history.len(), 1);
        assert_eq!(history[0].track_id, track_id);
        let player = core.playback_application.audio_player().lock().await;
        assert_eq!(player.get_current_song_id(), Some(track_id));
        drop(player);

        drop(core);
        tokio::time::sleep(std::time::Duration::from_millis(25)).await;
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn settings_validation_rejects_out_of_range_and_unsafe_values() {
        let mut invalid = settings();
        invalid.cross_fade_duration = 61;
        assert!(validate_settings(&invalid).is_err());

        invalid = settings();
        invalid.preferred_audio_quality = 0;
        assert!(validate_settings(&invalid).is_err());

        invalid = settings();
        invalid.preferred_audio_source = "local\nremote".to_string();
        assert!(validate_settings(&invalid).is_err());
    }

    #[test]
    fn persisted_settings_values_are_sanitized_before_ffi_conversion() {
        assert_eq!(normalized_cross_fade_duration(-1), 0);
        assert_eq!(normalized_cross_fade_duration(120), 60);
        assert_eq!(normalized_audio_quality(-1), 320);
        assert_eq!(normalized_audio_quality(0), 320);
        assert_eq!(normalized_audio_quality(320), 320);
        assert_eq!(normalized_audio_quality(2_000), 320);
    }

    #[test]
    fn volume_normalization_rejects_non_finite_persisted_values() {
        assert_eq!(normalized_volume(f64::NAN), 0.5);
        assert_eq!(normalized_volume(f64::INFINITY), 0.5);
        assert_eq!(normalized_volume(50.0), 0.5);
        assert_eq!(normalized_volume(-1.0), 0.0);
    }

    #[test]
    fn identifier_validation_rejects_negative_values() {
        assert!(matches!(
            non_negative_id(-1, "Track ID"),
            Err(CoreError::InvalidInput { .. })
        ));
        assert_eq!(non_negative_id(0, "Track ID").unwrap(), 0);
    }

    #[test]
    fn pagination_is_bounded_and_reports_the_next_offset() {
        let (fetch_size, page_size) = pagination_window(1_000, 0).unwrap();
        assert_eq!(fetch_size, MAX_LIBRARY_PAGE_SIZE + 1);
        assert_eq!(page_size, MAX_LIBRARY_PAGE_SIZE as usize);

        let (items, next_offset) = finish_page(
            (0..=MAX_LIBRARY_PAGE_SIZE).collect::<Vec<_>>(),
            page_size,
            40,
        );
        assert_eq!(items.len(), MAX_LIBRARY_PAGE_SIZE as usize);
        assert_eq!(next_offset, Some(40 + MAX_LIBRARY_PAGE_SIZE));

        let (items, next_offset) = finish_page(vec![1, 2], 10, 20);
        assert_eq!(items, vec![1, 2]);
        assert_eq!(next_offset, None);
        assert!(pagination_window(0, 0).is_err());
        assert!(pagination_window(10, i64::MAX as u64 + 1).is_err());
    }

    #[test]
    fn scrobbling_requires_a_meaningful_amount_of_playback() {
        assert!(!scrobble_eligible(29, 29));
        assert!(!scrobble_eligible(180, 89));
        assert!(scrobble_eligible(180, 90));
        assert!(!scrobble_eligible(1_000, 239));
        assert!(scrobble_eligible(1_000, 240));
    }

    #[test]
    fn artwork_paths_must_be_contained_by_the_covers_directory() {
        let directory = std::env::temp_dir().join(format!(
            "durvald-artwork-path-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let covers_dir = directory.join("covers");
        std::fs::create_dir_all(&covers_dir).unwrap();
        let inside = covers_dir.join("cover.jpg");
        let outside = directory.join("outside.jpg");
        std::fs::write(&inside, [1, 2, 3]).unwrap();
        std::fs::write(&outside, [4, 5, 6]).unwrap();

        assert_eq!(
            artwork_path_in_covers_dir(&covers_dir.to_string_lossy(), &inside.to_string_lossy(),)
                .unwrap(),
            Some(std::fs::canonicalize(&inside).unwrap())
        );
        assert!(matches!(
            artwork_path_in_covers_dir(&covers_dir.to_string_lossy(), &outside.to_string_lossy(),),
            Err(CoreError::InvalidInput { .. })
        ));

        std::fs::remove_dir_all(directory).unwrap();
    }
}
