use std::sync::Arc;

use crate::{CoreConfig, CoreResult, DurvaldCore};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AudioSettingsSnapshot {
    pub crossfade_duration_seconds: Option<u64>,
    pub normalize_volume: bool,
}

pub async fn open_core(config: CoreConfig) -> CoreResult<Arc<DurvaldCore>> {
    DurvaldCore::open_with_mock_audio(config).await
}

pub async fn registered_music_plugin_count(core: &DurvaldCore) -> CoreResult<usize> {
    core.music_plugins()
        .list()
        .await
        .map(|plugins| plugins.len())
        .map_err(|_| crate::api::CoreError::Storage {
            message: "Music plugin preferences unavailable".into(),
        })
}

pub async fn process_mock_audio(core: &DurvaldCore, blocks: usize) {
    core.process_mock_audio(blocks).await;
}

pub async fn audio_settings(core: &DurvaldCore) -> AudioSettingsSnapshot {
    let player = core.audio_player().lock().await;
    AudioSettingsSnapshot {
        crossfade_duration_seconds: player.crossfade_duration_seconds(),
        normalize_volume: player.normalize_volume_enabled(),
    }
}
