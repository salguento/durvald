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
mod application;
mod artwork;
pub mod audio;
mod composition;
pub mod core;
pub mod database;
mod domain;
pub mod enrichment;
mod infrastructure;
pub mod lastfm;
mod metadata;
mod metadata_edit;
mod secure_store;

// Re-export public API types
pub use crate::api::*;
pub use crate::core::DurvaldCore;

#[cfg(feature = "test-support")]
#[doc(hidden)]
pub mod test_support;
