#![cfg(feature = "test-support")]
mod common;
use common::TestCore;
use durvald_core::{
    CatalogFailure, CatalogFilter, CatalogItemKind, CatalogProvider, CatalogQuery, CatalogScope,
};

fn query(generation: u64) -> CatalogQuery {
    CatalogQuery {
        query: "Song".into(),
        scope: CatalogScope::Explore,
        filter: CatalogFilter::Tracks,
        language: "pt-BR".into(),
        page_size: 1,
        cursor: None,
        generation,
        cache_only: false,
    }
}
#[tokio::test]
async fn local_paging_filters_and_read_only_search_work_without_remote_configuration() {
    let core = TestCore::open().await.unwrap();
    for file in [
        "Artist/Album/Song One.wav",
        "Artist/Album/Song Two.wav",
        "Artist/Album/Song Three.wav",
    ] {
        core.files().write_silent_wav(file).unwrap();
    }
    core.core()
        .scan_library(vec![
            core.files().library_dir().to_string_lossy().into_owned(),
        ])
        .await
        .unwrap();
    let before = core.all_tracks_via_pages().await.unwrap();
    let session = core.core().catalog_search_session();
    let mut request = query(1);
    let mut ids = vec![];
    loop {
        let page = session
            .search_page(CatalogProvider::Library, request.clone())
            .await
            .unwrap();
        assert!(page.failure.is_none());
        assert_eq!(page.items.len(), 1);
        assert_eq!(page.items[0].kind, CatalogItemKind::Track);
        assert!(page.items[0].local_id.is_some());
        ids.push(page.items[0].id.clone());
        let Some(cursor) = page.next_cursor else {
            break;
        };
        request.cursor = Some(cursor);
    }
    ids.sort();
    ids.dedup();
    assert_eq!(ids.len(), 3);
    let mut cached = query(1);
    cached.cache_only = true;
    let page = session
        .search_page(CatalogProvider::MusicBrainz, cached)
        .await
        .unwrap();
    assert!(page.items.is_empty());
    assert!(!page.from_cache);
    assert!(page.failure.is_none());
    assert_eq!(core.all_tracks_via_pages().await.unwrap(), before);
}
#[tokio::test]
async fn stale_generations_cancellation_and_sessions_are_independent() {
    let core = TestCore::open().await.unwrap();
    let first = core.core().catalog_search_session();
    let second = core.core().catalog_search_session();
    let local = CatalogProvider::Library;
    assert!(
        first
            .search_page(local, query(2))
            .await
            .unwrap()
            .failure
            .is_none()
    );
    assert_eq!(
        first.search_page(local, query(1)).await.unwrap().failure,
        Some(CatalogFailure::Cancelled)
    );
    let mut changed = query(2);
    changed.query = "Another".into();
    assert!(first.search_page(local, changed).await.is_err());
    first.cancel(2).await;
    assert_eq!(
        first.search_page(local, query(2)).await.unwrap().failure,
        Some(CatalogFailure::Cancelled)
    );
    assert!(
        second
            .search_page(local, query(1))
            .await
            .unwrap()
            .failure
            .is_none()
    );
    first.close().await;
    assert_eq!(
        first.search_page(local, query(3)).await.unwrap().failure,
        Some(CatalogFailure::Cancelled)
    );
}
#[tokio::test]
async fn provider_disable_survives_restart_and_never_blocks_local_search() {
    let core = TestCore::open().await.unwrap();
    assert!(
        !core
            .core()
            .set_catalog_provider_enabled(false)
            .await
            .unwrap()
    );
    let core = core.restart().await.unwrap();
    let session = core.core().catalog_search_session();
    let mut request = query(1);
    request.cache_only = true;
    assert_eq!(
        session
            .search_page(CatalogProvider::MusicBrainz, request)
            .await
            .unwrap()
            .failure,
        Some(CatalogFailure::Disabled)
    );
    assert!(
        session
            .search_page(CatalogProvider::Library, query(1))
            .await
            .unwrap()
            .failure
            .is_none()
    );
    assert!(
        core.core()
            .set_catalog_provider_enabled(true)
            .await
            .unwrap()
    );
}
