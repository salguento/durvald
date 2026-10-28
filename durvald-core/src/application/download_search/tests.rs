use super::*;
use crate::application::music_plugins::{
    PluginCredentialStore, PluginFuture, PluginStateStore, RuntimeLimits,
};
use crate::domain::music::plugins::PluginPreferences;
use crate::infrastructure::music_plugins::RemoteRequestScope;
use std::{
    collections::BTreeMap,
    sync::atomic::{AtomicU16, AtomicUsize, Ordering},
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
    task::JoinHandle,
};
#[derive(Default)]
struct Memory {
    preferences: Mutex<PluginPreferences>,
    key: Mutex<Option<String>>,
}
impl PluginStateStore for Memory {
    fn load(&self) -> PluginFuture<'_, PluginPreferences> {
        Box::pin(async { Ok(self.preferences.lock().await.clone()) })
    }
    fn save(&self, p: PluginPreferences) -> PluginFuture<'_, ()> {
        Box::pin(async move {
            *self.preferences.lock().await = p;
            Ok(())
        })
    }
}
impl PluginCredentialStore for Memory {
    fn get<'a>(&'a self, _: &'a ProviderId, _: &'a str) -> PluginFuture<'a, Option<PluginSecret>> {
        Box::pin(async { Ok(self.key.lock().await.clone().map(PluginSecret::new)) })
    }
    fn set<'a>(&'a self, _: &'a ProviderId, _: &'a str, key: PluginSecret) -> PluginFuture<'a, ()> {
        Box::pin(async move {
            *self.key.lock().await = Some(key.expose().into());
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
struct Backend {
    url: String,
    requests: Arc<Mutex<Vec<(String, String)>>>,
    mode: Arc<AtomicU16>,
    polls: Arc<AtomicUsize>,
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
        let requests = Arc::new(Mutex::new(vec![]));
        let mode = Arc::new(AtomicU16::new(200));
        let polls = Arc::new(AtomicUsize::new(0));
        let (log, behavior, count) = (requests.clone(), mode.clone(), polls.clone());
        let task = tokio::spawn(async move {
            while let Ok((mut socket, _)) = listener.accept().await {
                let mut bytes = vec![];
                let mut chunk = [0; 4096];
                loop {
                    let n = socket.read(&mut chunk).await.unwrap_or(0);
                    if n == 0 {
                        break;
                    }
                    bytes.extend_from_slice(&chunk[..n]);
                    if let Some(end) = bytes.windows(4).position(|w| w == b"\r\n\r\n") {
                        let headers = String::from_utf8_lossy(&bytes[..end]);
                        let len = headers
                            .lines()
                            .find_map(|l| {
                                l.to_ascii_lowercase()
                                    .strip_prefix("content-length:")
                                    .and_then(|v| v.trim().parse::<usize>().ok())
                            })
                            .unwrap_or(0);
                        if bytes.len() >= end + 4 + len {
                            break;
                        }
                    }
                }
                let input = String::from_utf8_lossy(&bytes);
                let line = input.lines().next().unwrap_or("");
                let parts: Vec<_> = line.split_whitespace().collect();
                if parts.len() < 2 {
                    continue;
                }
                let (method, path) = (parts[0].to_owned(), parts[1].to_owned());
                log.lock().await.push((method.clone(), path.clone()));
                let mode = behavior.load(Ordering::SeqCst);
                if mode == 999 {
                    tokio::time::sleep(Duration::from_secs(8)).await;
                    continue;
                }
                let mut status = mode;
                let body = if !input
                    .to_ascii_lowercase()
                    .contains("x-api-key: fixture-secret-123456")
                {
                    status = 401;
                    serde_json::json!({"message":"never expose this body"})
                } else if mode == 998 {
                    serde_json::json!({"unexpected":"schema"})
                } else if method == "POST" {
                    let posted: serde_json::Value =
                        serde_json::from_str(input.split("\r\n\r\n").nth(1).unwrap()).unwrap();
                    serde_json::json!({"id":posted["id"]})
                } else if method == "GET" && path.ends_with("/responses") {
                    let n = count.fetch_add(1, Ordering::SeqCst);
                    if mode == 997 {
                        serde_json::json!([])
                    } else {
                        responses(n > 0)
                    }
                } else if method == "GET" {
                    serde_json::json!({"state":if mode==997||count.load(Ordering::SeqCst)<2 {"InProgress"}else{"Completed, Succeeded"}})
                } else {
                    serde_json::Value::Null
                };
                if status > 599 {
                    status = 200;
                }
                let body = serde_json::to_vec(&body).unwrap();
                let header = format!(
                    "HTTP/1.1 {status} Result\r\nContent-Length: {}\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n",
                    body.len()
                );
                let _ = socket.write_all(header.as_bytes()).await;
                let _ = socket.write_all(&body).await;
            }
        });
        Self {
            url,
            requests,
            mode,
            polls,
            task,
        }
    }
}
fn responses(more: bool) -> serde_json::Value {
    let one = serde_json::json!({"username":"peer-b","hasFreeUploadSlot":true,"queueLength":0,"uploadSpeed":1000,"files":[
        {"filename":"Music\\Album\\CD1\\01 - First.flac","size":100,"length":180,"sampleRate":44100,"bitDepth":16},
        {"filename":"Music\\Album\\CD2\\01 - Second.mp3","size":20,"length":200,"bitRate":320},
        {"filename":"Music\\Album\\CD2\\01 - Second.mp3","size":20,"length":200,"bitRate":320},
        {"filename":"Music\\Album\\cover.jpg","size":10},{"filename":"Music\\Album\\run.command","size":10},
        {"filename":"Music\\Album\\locked.flac","size":10,"isLocked":true}]});
    if more {
        serde_json::json!([one,{"username":"peer-a","files":[{"filename":"Music/Album/01 - Different.flac","size":150}]}])
    } else {
        serde_json::json!([one])
    }
}
async fn application(
    memory: Arc<Memory>,
    dir: &tempfile::TempDir,
) -> Arc<DownloadSearchApplication> {
    let runtime = Arc::new(
        PluginRuntime::new(
            memory.clone(),
            memory,
            Arc::new(RemoteRequestScope::new(dir.path().join("http.sqlite"))),
            RuntimeLimits::default(),
        )
        .await
        .unwrap(),
    );
    Arc::new(DownloadSearchApplication::new(runtime).await)
}
fn request() -> DownloadSearchRequest {
    DownloadSearchRequest {
        query: "Artist Album".into(),
        expected_tracks: vec![
            DownloadExpectedTrack {
                title: "First".into(),
                disc: 1,
                position: 1,
                duration_seconds: Some(180),
            },
            DownloadExpectedTrack {
                title: "Second".into(),
                disc: 2,
                position: 1,
                duration_seconds: Some(202),
            },
        ],
    }
}
async fn configured() -> (
    Backend,
    Arc<DownloadSearchApplication>,
    Arc<Memory>,
    tempfile::TempDir,
) {
    let backend = Backend::new().await;
    let memory = Arc::new(Memory::default());
    let dir = tempfile::tempdir().unwrap();
    let app = application(memory.clone(), &dir).await;
    app.configure(
        backend.url.clone(),
        Some("fixture-secret-123456".into()),
        true,
        true,
    )
    .await
    .unwrap();
    (backend, app, memory, dir)
}
#[tokio::test]
async fn incremental_groups_preserve_unknowns_deduplicate_and_compare_multiple_discs() {
    let (backend, app, _, _dir) = configured().await;
    let session = SearchSession::new(app);
    assert!(backend.requests.lock().await.is_empty());
    assert_eq!(
        session.start(request(), 1).await.unwrap().state,
        DownloadSearchState::Searching
    );
    let first = session.poll(1).await.unwrap();
    assert_eq!(first.groups.len(), 1);
    let g = &first.groups[0];
    assert_eq!(g.folder, "Music/Album");
    assert_eq!(g.files.len(), 2);
    assert_eq!(g.total_bytes, 120);
    assert_eq!(g.matched_tracks, 2);
    assert_eq!(g.duration_matches, 2);
    assert_eq!(g.files[0].bitrate_kbps, None);
    let second = session.poll(1).await.unwrap();
    assert_eq!(second.groups.len(), 2);
    assert_eq!(second.groups[0].offer_id, g.offer_id);
    let unknown = second.groups.iter().find(|g| g.peer == "peer-a").unwrap();
    assert_eq!(unknown.queue_length, None);
    assert_eq!(unknown.free_upload_slot, None);
    let end = session.poll(1).await.unwrap();
    assert_eq!(end.state, DownloadSearchState::Completed);
    assert_eq!(end.groups.len(), 2);
    let log = backend.requests.lock().await;
    assert!(log.iter().any(|(m, _)| m == "PUT"));
    assert!(log.iter().any(|(m, _)| m == "DELETE"));
    assert!(log.iter().all(|(_, p)| p.starts_with("/api/v0/searches")));
    assert!(backend.polls.load(Ordering::SeqCst) >= 2);
}
#[tokio::test]
async fn cancellation_supersession_and_close_never_publish_previous_results() {
    let (backend, app, _, _dir) = configured().await;
    let session = SearchSession::new(app);
    session.start(request(), 1).await.unwrap();
    session.poll(1).await.unwrap();
    let cancelled = session.cancel(false).await;
    assert_eq!(cancelled.state, DownloadSearchState::Cancelled);
    session.start(request(), 2).await.unwrap();
    assert_eq!(
        session.poll(1).await.unwrap().state,
        DownloadSearchState::Cancelled
    );
    assert!(session.start(request(), 1).await.is_err());
    session.cancel(true).await;
    assert!(session.start(request(), 3).await.is_err());
    let log = backend.requests.lock().await;
    let ids: Vec<_> = log
        .iter()
        .filter(|(m, _)| m == "DELETE")
        .map(|(_, p)| p.clone())
        .collect();
    assert_eq!(ids.len(), 2);
    assert_ne!(ids[0], ids[1]);
}
#[tokio::test]
async fn reconfiguration_cancels_old_search_and_cleans_up_its_original_backend() {
    let (backend, app, _, _dir) = configured().await;
    let session = SearchSession::new(app.clone());
    session.start(request(), 1).await.unwrap();
    app.configure("https://example.invalid".into(), None, false, true)
        .await
        .unwrap();
    let page = session.poll(1).await.unwrap();
    assert_eq!(page.failure, Some(DownloadSearchFailure::Disabled));
    assert!(
        backend
            .requests
            .lock()
            .await
            .iter()
            .any(|(m, _)| m == "DELETE")
    );
}
#[tokio::test]
async fn timeout_without_responses_is_bounded_and_keeps_partial_offers() {
    let (_backend, app, _, _dir) = configured().await;
    let session = SearchSession::new(app);
    session.start(request(), 1).await.unwrap();
    let partial = session.poll(1).await.unwrap();
    session.state.lock().await.active.as_mut().unwrap().deadline =
        Instant::now() - Duration::from_secs(1);
    let end = session.poll(1).await.unwrap();
    assert_eq!(end.state, DownloadSearchState::TimedOut);
    assert_eq!(end.groups, partial.groups);
}
#[tokio::test]
async fn api_failures_are_isolated_typed_and_never_expose_backend_messages() {
    for (status, expected) in [
        (401, DownloadSearchFailure::Authentication),
        (403, DownloadSearchFailure::Authentication),
        (429, DownloadSearchFailure::RateLimited),
        (503, DownloadSearchFailure::Unavailable),
    ] {
        let (backend, app, _, _dir) = configured().await;
        backend.mode.store(status, Ordering::SeqCst);
        let session = SearchSession::new(app);
        let page = session.start(request(), 1).await.unwrap();
        assert_eq!(page.failure, Some(expected));
        assert!(page.groups.is_empty());
        assert!(!format!("{page:?}").contains("never expose"));
    }
    let (backend, app, _, _dir) = configured().await;
    let session = SearchSession::new(app);
    session.start(request(), 1).await.unwrap();
    backend.mode.store(998, Ordering::SeqCst);
    assert_eq!(
        session.poll(1).await.unwrap().failure,
        Some(DownloadSearchFailure::InvalidResponse)
    );
}
#[tokio::test]
async fn no_responses_remain_unknown_until_deadline_and_transport_timeout_is_distinct() {
    let (backend, app, _, _dir) = configured().await;
    backend.mode.store(997, Ordering::SeqCst);
    let session = SearchSession::new(app);
    session.start(request(), 1).await.unwrap();
    let page = session.poll(1).await.unwrap();
    assert!(page.groups.is_empty());
    assert_eq!(page.state, DownloadSearchState::Searching);
    backend.mode.store(999, Ordering::SeqCst);
    assert_eq!(
        session.poll(1).await.unwrap().failure,
        Some(DownloadSearchFailure::TimedOut)
    );
}
#[tokio::test]
async fn settings_persist_separately_from_secret_and_validation_precedes_network() {
    let (backend, app, memory, dir) = configured().await;
    assert!(!format!("{:?}", memory.preferences.lock().await).contains("fixture-secret"));
    assert!(
        app.configure("http://192.168.1.2:5030".into(), None, true, true)
            .await
            .is_err()
    );
    assert!(
        app.configure(backend.url.clone(), None, true, false)
            .await
            .is_err()
    );
    let session = SearchSession::new(app.clone());
    let mut bad = request();
    bad.query = "x".into();
    assert!(session.start(bad, 1).await.is_err());
    assert!(backend.requests.lock().await.is_empty());
    let reopened = application(memory, &dir).await;
    assert!(reopened.settings().await.unwrap().enabled);
    app.configure(backend.url.clone(), Some(String::new()), false, true)
        .await
        .unwrap();
    assert!(!app.settings().await.unwrap().has_api_key);
}
#[test]
fn endpoint_and_matching_never_infer_edition_or_quality_from_extension() {
    use crate::infrastructure::slskd_search::endpoint;
    for bad in [
        "http://remote.test",
        "https://user:secret@host",
        "https://host?token=secret",
        "file:///tmp/a",
        "https://host/#secret",
    ] {
        assert!(endpoint(bad).is_err());
    }
    assert_eq!(
        endpoint("http://[::1]:5030").unwrap().as_str(),
        "http://[::1]:5030/api/v0/"
    );
    assert_eq!(
        endpoint("https://host/slskd/api/v0/").unwrap().as_str(),
        "https://host/slskd/api/v0/"
    );
    let mut group = DownloadOfferGroup {
        offer_id: "one".into(),
        peer: "p".into(),
        folder: "album".into(),
        files: vec![DownloadOfferFile {
            filename: "album/01 - First.flac".into(),
            size_bytes: 1,
            format: "flac".into(),
            duration_seconds: Some(900),
            bitrate_kbps: None,
            sample_rate_hz: None,
            bit_depth: None,
        }],
        total_bytes: 1,
        free_upload_slot: None,
        queue_length: None,
        upload_speed_bytes: None,
        matched_tracks: 0,
        expected_tracks: 0,
        duration_matches: 0,
        comparison: String::new(),
    };
    compare(&mut group, &request().expected_tracks);
    assert_eq!(group.matched_tracks, 0);
    assert!(group.comparison.contains("sem garantia"));
    group.files[0].duration_seconds = Some(180);
    compare(&mut group, &request().expected_tracks);
    assert_eq!(group.matched_tracks, 0); // Disc identity missing in a multidisc reference.
    compare(&mut group, &[]);
    assert!(group.comparison.contains("não verificada"));
    let _ = BTreeMap::<String, String>::new();
}

#[tokio::test]
async fn cancelling_an_inflight_blocked_request_discards_its_reply_and_reports_unconfirmed_cleanup()
{
    let (backend, app, _, _dir) = configured().await;
    let session = Arc::new(SearchSession::new(app));
    session.start(request(), 1).await.unwrap();
    backend.mode.store(999, Ordering::SeqCst);
    let polling = tokio::spawn({
        let session = session.clone();
        async move { session.poll(1).await.unwrap() }
    });
    tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            if backend
                .requests
                .lock()
                .await
                .iter()
                .any(|(method, _)| method == "GET")
            {
                break;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    let cancel = tokio::spawn({
        let session = session.clone();
        async move { session.cancel(false).await }
    });
    let result = tokio::time::timeout(Duration::from_secs(1), polling)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(result.state, DownloadSearchState::Cancelled);
    assert!(result.groups.is_empty());
    let end = cancel.await.unwrap();
    assert_eq!(end.state, DownloadSearchState::Cancelled);
    assert!(end.cleanup_pending);
}
