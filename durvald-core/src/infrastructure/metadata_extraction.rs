//! Local audio metadata extraction adapter.

use std::{
    path::Path,
    sync::{Arc, atomic::AtomicBool},
};

use crate::database::operations::{
    ExtractedMetadata, MetadataProgressCallback, PendingMetadataBatch,
};

pub(crate) struct LocalMetadataExtractor;

impl LocalMetadataExtractor {
    pub(crate) fn new() -> Self {
        Self
    }

    pub(crate) async fn extract(
        &self,
        batch: PendingMetadataBatch,
        covers_dir: &Path,
        cancellation: Arc<AtomicBool>,
        progress: Option<&MetadataProgressCallback>,
    ) -> ExtractedMetadata {
        crate::database::operations::extract_metadata_batch_with_cancel(
            batch,
            covers_dir,
            Some(cancellation),
            progress,
        )
        .await
    }
}
