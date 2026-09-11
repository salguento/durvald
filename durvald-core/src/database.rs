//! Database module - core data models and operations without Tauri dependencies

pub mod enrichment;
pub mod migrations;
pub mod models;
pub mod operations;

pub use models::*;
pub use operations::*;
