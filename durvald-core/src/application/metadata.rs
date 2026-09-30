//! Metadata use-case coordination.

use std::sync::Arc;

use crate::api::{
    AudioMetadata, CoreError, CoreResult, KeyValuePair, LibraryRepairAnalysis, TrackInfo,
    TrackMetadataEdit,
};
use crate::domain::ids::TrackId;
use crate::infrastructure::sqlite::track_metadata::SqliteTrackMetadataRepository;

pub(crate) struct MetadataApplication {
    repository: SqliteTrackMetadataRepository,
    covers_dir: String,
    metadata_edit_queue: Arc<tokio::sync::Mutex<()>>,
}

impl MetadataApplication {
    pub(crate) fn new(
        repository: SqliteTrackMetadataRepository,
        covers_dir: String,
        metadata_edit_queue: Arc<tokio::sync::Mutex<()>>,
    ) -> Self {
        Self {
            repository,
            covers_dir,
            metadata_edit_queue,
        }
    }

    pub(crate) async fn track_info(&self, track_id: TrackId) -> CoreResult<TrackInfo> {
        self.repository.info(track_id).await
    }

    pub(crate) async fn track_lyrics(&self, track_id: TrackId) -> CoreResult<Option<String>> {
        self.repository.lyrics(track_id).await
    }

    pub(crate) async fn extract_metadata(&self, file_path: String) -> CoreResult<AudioMetadata> {
        let covers_dir = std::path::PathBuf::from(&self.covers_dir);
        let metadata = tokio::task::spawn_blocking(move || {
            crate::metadata::extract_metadata_blocking(&file_path, &covers_dir).map_err(|error| {
                CoreError::Storage {
                    message: error.to_string(),
                }
            })
        })
        .await
        .map_err(|error| CoreError::Storage {
            message: format!("Metadata extraction task failed: {error}"),
        })??;
        Ok(metadata_to_api(metadata))
    }

    pub(crate) async fn artwork_bytes(&self, artwork_id: String) -> CoreResult<Option<Vec<u8>>> {
        let covers_dir = self.covers_dir.clone();
        tokio::task::spawn_blocking(move || {
            let Some(path) = artwork_path_in_covers_dir(&covers_dir, &artwork_id)? else {
                return Ok(None);
            };
            std::fs::read(path)
                .map(Some)
                .map_err(|error| CoreError::Storage {
                    message: format!("Unable to read artwork: {error}"),
                })
        })
        .await
        .map_err(|error| CoreError::Storage {
            message: format!("Artwork read task failed: {error}"),
        })?
    }

    pub(crate) async fn save_track_metadata(
        &self,
        track_id: TrackId,
        metadata: TrackMetadataEdit,
        write_to_file: bool,
    ) -> CoreResult<TrackInfo> {
        let _queue = self.metadata_edit_queue.lock().await;
        let backup_dir = std::path::PathBuf::from(&self.covers_dir).join("metadata-backups");
        self.repository
            .save(track_id, metadata, write_to_file, backup_dir)
            .await
    }

    pub(crate) async fn undo_track_metadata(&self, track_id: TrackId) -> CoreResult<TrackInfo> {
        let _queue = self.metadata_edit_queue.lock().await;
        self.repository.undo(track_id).await
    }

    pub(crate) async fn analyze_library_repairs(&self) -> CoreResult<LibraryRepairAnalysis> {
        let _queue = self.metadata_edit_queue.lock().await;
        self.repository.analyze_library().await
    }

    pub(crate) async fn merge_library_records(
        &self,
        source_id: i64,
        target_id: i64,
        source_is_missing: bool,
    ) -> CoreResult<()> {
        let _queue = self.metadata_edit_queue.lock().await;
        self.repository
            .merge_library_records(source_id, target_id, source_is_missing)
            .await
    }
}

fn metadata_to_api(metadata: crate::metadata::AudioMetadata) -> AudioMetadata {
    AudioMetadata {
        title: metadata.title,
        artist: metadata.artist,
        release: metadata.release,
        genre: metadata.genre,
        year: metadata.year,
        track: metadata.track,
        disc: metadata.disc,
        duration_seconds: metadata.duration,
        bitrate: metadata.bitrate,
        sample_rate: metadata.sample_rate,
        bit_depth: metadata.bit_depth,
        channels: metadata.channels,
        cover_artwork_id: metadata.cover_path,
        all_fields: metadata
            .all_fields
            .into_iter()
            .map(|(key, value)| KeyValuePair { key, value })
            .collect(),
        file_path: metadata.file_path,
    }
}

pub(crate) fn artwork_path_in_covers_dir(
    covers_dir: &str,
    artwork_id: &str,
) -> CoreResult<Option<std::path::PathBuf>> {
    if artwork_id.is_empty() {
        return Ok(None);
    }

    let artwork_path = std::path::Path::new(artwork_id);
    if !artwork_path.is_file() {
        return Ok(None);
    }
    let covers_dir = std::fs::canonicalize(covers_dir).map_err(|error| CoreError::Storage {
        message: format!("Unable to access covers directory: {error}"),
    })?;
    let artwork_path = std::fs::canonicalize(artwork_path).map_err(|error| CoreError::Storage {
        message: format!("Unable to access artwork: {error}"),
    })?;
    if !artwork_path.starts_with(&covers_dir) {
        return Err(CoreError::InvalidInput {
            message: "Artwork must be inside the configured covers directory".to_string(),
        });
    }
    Ok(Some(artwork_path))
}
