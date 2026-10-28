//! Application services that coordinate Durvald use cases.

pub(crate) mod enrichment;
pub(crate) mod history;
pub(crate) mod lastfm;
pub(crate) mod library;
pub(crate) mod metadata;
// Stage 1 ports; adapters and orchestration are introduced in subsequent stages.
#[allow(dead_code)]
pub(crate) mod music_catalog;
// Internal runtime; real catalog adapters and native commands follow in stage 3.
pub(crate) mod catalog_search;
#[allow(dead_code)]
pub(crate) mod music_plugins;
pub(crate) mod playback;
pub(crate) mod playlist;
pub(crate) mod settings;

pub(crate) mod catalog_details;
pub(crate) mod sources;

mod playback_embedded;

mod playback_sources;

pub(crate) mod download_search;

pub(crate) mod transfer_ports;
pub(crate) mod download_transfers;

pub(crate) mod service_collections;
pub(crate) mod service_collection_ports;
