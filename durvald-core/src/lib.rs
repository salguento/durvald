//! durvald-core: Core business logic for the durvald music player.
//! 
//! This crate contains all domain logic without any Tauri dependencies.
//! The public API is defined in the `api` module and exposed through
//! the `DurvaldCore` facade in the `core` module.

use uniffi::setup_scaffolding;

setup_scaffolding!();

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