//! Playback use-case coordination.
//!
//! Responsibilities move here incrementally while [`crate::core::DurvaldCore`]
//! remains the stable public facade.

/// Coordinates playback use cases behind the public core facade.
///
/// This type intentionally starts without dependencies. Concrete playback
/// collaborators will move into it alongside the first delegated use cases.
#[derive(Debug, Default)]
#[allow(dead_code)]
pub(crate) struct PlaybackApplication;
