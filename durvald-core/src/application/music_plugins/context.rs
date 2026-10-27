use std::{
    collections::BTreeMap,
    sync::{Arc, Mutex},
};
use tokio::sync::watch;
use zeroize::Zeroizing;

use crate::domain::music::plugins::PluginConfiguration;

/// Owned secrets are erased on drop and never participate in Debug or persistence.
pub(crate) struct PluginSecret(Zeroizing<String>);
impl PluginSecret {
    pub(crate) fn new(value: String) -> Self {
        Self(Zeroizing::new(value))
    }
    pub(crate) fn expose(&self) -> &str {
        &self.0
    }
}
impl std::fmt::Debug for PluginSecret {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("PluginSecret([redacted])")
    }
}

#[derive(Clone)]
pub(crate) struct Cancellation(watch::Sender<bool>);
impl Default for Cancellation {
    fn default() -> Self {
        Self(watch::channel(false).0)
    }
}
impl Cancellation {
    pub(crate) fn cancel(&self) {
        self.0.send_replace(true);
    }
    pub(crate) fn is_cancelled(&self) -> bool {
        *self.0.borrow()
    }
    pub(crate) async fn cancelled(&self) {
        let mut changes = self.0.subscribe();
        loop {
            if *changes.borrow_and_update() {
                return;
            }
            if changes.changed().await.is_err() {
                return;
            }
        }
    }
}

/// One UI/use-case scope. Begin supersedes its previous request, across providers.
#[derive(Default)]
pub(crate) struct RequestScope(Mutex<Cancellation>);
impl RequestScope {
    pub(crate) fn begin(&self) -> RequestTicket {
        let mut current = self
            .0
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        current.cancel();
        *current = Cancellation::default();
        RequestTicket(current.clone())
    }
}
impl Drop for RequestScope {
    fn drop(&mut self) {
        self.0
            .get_mut()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .cancel();
    }
}

#[derive(Clone)]
pub(crate) struct RequestTicket(pub(super) Cancellation);
impl RequestTicket {
    pub(crate) fn cancel(&self) {
        self.0.cancel();
    }
    pub(crate) fn is_current(&self) -> bool {
        !self.0.is_cancelled()
    }
}

pub(crate) struct PluginContext {
    pub(crate) configuration: Arc<PluginConfiguration>,
    pub(crate) generation: u64,
    pub(super) credentials: BTreeMap<String, PluginSecret>,
    pub(super) lifecycle: Cancellation,
    pub(super) request: Cancellation,
}
impl PluginContext {
    pub(crate) fn credential(&self, key: &str) -> Option<&PluginSecret> {
        self.credentials.get(key)
    }
    pub(crate) fn is_cancelled(&self) -> bool {
        self.lifecycle.is_cancelled() || self.request.is_cancelled()
    }
    pub(crate) async fn cancelled(&self) {
        tokio::select! { _ = self.lifecycle.cancelled() => {}, _ = self.request.cancelled() => {} }
    }
}
impl std::fmt::Debug for PluginContext {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PluginContext")
            .field("configuration", &self.configuration)
            .field("generation", &self.generation)
            .field("credentials", &"[redacted]")
            .finish()
    }
}
