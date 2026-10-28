//! Whole acquisition flow against a local HTTP daemon simulator, never Soulseek.
use super::*;
use crate::{
    api::*,
    application::{
        download_search::DownloadSearchApplication,
        download_transfers::{DownloadTransfersApplication, ImportJournal},
        music_plugins::{
            PluginCredentialStore, PluginFuture, PluginRuntime, PluginSecret, PluginStateStore,
            RuntimeLimits,
        },
    },
    domain::music::{identity::ProviderId, plugins::PluginPreferences},
    infrastructure::{
        music_plugins::RemoteRequestScope, sqlite::download_transfers::TransferRepository,
    },
};
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicU16, Ordering},
    },
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
    sync::Mutex,
    task::JoinHandle,
};
#[derive(Default)]
struct Secrets {
    state: Mutex<PluginPreferences>,
    key: Mutex<Option<String>>,
}
impl PluginStateStore for Secrets {
    fn load(&self) -> PluginFuture<'_, PluginPreferences> {
        Box::pin(async { Ok(self.state.lock().await.clone()) })
    }
    fn save(&self, v: PluginPreferences) -> PluginFuture<'_, ()> {
        Box::pin(async move {
            *self.state.lock().await = v;
            Ok(())
        })
    }
}
impl PluginCredentialStore for Secrets {
    fn get<'a>(&'a self, _: &'a ProviderId, _: &'a str) -> PluginFuture<'a, Option<PluginSecret>> {
        Box::pin(async { Ok(self.key.lock().await.clone().map(PluginSecret::new)) })
    }
    fn set<'a>(&'a self, _: &'a ProviderId, _: &'a str, v: PluginSecret) -> PluginFuture<'a, ()> {
        Box::pin(async move {
            *self.key.lock().await = Some(v.expose().into());
            Ok(())
        })
    }
    fn delete<'a>(&'a self, _: &'a ProviderId, _: &'a str) -> PluginFuture<'a, ()> {
        Box::pin(async {
            *self.key.lock().await = None;
            Ok(())
        })
    }
}
#[derive(Default)]
struct ServerState {
    batches: HashMap<String, Value>,
    calls: Vec<(String, String, Value)>,
    foreign: Vec<Value>,
    reject_last: bool,
    wrong_identity: bool,
}
struct Backend {
    url: String,
    state: Arc<Mutex<ServerState>>,
    mode: Arc<AtomicU16>,
    task: JoinHandle<()>,
}
impl Drop for Backend {
    fn drop(&mut self) {
        self.task.abort();
    }
}
impl Backend {
    async fn new() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let state = Arc::new(Mutex::new(ServerState::default()));
        let mode = Arc::new(AtomicU16::new(0));
        let (shared, behavior) = (state.clone(), mode.clone());
        let task = tokio::spawn(async move {
            while let Ok((mut socket, _)) = listener.accept().await {
                let (shared, behavior) = (shared.clone(), behavior.clone());
                tokio::spawn(async move {
                    let mut bytes = vec![];
                    let mut block = [0; 4096];
                    loop {
                        let n = socket.read(&mut block).await.unwrap_or(0);
                        if n == 0 {
                            return;
                        }
                        bytes.extend_from_slice(&block[..n]);
                        if let Some(end) = bytes.windows(4).position(|w| w == b"\r\n\r\n") {
                            let headers = String::from_utf8_lossy(&bytes[..end]);
                            let len = headers
                                .lines()
                                .find_map(|l| {
                                    l.to_ascii_lowercase()
                                        .strip_prefix("content-length:")
                                        .and_then(|s| s.trim().parse::<usize>().ok())
                                })
                                .unwrap_or(0);
                            if bytes.len() >= end + 4 + len {
                                break;
                            }
                        }
                    }
                    let input = String::from_utf8_lossy(&bytes);
                    let parts: Vec<_> = input.lines().next().unwrap().split_whitespace().collect();
                    let (method, path) = (parts[0], parts[1]);
                    let body: Value = input
                        .split("\r\n\r\n")
                        .nth(1)
                        .filter(|s| !s.is_empty())
                        .map(|s| serde_json::from_str(s).unwrap())
                        .unwrap_or(Value::Null);
                    let mode = behavior.load(Ordering::SeqCst);
                    let mut state = shared.lock().await;
                    state.calls.push((method.into(), path.into(), body.clone()));
                    let mut status = 200u16;
                    let value = if !input
                        .to_ascii_lowercase()
                        .contains("x-api-key: fixture-secret-123456")
                    {
                        status = 401;
                        json!({"secret":"not for diagnostics"})
                    } else if (400..=599).contains(&mode) {
                        status = mode;
                        json!({"untrusted":"never display"})
                    } else if method == "POST" && path == "/api/v0/searches" {
                        json!({"id":body["id"]})
                    } else if method == "GET"
                        && path.starts_with("/api/v0/searches/")
                        && path.ends_with("/responses")
                    {
                        json!([{"username":"peer","files":[{"filename":"Music\\Album\\01 - Track1.wav","size":wav().len(),"length":1}]}])
                    } else if method == "GET" && path.starts_with("/api/v0/searches/") {
                        json!({"state":"Completed, Succeeded"})
                    } else if (method == "PUT" || method == "DELETE")
                        && path.starts_with("/api/v0/searches/")
                    {
                        Value::Null
                    } else if method == "POST" && path == "/api/v0/transfers/downloads/batches" {
                        let id = body["id"].as_str().unwrap().to_owned();
                        if state.batches.contains_key(&id) {
                            status = 409;
                            json!({})
                        } else {
                            let input = body["files"].as_array().unwrap();
                            let limit = if state.reject_last {
                                input.len().saturating_sub(1)
                            } else {
                                input.len()
                            };
                            let rows:Vec<_>=input.iter().take(limit).map(|f|json!({"id":crate::infrastructure::slskd_search::search_id().unwrap(),"batchId":id,"username":body["username"],"filename":f["filename"],"size":f["size"],"bytesTransferred":0,"state":"Queued","placeInQueue":2})).collect();
                            let batch = json!({"id":id,"username":body["username"],"options":body["options"],"transfers":rows});
                            state.batches.insert(id, batch.clone());
                            status = 201;
                            json!({"batch":batch,"failures":[]})
                        }
                    } else if method == "GET"
                        && path.starts_with("/api/v0/transfers/downloads/batches/")
                    {
                        if mode == 999 {
                            status = 404;
                            json!({})
                        } else {
                            let id = path.rsplit('/').next().unwrap();
                            match state.batches.get(id) {
                                Some(v) => {
                                    let mut v = v.clone();
                                    if state.wrong_identity {
                                        v["id"] = json!("00000000-0000-4000-8000-000000000000");
                                    }
                                    v
                                }
                                None => {
                                    status = 404;
                                    json!({})
                                }
                            }
                        }
                    } else if method == "GET" && path.starts_with("/api/v0/transfers/downloads/") {
                        let files: Vec<_> = state
                            .batches
                            .values()
                            .flat_map(|b| b["transfers"].as_array().unwrap().clone())
                            .chain(state.foreign.clone())
                            .collect();
                        json!({"username":"peer","directories":[{"directory":"Music","files":files}]})
                    } else if method == "DELETE" && path.starts_with("/api/v0/transfers/downloads/")
                    {
                        let id = path.rsplit('/').next().unwrap();
                        for batch in state.batches.values_mut() {
                            for row in batch["transfers"].as_array_mut().unwrap() {
                                if row["id"].as_str() == Some(id) {
                                    row["state"] = json!("Completed, Cancelled");
                                }
                            }
                        }
                        status = 204;
                        Value::Null
                    } else {
                        status = 404;
                        json!({})
                    };
                    drop(state);
                    if mode == 999 && method == "POST" {
                        tokio::time::sleep(std::time::Duration::from_secs(8)).await;
                        return;
                    }
                    let data = if status == 204 {
                        vec![]
                    } else {
                        serde_json::to_vec(&value).unwrap()
                    };
                    let headers = format!(
                        "HTTP/1.1 {status} Result\r\nContent-Length: {}\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n",
                        data.len()
                    );
                    let _ = socket.write_all(headers.as_bytes()).await;
                    let _ = socket.write_all(&data).await;
                });
            }
        });
        Self {
            url,
            state,
            mode,
            task,
        }
    }
    async fn posts(&self) -> usize {
        self.state
            .lock()
            .await
            .calls
            .iter()
            .filter(|(m, _, _)| m == "POST")
            .count()
    }
}
struct Harness {
    dir: tempfile::TempDir,
    backend: Backend,
    app: Arc<DownloadTransfersApplication>,
    runtime: Arc<PluginRuntime>,
    config: CoreConfig,
    mapped: PathBuf,
    destination: PathBuf,
}
impl Harness {
    async fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let backend = Backend::new().await;
        let mapped = dir.path().join("mapped");
        let destination = dir.path().join("library");
        std::fs::create_dir_all(&mapped).unwrap();
        std::fs::create_dir_all(&destination).unwrap();
        let covers = dir.path().join("covers");
        std::fs::create_dir_all(&covers).unwrap();
        let config = CoreConfig {
            database_path: dir.path().join("core.sqlite").to_string_lossy().into(),
            app_support_dir: dir.path().to_string_lossy().into(),
            covers_dir: covers.to_string_lossy().into(),
            keychain_service: "unused-transfer-fixture".into(),
        };
        let secrets = Arc::new(Secrets::default());
        let runtime = Arc::new(
            PluginRuntime::new(
                secrets.clone(),
                secrets,
                Arc::new(RemoteRequestScope::new(dir.path().join("http.sqlite"))),
                RuntimeLimits::default(),
            )
            .await
            .unwrap(),
        );
        let search = DownloadSearchApplication::new(runtime.clone()).await;
        search
            .configure(
                backend.url.clone(),
                Some("fixture-secret-123456".into()),
                true,
                true,
            )
            .await
            .unwrap();
        let pool = crate::composition::open_database(&config).unwrap();
        let app = Arc::new(DownloadTransfersApplication::new(
            TransferRepository::new(pool),
            runtime.clone(),
            Arc::new(Mutex::new(())),
            config.covers_dir.clone(),
        ));
        app.configure(DownloadTransferSettings {
            enabled: true,
            remote_download_root: "/remote/completed".into(),
            mapped_download_root: mapped.to_string_lossy().into(),
            library_destination: destination.to_string_lossy().into(),
            mapping_confirmed: true,
        })
        .await
        .unwrap();
        Self {
            dir,
            backend,
            app,
            runtime,
            config,
            mapped,
            destination,
        }
    }
    fn offer(&self, count: usize) -> DownloadOfferGroup {
        DownloadOfferGroup {
            offer_id: "fixture-offer".into(),
            peer: "peer".into(),
            folder: "Music/Album".into(),
            files: (0..count)
                .map(|i| DownloadOfferFile {
                    filename: format!("Music\\Album\\{:02} - Track{}.wav", i + 1, i + 1),
                    size_bytes: wav().len() as u64,
                    format: "wav".into(),
                    duration_seconds: Some(1),
                    bitrate_kbps: None,
                    sample_rate_hz: Some(8000),
                    bit_depth: Some(16),
                })
                .collect(),
            total_bytes: count as u64 * wav().len() as u64,
            free_upload_slot: None,
            queue_length: None,
            upload_speed_bytes: None,
            matched_tracks: 0,
            expected_tracks: 0,
            duration_matches: 0,
            comparison: "unverified".into(),
        }
    }
    async fn enqueue(&self, count: usize) -> DownloadTransferJob {
        self.app
            .enqueue(
                crate::infrastructure::slskd_search::endpoint(&self.backend.url)
                    .unwrap()
                    .as_str()
                    .into(),
                self.offer(count),
            )
            .await
            .unwrap()
    }
    async fn complete(&self, job: &DownloadTransferJob, index: usize) -> PathBuf {
        let batch = self
            .app
            .repository
            .get(job.job_id.clone())
            .await
            .unwrap()
            .details[index]
            .batch_id
            .clone()
            .unwrap();
        {
            let mut s = self.backend.state.lock().await;
            let b = s.batches.get_mut(&batch).unwrap();
            let row = b["transfers"]
                .as_array_mut()
                .unwrap()
                .iter_mut()
                .find(|r| r["filename"] == job.files[index].filename)
                .unwrap();
            row["state"] = json!("Completed, Succeeded");
            row["bytesTransferred"] = json!(job.files[index].size_bytes);
        }
        let folder = self.mapped.join(&job.relative_destination).join("Album");
        std::fs::create_dir_all(&folder).unwrap();
        let path = folder.join(format!("Track{}.wav", index + 1));
        std::fs::write(&path, wav()).unwrap();
        path
    }
    fn reopened(&self) -> Arc<DownloadTransfersApplication> {
        Arc::new(DownloadTransfersApplication::new(
            TransferRepository::new(crate::composition::open_database(&self.config).unwrap()),
            self.runtime.clone(),
            Arc::new(Mutex::new(())),
            self.config.covers_dir.clone(),
        ))
    }
    async fn songs(&self) -> i64 {
        self.app
            .repository
            .run(|c| {
                Ok(c.query_row("SELECT COUNT(*) FROM songs", [], |r| r.get(0))
                    .unwrap())
            })
            .await
            .unwrap()
    }
}
fn wav() -> Vec<u8> {
    let length = 16000u32;
    let mut b = vec![];
    b.extend(b"RIFF");
    b.extend((length + 36).to_le_bytes());
    b.extend(b"WAVEfmt ");
    b.extend(16u32.to_le_bytes());
    b.extend(1u16.to_le_bytes());
    b.extend(1u16.to_le_bytes());
    b.extend(8000u32.to_le_bytes());
    b.extend(16000u32.to_le_bytes());
    b.extend(2u16.to_le_bytes());
    b.extend(16u16.to_le_bytes());
    b.extend(b"data");
    b.extend(length.to_le_bytes());
    b.resize(44 + length as usize, 0);
    b
}
#[tokio::test]
async fn explicit_batch_partial_completion_import_and_reimport_are_independent_and_idempotent() {
    let h = Harness::new().await;
    assert!(h.app.list().await.unwrap().is_empty());
    assert_eq!(h.backend.posts().await, 0);
    let job = h.enqueue(2).await;
    assert_eq!(job.files[0].state, S::Queued);
    assert_eq!(h.songs().await, 0);
    assert!(
        h.app
            .inspect_file(job.job_id.clone(), 0, "/remote/file.wav".into())
            .await
            .is_err()
    );
    let same = h.enqueue(2).await;
    assert_eq!(same.job_id, job.job_id);
    assert_eq!(h.backend.posts().await, 1);
    let path = h.complete(&job, 0).await;
    let refreshed = h.app.refresh(job.job_id.clone()).await.unwrap();
    assert_eq!(refreshed.files[0].state, S::Completed);
    assert_eq!(refreshed.files[1].state, S::Queued);
    let preview = h
        .app
        .inspect_file(job.job_id.clone(), 0, path.to_string_lossy().into())
        .await
        .unwrap();
    assert_eq!(h.songs().await, 0);
    assert!(
        h.app
            .import_file(
                job.job_id.clone(),
                0,
                preview.review_token.clone(),
                None,
                false
            )
            .await
            .is_err()
    );
    let imported = h
        .app
        .import_file(
            job.job_id.clone(),
            0,
            preview.review_token.clone(),
            None,
            true,
        )
        .await
        .unwrap();
    assert_eq!(imported.files[0].state, S::Imported);
    assert_eq!(imported.files[1].state, S::Queued);
    assert_eq!(h.songs().await, 1);
    assert!(path.exists());
    assert!(
        Path::new(imported.files[0].imported_path.as_ref().unwrap())
            .starts_with(h.destination.canonicalize().unwrap())
    );
    let repeat = h
        .app
        .import_file(job.job_id.clone(), 0, preview.review_token, None, true)
        .await
        .unwrap();
    assert_eq!(
        repeat.files[0].imported_track_id,
        imported.files[0].imported_track_id
    );
    assert_eq!(h.songs().await, 1);
    assert_eq!(h.reopened().list().await.unwrap()[0], repeat);
}
#[tokio::test]
async fn lost_submission_receipt_is_reconciled_after_restart_without_another_post() {
    let h = Harness::new().await;
    h.backend.mode.store(999, Ordering::SeqCst);
    let job = h.enqueue(1).await;
    assert_eq!(job.files[0].state, S::SubmissionUnknown);
    assert_eq!(h.backend.posts().await, 1);
    assert!(h.reopened().retry(job.job_id.clone()).await.is_err());
    assert_eq!(h.backend.posts().await, 1);
    h.backend.mode.store(0, Ordering::SeqCst);
    let restored = h.reopened().refresh(job.job_id.clone()).await.unwrap();
    assert_eq!(restored.files[0].state, S::Queued);
    assert_eq!(h.backend.posts().await, 1);
    assert_eq!(h.songs().await, 0);
}
#[tokio::test]
async fn cancellation_and_retry_never_resubmit_completed_files_or_cancel_foreign_ids() {
    let h = Harness::new().await;
    let job = h.enqueue(2).await;
    h.complete(&job, 0).await;
    h.app.refresh(job.job_id.clone()).await.unwrap();
    h.app.cancel(job.job_id.clone()).await.unwrap();
    let stopped = h.app.refresh(job.job_id.clone()).await.unwrap();
    assert_eq!(stopped.files[0].state, S::Completed);
    assert_eq!(stopped.files[1].state, S::Cancelled);
    let retried = h.app.retry(job.job_id.clone()).await.unwrap();
    assert_eq!(retried.files[0].state, S::Completed);
    assert_eq!(retried.files[1].state, S::Queued);
    let state = h.backend.state.lock().await;
    let posts: Vec<_> = state.calls.iter().filter(|(m, _, _)| m == "POST").collect();
    assert_eq!(posts.len(), 2);
    assert_eq!(posts[1].2["files"].as_array().unwrap().len(), 1);
    assert_eq!(posts[1].2["files"][0]["filename"], job.files[1].filename);
    assert!(
        state
            .calls
            .iter()
            .filter(|(m, _, _)| m == "DELETE")
            .all(|(_, p, _)| !p.contains("all"))
    );
}
#[tokio::test]
async fn partial_backend_acceptance_and_foreign_transfers_are_not_adopted() {
    let h = Harness::new().await;
    h.backend.state.lock().await.reject_last = true;
    let job = h.enqueue(2).await;
    assert_eq!(job.files[0].state, S::Queued);
    assert_eq!(job.files[1].state, S::Failed);
    let other = Harness::new().await;
    let file = &other.offer(1).files[0];
    other.backend.state.lock().await.foreign.push(json!({"id":"11111111-1111-4111-8111-111111111111","batchId":"22222222-2222-4222-8222-222222222222","filename":file.filename,"size":file.size_bytes,"bytesTransferred":0,"state":"Queued"}));
    let job = other.enqueue(1).await;
    assert_eq!(job.files[0].state, S::Failed);
    assert!(job.message.is_some());
    assert_eq!(other.backend.posts().await, 0);
}
#[tokio::test]
async fn wrong_batch_identity_or_configuration_changes_never_change_owned_progress() {
    let h = Harness::new().await;
    let job = h.enqueue(1).await;
    h.backend.state.lock().await.wrong_identity = true;
    let invalid = h.app.refresh(job.job_id.clone()).await.unwrap();
    assert!(invalid.message.is_some());
    assert_eq!(invalid.files[0].state, S::Queued);
    h.backend.state.lock().await.wrong_identity = false;
    let config = DownloadSearchApplication::new(h.runtime.clone()).await;
    config
        .configure("https://different.invalid".into(), None, true, true)
        .await
        .unwrap();
    let denied = h.app.refresh(job.job_id).await.unwrap();
    assert!(denied.message.is_some());
    assert_eq!(denied.files[0].state, S::Queued);
    assert_eq!(h.backend.posts().await, 1);
}
#[tokio::test]
async fn file_mapping_size_hash_and_atomic_destination_are_checked_before_library_writes() {
    let h = Harness::new().await;
    let job = h.enqueue(1).await;
    let path = h.complete(&job, 0).await;
    h.app.refresh(job.job_id.clone()).await.unwrap();
    let outside = h.dir.path().join("outside.wav");
    std::fs::write(&outside, wav()).unwrap();
    assert!(
        h.app
            .inspect_file(job.job_id.clone(), 0, outside.to_string_lossy().into())
            .await
            .is_err()
    );
    std::fs::write(&path, b"incomplete").unwrap();
    assert!(
        h.app
            .inspect_file(job.job_id.clone(), 0, path.to_string_lossy().into())
            .await
            .is_err()
    );
    std::fs::write(&path, wav()).unwrap();
    let preview = h
        .app
        .inspect_file(job.job_id.clone(), 0, path.to_string_lossy().into())
        .await
        .unwrap();
    let mut changed = wav();
    *changed.last_mut().unwrap() = 1;
    std::fs::write(&path, &changed).unwrap();
    assert!(
        h.app
            .import_file(job.job_id.clone(), 0, preview.review_token, None, true)
            .await
            .is_err()
    );
    assert_eq!(h.songs().await, 0);
    std::fs::write(&path, wav()).unwrap();
    let preview = h
        .app
        .inspect_file(job.job_id.clone(), 0, path.to_string_lossy().into())
        .await
        .unwrap();
    let destination = PathBuf::from(&preview.destination);
    std::fs::create_dir_all(destination.parent().unwrap()).unwrap();
    std::fs::write(&destination, &changed).unwrap();
    assert!(
        h.app
            .import_file(job.job_id, 0, preview.review_token, None, true)
            .await
            .is_err()
    );
    assert_eq!(std::fs::read(destination).unwrap(), changed);
    assert_eq!(h.songs().await, 0);
}
#[tokio::test]
async fn interrupted_import_reuses_the_published_copy_and_commits_once_after_restart() {
    let h = Harness::new().await;
    let job = h.enqueue(1).await;
    let path = h.complete(&job, 0).await;
    h.app.refresh(job.job_id.clone()).await.unwrap();
    let preview = h
        .app
        .inspect_file(job.job_id.clone(), 0, path.to_string_lossy().into())
        .await
        .unwrap();
    let mut stored = h.app.repository.get(job.job_id.clone()).await.unwrap();
    let review = stored.details[0].review.clone().unwrap();
    stored.job.files[0].state = S::Importing;
    stored.details[0].import = Some(ImportJournal {
        target: None,
        destination: preview.destination.clone(),
        digest: review.digest.clone(),
        token: preview.review_token.clone(),
    });
    h.app.repository.save(stored.clone()).await.unwrap();
    let decoded = crate::infrastructure::acquisition_files::materialize(
        stored.job.clone(),
        0,
        review,
        preview.destination,
        h.config.covers_dir.clone(),
        Arc::new(std::sync::atomic::AtomicBool::new(false)),
    )
    .await
    .unwrap();
    assert!(
        h.app
            .repository
            .commit_import(
                stored,
                0,
                decoded,
                Arc::new(std::sync::atomic::AtomicBool::new(true))
            )
            .await
            .is_err()
    );
    assert_eq!(h.songs().await, 0);
    std::fs::remove_file(path).unwrap();
    let app = h.reopened();
    let preview = app.pending_import(job.job_id.clone(), 0).await.unwrap();
    assert!(preview.resuming);
    let result = app
        .import_file(
            job.job_id.clone(),
            0,
            preview.review_token.clone(),
            None,
            true,
        )
        .await
        .unwrap();
    assert_eq!(result.files[0].state, S::Imported);
    assert_eq!(h.songs().await, 1);
    app.import_file(job.job_id, 0, preview.review_token, None, true)
        .await
        .unwrap();
    assert_eq!(h.songs().await, 1);
}
#[tokio::test]
async fn association_preserves_remote_identity_personal_values_history_and_playlist_duplicates() {
    let h = Harness::new().await;
    let target=h.app.repository.run(|c|{
        let entry=CatalogEntry {reference:CatalogReference{provider:"soundcloud".into(),kind:CatalogItemKind::AudioTrack,id:"artist/reviewed".into()},title:"Personal title".into(),artist_credit:Some("Artist".into()),version_label:None,duration_seconds:Some(180),canonical_url:Some("https://soundcloud.com/artist/reviewed".into())};
        let id=crate::database::source_catalog::save_remote(c,&entry).unwrap();
        c.execute("UPDATE songs SET rating_half_steps=9,is_favorite=1,play_count=4 WHERE song_id=?1",[id]).unwrap();
        c.execute("INSERT INTO user_tags(tag_id,name,normalized_name) VALUES(77,'Personal tag','personal tag')",[]).unwrap();
        c.execute("INSERT INTO track_user_tags(song_id,tag_id) VALUES(?1,77)",[id]).unwrap();
        c.execute("INSERT INTO play_history(song_id,played_at,play_duration) VALUES(?1,'2026-01-01',100)",[id]).unwrap();c.execute("INSERT INTO playlists(id,name) VALUES(9,'Personal')",[]).unwrap();c.execute("INSERT INTO playlist_songs(playlist_id,song_id,position) VALUES(9,?1,0),(9,?1,1)",[id]).unwrap();Ok(id)
    }).await.unwrap();
    let job = h.enqueue(1).await;
    let path = h.complete(&job, 0).await;
    h.app.refresh(job.job_id.clone()).await.unwrap();
    let preview = h
        .app
        .inspect_file(job.job_id.clone(), 0, path.to_string_lossy().into())
        .await
        .unwrap();
    let result = h
        .app
        .import_file(job.job_id, 0, preview.review_token, Some(target), true)
        .await
        .unwrap();
    assert_eq!(result.files[0].imported_track_id, Some(target));
    assert_eq!(h.songs().await, 1);
    h.app.repository.run(move|c|{let values:(String,i64,bool,i64)=c.query_row("SELECT title,rating_half_steps,is_favorite,play_count FROM songs WHERE song_id=?1",[target],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?))).unwrap();assert_eq!(values,("Personal title".into(),9,true,4));assert_eq!(c.query_row("SELECT COUNT(*) FROM track_user_tags WHERE song_id=?1",[target],|r|r.get::<_,i64>(0)).unwrap(),1);assert_eq!(c.query_row("SELECT COUNT(*) FROM play_history",[],|r|r.get::<_,i64>(0)).unwrap(),1);assert_eq!(c.query_row("SELECT COUNT(*) FROM playlist_songs",[],|r|r.get::<_,i64>(0)).unwrap(),2);assert_eq!(c.query_row("SELECT COUNT(*) FROM track_sources WHERE song_id=?1",[target],|r|r.get::<_,i64>(0)).unwrap(),2);Ok(())}).await.unwrap();
}

#[tokio::test]
async fn search_selection_is_explicit_session_owned_and_can_enqueue_without_adopting_the_library() {
    let h = Harness::new().await;
    let search = Arc::new(DownloadSearchApplication::new(h.runtime.clone()).await);
    let session = crate::application::download_search::SearchSession::new(search);
    session
        .start(
            DownloadSearchRequest {
                query: "Artist Album".into(),
                expected_tracks: vec![],
            },
            1,
        )
        .await
        .unwrap();
    let page = session.poll(1).await.unwrap();
    assert_eq!(page.groups.len(), 1);
    let offer = &page.groups[0];
    let names = vec![offer.files[0].filename.clone()];
    assert!(
        session
            .selected_offer("forged".into(), names.clone(), true)
            .await
            .is_err()
    );
    assert!(
        session
            .selected_offer(offer.offer_id.clone(), names.clone(), false)
            .await
            .is_err()
    );
    assert!(
        session
            .selected_offer(offer.offer_id.clone(), vec!["not-offered.wav".into()], true)
            .await
            .is_err()
    );
    let (endpoint, group) = session
        .selected_offer(offer.offer_id.clone(), names.clone(), true)
        .await
        .unwrap();
    let job = h.app.enqueue(endpoint, group).await.unwrap();
    assert_eq!(job.files[0].state, S::Queued);
    assert_eq!(h.songs().await, 0);
    session.cancel(true).await;
    assert!(
        session
            .selected_offer(offer.offer_id.clone(), names, true)
            .await
            .is_err()
    );
    let path = h.complete(&job, 0).await;
    h.app.refresh(job.job_id.clone()).await.unwrap();
    let preview = h
        .app
        .inspect_file(job.job_id.clone(), 0, path.to_string_lossy().into())
        .await
        .unwrap();
    h.app
        .import_file(job.job_id, 0, preview.review_token, None, true)
        .await
        .unwrap();
    assert_eq!(h.songs().await, 1);
}
#[tokio::test]
async fn complete_bytes_without_success_and_invalid_audio_never_import_but_completed_partial_files_survive_cancel()
 {
    let h = Harness::new().await;
    let job = h.enqueue(2).await;
    let path = h.complete(&job, 0).await;
    {
        let mut state = h.backend.state.lock().await;
        let row = &mut state.batches.values_mut().next().unwrap()["transfers"][0];
        row["state"] = json!("InProgress");
    }
    let progress = h.app.refresh(job.job_id.clone()).await.unwrap();
    assert_eq!(progress.files[0].state, S::Downloading);
    assert!(
        h.app
            .inspect_file(job.job_id.clone(), 0, path.to_string_lossy().into())
            .await
            .is_err()
    );
    h.complete(&job, 0).await;
    h.app.cancel(job.job_id.clone()).await.unwrap();
    let stopped = h.app.refresh(job.job_id.clone()).await.unwrap();
    assert_eq!(stopped.files[0].state, S::Completed);
    std::fs::write(&path, vec![0u8; wav().len()]).unwrap();
    assert!(
        h.app
            .inspect_file(job.job_id.clone(), 0, path.to_string_lossy().into())
            .await
            .is_err()
    );
    std::fs::write(&path, wav()).unwrap();
    let preview = h
        .app
        .inspect_file(job.job_id.clone(), 0, path.to_string_lossy().into())
        .await
        .unwrap();
    let imported = h
        .app
        .import_file(job.job_id, 0, preview.review_token, None, true)
        .await
        .unwrap();
    assert_eq!(imported.files[0].state, S::Imported);
    assert_eq!(imported.files[1].state, S::Cancelled);
    assert_eq!(h.songs().await, 1);
}

#[tokio::test]
async fn confirmed_completion_remains_importable_after_backend_retention_or_network_loss() {
    let h = Harness::new().await;
    let job = h.enqueue(1).await;
    let path = h.complete(&job, 0).await;
    h.app.refresh(job.job_id.clone()).await.unwrap();
    h.backend.state.lock().await.batches.clear();
    h.backend.mode.store(503, Ordering::SeqCst);
    let calls = h.backend.state.lock().await.calls.len();
    let restored = h.reopened().refresh(job.job_id.clone()).await.unwrap();
    assert_eq!(restored.files[0].state, S::Completed);
    assert_eq!(h.backend.state.lock().await.calls.len(), calls);
    let preview = h
        .app
        .inspect_file(job.job_id.clone(), 0, path.to_string_lossy().into())
        .await
        .unwrap();
    let imported = h
        .app
        .import_file(job.job_id, 0, preview.review_token, None, true)
        .await
        .unwrap();
    assert_eq!(imported.files[0].state, S::Imported);
    assert_eq!(h.songs().await, 1);
}

#[tokio::test]
async fn a_failure_before_submission_can_be_retried_without_creating_ambiguous_or_duplicate_downloads()
 {
    let h = Harness::new().await;
    h.backend.mode.store(503, Ordering::SeqCst);
    let job = h.enqueue(1).await;
    assert_eq!(job.files[0].state, S::Failed);
    assert_eq!(h.backend.posts().await, 0);
    h.backend.mode.store(0, Ordering::SeqCst);
    let retried = h.app.retry(job.job_id.clone()).await.unwrap();
    assert_eq!(retried.files[0].state, S::Queued);
    assert_eq!(h.backend.posts().await, 1);
    h.app.retry(job.job_id).await.unwrap();
    assert_eq!(h.backend.posts().await, 1);
}
#[tokio::test]
async fn a_journal_prepared_before_the_first_request_resumes_only_on_explicit_retry() {
    let h = Harness::new().await;
    h.runtime
        .set_enabled(&ProviderId::new("slskd").unwrap(), false)
        .await
        .unwrap();
    let job = h.enqueue(1).await;
    assert_eq!(h.backend.posts().await, 0);
    let mut stored = h.app.repository.get(job.job_id.clone()).await.unwrap();
    let original_batch = stored.attempts[0].id.clone();
    stored.job.files[0].state = S::Prepared;
    stored.attempts[0].not_submitted = false;
    h.app.repository.save(stored).await.unwrap();
    h.runtime
        .set_enabled(&ProviderId::new("slskd").unwrap(), true)
        .await
        .unwrap();
    let app = h.reopened();
    app.list().await.unwrap();
    assert_eq!(h.backend.posts().await, 0);
    let resumed = app.retry(job.job_id).await.unwrap();
    assert_eq!(resumed.files[0].state, S::Queued);
    assert_eq!(h.backend.posts().await, 1);
    assert!(
        h.backend
            .state
            .lock()
            .await
            .batches
            .contains_key(&original_batch)
    );
}
