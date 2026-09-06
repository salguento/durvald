//! Executes core operations on Tokio; GTK widgets remain on the GLib thread.
use std::{future::Future, sync::Arc};

use durvald_core::{CoreConfig, CoreError, CoreResult, DurvaldCore};

#[derive(Clone)]
pub struct Backend {
    runtime: tokio::runtime::Handle,
}

impl Backend {
    pub fn new(runtime: tokio::runtime::Handle) -> Self {
        Self { runtime }
    }

    pub async fn run<T: Send + 'static>(
        &self,
        operation: impl Future<Output = CoreResult<T>> + Send + 'static,
    ) -> CoreResult<T> {
        self.runtime
            .spawn(operation)
            .await
            .map_err(|error| CoreError::Storage {
                message: format!("Background task failed: {error}"),
            })?
    }

    pub async fn open(&self) -> CoreResult<Arc<DurvaldCore>> {
        let data_dir = gtk::glib::user_data_dir().join("durvald");
        let data_dir = data_dir.to_str().ok_or_else(|| CoreError::InvalidInput {
            message: "Application data path must be valid UTF-8".into(),
        })?;
        let config = CoreConfig::new(data_dir.to_owned(), crate::APP_ID.to_owned());
        self.run(DurvaldCore::open(config)).await
    }
}
