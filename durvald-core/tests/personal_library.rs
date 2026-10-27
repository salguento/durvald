#![cfg(feature = "test-support")]

mod common;

use common::TestCore;
use durvald_core::{ArtistNewsQuery, EnrichmentProvider, RecommendationEvent};
use std::error::Error;

async fn scanned_core() -> Result<TestCore, Box<dyn Error + Send + Sync>> {
    let core = TestCore::open().await?;
    core.files().write_silent_wav("Artist/Album/One.wav")?;
    core.core()
        .scan_library(vec![
            core.files().library_dir().to_string_lossy().into_owned(),
        ])
        .await?;
    Ok(core)
}

#[tokio::test]
async fn recommendations_keep_events_and_dismissals_across_named_operations_and_restart()
-> Result<(), Box<dyn Error + Send + Sync>> {
    let core = scanned_core().await?;
    let suggestions = core.core().local_recommendations(10).await?;
    let release = suggestions
        .items
        .first()
        .expect("local release is eligible")
        .release
        .id;
    core.core()
        .record_recommendation_event(release, RecommendationEvent::Shown)
        .await?;
    core.core()
        .record_recommendation_event(release, RecommendationEvent::Opened)
        .await?;
    let metrics = core.core().recommendation_metrics().await?;
    assert_eq!((metrics.shown, metrics.opened), (1, 1));
    core.core().dismiss_local_recommendation(release).await?;
    let core = core.restart().await?;
    assert!(
        core.core()
            .local_recommendations(10)
            .await?
            .items
            .is_empty()
    );
    assert_eq!(core.core().recommendation_metrics().await?, metrics);
    core.core().restore_local_recommendations().await?;
    assert_eq!(
        core.core().local_recommendations(10).await?.items[0]
            .release
            .id,
        release
    );
    Ok(())
}

#[tokio::test]
async fn news_follow_and_provider_clear_preserve_preferences_through_public_facade()
-> Result<(), Box<dyn Error + Send + Sync>> {
    let core = scanned_core().await?;
    let artist = core.all_tracks_via_pages().await?[0].artist_id;
    core.core().import_followed_artists(vec![artist]).await?;
    assert_eq!(core.core().followed_artists().await?.len(), 1);
    core.core().set_artist_followed(artist, false).await?;
    assert!(core.core().followed_artists().await?.is_empty());
    // The one-time legacy import must not resurrect an explicit unfollow.
    core.core().import_followed_artists(vec![artist]).await?;
    assert!(core.core().followed_artists().await?.is_empty());
    core.core().set_artist_followed(artist, true).await?;
    core.core()
        .clear_enrichment_provider_data(EnrichmentProvider::MusicBrainz)
        .await?;
    let core = core.restart().await?;
    let feed = core
        .core()
        .artist_news(ArtistNewsQuery {
            query: String::new(),
            unseen_only: false,
            kind: None,
            sort_by: "date".into(),
            descending: true,
            offset: 0,
            limit: 20,
        })
        .await?;
    assert!(feed.items.is_empty());
    assert_eq!(feed.followed_artists.len(), 1);
    assert_eq!(feed.followed_artists[0].artist.id, artist);
    Ok(())
}
