#![cfg(feature = "test-support")]
mod common;

use common::{TestCore, TestFs};
use durvald_core::{
    CoreError, RatingGranularity, RatingRounding, SmartPlaylistDefinition, SmartPlaylistRule,
};
use rusqlite::Connection;
use std::error::Error;
type TestResult = Result<(), Box<dyn Error + Send + Sync>>;

#[tokio::test]
async fn legacy_ratings_migrate_through_normal_startup_and_keep_playlist_links_after_restart()
-> TestResult {
    let files = TestFs::new()?;
    {
        let conn = Connection::open(files.database_path())?;
        conn.execute_batch(include_str!("fixtures/legacy-rating-schema.sql"))?;
    }
    let fixture = TestCore::open_with_files(files).await?;
    let core = fixture.core();
    assert_eq!(
        core.rating_preferences().await?.granularity,
        RatingGranularity::HalfStars
    );
    let mut tracks = fixture.all_tracks_via_pages().await?;
    tracks.sort_by_key(|track| track.id);
    assert_eq!(
        tracks
            .iter()
            .map(|track| track.rating_half_steps)
            .collect::<Vec<_>>(),
        vec![None, Some(0), Some(6), Some(10)]
    );
    assert!(tracks[2].is_favorite);
    assert_eq!(tracks[2].play_count, 19);
    assert_eq!(core.release(1).await?.rating_half_steps, Some(8));
    assert_eq!(
        core.playlist_tracks(7)
            .await?
            .iter()
            .map(|track| track.id)
            .collect::<Vec<_>>(),
        vec![3, 1]
    );
    // The old wrapper still means whole stars; the exact API accepts fractions.
    core.set_track_rating(3, Some(4)).await?;
    assert_eq!(
        core.tracks_by_ids(vec![3]).await?[0].rating_half_steps,
        Some(8)
    );
    core.set_track_rating_half_steps(3, Some(7)).await?;
    let fixture = fixture.restart().await?;
    assert_eq!(
        fixture.core().tracks_by_ids(vec![3]).await?[0].rating_half_steps,
        Some(7),
        "A second startup must not multiply migrated values again"
    );
    assert_eq!(
        fixture
            .core()
            .playlist_tracks(7)
            .await?
            .iter()
            .map(|track| track.id)
            .collect::<Vec<_>>(),
        vec![3, 1]
    );
    let conn = Connection::open(fixture.files().database_path())?;
    let violations: u64 =
        conn.query_row("SELECT COUNT(*) FROM pragma_foreign_key_check", [], |row| {
            row.get(0)
        })?;
    assert_eq!(violations, 0);
    Ok(())
}

#[tokio::test]
async fn conversion_preserves_nullable_rules_and_requires_confirmation_after_preview_race()
-> TestResult {
    let files = TestFs::new()?;
    {
        let conn = Connection::open(files.database_path())?;
        conn.execute_batch(include_str!("fixtures/legacy-rating-schema.sql"))?;
    }
    let fixture = TestCore::open_with_files(files).await?;
    let core = fixture.core();
    let unrated = core
        .create_smart_playlist(
            "Unrated".into(),
            String::new(),
            SmartPlaylistDefinition {
                match_all: true,
                rules: vec![SmartPlaylistRule {
                    field: "rating".into(),
                    comparison: "is_empty".into(),
                    value: String::new(),
                }],
                limit: None,
                sort_by: "rating".into(),
                descending: false,
            },
        )
        .await?;
    assert_eq!(core.rating_conversion_preview().await?.tracks, 0);
    // A half-star edit arriving after the settings preview still requires a choice.
    core.set_track_rating_half_steps(2, Some(1)).await?;
    let error = core
        .update_rating_preferences(RatingGranularity::WholeStars, None)
        .await
        .unwrap_err();
    assert!(matches!(error, CoreError::InvalidInput { .. }));
    assert_eq!(
        core.rating_preferences().await?.granularity,
        RatingGranularity::HalfStars
    );
    core.update_rating_preferences(RatingGranularity::WholeStars, Some(RatingRounding::Down))
        .await?;
    assert_eq!(
        core.tracks_by_ids(vec![2]).await?[0].rating_half_steps,
        Some(0)
    );
    assert_eq!(
        core.playlist_tracks(unrated.id)
            .await?
            .iter()
            .map(|track| track.id)
            .collect::<Vec<_>>(),
        vec![1]
    );
    let fixture = fixture.restart().await?;
    assert_eq!(
        fixture.core().rating_preferences().await?.granularity,
        RatingGranularity::WholeStars
    );
    assert!(matches!(
        fixture.core().set_track_rating_half_steps(3, Some(7)).await,
        Err(CoreError::InvalidInput { .. })
    ));
    Ok(())
}
