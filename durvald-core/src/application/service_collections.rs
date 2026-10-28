//! Explicit service import jobs: bounded pages, cancellation and item-level receipts.
use crate::{
    api::*,
    application::{
        music_plugins::{PluginRuntime, PluginSecret, context::RequestScope},
        service_collection_ports::*,
    },
    domain::music::{IntegrationError as E, identity::ProviderId, plugins::PluginError as P},
    infrastructure::{
        public_services::{PublicService, credential_key, locate, plugin_id},
        sqlite::service_collections::ServiceCollectionRepository,
    },
};
use std::{
    collections::{HashMap, HashSet},
    sync::{
        Arc, Mutex as StdMutex,
        atomic::{AtomicBool, Ordering},
    },
};
use tokio::sync::Mutex;
#[derive(Clone, serde::Serialize, serde::Deserialize)]
pub(crate) struct LoadedPage {
    pub(crate) cursor: Option<String>,
    pub(crate) next_cursor: Option<String>,
    pub(crate) occurrences: Vec<String>,
}
#[derive(Clone, serde::Serialize, serde::Deserialize)]
pub(crate) struct StoredCollection {
    pub(crate) job: ServiceCollectionJob,
    pub(crate) pages: Vec<LoadedPage>,
}
struct Control {
    scope: RequestScope,
    cancel: Arc<AtomicBool>,
}
impl Default for Control {
    fn default() -> Self {
        Self {
            scope: RequestScope::default(),
            cancel: Arc::new(AtomicBool::new(false)),
        }
    }
}
pub(crate) struct ServiceCollectionsApplication {
    pub(crate) runtime: Arc<PluginRuntime>,
    pub(crate) repository: ServiceCollectionRepository,
    operations: Mutex<()>,
    controls: StdMutex<HashMap<String, Arc<Control>>>,
}
fn invalid(m: &str) -> CoreError {
    CoreError::InvalidInput { message: m.into() }
}
impl ServiceCollectionsApplication {
    pub(crate) async fn new(
        runtime: Arc<PluginRuntime>,
        repository: ServiceCollectionRepository,
    ) -> Self {
        for p in [
            ServiceProvider::Bandcamp,
            ServiceProvider::SoundCloud,
            ServiceProvider::YouTube,
        ] {
            let _ = runtime
                .register_builtin_with_default(Arc::new(PublicService::new(p)), false)
                .await;
        }
        Self {
            runtime,
            repository,
            operations: Mutex::new(()),
            controls: StdMutex::default(),
        }
    }
    fn control(&self, id: &str) -> Arc<Control> {
        self.controls
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .entry(id.into())
            .or_default()
            .clone()
    }
    pub(crate) async fn settings(&self) -> CoreResult<Vec<ServiceImportSettings>> {
        let statuses = self
            .runtime
            .list()
            .await
            .map_err(|_| invalid("Não foi possível ler as integrações."))?;
        let mut result = vec![];
        for provider in [
            ServiceProvider::Bandcamp,
            ServiceProvider::SoundCloud,
            ServiceProvider::YouTube,
        ] {
            let enabled = statuses
                .iter()
                .any(|s| s.manifest.id.as_str() == plugin_id(provider) && s.enabled);
            let has_credential = if let Some(key) = credential_key(provider) {
                self.runtime
                    .has_credential(&ProviderId::new(plugin_id(provider)).unwrap(), key)
                    .await
                    .unwrap_or(false)
            } else {
                false
            };
            result.push(ServiceImportSettings {
                provider,
                enabled,
                has_credential,
            });
        }
        Ok(result)
    }
    pub(crate) async fn configure(
        &self,
        provider: ServiceProvider,
        enabled: bool,
        credential: Option<String>,
    ) -> CoreResult<Vec<ServiceImportSettings>> {
        let _guard = self.operations.lock().await;
        let id = ProviderId::new(plugin_id(provider)).unwrap();
        if let Some(value) = credential {
            let key = credential_key(provider)
                .ok_or_else(|| invalid("Bandcamp público não usa credencial de conta."))?;
            if value.len() > 4096 || value.chars().any(char::is_control) || value.contains(' ') {
                return Err(invalid(
                    "Informe uma credencial válida, sem espaços ou quebras de linha.",
                ));
            }
            self.runtime
                .set_credential(
                    &id,
                    key,
                    if value.is_empty() {
                        None
                    } else {
                        Some(PluginSecret::new(value))
                    },
                )
                .await
                .map_err(|_| invalid("Não foi possível salvar a credencial protegida."))?;
        }
        self.runtime
            .set_enabled(&id, enabled)
            .await
            .map_err(|_| invalid("Não foi possível alterar esta integração."))?;
        self.settings().await
    }
    async fn enabled(&self, provider: ServiceProvider) -> CoreResult<bool> {
        Ok(self
            .runtime
            .list()
            .await
            .map_err(|_| invalid("Integrações indisponíveis."))?
            .iter()
            .any(|s| s.manifest.id.as_str() == plugin_id(provider) && s.enabled))
    }
    pub(crate) async fn list(&self) -> CoreResult<Vec<ServiceCollectionJob>> {
        Ok(self
            .repository
            .list()
            .await?
            .into_iter()
            .map(|j| j.job)
            .collect())
    }
    pub(crate) async fn begin(&self, url: String) -> CoreResult<ServiceCollectionJob> {
        let _guard = self.operations.lock().await;
        if crate::infrastructure::soundcloud_links::is_short_link(url.trim())
            && !self.enabled(ServiceProvider::SoundCloud).await?
        {
            return Err(invalid(
                "Ative a importação SoundCloud antes de resolver o link curto.",
            ));
        }
        let url = if crate::infrastructure::soundcloud_links::is_short_link(url.trim()) {
            crate::infrastructure::soundcloud_links::expand_service_link(url.trim())
                .await
                .map_err(|_| invalid("Não foi possível expandir o link SoundCloud."))?
        } else {
            url
        };
        let location=locate(&url).map_err(|_|invalid("Use um link público de faixa ou álbum Bandcamp, faixa ou playlist SoundCloud, vídeo ou playlist finita YouTube. Mixes, perfis e URLs privadas não são aceitos."))?;
        let id = crate::infrastructure::slskd_search::search_id()
            .map_err(|_| invalid("Não foi possível iniciar a importação."))?;
        let job = StoredCollection {
            pages: vec![],
            job: ServiceCollectionJob {
                job_id: id,
                provider: location.provider,
                canonical_url: location.url,
                title: location.id,
                is_collection: location.collection,
                items: vec![],
                next_cursor: None,
                loaded_pages: 0,
                complete: false,
                truncated: false,
                from_cache: false,
                cancelled: false,
                playlist_id: None,
                failure: None,
            },
        };
        Ok(self.repository.create(job).await?.job)
    }
    pub(crate) async fn load(
        &self,
        id: String,
        refresh: bool,
        retry_page: Option<u32>,
    ) -> CoreResult<ServiceCollectionJob> {
        let _guard = self.operations.lock().await;
        let mut job = self.repository.get(id).await?;
        if job.job.cancelled {
            return Err(invalid("Retome a captura antes de consultar mais páginas."));
        }
        if !self.enabled(job.job.provider).await? {
            job.job.failure = Some(ServiceImportFailure::Disabled);
            self.repository.save(job.clone()).await?;
            return Ok(job.job);
        }
        if retry_page.is_none()
            && (job.job.complete
                || job.job.items.len() >= 1000
                || job.pages.len() >= 40
                || (!job.pages.is_empty() && job.job.next_cursor.is_none()))
        {
            return Ok(job.job);
        }
        let cursor = if let Some(index) = retry_page {
            job.pages
                .get(index as usize)
                .ok_or_else(|| invalid("Página de captura inexistente."))?
                .cursor
                .clone()
        } else if job.pages.is_empty() {
            None
        } else {
            job.job.next_cursor.clone()
        };
        let control = self.control(&job.job.job_id);
        if control.cancel.load(Ordering::SeqCst) {
            job.job.failure = Some(ServiceImportFailure::Cancelled);
            job.job.cancelled = true;
            self.repository.save(job.clone()).await?;
            return Ok(job.job);
        }
        let ticket = control.scope.begin();
        let key = cache_key(job.job.provider, &job.job.canonical_url, cursor.as_deref());
        let cached = if refresh {
            None
        } else {
            self.repository.cached(key.clone()).await?
        };
        let (result, from_cache) = if let Some(page) = cached {
            (Ok(page), true)
        } else {
            (
                self.runtime
                    .read_service_collection(
                        &ProviderId::new(plugin_id(job.job.provider)).unwrap(),
                        ticket.clone(),
                        ServicePageRequest {
                            url: job.job.canonical_url.clone(),
                            cursor: cursor.clone(),
                        },
                    )
                    .await,
                false,
            )
        };
        if !ticket.is_current() || control.cancel.load(Ordering::SeqCst) {
            job.job.failure = Some(ServiceImportFailure::Cancelled);
            job.job.cancelled = true;
            self.repository.save(job.clone()).await?;
            return Ok(job.job);
        }
        match result {
            Ok(page) => {
                if validate_page(&job, &page, retry_page).is_err() {
                    job.job.failure = Some(ServiceImportFailure::ChangedCollection);
                } else {
                    if !from_cache {
                        self.repository.cache(key, page.clone()).await?;
                    }
                    if let Some(index) = retry_page {
                        for incoming in page.items {
                            if let Some(old) = job
                                .job
                                .items
                                .iter_mut()
                                .find(|i| i.occurrence_id == incoming.occurrence_id)
                            {
                                let saved = old.saved_track_id;
                                *old = incoming;
                                old.saved_track_id = saved;
                            }
                        }
                        job.pages[index as usize].next_cursor = page.next_cursor;
                    } else {
                        let occurrences =
                            page.items.iter().map(|i| i.occurrence_id.clone()).collect();
                        job.job.items.extend(page.items);
                        job.pages.push(LoadedPage {
                            cursor,
                            next_cursor: page.next_cursor.clone(),
                            occurrences,
                        });
                        job.job.next_cursor = page.next_cursor;
                        job.job.title = page.title;
                        job.job.truncated |= page.truncated;
                        job.job.complete = job.job.next_cursor.is_none() && !job.job.truncated;
                    }
                    job.job.loaded_pages = job.pages.len() as u32;
                    job.job.from_cache = from_cache;
                    job.job.failure = if (job.job.items.len() >= 1000 || job.pages.len() >= 40)
                        && !job.job.complete
                    {
                        Some(ServiceImportFailure::LimitReached)
                    } else {
                        None
                    };
                }
            }
            Err(error) => job.job.failure = Some(failure(error)),
        }
        self.repository.save(job.clone()).await?;
        Ok(job.job)
    }
    pub(crate) async fn apply(
        &self,
        id: String,
        selected: Vec<String>,
        confirmed: bool,
    ) -> CoreResult<ServiceCollectionJob> {
        let _guard = self.operations.lock().await;
        let job = self.repository.get(id).await?;
        if !confirmed
            || job.job.cancelled
            || selected.is_empty()
            || selected.len() > 1000
            || !selected
                .iter()
                .all(|id| job.job.items.iter().any(|i| &i.occurrence_id == id))
        {
            return Err(invalid(
                "Revise a gravação, a versão e os itens desta captura antes de confirmar.",
            ));
        }
        if !self.enabled(job.job.provider).await? {
            return Err(invalid("Habilite esta integração antes de importar."));
        }
        let control = self.control(&job.job.job_id);
        self.repository
            .apply(job, selected, control.cancel.clone())
            .await
            .map(|j| j.job)
    }
    pub(crate) async fn cancel(&self, id: String) -> CoreResult<ServiceCollectionJob> {
        self.repository.get(id.clone()).await?;
        let control = self.control(&id);
        control.cancel.store(true, Ordering::SeqCst);
        control.scope.begin().cancel();
        let _guard = self.operations.lock().await;
        let mut job = self.repository.get(id).await?;
        job.job.cancelled = true;
        job.job.failure = Some(ServiceImportFailure::Cancelled);
        self.repository.save(job.clone()).await?;
        Ok(job.job)
    }
    pub(crate) async fn resume(&self, id: String) -> CoreResult<ServiceCollectionJob> {
        let _guard = self.operations.lock().await;
        let mut job = self.repository.get(id).await?;
        self.control(&job.job.job_id)
            .cancel
            .store(false, Ordering::SeqCst);
        job.job.cancelled = false;
        job.job.failure = None;
        self.repository.save(job.clone()).await?;
        Ok(job.job)
    }
}
fn cache_key(provider: ServiceProvider, url: &str, cursor: Option<&str>) -> String {
    use sha2::{Digest, Sha256};
    format!(
        "{:x}",
        Sha256::digest(serde_json::to_vec(&(provider, url, cursor)).unwrap())
    )
}
fn validate_page(job: &StoredCollection, page: &ServicePage, retry: Option<u32>) -> Result<(), ()> {
    if page.title.is_empty()
        || page.title.len() > 2000
        || page.title.chars().any(char::is_control)
        || page.items.len() > 50
        || page.is_collection != job.job.is_collection
    {
        return Err(());
    }
    if page.next_cursor.as_ref().is_some_and(|c| {
        c.is_empty()
            || c.len() > 4096
            || c.chars().any(char::is_control)
            || (retry.is_none()
                && (job.pages.iter().any(|p| p.cursor.as_ref() == Some(c))
                    || job.job.next_cursor.as_ref() == Some(c)))
    }) {
        return Err(());
    }
    let mut ids = HashSet::new();
    let mut positions = HashSet::new();
    let mut last = None;
    for item in &page.items {
        if item.occurrence_id.is_empty()
            || item.occurrence_id.len() > 2000
            || item.saved_track_id.is_some()
            || item.position > 100000
            || !ids.insert(&item.occurrence_id)
            || !positions.insert(item.position)
            || last.is_some_and(|p| p >= item.position)
        {
            return Err(());
        }
        last = Some(item.position);
        if let Some(entry) = &item.entry {
            let parsed = entry
                .canonical_url
                .as_deref()
                .and_then(crate::infrastructure::service_links::canonical_link)
                .ok_or(())?;
            if parsed.entity().provider().as_str()
                != crate::infrastructure::public_services::provider_name(job.job.provider)
                || parsed.entity().external_id() != entry.reference.id
                || entry.title.is_empty()
                || entry.title.len() > 2000
                || entry.title.chars().any(char::is_control)
            {
                return Err(());
            }
        }
    }
    if let Some(index) = retry {
        let prior = &job.pages[index as usize];
        if prior.next_cursor != page.next_cursor
            || prior.occurrences
                != page
                    .items
                    .iter()
                    .map(|i| i.occurrence_id.clone())
                    .collect::<Vec<_>>()
        {
            return Err(());
        }
        for item in &page.items {
            let old = job
                .job
                .items
                .iter()
                .find(|i| i.occurrence_id == item.occurrence_id)
                .ok_or(())?;
            if old.position != item.position
                || old
                    .entry
                    .as_ref()
                    .zip(item.entry.as_ref())
                    .is_some_and(|(a, b)| a.reference != b.reference)
            {
                return Err(());
            }
        }
    } else if page.items.iter().any(|item| {
        job.job
            .items
            .iter()
            .any(|old| old.occurrence_id == item.occurrence_id || old.position == item.position)
    }) {
        return Err(());
    }
    Ok(())
}
fn failure(error: P) -> ServiceImportFailure {
    match error {
        P::Disabled | P::NotRegistered => ServiceImportFailure::Disabled,
        P::MissingCredential | P::Adapter(E::AuthenticationRequired) => {
            ServiceImportFailure::Authentication
        }
        P::Adapter(E::AccessDenied) => ServiceImportFailure::Restricted,
        P::Adapter(E::NotFound) => ServiceImportFailure::NotFound,
        P::Timeout | P::Adapter(E::Timeout) => ServiceImportFailure::TimedOut,
        P::Adapter(E::RateLimited { .. }) => ServiceImportFailure::RateLimited,
        P::Cancelled | P::Adapter(E::Cancelled) => ServiceImportFailure::Cancelled,
        P::Adapter(E::InvalidResponse | E::InvalidInput(_)) => {
            ServiceImportFailure::InvalidResponse
        }
        _ => ServiceImportFailure::Unavailable,
    }
}
