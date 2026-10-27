//! Plugin preferences, platform credentials and the existing remote request scope.
use serde::{Deserialize, Serialize};
use std::io::Read;
use std::{
    collections::{BTreeMap, HashMap},
    future::Future,
    path::PathBuf,
    sync::{Arc, LazyLock, Mutex, Weak},
};

use crate::{
    application::music_plugins::{
        PluginCredentialStore, PluginFuture, PluginSecret, PluginStateStore,
    },
    domain::music::{
        identity::ProviderId,
        plugins::{PluginConfiguration, PluginError, PluginPreferences, SavedPluginState},
    },
    enrichment::{cache, transport::TransportError},
    secure_store::{SecureStore, SecureStoreError},
};

const MAX_PREFERENCES_BYTES: usize = 1024 * 1024;

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct PreferencesFile {
    version: u16,
    plugins: BTreeMap<String, PreferenceRow>,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct PreferenceRow {
    enabled: bool,
    removed: bool,
    values: BTreeMap<String, String>,
    flags: BTreeMap<String, bool>,
}

pub(crate) struct FilePluginStateStore {
    path: PathBuf,
}
impl FilePluginStateStore {
    pub(crate) fn new(path: PathBuf) -> Self {
        Self { path }
    }
}
impl PluginStateStore for FilePluginStateStore {
    fn load(&self) -> PluginFuture<'_, PluginPreferences> {
        let path = self.path.clone();
        Box::pin(async move {
            tokio::task::spawn_blocking(move || {
                let file = match std::fs::File::open(path) {
                    Ok(file) => file,
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                        return Ok(BTreeMap::new());
                    }
                    _ => return Err(PluginError::Storage),
                };
                let mut bytes = Vec::new();
                file.take(MAX_PREFERENCES_BYTES as u64 + 1)
                    .read_to_end(&mut bytes)
                    .map_err(|_| PluginError::Storage)?;
                if bytes.len() > MAX_PREFERENCES_BYTES {
                    return Err(PluginError::Storage);
                }
                let saved: PreferencesFile =
                    serde_json::from_slice(&bytes).map_err(|_| PluginError::Storage)?;
                if saved.version != 1 || saved.plugins.len() > 256 {
                    return Err(PluginError::Storage);
                }
                saved
                    .plugins
                    .into_iter()
                    .map(|(id, row)| {
                        ProviderId::new(id.clone()).map_err(|_| PluginError::Storage)?;
                        Ok((
                            id,
                            SavedPluginState {
                                enabled: row.enabled,
                                removed: row.removed,
                                configuration: PluginConfiguration {
                                    values: row.values,
                                    flags: row.flags,
                                },
                            },
                        ))
                    })
                    .collect()
            })
            .await
            .map_err(|_| PluginError::Storage)?
        })
    }
    fn save(&self, preferences: PluginPreferences) -> PluginFuture<'_, ()> {
        let path = self.path.clone();
        Box::pin(async move {
            tokio::task::spawn_blocking(move || {
                if preferences.len() > 256 {
                    return Err(PluginError::Storage);
                }
                let saved = PreferencesFile {
                    version: 1,
                    plugins: preferences
                        .into_iter()
                        .map(|(id, state)| {
                            (
                                id,
                                PreferenceRow {
                                    enabled: state.enabled,
                                    removed: state.removed,
                                    values: state.configuration.values,
                                    flags: state.configuration.flags,
                                },
                            )
                        })
                        .collect(),
                };
                let bytes = serde_json::to_vec(&saved).map_err(|_| PluginError::Storage)?;
                if bytes.len() > MAX_PREFERENCES_BYTES {
                    return Err(PluginError::Storage);
                }
                std::fs::create_dir_all(path.parent().ok_or(PluginError::Storage)?)
                    .map_err(|_| PluginError::Storage)?;
                crate::secure_store::write_secure_file(&path, &bytes)
                    .map_err(|_| PluginError::Storage)
            })
            .await
            .map_err(|_| PluginError::Storage)?
        })
    }
}

/// Lazily opens the platform service only for an explicit credential operation.
pub(crate) struct PlatformPluginCredentials {
    directory: PathBuf,
    service: String,
}
impl PlatformPluginCredentials {
    pub(crate) fn new(directory: PathBuf, service: String) -> Self {
        Self { directory, service }
    }
    async fn with_store<T: Send + 'static>(
        &self,
        action: impl FnOnce(SecureStore) -> Result<T, PluginError> + Send + 'static,
    ) -> Result<T, PluginError> {
        let directory = self.directory.clone();
        let service = self.service.clone();
        tokio::task::spawn_blocking(move || {
            let store = SecureStore::new(directory, service).map_err(|_| PluginError::Storage)?;
            action(store)
        })
        .await
        .map_err(|_| PluginError::Storage)?
    }
}
impl PluginCredentialStore for PlatformPluginCredentials {
    fn get<'a>(
        &'a self,
        provider: &'a ProviderId,
        key: &'a str,
    ) -> PluginFuture<'a, Option<PluginSecret>> {
        let key = format!("music-plugin:{}:{key}", provider.as_str());
        Box::pin(self.with_store(move |store| match store.get_secret(&key) {
            Ok(value) => Ok(Some(PluginSecret::new(value))),
            Err(SecureStoreError::Custom(message)) if message == "Not found" => Ok(None),
            Err(_) => Err(PluginError::Storage),
        }))
    }
    fn set<'a>(
        &'a self,
        provider: &'a ProviderId,
        key: &'a str,
        value: PluginSecret,
    ) -> PluginFuture<'a, ()> {
        let key = format!("music-plugin:{}:{key}", provider.as_str());
        Box::pin(self.with_store(move |store| {
            store
                .set_secret(&key, value.expose())
                .map_err(|_| PluginError::Storage)
        }))
    }
    fn delete<'a>(&'a self, provider: &'a ProviderId, key: &'a str) -> PluginFuture<'a, ()> {
        let key = format!("music-plugin:{}:{key}", provider.as_str());
        Box::pin(
            self.with_store(move |store| {
                store.delete_secret(&key).map_err(|_| PluginError::Storage)
            }),
        )
    }
}

static SHARED_LOCKS: LazyLock<Mutex<HashMap<PathBuf, Weak<cache::RequestLocks>>>> =
    LazyLock::new(Mutex::default);

/// Same representations, request locks and durable cooldowns as enrichment.
/// Provider HTTP clients continue using their existing process-wide request gates.
pub(crate) struct RemoteRequestScope {
    path: PathBuf,
    locks: Arc<cache::RequestLocks>,
}
impl RemoteRequestScope {
    pub(crate) fn new(path: PathBuf) -> Self {
        let path = path
            .parent()
            .and_then(|parent| parent.canonicalize().ok())
            .zip(path.file_name())
            .map(|(parent, name)| parent.join(name))
            .unwrap_or(path);
        let mut registry = SHARED_LOCKS
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        registry.retain(|_, locks| locks.strong_count() > 0);
        let locks = registry
            .get(&path)
            .and_then(Weak::upgrade)
            .unwrap_or_else(|| {
                let locks = Arc::new(cache::RequestLocks::default());
                registry.insert(path.clone(), Arc::downgrade(&locks));
                locks
            });
        Self { path, locks }
    }
    pub(crate) async fn scope<T>(&self, force: bool, request: impl Future<Output = T>) -> T {
        cache::REQUEST_LOCKS
            .scope(
                self.locks.clone(),
                cache::CACHE_CONTEXT.scope((self.path.clone(), force), request),
            )
            .await
    }
    pub(crate) async fn cooldown(&self, host: &str) -> Result<(), PluginError> {
        cache::cooldown(host).await.map_err(map_transport)
    }
    pub(crate) async fn defer(&self, host: &str, seconds: u64) -> Result<(), PluginError> {
        cache::defer(host, seconds).await.map_err(map_transport)
    }
}
fn map_transport(error: TransportError) -> PluginError {
    match error {
        TransportError::RateLimited {
            retry_after_seconds,
        } => PluginError::Adapter(crate::domain::music::IntegrationError::RateLimited {
            retry_after_seconds: Some(retry_after_seconds),
        }),
        _ => PluginError::Storage,
    }
}
