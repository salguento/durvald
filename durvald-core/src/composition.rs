use crate::api::{CoreConfig, CoreError, CoreResult, RepeatMode};
use crate::application::enrichment::EnrichmentApplication;
use crate::application::history::HistoryApplication;
use crate::application::lastfm::{LastFmApplication, lastfm_error};
use crate::application::library::{LibraryApplication, LibraryPersistence};
use crate::application::metadata::MetadataApplication;
use crate::application::playback::PlaybackApplication;
use crate::application::playlist::PlaylistApplication;
use crate::application::settings::SettingsApplication;
use crate::audio::{AudioPlayer, player::AudioError};
use crate::enrichment::service::EnrichmentService;
use crate::infrastructure::metadata_extraction::LocalMetadataExtractor;
use crate::infrastructure::sqlite::catalog_artist::SqliteCatalogArtistQuery;
use crate::infrastructure::sqlite::catalog_preferences::SqliteCatalogPreferencesRepository;
use crate::infrastructure::sqlite::catalog_release::SqliteCatalogReleaseQuery;
use crate::infrastructure::sqlite::catalog_search::SqliteCatalogSearchQuery;
use crate::infrastructure::sqlite::catalog_track::SqliteCatalogTrackQuery;
use crate::infrastructure::sqlite::library_paths::SqliteLibraryPathsRepository;
use crate::infrastructure::sqlite::library_scan::SqliteLibraryScanRepository;
use crate::infrastructure::sqlite::playback_history::SqlitePlaybackHistoryRepository;
use crate::infrastructure::sqlite::playback_session::SqlitePlaybackSessionRepository;
use crate::infrastructure::sqlite::playlists::SqlitePlaylistRepository;
use crate::infrastructure::sqlite::settings::SqliteSettingsRepository;
use crate::infrastructure::sqlite::track_metadata::SqliteTrackMetadataRepository;
use crate::lastfm::LastFmClient;
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

pub(crate) struct PersistenceApplications {
    pub(crate) history: HistoryApplication,
    pub(crate) metadata: MetadataApplication,
    pub(crate) playlist: PlaylistApplication,
    pub(crate) settings: SettingsApplication,
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

pub(crate) async fn initialize_audio_player<F>(
    pool: Arc<DatabasePool>,
    playback: PlaybackBootstrap,
    factory: F,
) -> CoreResult<(AudioPlayer, SqliteSettingsRepository)>
where
    F: FnOnce() -> Result<AudioPlayer, AudioError>,
{
    let settings_repository = SqliteSettingsRepository::new(pool);
    let settings = settings_repository
        .get()
        .await
        .map_err(|message| CoreError::Storage { message })?;
    let mut audio_player = factory().map_err(|error| CoreError::Playback {
        message: error.to_string(),
    })?;
    audio_player.set_volume(normalized_volume(playback.volume));
    audio_player.set_crossfade(settings.cross_fade, settings.cross_fade_duration);
    audio_player.set_volume_normalization(settings.normalize_volume);
    audio_player.restore_session(
        playback.current_track,
        playback.upcoming_tracks,
        playback.progress_seconds,
        playback.shuffle_enabled,
        playback.repeat_mode,
    );

    Ok((audio_player, settings_repository))
}

pub(crate) fn open_lastfm(config: &CoreConfig) -> CoreResult<Arc<LastFmClient>> {
    LastFmClient::open(
        config.app_support_dir.clone().into(),
        config.keychain_service.clone(),
    )
    .map(Arc::new)
    .map_err(lastfm_error)
}

pub(crate) fn build_playback_application(
    pool: Arc<DatabasePool>,
    audio_player: AudioPlayer,
    lastfm: Arc<LastFmClient>,
) -> Arc<PlaybackApplication> {
    Arc::new(PlaybackApplication::new(
        SqliteCatalogTrackQuery::new(pool.clone()),
        SqlitePlaybackHistoryRepository::new(pool.clone()),
        SqlitePlaybackSessionRepository::new(pool),
        audio_player,
        lastfm,
    ))
}

pub(crate) fn build_library_application(
    pool: Arc<DatabasePool>,
    covers_dir: String,
    metadata_edit_queue: Arc<tokio::sync::Mutex<()>>,
) -> Arc<LibraryApplication> {
    Arc::new(LibraryApplication::new(
        LibraryPersistence::new(
            SqliteCatalogArtistQuery::new(pool.clone()),
            SqliteCatalogPreferencesRepository::new(pool.clone()),
            SqliteCatalogReleaseQuery::new(pool.clone()),
            SqliteCatalogSearchQuery::new(pool.clone()),
            SqliteCatalogTrackQuery::new(pool.clone()),
            SqliteLibraryPathsRepository::new(pool.clone()),
            SqliteLibraryScanRepository::new(pool),
        ),
        LocalMetadataExtractor::new(),
        covers_dir,
        metadata_edit_queue,
    ))
}

pub(crate) fn build_enrichment_applications(
    pool: Arc<DatabasePool>,
    covers_dir: String,
    lastfm: Arc<LastFmClient>,
    playback: Arc<PlaybackApplication>,
    library: Arc<LibraryApplication>,
) -> (EnrichmentApplication, LastFmApplication) {
    let enrichment = EnrichmentService::new(pool, covers_dir, lastfm.clone());
    let enrichment_application = EnrichmentApplication::new(enrichment.clone(), library);
    let lastfm_application = LastFmApplication::new(lastfm, enrichment, playback);
    (enrichment_application, lastfm_application)
}

pub(crate) fn build_persistence_applications(
    pool: Arc<DatabasePool>,
    covers_dir: String,
    metadata_edit_queue: Arc<tokio::sync::Mutex<()>>,
    settings_repository: SqliteSettingsRepository,
    playback: &PlaybackApplication,
) -> PersistenceApplications {
    PersistenceApplications {
        history: HistoryApplication::new(SqlitePlaybackHistoryRepository::new(pool.clone())),
        metadata: MetadataApplication::new(
            SqliteTrackMetadataRepository::new(pool.clone()),
            covers_dir,
            metadata_edit_queue,
        ),
        playlist: PlaylistApplication::new(SqlitePlaylistRepository::new(pool)),
        settings: SettingsApplication::new(settings_repository, playback.audio_player().clone()),
    }
}

fn repeat_mode_from_string(mode: &str) -> RepeatMode {
    match mode {
        "one" => RepeatMode::One,
        "all" => RepeatMode::All,
        _ => RepeatMode::None,
    }
}

fn normalized_volume(volume: f64) -> f32 {
    if !volume.is_finite() {
        return 0.5;
    }
    let normalized = if volume > 1.0 { volume / 100.0 } else { volume };
    normalized.clamp(0.0, 1.0) as f32
}

fn storage_error(error: impl std::fmt::Display) -> CoreError {
    CoreError::Storage {
        message: error.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::normalized_volume;

    #[test]
    fn volume_normalization_rejects_non_finite_persisted_values() {
        assert_eq!(normalized_volume(f64::NAN), 0.5);
        assert_eq!(normalized_volume(f64::INFINITY), 0.5);
        assert_eq!(normalized_volume(50.0), 0.5);
        assert_eq!(normalized_volume(-1.0), 0.0);
    }
}
