//! Deterministic official-contract fixtures. No accounts or external network.
use super::*;
use crate::{
    application::{
        music_plugins::{
            PluginCredentialStore, PluginFuture, PluginRuntime, PluginSecret, PluginStateStore,
            RuntimeLimits,
        },
        service_collections::ServiceCollectionsApplication,
    },
    domain::music::plugins::PluginPreferences,
    infrastructure::{
        music_plugins::RemoteRequestScope, sqlite::service_collections::ServiceCollectionRepository,
    },
};
use serde_json::{Value, json};
use std::{
    collections::VecDeque,
    sync::atomic::{AtomicUsize, Ordering},
};
use tokio::sync::Mutex;
#[derive(Default)]
struct Memory {
    preferences: Mutex<PluginPreferences>,
    keys: Mutex<BTreeMap<String, String>>,
}
impl PluginStateStore for Memory {
    fn load(&self) -> PluginFuture<'_, PluginPreferences> {
        Box::pin(async { Ok(self.preferences.lock().await.clone()) })
    }
    fn save(&self, v: PluginPreferences) -> PluginFuture<'_, ()> {
        Box::pin(async move {
            *self.preferences.lock().await = v;
            Ok(())
        })
    }
}
impl PluginCredentialStore for Memory {
    fn get<'a>(&'a self, p: &'a ProviderId, k: &'a str) -> PluginFuture<'a, Option<PluginSecret>> {
        Box::pin(async move {
            Ok(self
                .keys
                .lock()
                .await
                .get(&format!("{}:{k}", p.as_str()))
                .cloned()
                .map(PluginSecret::new))
        })
    }
    fn set<'a>(&'a self, p: &'a ProviderId, k: &'a str, v: PluginSecret) -> PluginFuture<'a, ()> {
        Box::pin(async move {
            self.keys
                .lock()
                .await
                .insert(format!("{}:{k}", p.as_str()), v.expose().into());
            Ok(())
        })
    }
    fn delete<'a>(&'a self, p: &'a ProviderId, k: &'a str) -> PluginFuture<'a, ()> {
        Box::pin(async move {
            self.keys
                .lock()
                .await
                .remove(&format!("{}:{k}", p.as_str()));
            Ok(())
        })
    }
}
struct Step {
    path: &'static str,
    result: Result<Response, E>,
}
#[derive(Default)]
struct Fake {
    steps: Mutex<VecDeque<Step>>,
    calls: AtomicUsize,
    urls: Mutex<Vec<String>>,
}
impl Fake {
    async fn json(&self, path: &'static str, body: Value) {
        self.response(path, 200, None, serde_json::to_vec(&body).unwrap())
            .await;
    }
    async fn response(
        &self,
        path: &'static str,
        status: u16,
        location: Option<&str>,
        body: Vec<u8>,
    ) {
        self.steps.lock().await.push_back(Step {
            path,
            result: Ok(Response {
                status,
                location: location.map(str::to_owned),
                retry: None,
                body,
            }),
        });
    }
    async fn error(&self, path: &'static str, error: E) {
        self.steps.lock().await.push_back(Step {
            path,
            result: Err(error),
        });
    }
}
impl ServiceHttp for Fake {
    fn get(&self, url: Url, headers: HeaderMap) -> IntegrationFuture<'_, Response> {
        Box::pin(async move {
            self.calls.fetch_add(1, Ordering::SeqCst);
            assert!(url.query_pairs().all(|(k, _)| {
                ![
                    "key",
                    "api_key",
                    "access_token",
                    "oauth_token",
                    "client_secret",
                ]
                .contains(&k.as_ref())
            }));
            for name in ["authorization", "x-goog-api-key"] {
                if let Some(v) = headers.get(name) {
                    assert!(v.is_sensitive());
                }
            }
            self.urls.lock().await.push(url.as_str().into());
            let step = self
                .steps
                .lock()
                .await
                .pop_front()
                .expect("unexpected external request");
            assert_eq!(url.path(), step.path);
            step.result
        })
    }
}
struct Harness {
    _dir: tempfile::TempDir,
    app: Arc<ServiceCollectionsApplication>,
    http: Arc<Fake>,
    config: CoreConfig,
}
impl Harness {
    async fn new(provider: ServiceProvider) -> Self {
        let dir = tempfile::tempdir().unwrap();
        let config = CoreConfig {
            database_path: dir.path().join("library.sqlite").to_string_lossy().into(),
            app_support_dir: dir.path().to_string_lossy().into(),
            covers_dir: dir.path().join("covers").to_string_lossy().into(),
            keychain_service: "unused-service-fixture".into(),
        };
        let pool = crate::composition::open_database(&config).unwrap();
        let memory = Arc::new(Memory::default());
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
        let http = Arc::new(Fake::default());
        runtime
            .register_builtin_with_default(
                Arc::new(PublicService {
                    provider,
                    http: http.clone(),
                }),
                false,
            )
            .await
            .unwrap();
        let app = Arc::new(
            ServiceCollectionsApplication::new(runtime, ServiceCollectionRepository::new(pool))
                .await,
        );
        app.configure(
            provider,
            true,
            credential_key(provider).map(|_| "fixture-protected-token".into()),
        )
        .await
        .unwrap();
        Self {
            _dir: dir,
            app,
            http,
            config,
        }
    }
    async fn count(&self, table: &'static str) -> i64 {
        self.app
            .repository
            .run(move |c| {
                Ok(
                    c.query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |r| r.get(0))
                        .unwrap(),
                )
            })
            .await
            .unwrap()
    }
    fn reopened(&self) -> ServiceCollectionRepository {
        ServiceCollectionRepository::new(crate::composition::open_database(&self.config).unwrap())
    }
}
fn bandcamp(count: usize) -> Vec<u8> {
    let tracks:Vec<_>=(0..count).map(|i|json!({"track_id":i,"title":format!("Track {i}"),"title_link":format!("/track/song-{i}"),"duration":180,"file":{"mp3-128":"https://cdn.example/temporary?private-audio-token=never-persist"}})).collect();
    let album = json!({"artist":"Artist","current":{"title":"Album"},"trackinfo":tracks});
    format!(
        "<html><script data-tralbum='{}'></script></html>",
        album
            .to_string()
            .replace('&', "&amp;")
            .replace('\'', "&#39;")
    )
    .into_bytes()
}
fn youtube_video(id: &str, title: &str, live: &str) -> Value {
    json!({"id":id,"snippet":{"title":title,"channelTitle":"Uploader","liveBroadcastContent":live},"status":{"embeddable":true,"privacyStatus":"public"},"contentDetails":{"duration":"PT2M30S"}})
}
fn playlist_item(occ: &str, pos: u32, id: &str) -> Value {
    json!({"id":occ,"snippet":{"position":pos,"resourceId":{"videoId":id}},"contentDetails":{"videoId":id}})
}
fn sc_track(id: u64, name: &str, access: &str) -> Value {
    json!({"urn":format!("soundcloud:tracks:{id}"),"title":name,"permalink_url":format!("https://soundcloud.com/artist/track-{id}"),"user":{"username":"Uploader"},"duration":30000,"access":access,"stream_url":"https://private-cdn/secret-audio-token"})
}
#[tokio::test]
async fn bandcamp_album_pages_cache_and_imports_do_not_contain_media_or_duplicate_tracks() {
    let h = Harness::new(ServiceProvider::Bandcamp).await;
    let start = h
        .app
        .begin("https://artist.bandcamp.com/album/album?utm_source=discard".into())
        .await
        .unwrap();
    assert_eq!(h.http.calls.load(Ordering::SeqCst), 0);
    h.http
        .response("/album/album", 200, None, bandcamp(52))
        .await;
    let first = h.app.load(start.job_id.clone(), false, None).await.unwrap();
    assert_eq!(first.items.len(), 50);
    assert!(!first.complete);
    assert_eq!(h.count("songs").await, 0);
    assert_eq!(first.items[0].access, ServiceMediaAccess::StreamObserved);
    let cached = h
        .app
        .load(start.job_id.clone(), false, Some(0))
        .await
        .unwrap();
    assert!(cached.from_cache);
    assert_eq!(h.http.calls.load(Ordering::SeqCst), 1);
    assert!(
        h.app
            .apply(
                start.job_id.clone(),
                vec![first.items[0].occurrence_id.clone()],
                false
            )
            .await
            .is_err()
    );
    let saved = h
        .app
        .apply(
            start.job_id.clone(),
            first
                .items
                .iter()
                .map(|i| i.occurrence_id.clone())
                .collect(),
            true,
        )
        .await
        .unwrap();
    assert_eq!(h.count("songs").await, 50);
    assert_eq!(h.count("playlist_songs").await, 50);
    h.http
        .response("/album/album", 200, None, bandcamp(52))
        .await;
    let second = h.app.load(start.job_id.clone(), false, None).await.unwrap();
    assert_eq!(second.items.len(), 52);
    assert!(second.complete);
    let all: Vec<_> = second
        .items
        .iter()
        .map(|i| i.occurrence_id.clone())
        .collect();
    let applied = h
        .app
        .apply(start.job_id.clone(), all.clone(), true)
        .await
        .unwrap();
    h.app.apply(start.job_id.clone(), all, true).await.unwrap();
    assert_eq!(applied.playlist_id, saved.playlist_id);
    assert_eq!(h.count("songs").await, 52);
    assert_eq!(h.count("track_sources").await, 52);
    assert_eq!(h.count("playlist_songs").await, 52);
    assert_eq!(
        h.app.begin(start.canonical_url).await.unwrap().job_id,
        start.job_id
    );
    let restored = h.reopened().get(start.job_id).await.unwrap();
    assert_eq!(restored.job.items.len(), 52);
    h.app
        .repository
        .run(|c| {
            for table in ["service_collection_jobs", "service_collection_cache"] {
                let mut q = c.prepare(&format!("SELECT payload FROM {table}")).unwrap();
                for s in q.query_map([], |r| r.get::<_, String>(0)).unwrap() {
                    let s = s.unwrap();
                    assert!(!s.contains("private-audio-token"));
                    assert!(!s.contains("fixture-protected-token"));
                    assert!(!s.contains("stream_url"));
                }
            }
            Ok(())
        })
        .await
        .unwrap();
}
#[tokio::test]
async fn youtube_finite_playlist_preserves_duplicate_occurrences_and_partial_failures() {
    let h = Harness::new(ServiceProvider::YouTube).await;
    let job = h
        .app
        .begin("https://www.youtube.com/playlist?list=PLabcdefghijklmnop".into())
        .await
        .unwrap();
    h.http.json("/youtube/v3/playlistItems",json!({"items":[playlist_item("one",0,"abcdefghijk"),playlist_item("two",1,"abcdefghijk"),playlist_item("missing",2,"missing0000")],"nextPageToken":"NEXT"})).await;
    h.http
        .json(
            "/youtube/v3/videos",
            json!({"items":[youtube_video("abcdefghijk","Original title","none")]}),
        )
        .await;
    let first = h.app.load(job.job_id.clone(), false, None).await.unwrap();
    assert_eq!(first.items.len(), 3);
    assert_eq!(first.items[2].access, ServiceMediaAccess::Unavailable);
    let partial = h
        .app
        .apply(
            job.job_id.clone(),
            first
                .items
                .iter()
                .map(|i| i.occurrence_id.clone())
                .collect(),
            true,
        )
        .await
        .unwrap();
    assert_eq!(
        partial.items[0].saved_track_id,
        partial.items[1].saved_track_id
    );
    assert_eq!(h.count("songs").await, 1);
    assert_eq!(h.count("playlist_songs").await, 2);
    h.http.error("/youtube/v3/playlistItems", E::Timeout).await;
    let failed = h.app.load(job.job_id.clone(), false, None).await.unwrap();
    assert_eq!(failed.failure, Some(ServiceImportFailure::TimedOut));
    assert_eq!(
        failed.items[0].saved_track_id,
        partial.items[0].saved_track_id
    );
    h.http
        .json(
            "/youtube/v3/playlistItems",
            json!({"items":[playlist_item("three",3,"mnopqrstuvw")]}),
        )
        .await;
    h.http
        .json(
            "/youtube/v3/videos",
            json!({"items":[youtube_video("mnopqrstuvw","Cover / remix with intro","none")]}),
        )
        .await;
    let second = h.app.load(job.job_id.clone(), false, None).await.unwrap();
    assert!(second.complete);
    assert_eq!(second.items[3].position, 3);
    let final_job = h
        .app
        .apply(
            job.job_id,
            second
                .items
                .iter()
                .map(|i| i.occurrence_id.clone())
                .collect(),
            true,
        )
        .await
        .unwrap();
    assert_eq!(h.count("songs").await, 2);
    assert_eq!(h.count("playlist_songs").await, 3);
    let playlist = final_job.playlist_id.unwrap();
    h.app
        .repository
        .run(move |c| {
            let mut q = c
                .prepare(
                    "SELECT position FROM playlist_songs WHERE playlist_id=?1 ORDER BY position",
                )
                .unwrap();
            let positions: Vec<i64> = q
                .query_map([playlist], |r| r.get(0))
                .unwrap()
                .map(Result::unwrap)
                .collect();
            assert_eq!(positions, vec![0, 1, 3]);
            assert_eq!(
                c.query_row(
                    "SELECT COUNT(*) FROM service_media_policy WHERE finite_video=1",
                    [],
                    |r| r.get::<_, i64>(0)
                )
                .unwrap(),
                2
            );
            Ok(())
        })
        .await
        .unwrap();
}
#[tokio::test]
async fn youtube_lives_future_restricted_and_unknown_items_do_not_create_library_rows() {
    let h = Harness::new(ServiceProvider::YouTube).await;
    let job = h
        .app
        .begin("https://youtu.be/abcdefghijk".into())
        .await
        .unwrap();
    h.http
        .json(
            "/youtube/v3/videos",
            json!({"items":[youtube_video("abcdefghijk","A live event","live")]}),
        )
        .await;
    let loaded = h.app.load(job.job_id.clone(), false, None).await.unwrap();
    assert_eq!(loaded.items[0].access, ServiceMediaAccess::UnsupportedLive);
    h.app
        .apply(
            job.job_id,
            vec![loaded.items[0].occurrence_id.clone()],
            true,
        )
        .await
        .unwrap();
    assert_eq!(h.count("songs").await, 0);
    assert_eq!(h.count("playlists").await, 0);
    assert!(locate("https://www.youtube.com/playlist?list=RDabcdefghijklmnop").is_err());
}
#[tokio::test]
async fn soundcloud_redirect_playlists_preserve_repeats_preview_and_blocked_placeholders() {
    let h = Harness::new(ServiceProvider::SoundCloud).await;
    let job = h
        .app
        .begin("https://soundcloud.com/artist/sets/playlist".into())
        .await
        .unwrap();
    h.http
        .response(
            "/resolve",
            302,
            Some("https://api.soundcloud.com/playlists/soundcloud:playlists:10"),
            vec![],
        )
        .await;
    h.http.json("/playlists/soundcloud:playlists:10",json!({"title":"SC playlist","sharing":"public","track_count":4,"tracks":[sc_track(1,"Preview","preview"),sc_track(1,"Preview","preview"),sc_track(2,"Blocked","blocked"),{"urn":"soundcloud:tracks:3"}]})).await;
    h.http.json("/tracks", json!([])).await;
    let page = h.app.load(job.job_id.clone(), false, None).await.unwrap();
    assert!(page.complete);
    assert_eq!(page.items.len(), 4);
    assert_eq!(page.items[3].access, ServiceMediaAccess::Unavailable);
    let saved = h
        .app
        .apply(
            job.job_id,
            page.items.iter().map(|i| i.occurrence_id.clone()).collect(),
            true,
        )
        .await
        .unwrap();
    assert_eq!(saved.items[0].saved_track_id, saved.items[1].saved_track_id);
    assert_eq!(h.count("songs").await, 1);
    assert_eq!(h.count("playlist_songs").await, 2);
    h.app.repository.run(|c|{assert!(c.query_row("SELECT preview_only FROM service_media_policy WHERE provider='soundcloud' AND external_id='artist/track-1'",[],|r|r.get::<_,bool>(0)).unwrap());let payload:String=c.query_row("SELECT payload FROM service_collection_jobs LIMIT 1",[],|r|r.get(0)).unwrap();assert!(!payload.contains("secret-audio-token"));Ok(())}).await.unwrap();
}
#[tokio::test]
async fn provider_disable_authentication_and_host_validation_are_independent() {
    let h = Harness::new(ServiceProvider::Bandcamp).await;
    let sc = h
        .app
        .begin("https://soundcloud.com/artist/track".into())
        .await
        .unwrap();
    let disabled = h.app.load(sc.job_id.clone(), false, None).await.unwrap();
    assert_eq!(disabled.failure, Some(ServiceImportFailure::Disabled));
    h.app
        .configure(ServiceProvider::SoundCloud, true, None)
        .await
        .unwrap();
    let missing = h.app.load(sc.job_id, false, None).await.unwrap();
    assert_eq!(missing.failure, Some(ServiceImportFailure::Authentication));
    h.http.response("/track/song", 200, None, bandcamp(1)).await;
    let bc = h
        .app
        .begin("https://artist.bandcamp.com/track/song".into())
        .await
        .unwrap();
    let page = h.app.load(bc.job_id, false, None).await.unwrap();
    assert_eq!(page.items.len(), 1);
    for url in [
        "http://artist.bandcamp.com/track/song",
        "https://soundcloud.com/artist",
        "https://user:password@soundcloud.com/a/b",
        "https://artist.bandcamp.com.evil.test/album/album",
    ] {
        assert!(locate(url).is_err());
    }
    assert_eq!(h.http.calls.load(Ordering::SeqCst), 1);
}
#[tokio::test]
async fn soundcloud_never_forwards_credentials_to_redirects_outside_the_api() {
    let h = Harness::new(ServiceProvider::SoundCloud).await;
    h.http
        .response(
            "/resolve",
            302,
            Some("https://evil.test/tracks/123"),
            vec![],
        )
        .await;
    let job = h
        .app
        .begin("https://soundcloud.com/artist/track".into())
        .await
        .unwrap();
    let result = h.app.load(job.job_id, false, None).await.unwrap();
    assert_eq!(result.failure, Some(ServiceImportFailure::InvalidResponse));
    assert_eq!(h.http.calls.load(Ordering::SeqCst), 1);
    assert_eq!(h.count("songs").await, 0);
}
#[tokio::test]
async fn cancellation_restart_and_changed_snapshot_keep_already_imported_occurrences() {
    let h = Harness::new(ServiceProvider::Bandcamp).await;
    let job = h
        .app
        .begin("https://artist.bandcamp.com/album/album".into())
        .await
        .unwrap();
    h.http
        .response("/album/album", 200, None, bandcamp(51))
        .await;
    let page = h.app.load(job.job_id.clone(), false, None).await.unwrap();
    let saved = h
        .app
        .apply(
            job.job_id.clone(),
            vec![page.items[0].occurrence_id.clone()],
            true,
        )
        .await
        .unwrap();
    let stopped = h.app.cancel(job.job_id.clone()).await.unwrap();
    assert!(stopped.cancelled);
    assert!(h.app.load(job.job_id.clone(), false, None).await.is_err());
    h.app.resume(job.job_id.clone()).await.unwrap();
    h.http
        .response("/album/album", 200, None, bandcamp(52))
        .await;
    let changed = h.app.load(job.job_id.clone(), false, None).await.unwrap();
    assert_eq!(changed.failure, Some(ServiceImportFailure::InvalidResponse));
    assert_eq!(
        changed.items[0].saved_track_id,
        saved.items[0].saved_track_id
    );
    assert_eq!(h.count("songs").await, 1);
    assert_eq!(h.count("playlist_songs").await, 1);
    assert_eq!(
        h.reopened().get(job.job_id).await.unwrap().job.items.len(),
        50
    );
}
#[tokio::test]
async fn reimport_does_not_overwrite_personal_values_or_manually_edited_playlist_positions() {
    let h = Harness::new(ServiceProvider::Bandcamp).await;
    let job = h
        .app
        .begin("https://artist.bandcamp.com/album/album".into())
        .await
        .unwrap();
    h.http
        .response("/album/album", 200, None, bandcamp(2))
        .await;
    let page = h.app.load(job.job_id.clone(), false, None).await.unwrap();
    let first = h
        .app
        .apply(
            job.job_id.clone(),
            vec![page.items[0].occurrence_id.clone()],
            true,
        )
        .await
        .unwrap();
    let song = first.items[0].saved_track_id.unwrap();
    let playlist = first.playlist_id.unwrap();
    h.app.repository.run(move|c|{c.execute("UPDATE songs SET title='Personal',rating_half_steps=8,is_favorite=1 WHERE song_id=?1",[song]).unwrap();c.execute("UPDATE playlists SET name='Renamed' WHERE id=?1",[playlist]).unwrap();c.execute("INSERT INTO playlist_songs(playlist_id,song_id,position) VALUES(?1,?2,1)",rusqlite::params![playlist,song]).unwrap();Ok(())}).await.unwrap();
    let saved = h
        .app
        .apply(
            job.job_id,
            page.items.iter().map(|i| i.occurrence_id.clone()).collect(),
            true,
        )
        .await
        .unwrap();
    assert_eq!(
        saved.items[1].failure,
        Some(ServiceImportFailure::InvalidResponse)
    );
    assert_eq!(h.count("songs").await, 1);
    assert_eq!(h.count("track_sources").await, 1);
    h.app
        .repository
        .run(move |c| {
            assert_eq!(
                c.query_row(
                    "SELECT title,rating_half_steps,is_favorite FROM songs WHERE song_id=?1",
                    [song],
                    |r| Ok((
                        r.get::<_, String>(0)?,
                        r.get::<_, i64>(1)?,
                        r.get::<_, bool>(2)?
                    ))
                )
                .unwrap(),
                ("Personal".into(), 8, true)
            );
            assert_eq!(
                c.query_row("SELECT name FROM playlists WHERE id=?1", [playlist], |r| {
                    r.get::<_, String>(0)
                })
                .unwrap(),
                "Renamed"
            );
            Ok(())
        })
        .await
        .unwrap();
}

#[tokio::test]
#[ignore = "Explicit public Bandcamp network smoke; no account or media download"]
async fn live_public_bandcamp_track_metadata() {
    let h = Harness::new(ServiceProvider::Bandcamp).await;
    let id = ProviderId::new(plugin_id(ServiceProvider::Bandcamp)).unwrap();
    h.app.runtime.remove(&id).await.unwrap();
    h.app
        .runtime
        .install(Arc::new(PublicService::new(ServiceProvider::Bandcamp)))
        .await
        .unwrap();
    h.app
        .configure(ServiceProvider::Bandcamp, true, None)
        .await
        .unwrap();
    let job = h
        .app
        .begin("https://benprunty.bandcamp.com/track/civil-explore".into())
        .await
        .unwrap();
    let page = h.app.load(job.job_id, false, None).await.unwrap();
    assert_eq!(page.failure, None);
    assert_eq!(page.items.len(), 1);
    assert!(
        page.items[0]
            .entry
            .as_ref()
            .unwrap()
            .title
            .to_ascii_lowercase()
            .contains("civil")
    );
    assert_eq!(h.count("songs").await, 0);
}

#[tokio::test]
async fn youtube_cursor_cycles_and_empty_page_limits_stop_without_library_writes() {
    let h = Harness::new(ServiceProvider::YouTube).await;
    let job = h
        .app
        .begin("https://www.youtube.com/playlist?list=PLboundedfixture".into())
        .await
        .unwrap();
    for page in 0..40 {
        h.http
            .response(
                "/youtube/v3/playlistItems",
                200,
                None,
                serde_json::to_vec(&json!({"items":[], "nextPageToken":format!("page-{page}")}))
                    .unwrap(),
            )
            .await;
        let loaded = h.app.load(job.job_id.clone(), false, None).await.unwrap();
        assert_eq!(loaded.loaded_pages, page + 1);
        if page == 39 {
            assert_eq!(loaded.failure, Some(ServiceImportFailure::LimitReached));
        }
    }
    let bounded = h.app.load(job.job_id, false, None).await.unwrap();
    assert_eq!(bounded.loaded_pages, 40);
    let cycle = h
        .app
        .begin("https://www.youtube.com/playlist?list=PLcursorfixture".into())
        .await
        .unwrap();
    for _ in 0..2 {
        h.http
            .response(
                "/youtube/v3/playlistItems",
                200,
                None,
                serde_json::to_vec(&json!({"items":[], "nextPageToken":"same-page"})).unwrap(),
            )
            .await;
    }
    h.app.load(cycle.job_id.clone(), false, None).await.unwrap();
    let rejected = h.app.load(cycle.job_id, false, None).await.unwrap();
    assert_eq!(
        rejected.failure,
        Some(ServiceImportFailure::ChangedCollection)
    );
    assert_eq!(rejected.loaded_pages, 1);
    assert_eq!(h.count("songs").await, 0);
}
