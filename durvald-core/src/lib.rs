//! durvald-core: Core business logic for the durvald music player.
//!
//! This crate contains all domain logic without any Tauri dependencies.
//! The public API is defined in the `api` module and exposed through
//! UniFFI bindings for SwiftUI, GTK4, and other targets.

// UniFFI scaffolding - proc-macro metadata from #[uniffi::export] and derives in api.rs.
// durvald.udl references those Rust types for bindgen; it is not included here.
#[cfg(feature = "uniffi")]
uniffi::setup_scaffolding!();

pub mod api;
pub mod core;
pub mod audio;
pub mod database;
pub mod lastfm;
pub mod metadata;
pub mod secure_store;

// Re-export public API types
pub use crate::api::*;
pub use crate::core::DurvaldCore;

// Re-export internal types for backward compatibility during transition
pub use crate::audio::AudioPlayer;
pub use crate::database::operations::*;
pub use crate::lastfm::LastFmClient;
pub use crate::secure_store::{SecureStore, SecureStoreError};

// ===== UniFFI Export Functions =====
// These are the FFI entry points generated from the UDL file.
// They use the opaque handle pattern: create -> get handle -> pass handle to all ops.

#[cfg(feature = "uniffi")]
mod uniffi_exports {
    use crate::core::DurvaldCore;
    use crate::api::{
        AudioMetadata as ApiAudioMetadata, CoreConfig, CoreError, CoreResult, KeyValuePair,
    };
    use crate::metadata::AudioMetadata as MetaAudioMetadata;
    use std::sync::Arc;

    /// Creates a new core engine and returns an opaque handle.
    ///
    /// This is the ONLY way to create a DurvaldCore instance from FFI.
    /// The handle is reference-counted (Arc) and automatically managed by UniFFI.
    #[uniffi::export]
    pub async fn durvald_core_open(config: CoreConfig) -> CoreResult<Arc<DurvaldCore>> {
        DurvaldCore::open(config).await
    }

    /// Extracts metadata from an audio file (for preview/import).
    #[uniffi::export]
    pub fn durvald_core_extract_metadata(
        core: Arc<DurvaldCore>,
        file_path: String
    ) -> CoreResult<ApiAudioMetadata> {
        let covers_dir = std::path::PathBuf::from(core.covers_dir());
        let meta: MetaAudioMetadata = crate::metadata::extract_metadata_blocking(&file_path, &covers_dir)
            .map_err(|e| CoreError::Storage { message: e.to_string() })?;
        Ok(convert_metadata(meta))
    }

    fn convert_metadata(meta: MetaAudioMetadata) -> ApiAudioMetadata {
        ApiAudioMetadata {
            title: meta.title,
            artist: meta.artist,
            release: meta.release,
            genre: meta.genre,
            year: meta.year,
            track: meta.track,
            disc: meta.disc,
            duration_seconds: meta.duration,
            bitrate: meta.bitrate,
            sample_rate: meta.sample_rate,
            channels: meta.channels,
            cover_artwork_id: meta.cover_path,
            all_fields: meta
                .all_fields
                .into_iter()
                .map(|(key, value)| KeyValuePair { key, value })
                .collect(),
            file_path: meta.file_path,
        }
    }
}