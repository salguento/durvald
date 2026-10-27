//! Domain types shared by application services.

pub(crate) mod catalog;
pub(crate) mod ids;
// Stage 1 contracts; consumed incrementally by the integration registry and catalog.
#[allow(dead_code)]
pub(crate) mod music;
pub(crate) mod playback_history;
pub(crate) mod playback_session;
pub(crate) mod playlist;
pub(crate) mod settings;

pub(crate) mod rating;

pub(crate) mod replay;
pub(crate) mod smart_playlist;
