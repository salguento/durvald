//! Catalog discovery is read-only. Provider pages are independently requested/published.
use crate::{
    api::*,
    application::music_plugins::{
        MusicPlugin, PluginRuntime, RequestTicket, context::RequestScope,
    },
    domain::music::{IntegrationError, catalog::*, identity::*, plugins::PluginError},
    infrastructure::sqlite::catalog_search::SqliteCatalogSearchQuery,
};
use std::sync::Arc;
use tokio::sync::Mutex;

pub(crate) struct CatalogSearchApplication {
    local: SqliteCatalogSearchQuery,
    plugins: Arc<PluginRuntime>,
    builtin: Arc<dyn MusicPlugin>,
}
pub(crate) struct CatalogSessionState {
    state: Mutex<Session>,
}
#[derive(Default)]
struct Session {
    generation: u64,
    signature: String,
    scope: RequestScope,
    ticket: Option<RequestTicket>,
    closed: bool,
}
impl Default for CatalogSessionState {
    fn default() -> Self {
        Self {
            state: Mutex::new(Session::default()),
        }
    }
}
impl CatalogSessionState {
    pub(crate) async fn cancel(&self, generation: u64) {
        let state = self.state.lock().await;
        if state.generation == generation {
            if let Some(ticket) = &state.ticket {
                ticket.cancel();
            }
        }
    }
    pub(crate) async fn close(&self) {
        let mut state = self.state.lock().await;
        state.closed = true;
        if let Some(ticket) = &state.ticket {
            ticket.cancel();
        }
    }
    async fn ticket(
        &self,
        query: &CatalogQuery,
        request: &CatalogSearchRequest,
    ) -> CoreResult<Option<RequestTicket>> {
        let mut state = self.state.lock().await;
        if state.closed || query.generation < state.generation {
            return Ok(None);
        }
        let signature = query_fingerprint(request, "session");
        if query.generation > state.generation {
            state.generation = query.generation;
            state.signature = signature;
            state.ticket = Some(state.scope.begin());
        } else if state.signature != signature {
            return Err(CoreError::InvalidInput {
                message: "Catalog generation cannot be reused for another query".into(),
            });
        }
        Ok(state.ticket.clone().filter(RequestTicket::is_current))
    }
}
impl CatalogSearchApplication {
    pub(crate) async fn new(
        local: SqliteCatalogSearchQuery,
        plugins: Arc<PluginRuntime>,
        builtin: Arc<dyn MusicPlugin>,
    ) -> Self {
        // Invalid plugin preferences never prevent local catalog search or core startup.
        let _ = plugins
            .register_builtin_with_default(builtin.clone(), true)
            .await;
        Self {
            local,
            plugins,
            builtin,
        }
    }
    pub(crate) async fn set_enabled(&self, enabled: bool) -> CoreResult<bool> {
        let id = ProviderId::new("musicbrainz").expect("built-in ID");
        match self.plugins.set_enabled(&id, enabled).await {
            Ok(status) => Ok(status.enabled),
            Err(PluginError::NotRegistered) if enabled => {
                self.plugins
                    .install(self.builtin.clone())
                    .await
                    .map_err(plugin_error)?;
                self.plugins
                    .set_enabled(&id, true)
                    .await
                    .map(|status| status.enabled)
                    .map_err(plugin_error)
            }
            Err(error) => Err(plugin_error(error)),
        }
    }
    pub(crate) async fn page(
        &self,
        session: &CatalogSessionState,
        provider: CatalogProvider,
        query: CatalogQuery,
    ) -> CoreResult<CatalogPage> {
        if query.generation == 0 || query.page_size == 0 || query.page_size > 50 {
            return Err(invalid_query());
        }
        let request = CatalogSearchRequest::new(
            &query.query,
            match query.scope {
                CatalogScope::Library => SearchScope::Library,
                CatalogScope::Explore => SearchScope::Explore,
            },
            match query.filter {
                CatalogFilter::All => SearchEntityFilter::All,
                CatalogFilter::Artists => SearchEntityFilter::Artists,
                CatalogFilter::Releases => SearchEntityFilter::Releases,
                CatalogFilter::Tracks => SearchEntityFilter::Tracks,
            },
            query.page_size,
            query.cursor.clone(),
        )
        .and_then(|request| request.with_language(&query.language))
        .map_err(|_| invalid_query())?
        .cached_only(query.cache_only);
        let Some(ticket) = session.ticket(&query, &request).await? else {
            return Ok(failed(
                provider,
                query.generation,
                CatalogFailure::Cancelled,
                None,
            ));
        };
        let result = match provider {
            CatalogProvider::Library => self
                .local
                .catalog_page(request)
                .await
                .map_err(PluginError::Adapter),
            CatalogProvider::MusicBrainz if query.scope == CatalogScope::Explore => {
                self.plugins
                    .search(
                        &ProviderId::new("musicbrainz").expect("built-in ID"),
                        ticket.clone(),
                        request,
                    )
                    .await
            }
            _ => {
                return Ok(failed(
                    provider,
                    query.generation,
                    CatalogFailure::InvalidQuery,
                    None,
                ));
            }
        };
        let state = session.state.lock().await;
        if state.closed || state.generation != query.generation || !ticket.is_current() {
            return Ok(failed(
                provider,
                query.generation,
                CatalogFailure::Cancelled,
                None,
            ));
        }
        Ok(match result {
            Ok(page) => CatalogPage {
                provider,
                generation: query.generation,
                items: page
                    .items
                    .into_iter()
                    .map(|item| public_item(provider, item))
                    .collect(),
                next_cursor: page.next_cursor,
                failure: None,
                retry_after_seconds: None,
                from_cache: page.from_cache,
            },
            Err(error) => {
                let (failure, retry) = failure(error);
                failed(provider, query.generation, failure, retry)
            }
        })
    }
}
fn invalid_query() -> CoreError {
    CoreError::InvalidInput {
        message: "Invalid catalog query, language or page size (1–50)".into(),
    }
}
fn plugin_error(_error: PluginError) -> CoreError {
    CoreError::Storage {
        message: "Catalog provider configuration unavailable".into(),
    }
}
fn failed(
    provider: CatalogProvider,
    generation: u64,
    failure: CatalogFailure,
    retry: Option<u64>,
) -> CatalogPage {
    CatalogPage {
        provider,
        generation,
        items: vec![],
        next_cursor: None,
        failure: Some(failure),
        retry_after_seconds: retry,
        from_cache: false,
    }
}
fn failure(error: PluginError) -> (CatalogFailure, Option<u64>) {
    match error {
        PluginError::Disabled | PluginError::NotRegistered => (CatalogFailure::Disabled, None),
        PluginError::Cancelled | PluginError::Adapter(IntegrationError::Cancelled) => {
            (CatalogFailure::Cancelled, None)
        }
        PluginError::Timeout | PluginError::Adapter(IntegrationError::Timeout) => {
            (CatalogFailure::TimedOut, None)
        }
        PluginError::Adapter(IntegrationError::RateLimited {
            retry_after_seconds,
        }) => (CatalogFailure::RateLimited, retry_after_seconds),
        PluginError::Adapter(IntegrationError::InvalidInput(_)) => {
            (CatalogFailure::InvalidQuery, None)
        }
        _ => (CatalogFailure::Unavailable, None),
    }
}
fn public_item(provider: CatalogProvider, item: CatalogEntitySummary) -> CatalogItem {
    let (kind, id, local_id, url) = match item.identity {
        CatalogEntityRef::Local(local) => {
            let (kind, id) = match local {
                LocalEntityRef::Artist(id) => (CatalogItemKind::Artist, id.get()),
                LocalEntityRef::Release(id) => (CatalogItemKind::ReleaseEdition, id.get()),
                LocalEntityRef::Track(id) => (CatalogItemKind::Track, id.get()),
                LocalEntityRef::Playlist(id) => (CatalogItemKind::Playlist, id.get()),
            };
            (kind, id.to_string(), Some(id as i64), None)
        }
        CatalogEntityRef::External(reference) => {
            let (kind, endpoint) = match reference.kind() {
                ExternalEntityKind::Artist => (CatalogItemKind::Artist, "artist"),
                ExternalEntityKind::ReleaseGroup => {
                    (CatalogItemKind::ReleaseGroup, "release-group")
                }
                ExternalEntityKind::ReleaseEdition => (CatalogItemKind::ReleaseEdition, "release"),
                _ => (CatalogItemKind::Recording, "recording"),
            };
            (
                kind,
                reference.external_id().to_owned(),
                None,
                Some(format!(
                    "https://musicbrainz.org/{endpoint}/{}",
                    reference.external_id()
                )),
            )
        }
    };
    CatalogItem {
        provider,
        kind,
        id,
        local_id,
        title: item.title,
        artist_credit: item.artist_credit,
        version_label: item.version_label,
        duration_seconds: item.duration_seconds,
        canonical_url: url,
    }
}
