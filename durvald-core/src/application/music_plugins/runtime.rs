use std::{
    collections::{BTreeMap, HashMap},
    future::Future,
    sync::Arc,
    time::Duration,
};
use tokio::{
    sync::{Mutex, Semaphore},
    task::JoinHandle,
};

use super::{
    MusicPlugin, PluginContext, PluginCredentialStore, PluginSecret, PluginStateStore,
    RequestTicket, context::Cancellation,
};
use crate::{
    domain::music::{
        IntegrationError,
        catalog::{CatalogEntityDetails, CatalogSearchPage, CatalogSearchRequest},
        identity::{CatalogEntityRef, ProviderId},
        plugins::*,
        sources::{ResolvedMedia, SourceCandidate, SourceReference, SourceSearchRequest},
    },
    infrastructure::music_plugins::RemoteRequestScope,
};

#[derive(Clone, Copy)]
pub(crate) struct RuntimeLimits {
    pub(crate) concurrent: usize,
    pub(crate) per_plugin: usize,
    pub(crate) admitted: usize,
    pub(crate) timeout: Duration,
}
impl Default for RuntimeLimits {
    fn default() -> Self {
        Self {
            concurrent: 4,
            per_plugin: 2,
            admitted: 32,
            timeout: Duration::from_secs(30),
        }
    }
}

struct Entry {
    adapter: Arc<dyn MusicPlugin>,
    manifest: PluginManifest,
    configuration: Arc<PluginConfiguration>,
    enabled: bool,
    generation: u64,
    cancel: Cancellation,
    slots: Arc<Semaphore>,
}
impl Entry {
    fn status(&self) -> PluginStatus {
        PluginStatus {
            manifest: self.manifest.clone(),
            enabled: self.enabled,
            generation: self.generation,
            configuration: (*self.configuration).clone(),
        }
    }
}
#[derive(Default)]
struct Registry {
    entries: HashMap<ProviderId, Arc<Entry>>,
    preferences: PluginPreferences,
    next_generation: u64,
    storage_error: Option<PluginError>,
}
#[derive(Clone)]
pub(crate) struct PluginRuntime(Arc<RuntimeState>);

pub(crate) struct RuntimeState {
    registry: Mutex<Registry>,
    control: Mutex<()>,
    administration: Arc<Semaphore>,
    store: Arc<dyn PluginStateStore>,
    credentials: Arc<dyn PluginCredentialStore>,
    remote: Arc<RemoteRequestScope>,
    slots: Arc<Semaphore>,
    admitted: Arc<Semaphore>,
    limits: RuntimeLimits,
}

impl std::ops::Deref for PluginRuntime {
    type Target = RuntimeState;
    fn deref(&self) -> &Self::Target {
        &self.0
    }
}

impl PluginRuntime {
    pub(crate) async fn new(
        store: Arc<dyn PluginStateStore>,
        credentials: Arc<dyn PluginCredentialStore>,
        remote: Arc<RemoteRequestScope>,
        limits: RuntimeLimits,
    ) -> Result<Self, PluginError> {
        if limits.concurrent == 0
            || limits.concurrent > 128
            || limits.per_plugin == 0
            || limits.per_plugin > limits.concurrent
            || limits.admitted < limits.concurrent
            || limits.admitted > 1024
            || limits.timeout.is_zero()
            || limits.timeout > Duration::from_secs(300)
        {
            return Err(PluginError::InvalidConfiguration);
        }
        // Corrupt/unavailable plugin settings disable this subsystem, never the library.
        let mut registry = Registry::default();
        match store.load().await {
            Ok(preferences) => registry.preferences = preferences,
            Err(error) => registry.storage_error = Some(error),
        }
        Ok(Self(Arc::new(RuntimeState {
            registry: Mutex::new(registry),
            control: Mutex::new(()),
            administration: Arc::new(Semaphore::new(limits.admitted)),
            store,
            credentials,
            remote,
            slots: Arc::new(Semaphore::new(limits.concurrent)),
            admitted: Arc::new(Semaphore::new(limits.admitted)),
            limits,
        })))
    }

    pub(crate) async fn has_credential(
        &self,
        id: &ProviderId,
        key: &str,
    ) -> Result<bool, PluginError> {
        Ok(self.credentials.get(id, key).await?.is_some())
    }
    pub(crate) async fn list(&self) -> Result<Vec<PluginStatus>, PluginError> {
        let registry = self.registry.lock().await;
        if let Some(error) = registry.storage_error {
            return Err(error);
        }
        let mut result = registry
            .entries
            .values()
            .map(|entry| entry.status())
            .collect::<Vec<_>>();
        result.sort_by(|a, b| a.manifest.id.as_str().cmp(b.manifest.id.as_str()));
        Ok(result)
    }

    /// Composition registration respects persisted uninstall tombstones.
    pub(crate) async fn register_builtin(
        &self,
        adapter: Arc<dyn MusicPlugin>,
    ) -> Result<Option<PluginStatus>, PluginError> {
        self.mutation(move |runtime| async move { runtime.register(adapter, false, false).await })
            .await
    }
    /// Defaults apply only to a previously unseen built-in; user disable/removal wins.
    pub(crate) async fn register_builtin_with_default(
        &self,
        adapter: Arc<dyn MusicPlugin>,
        enabled: bool,
    ) -> Result<Option<PluginStatus>, PluginError> {
        self.mutation(move |runtime| async move { runtime.register(adapter, false, enabled).await })
            .await
    }
    /// Explicit reinstall may replace a tombstone, with disabled default configuration.
    pub(crate) async fn install(
        &self,
        adapter: Arc<dyn MusicPlugin>,
    ) -> Result<PluginStatus, PluginError> {
        self.mutation(move |runtime| async move {
            runtime
                .register(adapter, true, false)
                .await?
                .ok_or(PluginError::NotRegistered)
        })
        .await
    }
    /// Administrative writes finish under the control gate even if their caller
    /// drops the awaiting future. This prevents partial disk/in-memory commits.
    async fn mutation<T, F, Fut>(&self, operation: F) -> Result<T, PluginError>
    where
        T: Send + 'static,
        F: FnOnce(Self) -> Fut + Send + 'static,
        Fut: Future<Output = Result<T, PluginError>> + Send + 'static,
    {
        let permit = self
            .administration
            .clone()
            .try_acquire_owned()
            .map_err(|_| PluginError::Busy)?;
        let runtime = self.clone();
        tokio::spawn(async move {
            let _permit = permit;
            operation(runtime).await
        })
        .await
        .map_err(|_| PluginError::AdapterFailed)?
    }
    pub(crate) async fn set_enabled(
        &self,
        id: &ProviderId,
        enabled: bool,
    ) -> Result<PluginStatus, PluginError> {
        let id = id.clone();
        self.mutation(move |runtime| async move { runtime.set_enabled_inner(&id, enabled).await })
            .await
    }
    pub(crate) async fn configure(
        &self,
        id: &ProviderId,
        configuration: PluginConfiguration,
    ) -> Result<PluginStatus, PluginError> {
        let id = id.clone();
        self.mutation(
            move |runtime| async move { runtime.configure_inner(&id, configuration).await },
        )
        .await
    }
    pub(crate) async fn set_credential(
        &self,
        id: &ProviderId,
        key: &str,
        value: Option<PluginSecret>,
    ) -> Result<PluginStatus, PluginError> {
        let id = id.clone();
        let key = key.to_owned();
        self.mutation(
            move |runtime| async move { runtime.set_credential_inner(&id, &key, value).await },
        )
        .await
    }
    pub(crate) async fn remove(&self, id: &ProviderId) -> Result<(), PluginError> {
        let id = id.clone();
        self.mutation(move |runtime| async move { runtime.remove_inner(&id).await })
            .await
    }
    async fn register(
        &self,
        adapter: Arc<dyn MusicPlugin>,
        explicit: bool,
        default_enabled: bool,
    ) -> Result<Option<PluginStatus>, PluginError> {
        let _control = self.control.lock().await;
        let manifest = adapter.manifest();
        manifest.validate()?;
        for capability in &manifest.capabilities {
            let implemented = match capability {
                PluginCapability::CatalogSearch | PluginCapability::Metadata => {
                    adapter.catalog().is_some()
                }
                PluginCapability::SourceSearch => adapter.sources().is_some(),
                PluginCapability::Playback => adapter.resolver().is_some(),
                PluginCapability::DownloadSearch => adapter.download_search().is_some(),
                _ => false, // Reserved capabilities gain ports in their own roadmap stages.
            };
            if !implemented {
                return Err(PluginError::PermissionDenied);
            }
        }
        let mut preferences = {
            let registry = self.registry.lock().await;
            if let Some(error) = registry.storage_error {
                return Err(error);
            }
            if registry.entries.contains_key(&manifest.id) {
                return Err(PluginError::AlreadyRegistered);
            }
            if registry.entries.len() >= 128 {
                return Err(PluginError::Busy);
            }
            registry.preferences.clone()
        };
        let was_registered = preferences.contains_key(manifest.id.as_str());
        let saved = preferences
            .get(manifest.id.as_str())
            .cloned()
            .unwrap_or_default();
        if saved.removed && !explicit {
            return Ok(None);
        }
        let mut configuration = manifest.defaults();
        if !saved.removed {
            configuration.values.extend(saved.configuration.values);
            configuration.flags.extend(saved.configuration.flags);
        }
        let enabled = !saved.removed && (saved.enabled || (!was_registered && default_enabled));
        manifest.validate_configuration(&configuration, enabled)?;
        adapter.validate_configuration(&configuration)?;
        if enabled {
            self.load_credentials(&manifest).await?;
        }
        preferences.insert(
            manifest.id.as_str().to_owned(),
            SavedPluginState {
                enabled,
                removed: false,
                configuration: configuration.clone(),
            },
        );
        self.store.save(preferences.clone()).await?;
        let mut registry = self.registry.lock().await;
        registry.next_generation += 1;
        let entry = Arc::new(Entry {
            adapter,
            manifest,
            configuration: Arc::new(configuration),
            enabled,
            generation: registry.next_generation,
            cancel: Cancellation::default(),
            slots: Arc::new(Semaphore::new(self.limits.per_plugin)),
        });
        let status = entry.status();
        registry.entries.insert(entry.manifest.id.clone(), entry);
        registry.preferences = preferences;
        Ok(Some(status))
    }

    async fn entry(&self, id: &ProviderId) -> Result<Arc<Entry>, PluginError> {
        let registry = self.registry.lock().await;
        if let Some(error) = registry.storage_error {
            return Err(error);
        }
        registry
            .entries
            .get(id)
            .cloned()
            .ok_or(PluginError::NotRegistered)
    }
    async fn replace(
        &self,
        old: Arc<Entry>,
        enabled: bool,
        configuration: PluginConfiguration,
    ) -> Result<PluginStatus, PluginError> {
        let mut preferences = self.registry.lock().await.preferences.clone();
        preferences.insert(
            old.manifest.id.as_str().to_owned(),
            SavedPluginState {
                enabled,
                removed: false,
                configuration: configuration.clone(),
            },
        );
        self.store.save(preferences.clone()).await?;
        let mut registry = self.registry.lock().await;
        old.cancel.cancel();
        registry.next_generation += 1;
        let entry = Arc::new(Entry {
            adapter: old.adapter.clone(),
            manifest: old.manifest.clone(),
            configuration: Arc::new(configuration),
            enabled,
            generation: registry.next_generation,
            cancel: Cancellation::default(),
            slots: old.slots.clone(),
        });
        let status = entry.status();
        registry.entries.insert(entry.manifest.id.clone(), entry);
        registry.preferences = preferences;
        Ok(status)
    }
    async fn set_enabled_inner(
        &self,
        id: &ProviderId,
        enabled: bool,
    ) -> Result<PluginStatus, PluginError> {
        let _control = self.control.lock().await;
        let entry = self.entry(id).await?;
        if enabled == entry.enabled {
            return Ok(entry.status());
        }
        entry
            .manifest
            .validate_configuration(&entry.configuration, enabled)?;
        if enabled {
            self.load_credentials(&entry.manifest).await?;
        }
        self.replace(entry.clone(), enabled, (*entry.configuration).clone())
            .await
    }
    async fn configure_inner(
        &self,
        id: &ProviderId,
        configuration: PluginConfiguration,
    ) -> Result<PluginStatus, PluginError> {
        let _control = self.control.lock().await;
        let entry = self.entry(id).await?;
        entry
            .manifest
            .validate_configuration(&configuration, entry.enabled)?;
        entry.adapter.validate_configuration(&configuration)?;
        if *entry.configuration == configuration {
            return Ok(entry.status());
        }
        self.replace(entry.clone(), entry.enabled, configuration)
            .await
    }
    async fn set_credential_inner(
        &self,
        id: &ProviderId,
        key: &str,
        value: Option<PluginSecret>,
    ) -> Result<PluginStatus, PluginError> {
        let _control = self.control.lock().await;
        let entry = self.entry(id).await?;
        if !entry
            .manifest
            .permissions
            .contains(&PluginPermission::Credentials)
            || !entry.manifest.credentials.contains_key(key)
        {
            return Err(PluginError::PermissionDenied);
        }
        if value
            .as_ref()
            .is_some_and(|secret| secret.expose().is_empty() || secret.expose().len() > 65536)
        {
            return Err(PluginError::InvalidConfiguration);
        }
        // Fail closed: stop old credential users before touching platform storage.
        if entry.enabled {
            self.replace(entry.clone(), false, (*entry.configuration).clone())
                .await?;
        }
        match value {
            Some(secret) => self.credentials.set(id, key, secret).await?,
            None => self.credentials.delete(id, key).await?,
        }
        let current = self.entry(id).await?;
        if entry.enabled {
            match self.load_credentials(&current.manifest).await {
                Ok(_) => {
                    return self
                        .replace(current.clone(), true, (*current.configuration).clone())
                        .await;
                }
                Err(PluginError::MissingCredential) => {}
                Err(error) => return Err(error),
            }
        }
        Ok(current.status())
    }
    async fn remove_inner(&self, id: &ProviderId) -> Result<(), PluginError> {
        let _control = self.control.lock().await;
        let mut entry = self.entry(id).await?;
        if entry.enabled {
            self.replace(entry.clone(), false, (*entry.configuration).clone())
                .await?;
            entry = self.entry(id).await?;
        }
        // Keep a disabled entry available for retry if platform cleanup fails.
        for key in entry.manifest.credentials.keys() {
            self.credentials.delete(id, key).await?;
        }
        let mut preferences = self.registry.lock().await.preferences.clone();
        preferences.insert(
            id.as_str().to_owned(),
            SavedPluginState {
                removed: true,
                ..SavedPluginState::default()
            },
        );
        self.store.save(preferences.clone()).await?;
        {
            let mut registry = self.registry.lock().await;
            entry.cancel.cancel();
            registry.entries.remove(id);
            registry.preferences = preferences;
        }
        // Catalog/library storage is not a dependency of this runtime.
        Ok(())
    }
    async fn load_credentials(
        &self,
        manifest: &PluginManifest,
    ) -> Result<BTreeMap<String, PluginSecret>, PluginError> {
        let mut values = BTreeMap::new();
        for (key, required) in &manifest.credentials {
            match self.credentials.get(&manifest.id, key).await? {
                Some(secret) => {
                    values.insert(key.clone(), secret);
                }
                None if *required => return Err(PluginError::MissingCredential),
                None => {}
            }
        }
        Ok(values)
    }

    pub(crate) async fn search(
        &self,
        id: &ProviderId,
        ticket: RequestTicket,
        request: CatalogSearchRequest,
    ) -> Result<CatalogSearchPage, PluginError> {
        self.execute(
            id,
            PluginCapability::CatalogSearch,
            ticket,
            !request.is_cache_only(),
            move |adapter, context| async move {
                adapter
                    .catalog()
                    .ok_or(IntegrationError::UnsupportedCapability)?
                    .search(context, request)
                    .await
            },
        )
        .await
    }
    pub(crate) async fn details(
        &self,
        id: &ProviderId,
        ticket: RequestTicket,
        target: CatalogEntityRef,
    ) -> Result<CatalogEntityDetails, PluginError> {
        self.execute(
            id,
            PluginCapability::Metadata,
            ticket,
            true,
            move |adapter, context| async move {
                adapter
                    .catalog()
                    .ok_or(IntegrationError::UnsupportedCapability)?
                    .details(context, target)
                    .await
            },
        )
        .await
    }
    pub(crate) async fn detail_section(
        &self,
        id: &ProviderId,
        ticket: RequestTicket,
        request: crate::api::CatalogDetailRequest,
    ) -> Result<crate::api::CatalogDetailPage, PluginError> {
        // Blocks can use different hosts. Each existing transport enforces its own
        // cooldown; do not attribute a Wikimedia/CAA failure to MusicBrainz.
        self.execute(
            id,
            PluginCapability::Metadata,
            ticket,
            false,
            move |adapter, context| async move {
                adapter
                    .catalog()
                    .ok_or(IntegrationError::UnsupportedCapability)?
                    .detail_section(context, request)
                    .await
            },
        )
        .await
    }
    pub(crate) async fn find_sources(
        &self,
        id: &ProviderId,
        ticket: RequestTicket,
        request: SourceSearchRequest,
    ) -> Result<Vec<SourceCandidate>, PluginError> {
        self.execute(
            id,
            PluginCapability::SourceSearch,
            ticket,
            true,
            move |adapter, context| async move {
                adapter
                    .sources()
                    .ok_or(IntegrationError::UnsupportedCapability)?
                    .find_sources(context, request)
                    .await
            },
        )
        .await
    }
    pub(crate) async fn resolve(
        &self,
        id: &ProviderId,
        ticket: RequestTicket,
        source: SourceReference,
    ) -> Result<ResolvedMedia, PluginError> {
        self.execute(
            id,
            PluginCapability::Playback,
            ticket,
            true,
            move |adapter, context| async move {
                adapter
                    .resolver()
                    .ok_or(IntegrationError::UnsupportedCapability)?
                    .resolve(context, source)
                    .await
            },
        )
        .await
    }

    pub(crate) async fn begin_download_search(
        &self,
        ticket: RequestTicket,
        request: crate::api::DownloadSearchRequest,
    ) -> Result<
        (
            u64,
            Arc<dyn crate::application::music_catalog::DownloadSearchHandle>,
        ),
        PluginError,
    > {
        self.execute(
            &ProviderId::new("slskd").unwrap(),
            PluginCapability::DownloadSearch,
            ticket,
            true,
            move |adapter, context| async move {
                let generation = context.generation;
                let handle = adapter
                    .download_search()
                    .ok_or(IntegrationError::UnsupportedCapability)?
                    .begin(context, request)
                    .await?;
                Ok((generation, handle))
            },
        )
        .await
    }
    pub(crate) async fn poll_download_search(
        &self,
        ticket: RequestTicket,
        generation: u64,
        handle: Arc<dyn crate::application::music_catalog::DownloadSearchHandle>,
    ) -> Result<crate::api::DownloadSearchPage, PluginError> {
        self.execute(
            &ProviderId::new("slskd").unwrap(),
            PluginCapability::DownloadSearch,
            ticket,
            true,
            move |_, context| async move {
                if context.generation != generation {
                    return Err(IntegrationError::Cancelled);
                }
                handle.poll().await
            },
        )
        .await
    }
    async fn execute<T, F, Fut>(
        &self,
        id: &ProviderId,
        capability: PluginCapability,
        ticket: RequestTicket,
        check_cooldown: bool,
        operation: F,
    ) -> Result<T, PluginError>
    where
        T: Send + 'static,
        F: FnOnce(Arc<dyn MusicPlugin>, PluginContext) -> Fut + Send + 'static,
        Fut: Future<Output = Result<T, IntegrationError>> + Send + 'static,
    {
        let entry = self.entry(id).await?;
        if !entry.enabled {
            return Err(PluginError::Disabled);
        }
        if !entry.manifest.capabilities.contains(&capability) {
            return Err(PluginError::PermissionDenied);
        }
        let _admission = self
            .admitted
            .clone()
            .try_acquire_owned()
            .map_err(|_| PluginError::Busy)?;
        let request = ticket.0.clone();
        let lifecycle = entry.cancel.clone();
        let work = async {
            let global = self
                .slots
                .clone()
                .acquire_owned()
                .await
                .map_err(|_| PluginError::Busy)?;
            let local = entry
                .slots
                .clone()
                .acquire_owned()
                .await
                .map_err(|_| PluginError::Busy)?;
            let credentials = self.load_credentials(&entry.manifest).await?;
            let context = PluginContext {
                configuration: entry.configuration.clone(),
                generation: entry.generation,
                credentials,
                lifecycle: lifecycle.clone(),
                request: request.clone(),
            };
            if context.is_cancelled() {
                return Err(PluginError::Cancelled);
            }
            let remote = self.remote.clone();
            let host = entry.adapter.request_host(&entry.configuration);
            let adapter = entry.adapter.clone();
            let mut task = ManagedTask(tokio::spawn(async move {
                let (_global, _local) = (global, local);
                remote
                    .scope(false, async {
                        if check_cooldown {
                            if let Some(host) = &host {
                                remote.cooldown(host).await?;
                            }
                        }
                        let result = operation(adapter, context).await;
                        if let (
                            Some(host),
                            Err(IntegrationError::RateLimited {
                                retry_after_seconds: Some(seconds),
                            }),
                        ) = (&host.as_ref().filter(|_| check_cooldown), &result)
                        {
                            remote.defer(host, *seconds).await?;
                        }
                        result.map_err(PluginError::Adapter)
                    })
                    .await
            }));
            (&mut task.0)
                .await
                .map_err(|_| PluginError::AdapterFailed)?
        };
        let result = tokio::select! {
            biased;
            _ = lifecycle.cancelled() => Err(PluginError::Cancelled),
            _ = request.cancelled() => Err(PluginError::Cancelled),
            outcome = tokio::time::timeout(self.limits.timeout,work) => outcome.unwrap_or(Err(PluginError::Timeout)),
        };
        let registry = self.registry.lock().await;
        if !ticket.is_current()
            || entry.cancel.is_cancelled()
            || registry
                .entries
                .get(id)
                .is_none_or(|current| current.generation != entry.generation || !current.enabled)
        {
            return Err(PluginError::Cancelled);
        }
        result
    }
}

impl Drop for RuntimeState {
    fn drop(&mut self) {
        for entry in self.registry.get_mut().entries.values() {
            entry.cancel.cancel();
        }
    }
}
struct ManagedTask<T>(JoinHandle<T>);
impl<T> Drop for ManagedTask<T> {
    fn drop(&mut self) {
        self.0.abort();
    }
}
