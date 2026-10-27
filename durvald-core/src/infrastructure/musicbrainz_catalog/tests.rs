use super::*;
use crate::{
    application::music_plugins::{PluginRuntime, RuntimeLimits, context::RequestScope},
    enrichment::transport::tests::{MockTransport, Step, client, response},
    infrastructure::music_plugins::{
        FilePluginStateStore, PlatformPluginCredentials, RemoteRequestScope,
    },
};
use std::sync::Arc;

const FIRST: &str = "11111111-1111-4111-8111-111111111111";
const SECOND: &str = "22222222-2222-4222-8222-222222222222";
struct Harness {
    runtime: PluginRuntime,
    mock: Arc<MockTransport>,
    remote: Arc<RemoteRequestScope>,
    _directory: tempfile::TempDir,
}
impl Harness {
    async fn new(steps: Vec<Step>) -> Self {
        let directory = tempfile::tempdir().unwrap();
        let remote = Arc::new(RemoteRequestScope::new(
            directory.path().join("http.sqlite"),
        ));
        let runtime = PluginRuntime::new(
            Arc::new(FilePluginStateStore::new(
                directory.path().join("plugins.json"),
            )),
            Arc::new(PlatformPluginCredentials::new(
                directory.path().join("credentials"),
                "DurvaldCatalogTests".into(),
            )),
            remote.clone(),
            RuntimeLimits::default(),
        )
        .await
        .unwrap();
        let (http, mock) = client(steps);
        runtime
            .register_builtin_with_default(Arc::new(MusicBrainzCatalog::with_http(http)), true)
            .await
            .unwrap();
        Self {
            runtime,
            mock,
            remote,
            _directory: directory,
        }
    }
    async fn search(
        &self,
        request: CatalogSearchRequest,
    ) -> Result<CatalogSearchPage, PluginError> {
        let scope = RequestScope::default();
        self.runtime
            .search(
                &ProviderId::new("musicbrainz").unwrap(),
                scope.begin(),
                request,
            )
            .await
    }
}
fn query(filter: SearchEntityFilter) -> CatalogSearchRequest {
    CatalogSearchRequest::new("Same Name", SearchScope::Explore, filter, 2, None).unwrap()
}
fn ok(body: &str) -> Step {
    response(200, &[], &[body], None)
}
fn artists() -> String {
    format!(
        r#"{{"count":3,"offset":0,"artists":[{{"id":"{FIRST}","name":"Same Name","disambiguation":"Brazil"}},{{"id":"{SECOND}","name":"Same Name","disambiguation":"Portugal"}}]}}"#
    )
}
#[tokio::test]
async fn homonyms_keep_identity_and_cache_is_normalized_and_available_during_cooldown() {
    let h = Harness::new(vec![ok(&artists())]).await;
    let page = h.search(query(SearchEntityFilter::Artists)).await.unwrap();
    assert_eq!(page.items.len(), 2);
    assert_ne!(page.items[0].identity, page.items[1].identity);
    assert_eq!(page.items[0].version_label.as_deref(), Some("Brazil"));
    assert!(page.next_cursor.is_some());
    assert!(!page.from_cache);
    h.remote
        .scope(false, h.remote.defer("musicbrainz.org", 60))
        .await
        .unwrap();
    let cached = CatalogSearchRequest::new(
        " SAME   NAME ",
        SearchScope::Explore,
        SearchEntityFilter::Artists,
        2,
        None,
    )
    .unwrap()
    .cached_only(true);
    let hit = h.search(cached).await.unwrap();
    assert!(hit.from_cache);
    assert_eq!(hit.items, page.items);
    let miss = query(SearchEntityFilter::Tracks).cached_only(true);
    assert!(h.search(miss).await.unwrap().items.is_empty());
    let other_language = query(SearchEntityFilter::Artists)
        .with_language("pt-BR")
        .unwrap()
        .cached_only(true);
    assert!(!h.search(other_language).await.unwrap().from_cache);
    assert_eq!(h.mock.calls(), 1);
}
#[tokio::test]
async fn all_searches_only_three_indexes_without_candidate_enrichment() {
    let group = format!(
        r#"{{"count":1,"offset":0,"release-groups":[{{"id":"{FIRST}","title":"Album","first-release-date":"2020","artist-credit":[{{"name":"Artist"}}]}}]}}"#
    );
    let recording = format!(
        r#"{{"count":1,"offset":0,"recordings":[{{"id":"{SECOND}","title":"Song","length":123000}}]}}"#
    );
    let h = Harness::new(vec![ok(&artists()), ok(&group), ok(&recording)]).await;
    let page = h.search(query(SearchEntityFilter::All)).await.unwrap();
    assert_eq!(page.items.len(), 4);
    assert_eq!(page.items[3].duration_seconds, Some(123));
    assert_eq!(h.mock.calls(), 3);
    let urls = h.mock.urls();
    assert!(urls[0].contains("/artist/?"));
    assert!(urls[1].contains("/release-group/?"));
    assert!(urls[2].contains("/recording/?"));
    assert!(urls.iter().all(|url| !url.contains("inc=")));
    let cursor = page.next_cursor.unwrap();
    let offsets = SearchCursor::read(
        &CatalogSearchRequest::new(
            "Same Name",
            SearchScope::Explore,
            SearchEntityFilter::All,
            2,
            Some(cursor),
        )
        .unwrap(),
        "musicbrainz",
        3,
    )
    .unwrap();
    assert_eq!(offsets, vec![Some(2), None, None]);
}
#[tokio::test]
async fn paging_binds_cursor_to_query_filter_language_and_provider() {
    let tail = r#"{"count":3,"offset":2,"artists":[{"id":"33333333-3333-4333-8333-333333333333","name":"Last"}]}"#.to_string();
    let h = Harness::new(vec![ok(&artists()), ok(&tail)]).await;
    let page = h.search(query(SearchEntityFilter::Artists)).await.unwrap();
    let cursor = page.next_cursor.unwrap();
    for (text, filter, lang) in [
        ("Other", SearchEntityFilter::Artists, "und"),
        ("Same Name", SearchEntityFilter::Tracks, "und"),
        ("Same Name", SearchEntityFilter::Artists, "pt"),
    ] {
        let request =
            CatalogSearchRequest::new(text, SearchScope::Explore, filter, 2, Some(cursor.clone()))
                .unwrap()
                .with_language(lang)
                .unwrap();
        assert!(h.search(request).await.is_err());
    }
    assert_eq!(h.mock.calls(), 1);
    let request = CatalogSearchRequest::new(
        "Same Name",
        SearchScope::Explore,
        SearchEntityFilter::Artists,
        2,
        Some(cursor),
    )
    .unwrap();
    let page = h.search(request).await.unwrap();
    assert_eq!(page.items.len(), 1);
    assert!(page.next_cursor.is_none());
    assert!(h.mock.urls()[1].contains("offset=2"));
}
#[tokio::test]
async fn recognized_url_uses_one_lookup_and_foreign_urls_never_reach_transport() {
    let body = format!(r#"{{"id":"{FIRST}","name":"Direct artist"}}"#);
    let h = Harness::new(vec![ok(&body)]).await;
    for url in [
        "https://evil.example/artist/id",
        "https://musicbrainz.org/artist/bad",
        "https://user@musicbrainz.org/artist/id",
    ] {
        let request =
            CatalogSearchRequest::new(url, SearchScope::Explore, SearchEntityFilter::All, 2, None)
                .unwrap();
        assert!(h.search(request).await.is_err());
    }
    assert_eq!(h.mock.calls(), 0);
    let request = CatalogSearchRequest::new(
        &format!("https://musicbrainz.org/artist/{FIRST}"),
        SearchScope::Explore,
        SearchEntityFilter::All,
        2,
        None,
    )
    .unwrap();
    assert_eq!(
        h.search(request).await.unwrap().items[0].title,
        "Direct artist"
    );
    assert_eq!(h.mock.calls(), 1);
    assert!(!h.mock.urls()[0].contains("inc="));
}
#[tokio::test]
async fn cancelled_request_does_not_publish_delayed_result_and_other_scope_remains_valid() {
    let mut delayed = ok(&artists());
    delayed.delay = Duration::from_millis(200);
    let h = Harness::new(vec![delayed, ok(&artists())]).await;
    let scope = RequestScope::default();
    let ticket = scope.begin();
    let cancellation = ticket.clone();
    let id = ProviderId::new("musicbrainz").unwrap();
    let operation = h
        .runtime
        .search(&id, ticket, query(SearchEntityFilter::Artists));
    let cancel = async {
        while h.mock.calls() == 0 {
            tokio::task::yield_now().await;
        }
        cancellation.cancel();
    };
    let (result, _) = tokio::join!(operation, cancel);
    assert!(matches!(result, Err(PluginError::Cancelled)));
    assert!(h.search(query(SearchEntityFilter::Artists)).await.is_ok());
}

#[tokio::test]
async fn rate_limit_exposes_retry_delay_without_repeated_requests() {
    let h = Harness::new(vec![response(429, &[("retry-after", "120")], &[], None)]).await;
    let request = query(SearchEntityFilter::Artists);
    let result = h.search(request.clone()).await;
    assert!(matches!(
        result,
        Err(PluginError::Adapter(IntegrationError::RateLimited {
            retry_after_seconds: Some(120)
        }))
    ));
    assert!(matches!(
        h.search(request).await,
        Err(PluginError::Adapter(IntegrationError::RateLimited { .. }))
    ));
    assert!(
        h.search(query(SearchEntityFilter::Artists).cached_only(true))
            .await
            .unwrap()
            .items
            .is_empty()
    );
    assert_eq!(h.mock.calls(), 1);
}
