#![cfg(feature = "test-support")]
mod common;
use common::TestCore;
use durvald_core::*;
use std::{
    error::Error,
    sync::{Arc, Mutex},
    time::Duration,
};
type Result<T = ()> = std::result::Result<T, Box<dyn Error + Send + Sync>>;
#[derive(Clone, Default)]
struct Host(Arc<Mutex<Vec<EmbeddedPlaybackCommand>>>);
impl EmbeddedPlaybackHost for Host {
    fn execute(&self, c: EmbeddedPlaybackCommand) -> bool {
        self.0.lock().unwrap().push(c);
        true
    }
}
fn entry(provider: &str, id: &str, url: &str, kind: CatalogItemKind) -> CatalogEntry {
    CatalogEntry {
        reference: CatalogReference {
            provider: provider.into(),
            kind,
            id: id.into(),
        },
        title: "Service fixture".into(),
        artist_credit: Some("Uploader".into()),
        version_label: None,
        duration_seconds: Some(2),
        canonical_url: Some(url.into()),
    }
}
#[tokio::test]
async fn youtube_requires_a_recent_finite_policy_and_its_own_flag_and_excludes_live_metadata()
-> Result {
    let app = TestCore::open().await?;
    let track = app
        .core()
        .save_remote_track(entry(
            "youtube",
            "abcdefghijk",
            "https://www.youtube.com/watch?v=abcdefghijk",
            CatalogItemKind::Video,
        ))
        .await?;
    let host = Host::default();
    app.core()
        .set_embedded_playback_host(Box::new(host.clone()))
        .await?;
    assert!(!app.core().youtube_playback_enabled().await);
    assert!(app.core().play(track.id).await.is_err());
    app.core().set_youtube_playback_enabled(true).await?;
    assert!(app.core().play(track.id).await.is_err());
    let conn = rusqlite::Connection::open(app.files().core_config().database_path)?;
    conn.execute("INSERT INTO service_media_policy(provider,external_id,preview_only,finite_video,verified_at) VALUES('youtube','abcdefghijk',0,1,?1)",[chrono::Utc::now().timestamp()])?;
    app.core().play(track.id).await?;
    assert_eq!(
        app.core().embedded_playback().await.unwrap().canonical_url,
        "https://www.youtube.com/watch?v=abcdefghijk"
    );
    app.core().set_soundcloud_playback_enabled(false).await?;
    assert!(app.core().embedded_playback().await.is_some());
    app.core().set_youtube_playback_enabled(false).await?;
    assert!(app.core().embedded_playback().await.is_none());
    app.core().set_youtube_playback_enabled(true).await?;
    conn.execute("UPDATE service_media_policy SET finite_video=0", [])?;
    assert!(app.core().play(track.id).await.is_err());
    conn.execute(
        "UPDATE service_media_policy SET finite_video=1,verified_at=0",
        [],
    )?;
    assert!(app.core().play(track.id).await.is_err());
    assert!(
        app.core()
            .playback_history_page(10, 0)
            .await?
            .items
            .is_empty()
    );
    Ok(())
}
#[tokio::test]
async fn known_soundcloud_previews_never_record_a_complete_play() -> Result {
    check_preview_history(false).await
}
#[tokio::test]
async fn retry_rechecks_a_soundcloud_preview_observed_after_the_original_attempt() -> Result {
    check_preview_history(true).await
}
async fn check_preview_history(retry: bool) -> Result {
    let app = TestCore::open().await?;
    let track = app
        .core()
        .save_remote_track(entry(
            "soundcloud",
            "artist/preview",
            "https://soundcloud.com/artist/preview",
            CatalogItemKind::AudioTrack,
        ))
        .await?;
    let conn = rusqlite::Connection::open(app.files().core_config().database_path)?;
    if !retry {
        conn.execute("INSERT INTO service_media_policy(provider,external_id,preview_only,finite_video,verified_at) VALUES('soundcloud','artist/preview',1,0,?1)",[chrono::Utc::now().timestamp()])?;
    }
    app.core()
        .set_embedded_playback_host(Box::new(Host::default()))
        .await?;
    app.core().play(track.id).await?;
    if retry {
        let original = app.core().embedded_playback().await.unwrap().generation;
        app.core()
            .report_embedded_playback_event(EmbeddedPlaybackEvent {
                generation: original.clone(),
                sequence: 1,
                kind: EmbeddedEventKind::Failed,
                position_seconds: 0.0,
                duration_seconds: None,
            })
            .await?;
        conn.execute("INSERT INTO service_media_policy(provider,external_id,preview_only,finite_video,verified_at) VALUES('soundcloud','artist/preview',1,0,?1)",[chrono::Utc::now().timestamp()])?;
        app.core().resume().await?;
        assert_ne!(
            original,
            app.core().embedded_playback().await.unwrap().generation
        );
    }
    let generation = app.core().embedded_playback().await.unwrap().generation;
    for (sequence, kind, position) in [
        (1, EmbeddedEventKind::Ready, 0.0),
        (2, EmbeddedEventKind::Playing, 0.0),
    ] {
        app.core()
            .report_embedded_playback_event(EmbeddedPlaybackEvent {
                generation: generation.clone(),
                sequence,
                kind,
                position_seconds: position,
                duration_seconds: Some(2.0),
            })
            .await?;
    }
    tokio::time::sleep(Duration::from_millis(1100)).await;
    for (sequence, kind, position) in [
        (3, EmbeddedEventKind::Progress, 1.1),
        (4, EmbeddedEventKind::Ended, 2.0),
    ] {
        app.core()
            .report_embedded_playback_event(EmbeddedPlaybackEvent {
                generation: generation.clone(),
                sequence,
                kind,
                position_seconds: position,
                duration_seconds: Some(2.0),
            })
            .await?;
    }
    assert!(
        app.core()
            .playback_history_page(10, 0)
            .await?
            .items
            .is_empty()
    );
    let updated = app.core().track_info(track.id).await?;
    assert_eq!(updated.track.play_count, 0);
    Ok(())
}
