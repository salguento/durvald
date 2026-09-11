//! Optional remote metadata infrastructure, independent of scanning and playback.
//!
//! Stage one exposes persisted settings and local profile snapshots only. HTTP
//! transport is available to future adapters; opening the core never invokes it.

pub mod models;
pub mod policy;
pub mod service;
pub mod transport;
