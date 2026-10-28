//! Built-in integration registry, isolated from the personal library and player.
use crate::{
    application::music_catalog::{CatalogReader, DownloadSearcher, MediaResolver, SourceFinder},
    domain::music::{
        identity::ProviderId,
        plugins::{PluginConfiguration, PluginError, PluginManifest, PluginPreferences},
    },
};
use std::{future::Future, pin::Pin};

pub(crate) mod context;
mod runtime;
pub(crate) use context::{PluginContext, PluginSecret, RequestTicket};
pub(crate) use runtime::{PluginRuntime, RuntimeLimits};

pub(crate) type PluginFuture<'a, T> =
    Pin<Box<dyn Future<Output = Result<T, PluginError>> + Send + 'a>>;

/// Only compiled-in trusted adapters. No dynamic code loading or detached workers.
pub(crate) trait MusicPlugin: Send + Sync {
    fn manifest(&self) -> PluginManifest;
    fn validate_configuration(
        &self,
        _configuration: &PluginConfiguration,
    ) -> Result<(), PluginError> {
        Ok(())
    }
    fn download_transfer(
        &self,
    ) -> Option<&dyn crate::application::transfer_ports::DownloadTransferProvider> {
        None
    }
    fn download_search(&self) -> Option<&dyn DownloadSearcher> {
        None
    }
    fn request_host(&self, _configuration: &PluginConfiguration) -> Option<String> {
        self.manifest().primary_host
    }
    fn catalog(&self) -> Option<&dyn CatalogReader> {
        None
    }
    fn sources(&self) -> Option<&dyn SourceFinder> {
        None
    }
    fn resolver(&self) -> Option<&dyn MediaResolver> {
        None
    }
}

pub(crate) trait PluginStateStore: Send + Sync {
    fn load(&self) -> PluginFuture<'_, PluginPreferences>;
    fn save(&self, preferences: PluginPreferences) -> PluginFuture<'_, ()>;
}

pub(crate) trait PluginCredentialStore: Send + Sync {
    fn get<'a>(
        &'a self,
        provider: &'a ProviderId,
        key: &'a str,
    ) -> PluginFuture<'a, Option<PluginSecret>>;
    fn set<'a>(
        &'a self,
        provider: &'a ProviderId,
        key: &'a str,
        value: PluginSecret,
    ) -> PluginFuture<'a, ()>;
    fn delete<'a>(&'a self, provider: &'a ProviderId, key: &'a str) -> PluginFuture<'a, ()>;
}

#[cfg(test)]
mod tests;
