//! Optional remote metadata infrastructure, independent of scanning and playback.
//!
//! Local reads and explicit MusicBrainz identity lookups. Opening the core and
//! scanning files never initiate HTTP requests.

pub mod models;
pub mod policy;
pub mod service;
pub mod transport;

pub mod identity;
pub mod providers;
