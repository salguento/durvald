use std::{
    collections::BTreeMap,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
    time::Duration,
};
use tokio::sync::{Mutex, Semaphore};

use super::context::RequestScope;
use super::*;
use crate::{
    application::music_catalog::IntegrationFuture,
    domain::music::{IntegrationError, catalog::*, identity::*, plugins::*, sources::*},
    enrichment::{cache, models::CacheValidators},
    infrastructure::music_plugins::{FilePluginStateStore, RemoteRequestScope},
};

#[derive(Default)]
struct MemoryStore {
    preferences: Mutex<PluginPreferences>,
    fail: AtomicBool,
    pause: Mutex<Option<Arc<PausedSave>>>,
}
struct PausedSave {
    started: Semaphore,
    resume: Semaphore,
}
impl PluginStateStore for MemoryStore {
    fn load(&self) -> PluginFuture<'_, PluginPreferences> {
        Box::pin(async {
            if self.fail.load(Ordering::SeqCst) {
                Err(PluginError::Storage)
            } else {
                Ok(self.preferences.lock().await.clone())
            }
        })
    }
    fn save(&self, preferences: PluginPreferences) -> PluginFuture<'_, ()> {
        Box::pin(async move {
            let pause = self.pause.lock().await.clone();
            if let Some(pause) = pause {
                pause.started.add_permits(1);
                pause.resume.acquire().await.unwrap().forget();
            }
            if self.fail.load(Ordering::SeqCst) {
                Err(PluginError::Storage)
            } else {
                *self.preferences.lock().await = preferences;
                Ok(())
            }
        })
    }
}
#[derive(Default)]
struct MemoryCredentials {
    values: Mutex<BTreeMap<(String, String), String>>,
    fail: AtomicBool,
}
impl PluginCredentialStore for MemoryCredentials {
    fn get<'a>(
        &'a self,
        id: &'a ProviderId,
        key: &'a str,
    ) -> PluginFuture<'a, Option<PluginSecret>> {
        Box::pin(async move {
            Ok(self
                .values
                .lock()
                .await
                .get(&(id.as_str().to_owned(), key.into()))
                .cloned()
                .map(PluginSecret::new))
        })
    }
    fn set<'a>(
        &'a self,
        id: &'a ProviderId,
        key: &'a str,
        value: PluginSecret,
    ) -> PluginFuture<'a, ()> {
        Box::pin(async move {
            if self.fail.load(Ordering::SeqCst) {
                return Err(PluginError::Storage);
            }
            self.values
                .lock()
                .await
                .insert((id.as_str().to_owned(), key.into()), value.expose().into());
            Ok(())
        })
    }
    fn delete<'a>(&'a self, id: &'a ProviderId, key: &'a str) -> PluginFuture<'a, ()> {
        Box::pin(async move {
            if self.fail.load(Ordering::SeqCst) {
                return Err(PluginError::Storage);
            }
            self.values
                .lock()
                .await
                .remove(&(id.as_str().to_owned(), key.into()));
            Ok(())
        })
    }
}

#[derive(Clone, Copy)]
enum Behavior {
    Immediate,
    Block,
    Fail,
    RateLimit,
    Cached,
    Credential,
}
struct Fake {
    manifest: PluginManifest,
    behavior: Behavior,
    calls: AtomicUsize,
    active: Arc<AtomicUsize>,
    maximum: AtomicUsize,
    started: Semaphore,
    release: Semaphore,
    fetches: AtomicUsize,
}
impl Fake {
    fn new(id: &str, behavior: Behavior) -> Arc<Self> {
        Arc::new(Self {
            manifest: manifest(id),
            behavior,
            calls: AtomicUsize::new(0),
            active: Arc::default(),
            maximum: AtomicUsize::new(0),
            started: Semaphore::new(0),
            release: Semaphore::new(0),
            fetches: AtomicUsize::new(0),
        })
    }
    async fn started(&self, n: u32) {
        self.started.acquire_many(n).await.unwrap().forget();
    }
}
struct Active(Arc<AtomicUsize>);
impl Drop for Active {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::SeqCst);
    }
}
fn manifest(id: &str) -> PluginManifest {
    PluginManifest {
        id: ProviderId::new(id).unwrap(),
        version: PluginVersion {
            major: 1,
            minor: 0,
            patch: 0,
        },
        api_version: PLUGIN_API_VERSION,
        capabilities: [
            PluginCapability::CatalogSearch,
            PluginCapability::Metadata,
            PluginCapability::SourceSearch,
            PluginCapability::Playback,
        ]
        .into(),
        permissions: Default::default(),
        primary_host: None,
        settings: [(
            "label".into(),
            ConfigurationField {
                required: false,
                default: Some("default".into()),
            },
        )]
        .into(),
        flags: ["previews".into()].into(),
        credentials: Default::default(),
    }
}
impl MusicPlugin for Fake {
    fn manifest(&self) -> PluginManifest {
        self.manifest.clone()
    }
    fn catalog(&self) -> Option<&dyn CatalogReader> {
        Some(self)
    }
    fn sources(&self) -> Option<&dyn SourceFinder> {
        Some(self)
    }
    fn resolver(&self) -> Option<&dyn MediaResolver> {
        Some(self)
    }
}
impl CatalogReader for Fake {
    fn search(
        &self,
        context: PluginContext,
        request: CatalogSearchRequest,
    ) -> IntegrationFuture<'_, CatalogSearchPage> {
        Box::pin(async move {
            self.calls.fetch_add(1, Ordering::SeqCst);
            let active = self.active.fetch_add(1, Ordering::SeqCst) + 1;
            self.maximum.fetch_max(active, Ordering::SeqCst);
            let _active = Active(self.active.clone());
            self.started.add_permits(1);
            match self.behavior {
                Behavior::Block => self.release.acquire().await.unwrap().forget(),
                Behavior::Fail => return Err(IntegrationError::TemporarilyUnavailable),
                Behavior::RateLimit => {
                    return Err(IntegrationError::RateLimited {
                        retry_after_seconds: Some(60),
                    });
                }
                Behavior::Credential => assert_eq!(
                    context.credential("token").unwrap().expose(),
                    "private-secret"
                ),
                Behavior::Cached => {
                    let key = cache::key("plugin-fixture", request.query());
                    let _lock = cache::request_lock(&key).await.unwrap();
                    if cache::load(&key)
                        .await
                        .unwrap()
                        .is_none_or(|entry| !entry.fresh())
                    {
                        self.fetches.fetch_add(1, Ordering::SeqCst);
                        cache::store(
                            &key,
                            &cache::entry(
                                b"fixture".to_vec(),
                                CacheValidators::default(),
                                Duration::from_secs(60),
                            ),
                        )
                        .await
                        .unwrap();
                    }
                }
                Behavior::Immediate => {}
            }
            Ok(CatalogSearchPage {
                items: vec![CatalogEntitySummary {
                    identity: CatalogEntityRef::External(
                        ExternalEntityRef::new(
                            self.manifest.id.clone(),
                            ExternalEntityKind::AudioTrack,
                            "1",
                        )
                        .unwrap(),
                    ),
                    title: context
                        .configuration
                        .values
                        .get("label")
                        .cloned()
                        .unwrap_or_default(),
                    artist_credit: None,
                    version_label: None,
                    duration_seconds: None,
                }],
                next_cursor: None,
            })
        })
    }
    fn details(
        &self,
        _context: PluginContext,
        target: CatalogEntityRef,
    ) -> IntegrationFuture<'_, CatalogEntityDetails> {
        Box::pin(async move {
            Ok(CatalogEntityDetails {
                summary: CatalogEntitySummary {
                    identity: target,
                    title: "detail".into(),
                    artist_credit: None,
                    version_label: None,
                    duration_seconds: None,
                },
                related: vec![],
                completeness: DetailCompleteness::Basic,
            })
        })
    }
}
impl SourceFinder for Fake {
    fn find_sources(
        &self,
        _context: PluginContext,
        _request: SourceSearchRequest,
    ) -> IntegrationFuture<'_, Vec<SourceCandidate>> {
        Box::pin(async { Ok(vec![]) })
    }
}
impl MediaResolver for Fake {
    fn resolve(
        &self,
        _context: PluginContext,
        _source: SourceReference,
    ) -> IntegrationFuture<'_, ResolvedMedia> {
        Box::pin(async { Err(IntegrationError::NotFound) })
    }
}
fn request() -> CatalogSearchRequest {
    CatalogSearchRequest::new(
        "artist",
        SearchScope::Explore,
        SearchEntityFilter::All,
        20,
        None,
    )
    .unwrap()
}
struct Harness {
    runtime: Arc<PluginRuntime>,
    store: Arc<MemoryStore>,
    credentials: Arc<MemoryCredentials>,
    remote: Arc<RemoteRequestScope>,
    _directory: tempfile::TempDir,
}
async fn harness(limits: RuntimeLimits) -> Harness {
    let directory = tempfile::tempdir().unwrap();
    let store = Arc::new(MemoryStore::default());
    let credentials = Arc::new(MemoryCredentials::default());
    let remote = Arc::new(RemoteRequestScope::new(
        directory.path().join("enrichment-http.sqlite"),
    ));
    let runtime = Arc::new(
        PluginRuntime::new(store.clone(), credentials.clone(), remote.clone(), limits)
            .await
            .unwrap(),
    );
    Harness {
        runtime,
        store,
        credentials,
        remote,
        _directory: directory,
    }
}
async fn enabled(runtime: &PluginRuntime, fake: Arc<Fake>) {
    runtime.install(fake.clone()).await.unwrap();
    runtime.set_enabled(&fake.manifest.id, true).await.unwrap();
}
async fn search(
    runtime: &PluginRuntime,
    id: &ProviderId,
) -> Result<CatalogSearchPage, PluginError> {
    let scope = RequestScope::default();
    runtime.search(id, scope.begin(), request()).await
}
fn start(
    runtime: Arc<PluginRuntime>,
    fake: Arc<Fake>,
) -> tokio::task::JoinHandle<Result<CatalogSearchPage, PluginError>> {
    tokio::spawn(async move { search(&runtime, &fake.manifest.id).await })
}

#[tokio::test]
async fn registry_validates_versions_ports_permissions_and_duplicates() {
    let h = harness(RuntimeLimits::default()).await;
    struct MissingPorts;
    impl MusicPlugin for MissingPorts {
        fn manifest(&self) -> PluginManifest {
            manifest("missing-ports")
        }
    }
    assert_eq!(
        h.runtime.install(Arc::new(MissingPorts)).await.unwrap_err(),
        PluginError::PermissionDenied
    );
    let mut fake = Fake::new("bad", Behavior::Immediate);
    Arc::get_mut(&mut fake).unwrap().manifest.api_version = 99;
    assert_eq!(
        h.runtime.install(fake).await.unwrap_err(),
        PluginError::IncompatibleApi
    );
    let mut fake = Fake::new("bad", Behavior::Immediate);
    Arc::get_mut(&mut fake)
        .unwrap()
        .manifest
        .credentials
        .insert("token".into(), true);
    assert_eq!(
        h.runtime.install(fake).await.unwrap_err(),
        PluginError::InvalidManifest
    );
    let mut fake = Fake::new("bad", Behavior::Immediate);
    Arc::get_mut(&mut fake)
        .unwrap()
        .manifest
        .capabilities
        .insert(PluginCapability::DownloadTransfer);
    assert_eq!(
        h.runtime.install(fake).await.unwrap_err(),
        PluginError::PermissionDenied
    );
    let fake = Fake::new("good", Behavior::Immediate);
    h.runtime.install(fake.clone()).await.unwrap();
    assert_eq!(
        search(&h.runtime, &fake.manifest.id).await.unwrap_err(),
        PluginError::Disabled
    );
    assert_eq!(
        h.runtime.install(fake.clone()).await.unwrap_err(),
        PluginError::AlreadyRegistered
    );
    assert_eq!(h.runtime.list().await.unwrap().len(), 1);
}

#[tokio::test]
async fn configuration_flags_and_capabilities_are_enforced_before_dispatch() {
    let h = harness(RuntimeLimits::default()).await;
    let mut fake = Fake::new("configured", Behavior::Immediate);
    Arc::get_mut(&mut fake)
        .unwrap()
        .manifest
        .capabilities
        .remove(&PluginCapability::Playback);
    h.runtime.install(fake.clone()).await.unwrap();
    let mut config = fake.manifest.defaults();
    config.values.insert("token".into(), "not-allowed".into());
    assert_eq!(
        h.runtime
            .configure(&fake.manifest.id, config)
            .await
            .unwrap_err(),
        PluginError::InvalidConfiguration
    );
    let mut config = fake.manifest.defaults();
    config.flags.insert("unknown".into(), true);
    assert_eq!(
        h.runtime
            .configure(&fake.manifest.id, config)
            .await
            .unwrap_err(),
        PluginError::InvalidConfiguration
    );
    let mut config = fake.manifest.defaults();
    config.values.insert("label".into(), "new".into());
    config.flags.insert("previews".into(), true);
    h.runtime
        .configure(&fake.manifest.id, config)
        .await
        .unwrap();
    h.runtime
        .set_enabled(&fake.manifest.id, true)
        .await
        .unwrap();
    assert_eq!(
        search(&h.runtime, &fake.manifest.id).await.unwrap().items[0].title,
        "new"
    );
    let scope = RequestScope::default();
    let path = LocalMediaPath::new(std::env::temp_dir().join("missing.flac")).unwrap();
    assert_eq!(
        h.runtime
            .resolve(
                &fake.manifest.id,
                scope.begin(),
                SourceReference::Local(path)
            )
            .await
            .unwrap_err(),
        PluginError::PermissionDenied
    );
}

#[tokio::test]
async fn required_settings_are_checked_on_enable_without_saving_invalid_changes() {
    let h = harness(RuntimeLimits::default()).await;
    let mut fake = Fake::new("required", Behavior::Immediate);
    Arc::get_mut(&mut fake).unwrap().manifest.settings.insert(
        "endpoint".into(),
        ConfigurationField {
            required: true,
            default: None,
        },
    );
    h.runtime.install(fake.clone()).await.unwrap();
    assert_eq!(
        h.runtime
            .set_enabled(&fake.manifest.id, true)
            .await
            .unwrap_err(),
        PluginError::InvalidConfiguration
    );
    let mut config = fake.manifest.defaults();
    config
        .values
        .insert("endpoint".into(), "local-fixture".into());
    h.runtime
        .configure(&fake.manifest.id, config)
        .await
        .unwrap();
    h.runtime
        .set_enabled(&fake.manifest.id, true)
        .await
        .unwrap();
    assert_eq!(
        h.runtime
            .configure(&fake.manifest.id, fake.manifest.defaults())
            .await
            .unwrap_err(),
        PluginError::InvalidConfiguration
    );
    assert!(search(&h.runtime, &fake.manifest.id).await.is_ok());
}

#[tokio::test]
async fn credential_lifecycle_is_separate_from_settings_and_fails_closed() {
    let h = harness(RuntimeLimits::default()).await;
    let mut fake = Fake::new("authenticated", Behavior::Credential);
    let manifest = &mut Arc::get_mut(&mut fake).unwrap().manifest;
    manifest.permissions.insert(PluginPermission::Credentials);
    manifest.credentials.insert("token".into(), true);
    h.runtime.install(fake.clone()).await.unwrap();
    assert_eq!(
        h.runtime
            .set_enabled(&fake.manifest.id, true)
            .await
            .unwrap_err(),
        PluginError::MissingCredential
    );
    h.runtime
        .set_credential(
            &fake.manifest.id,
            "token",
            Some(PluginSecret::new("private-secret".into())),
        )
        .await
        .unwrap();
    h.runtime
        .set_enabled(&fake.manifest.id, true)
        .await
        .unwrap();
    search(&h.runtime, &fake.manifest.id).await.unwrap();
    assert!(!format!("{:?}", h.store.preferences.lock().await).contains("private-secret"));
    assert!(
        !format!("{:?}", PluginSecret::new("private-secret".into())).contains("private-secret")
    );
    h.credentials.fail.store(true, Ordering::SeqCst);
    assert_eq!(
        h.runtime
            .set_credential(
                &fake.manifest.id,
                "token",
                Some(PluginSecret::new("replacement".into()))
            )
            .await
            .unwrap_err(),
        PluginError::Storage
    );
    assert!(!h.runtime.list().await.unwrap()[0].enabled);
    h.credentials.fail.store(false, Ordering::SeqCst);
    h.runtime
        .set_enabled(&fake.manifest.id, true)
        .await
        .unwrap();
    let status = h
        .runtime
        .set_credential(&fake.manifest.id, "token", None)
        .await
        .unwrap();
    assert!(!status.enabled);
    assert_eq!(
        h.runtime
            .set_credential(&fake.manifest.id, "undeclared", None)
            .await
            .unwrap_err(),
        PluginError::PermissionDenied
    );
}

#[tokio::test]
async fn failed_credential_cleanup_leaves_a_disabled_plugin_that_can_be_removed_again() {
    let h = harness(RuntimeLimits::default()).await;
    let mut fake = Fake::new("cleanup", Behavior::Immediate);
    let manifest = &mut Arc::get_mut(&mut fake).unwrap().manifest;
    manifest.permissions.insert(PluginPermission::Credentials);
    manifest.credentials.insert("token".into(), true);
    h.runtime.install(fake.clone()).await.unwrap();
    h.runtime
        .set_credential(
            &fake.manifest.id,
            "token",
            Some(PluginSecret::new("private-secret".into())),
        )
        .await
        .unwrap();
    h.runtime
        .set_enabled(&fake.manifest.id, true)
        .await
        .unwrap();
    h.credentials.fail.store(true, Ordering::SeqCst);
    assert_eq!(
        h.runtime.remove(&fake.manifest.id).await.unwrap_err(),
        PluginError::Storage
    );
    assert!(!h.runtime.list().await.unwrap()[0].enabled);
    assert_eq!(
        search(&h.runtime, &fake.manifest.id).await.unwrap_err(),
        PluginError::Disabled
    );
    h.credentials.fail.store(false, Ordering::SeqCst);
    h.runtime.remove(&fake.manifest.id).await.unwrap();
    assert!(h.runtime.list().await.unwrap().is_empty());
    assert!(h.credentials.values.lock().await.is_empty());
}

#[tokio::test]
async fn disabling_removing_or_reconfiguring_cancels_only_that_plugins_generation() {
    for action in ["disable", "remove", "configure"] {
        let h = harness(RuntimeLimits::default()).await;
        let slow = Fake::new("slow", Behavior::Block);
        let other = Fake::new("other", Behavior::Immediate);
        enabled(&h.runtime, slow.clone()).await;
        enabled(&h.runtime, other.clone()).await;
        let task = start(h.runtime.clone(), slow.clone());
        slow.started(1).await;
        match action {
            "disable" => {
                h.runtime
                    .set_enabled(&slow.manifest.id, false)
                    .await
                    .unwrap();
            }
            "remove" => {
                h.runtime.remove(&slow.manifest.id).await.unwrap();
            }
            _ => {
                let mut config = slow.manifest.defaults();
                config.values.insert("label".into(), "changed".into());
                h.runtime
                    .configure(&slow.manifest.id, config)
                    .await
                    .unwrap();
            }
        }
        assert_eq!(task.await.unwrap().unwrap_err(), PluginError::Cancelled);
        tokio::task::yield_now().await;
        assert_eq!(slow.active.load(Ordering::SeqCst), 0);
        assert!(search(&h.runtime, &other.manifest.id).await.is_ok());
    }
}

#[tokio::test]
async fn request_generations_cancel_superseded_results_and_explicit_cancel() {
    let h = harness(RuntimeLimits::default()).await;
    let fake = Fake::new("queries", Behavior::Block);
    enabled(&h.runtime, fake.clone()).await;
    let scope = RequestScope::default();
    let old = scope.begin();
    let runtime = h.runtime.clone();
    let id = fake.manifest.id.clone();
    let pending = tokio::spawn(async move { runtime.search(&id, old, request()).await });
    fake.started(1).await;
    let current = scope.begin();
    assert_eq!(pending.await.unwrap().unwrap_err(), PluginError::Cancelled);
    current.cancel();
    assert_eq!(
        h.runtime
            .search(&fake.manifest.id, current, request())
            .await
            .unwrap_err(),
        PluginError::Cancelled
    );
}

#[tokio::test(start_paused = true)]
async fn timeouts_and_caller_drop_abort_adapter_work_and_release_permits() {
    let h = harness(RuntimeLimits {
        timeout: Duration::from_secs(5),
        ..RuntimeLimits::default()
    })
    .await;
    let fake = Fake::new("timeout", Behavior::Block);
    enabled(&h.runtime, fake.clone()).await;
    let task = start(h.runtime.clone(), fake.clone());
    fake.started(1).await;
    tokio::time::advance(Duration::from_secs(5)).await;
    assert_eq!(task.await.unwrap().unwrap_err(), PluginError::Timeout);
    tokio::task::yield_now().await;
    assert_eq!(fake.active.load(Ordering::SeqCst), 0);
    let task = start(h.runtime.clone(), fake.clone());
    fake.started(1).await;
    task.abort();
    let _ = task.await;
    tokio::task::yield_now().await;
    assert_eq!(fake.active.load(Ordering::SeqCst), 0);
}

#[tokio::test(start_paused = true)]
async fn deadline_includes_waiting_for_a_plugin_slot() {
    let h = harness(RuntimeLimits {
        concurrent: 1,
        per_plugin: 1,
        admitted: 2,
        timeout: Duration::from_secs(5),
    })
    .await;
    let fake = Fake::new("queued", Behavior::Block);
    enabled(&h.runtime, fake.clone()).await;
    let first = start(h.runtime.clone(), fake.clone());
    fake.started(1).await;
    tokio::time::advance(Duration::from_secs(3)).await;
    let second = start(h.runtime.clone(), fake.clone());
    tokio::task::yield_now().await;
    tokio::time::advance(Duration::from_secs(2)).await;
    assert_eq!(first.await.unwrap().unwrap_err(), PluginError::Timeout);
    fake.started(1).await;
    tokio::time::advance(Duration::from_secs(3)).await;
    assert_eq!(second.await.unwrap().unwrap_err(), PluginError::Timeout);
}

#[tokio::test]
async fn task_limits_bound_concurrency_and_queued_requests_without_affecting_other_adapters() {
    let h = harness(RuntimeLimits {
        concurrent: 2,
        per_plugin: 1,
        admitted: 3,
        ..RuntimeLimits::default()
    })
    .await;
    let one = Fake::new("one", Behavior::Block);
    let two = Fake::new("two", Behavior::Block);
    enabled(&h.runtime, one.clone()).await;
    enabled(&h.runtime, two.clone()).await;
    let first = start(h.runtime.clone(), one.clone());
    one.started(1).await;
    let second = start(h.runtime.clone(), two.clone());
    two.started(1).await;
    let queued = start(h.runtime.clone(), one.clone());
    for _ in 0..10 {
        tokio::task::yield_now().await;
    }
    assert_eq!(
        search(&h.runtime, &two.manifest.id).await.unwrap_err(),
        PluginError::Busy
    );
    assert_eq!(one.maximum.load(Ordering::SeqCst), 1);
    assert_eq!(two.maximum.load(Ordering::SeqCst), 1);
    h.runtime
        .set_enabled(&one.manifest.id, false)
        .await
        .unwrap();
    assert_eq!(first.await.unwrap().unwrap_err(), PluginError::Cancelled);
    assert_eq!(queued.await.unwrap().unwrap_err(), PluginError::Cancelled);
    two.release.add_permits(1);
    assert!(second.await.unwrap().is_ok());
}

#[tokio::test]
async fn errors_and_storage_failures_do_not_change_other_plugins_or_current_configuration() {
    let h = harness(RuntimeLimits::default()).await;
    let failed = Fake::new("failed", Behavior::Fail);
    let good = Fake::new("good", Behavior::Immediate);
    enabled(&h.runtime, failed.clone()).await;
    enabled(&h.runtime, good.clone()).await;
    assert_eq!(
        search(&h.runtime, &failed.manifest.id).await.unwrap_err(),
        PluginError::Adapter(IntegrationError::TemporarilyUnavailable)
    );
    let before = h.runtime.list().await.unwrap();
    h.store.fail.store(true, Ordering::SeqCst);
    assert_eq!(
        h.runtime
            .set_enabled(&good.manifest.id, false)
            .await
            .unwrap_err(),
        PluginError::Storage
    );
    assert_eq!(h.runtime.list().await.unwrap(), before);
    assert!(search(&h.runtime, &good.manifest.id).await.is_ok());
}

#[tokio::test]
async fn dropping_a_configuration_caller_does_not_interrupt_a_serialized_state_commit() {
    let h = harness(RuntimeLimits::default()).await;
    let fake = Fake::new("atomic", Behavior::Immediate);
    enabled(&h.runtime, fake.clone()).await;
    let paused = Arc::new(PausedSave {
        started: Semaphore::new(0),
        resume: Semaphore::new(0),
    });
    *h.store.pause.lock().await = Some(paused.clone());
    let runtime = h.runtime.clone();
    let id = fake.manifest.id.clone();
    let caller = tokio::spawn(async move { runtime.set_enabled(&id, false).await });
    paused.started.acquire().await.unwrap().forget();
    caller.abort();
    let _ = caller.await;
    *h.store.pause.lock().await = None;
    let runtime = h.runtime.clone();
    let id = fake.manifest.id.clone();
    let mut configuration = fake.manifest.defaults();
    configuration
        .values
        .insert("label".into(), "after-commit".into());
    let next = tokio::spawn(async move { runtime.configure(&id, configuration).await });
    tokio::task::yield_now().await;
    assert!(!next.is_finished());
    paused.resume.add_permits(1);
    let status = next.await.unwrap().unwrap();
    assert!(!status.enabled);
    assert_eq!(status.configuration.values["label"], "after-commit");
    let saved = h.store.preferences.lock().await;
    assert!(!saved[fake.manifest.id.as_str()].enabled);
    assert_eq!(
        saved[fake.manifest.id.as_str()].configuration,
        status.configuration
    );
}

#[tokio::test]
async fn preferences_survive_restart_and_uninstall_tombstones_preserve_unrelated_data() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("music-plugins.json");
    let store = Arc::new(FilePluginStateStore::new(path.clone()));
    let credentials = Arc::new(MemoryCredentials::default());
    let remote = Arc::new(RemoteRequestScope::new(
        directory.path().join("http.sqlite"),
    ));
    let fake = Fake::new("persisted", Behavior::Immediate);
    let runtime = PluginRuntime::new(
        store.clone(),
        credentials.clone(),
        remote.clone(),
        RuntimeLimits::default(),
    )
    .await
    .unwrap();
    enabled(&runtime, fake.clone()).await;
    let mut config = fake.manifest.defaults();
    config.values.insert("label".into(), "saved".into());
    runtime.configure(&fake.manifest.id, config).await.unwrap();
    drop(runtime);
    let runtime = PluginRuntime::new(
        store.clone(),
        credentials.clone(),
        remote.clone(),
        RuntimeLimits::default(),
    )
    .await
    .unwrap();
    let status = runtime
        .register_builtin(fake.clone())
        .await
        .unwrap()
        .unwrap();
    assert!(status.enabled);
    assert_eq!(
        search(&runtime, &fake.manifest.id).await.unwrap().items[0].title,
        "saved"
    );
    let sentinel = directory.path().join("personal-library.txt");
    std::fs::write(&sentinel, "ratings/playlists/history").unwrap();
    runtime.remove(&fake.manifest.id).await.unwrap();
    drop(runtime);
    let runtime = PluginRuntime::new(store, credentials, remote, RuntimeLimits::default())
        .await
        .unwrap();
    assert!(
        runtime
            .register_builtin(fake.clone())
            .await
            .unwrap()
            .is_none()
    );
    assert!(runtime.list().await.unwrap().is_empty());
    assert!(!runtime.install(fake).await.unwrap().enabled);
    assert_eq!(
        std::fs::read_to_string(sentinel).unwrap(),
        "ratings/playlists/history"
    );
    assert!(
        !std::fs::read_to_string(path)
            .unwrap()
            .contains("private-secret")
    );
}

#[tokio::test]
async fn shared_http_representations_and_rate_limits_are_reused_by_the_registry() {
    let h = harness(RuntimeLimits::default()).await;
    h.remote
        .scope(false, async {
            cache::store(
                &cache::key("plugin-fixture", "artist"),
                &cache::entry(
                    b"existing".to_vec(),
                    CacheValidators::default(),
                    Duration::from_secs(60),
                ),
            )
            .await
            .unwrap();
        })
        .await;
    let fake = Fake::new("cached", Behavior::Cached);
    enabled(&h.runtime, fake.clone()).await;
    search(&h.runtime, &fake.manifest.id).await.unwrap();
    assert_eq!(fake.fetches.load(Ordering::SeqCst), 0);
    // Separate core/service scopes for the same library must deduplicate cache misses.
    let second = PluginRuntime::new(
        Arc::new(MemoryStore::default()),
        h.credentials.clone(),
        Arc::new(RemoteRequestScope::new(
            h._directory.path().join("enrichment-http.sqlite"),
        )),
        RuntimeLimits::default(),
    )
    .await
    .unwrap();
    enabled(&second, fake.clone()).await;
    let first_scope = RequestScope::default();
    let second_scope = RequestScope::default();
    let query = CatalogSearchRequest::new(
        "concurrent",
        SearchScope::Explore,
        SearchEntityFilter::All,
        20,
        None,
    )
    .unwrap();
    let (first, second) = tokio::join!(
        h.runtime
            .search(&fake.manifest.id, first_scope.begin(), query.clone()),
        second.search(&fake.manifest.id, second_scope.begin(), query)
    );
    assert!(first.is_ok() && second.is_ok());
    assert_eq!(fake.fetches.load(Ordering::SeqCst), 1);
    let mut limited = Fake::new("limited", Behavior::RateLimit);
    let manifest = &mut Arc::get_mut(&mut limited).unwrap().manifest;
    manifest.permissions.insert(PluginPermission::Network);
    manifest.primary_host = Some("musicbrainz.org".into());
    enabled(&h.runtime, limited.clone()).await;
    assert!(matches!(
        search(&h.runtime, &limited.manifest.id).await,
        Err(PluginError::Adapter(IntegrationError::RateLimited { .. }))
    ));
    assert!(matches!(
        search(&h.runtime, &limited.manifest.id).await,
        Err(PluginError::Adapter(IntegrationError::RateLimited { .. }))
    ));
    assert_eq!(limited.calls.load(Ordering::SeqCst), 1);
    h.remote
        .scope(false, async {
            assert!(cache::cooldown("musicbrainz.org").await.is_err());
        })
        .await;
}

#[tokio::test]
async fn corrupted_or_future_preferences_block_only_plugin_registration() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("music-plugins.json");
    let bytes = r#"{"version":99,"plugins":{}}"#;
    std::fs::write(&path, bytes).unwrap();
    let runtime = PluginRuntime::new(
        Arc::new(FilePluginStateStore::new(path.clone())),
        Arc::new(MemoryCredentials::default()),
        Arc::new(RemoteRequestScope::new(
            directory.path().join("http.sqlite"),
        )),
        RuntimeLimits::default(),
    )
    .await
    .unwrap();
    assert_eq!(
        runtime
            .install(Fake::new("test", Behavior::Immediate))
            .await
            .unwrap_err(),
        PluginError::Storage
    );
    assert_eq!(std::fs::read_to_string(path).unwrap(), bytes);
}

#[tokio::test]
async fn real_preferences_never_include_credentials_or_accept_oversized_files() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("music-plugins.json");
    let store = Arc::new(FilePluginStateStore::new(path.clone()));
    let runtime = PluginRuntime::new(
        store.clone(),
        Arc::new(MemoryCredentials::default()),
        Arc::new(RemoteRequestScope::new(
            directory.path().join("http.sqlite"),
        )),
        RuntimeLimits::default(),
    )
    .await
    .unwrap();
    let mut fake = Fake::new("secret", Behavior::Immediate);
    let manifest = &mut Arc::get_mut(&mut fake).unwrap().manifest;
    manifest.permissions.insert(PluginPermission::Credentials);
    manifest.credentials.insert("token".into(), true);
    runtime.install(fake.clone()).await.unwrap();
    runtime
        .set_credential(
            &fake.manifest.id,
            "token",
            Some(PluginSecret::new("private-secret".into())),
        )
        .await
        .unwrap();
    runtime.set_enabled(&fake.manifest.id, true).await.unwrap();
    let contents = std::fs::read_to_string(&path).unwrap();
    assert!(!contents.contains("private-secret"));
    assert!(!contents.contains("token"));
    std::fs::write(&path, vec![b' '; 1024 * 1024 + 1]).unwrap();
    assert_eq!(store.load().await.unwrap_err(), PluginError::Storage);
}

#[tokio::test]
async fn detail_and_source_ports_dispatch_without_starting_playback_or_adopting_tracks() {
    let h = harness(RuntimeLimits::default()).await;
    let fake = Fake::new("ports", Behavior::Immediate);
    enabled(&h.runtime, fake.clone()).await;
    let scope = RequestScope::default();
    let target = CatalogEntityRef::External(
        ExternalEntityRef::new(fake.manifest.id.clone(), ExternalEntityKind::Artist, "1").unwrap(),
    );
    assert_eq!(
        h.runtime
            .details(&fake.manifest.id, scope.begin(), target.clone())
            .await
            .unwrap()
            .summary
            .identity,
        target
    );
    assert!(
        h.runtime
            .find_sources(
                &fake.manifest.id,
                scope.begin(),
                SourceSearchRequest { target }
            )
            .await
            .unwrap()
            .is_empty()
    );
    let source = SourceReference::Local(
        LocalMediaPath::new(std::env::temp_dir().join("missing.flac")).unwrap(),
    );
    assert!(matches!(
        h.runtime
            .resolve(&fake.manifest.id, scope.begin(), source)
            .await,
        Err(PluginError::Adapter(IntegrationError::NotFound))
    ));
}
