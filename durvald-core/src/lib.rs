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
pub mod audio;
pub mod core;
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
