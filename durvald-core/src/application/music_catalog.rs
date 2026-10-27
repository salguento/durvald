//! Read-only integration ports, deliberately separate from library-adoption writes.
//! Implementations must honor provider limits; dropping a future must not publish
//! obsolete results. Cooperative task cancellation belongs to the stage 2 runtime.

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
    fn search(&self, request: CatalogSearchRequest) -> IntegrationFuture<'_, CatalogSearchPage>;

    fn details(&self, target: CatalogEntityRef) -> IntegrationFuture<'_, CatalogEntityDetails>;
}

/// Finding candidate pages does not resolve media or start a download.
pub(crate) trait SourceFinder: Send + Sync {
    fn find_sources(
        &self,
        request: SourceSearchRequest,
    ) -> IntegrationFuture<'_, Vec<SourceCandidate>>;
}

/// Called near playback, never for every search result or the entire queue.
pub(crate) trait MediaResolver: Send + Sync {
    fn resolve(&self, source: SourceReference) -> IntegrationFuture<'_, ResolvedMedia>;
}
