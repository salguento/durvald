use std::sync::Arc;

use crate::{CoreConfig, CoreResult, DurvaldCore};

pub async fn open_core(config: CoreConfig) -> CoreResult<Arc<DurvaldCore>> {
    DurvaldCore::open_with_mock_audio(config).await
}

pub async fn process_mock_audio(core: &DurvaldCore, blocks: usize) {
    core.process_mock_audio(blocks).await;
}
