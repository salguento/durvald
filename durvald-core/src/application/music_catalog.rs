//! Read-only integration ports, deliberately separate from library-adoption writes.
//! Implementations must honor provider limits; dropping a future must not publish
//! obsolete results. Cooperative task cancellation belongs to the stage 2 runtime.

use super::music_plugins::PluginContext;
use std::{future::Future, pin::Pin};

use crate::domain::music::{
    IntegrationError,
    catalog::{CatalogEntityDetails, CatalogSearchPage, CatalogSearchRequest},
    identity::CatalogEntityRef,
    sources::{ResolvedMedia, SourceCandidate, SourceReference, SourceSearchRequest},
};

pub(crate) type IntegrationFuture<'a, T> =
    Pin<Box<dyn Future<Output = Result<T, IntegrationError>> + Send + 'a>>;

/// Local and external catalog adapters return values; they never adopt library items.
pub(crate) trait CatalogReader: Send + Sync {
    fn search(
        &self,
        context: PluginContext,
        request: CatalogSearchRequest,
    ) -> IntegrationFuture<'_, CatalogSearchPage>;

    /// Independent detail blocks; unsupported blocks never prevent basic identity.
    fn detail_section(
        &self,
        _context: PluginContext,
        _request: crate::api::CatalogDetailRequest,
    ) -> IntegrationFuture<'_, crate::api::CatalogDetailPage> {
        Box::pin(async { Err(IntegrationError::UnsupportedCapability) })
    }

    fn details(
        &self,
        context: PluginContext,
        target: CatalogEntityRef,
    ) -> IntegrationFuture<'_, CatalogEntityDetails>;
}

/// Finding candidate pages does not resolve media or start a download.
pub(crate) trait SourceFinder: Send + Sync {
    fn find_sources(
        &self,
        context: PluginContext,
        request: SourceSearchRequest,
    ) -> IntegrationFuture<'_, Vec<SourceCandidate>>;
}

/// Called near playback, never for every search result or the entire queue.
pub(crate) trait MediaResolver: Send + Sync {
    fn resolve(
        &self,
        context: PluginContext,
        source: SourceReference,
    ) -> IntegrationFuture<'_, ResolvedMedia>;
}

/// A search lease belongs to one request and one backend configuration.
pub(crate) trait DownloadSearchHandle: Send + Sync {
    fn endpoint(&self) -> String;
    fn poll(&self) -> IntegrationFuture<'_, crate::api::DownloadSearchPage>;
    fn cancel(&self) -> IntegrationFuture<'_, ()>;
}
pub(crate) trait DownloadSearcher: Send + Sync {
    fn begin(
        &self,
        context: PluginContext,
        request: crate::api::DownloadSearchRequest,
    ) -> IntegrationFuture<'_, std::sync::Arc<dyn DownloadSearchHandle>>;
}
