#![cfg(feature = "test-support")]
mod common;
use common::TestCore;
use durvald_core::{CatalogEntry, CatalogItemKind, CatalogReference, CoreError};
use std::error::Error;
type Result<T = ()> = std::result::Result<T, Box<dyn Error + Send + Sync>>;
fn remote(kind: CatalogItemKind) -> CatalogEntry {
    CatalogEntry {
        reference: CatalogReference {
            provider: "test".into(),
            kind,
            id: "opaque-audio-1".into(),
        },
        title: "Remote-only recording".into(),
        artist_credit: Some("Remote artist".into()),
        version_label: None,
        duration_seconds: Some(180),
        canonical_url: Some("https://example.org/recording/1".into()),
    }
}
#[tokio::test]
async fn remote_track_survives_scan_repair_playlist_duplicates_metadata_edits_and_restart() -> Result
{
    let app = TestCore::open().await?;
    let entry = remote(CatalogItemKind::Recording);
    let track = app.core().save_remote_track(entry.clone()).await?;
    assert!(track.file_path.is_none());
    assert_eq!(app.core().save_remote_track(entry).await?.id, track.id);
    let mut another = remote(CatalogItemKind::Recording);
    another.reference.id = "different-recording-with-same-artist-credit".into();
    let another = app.core().save_remote_track(another).await?;
    assert_ne!(another.artist_id, track.artist_id);
    let playlist = app
        .core()
        .create_playlist("Mixed".into(), String::new(), None)
        .await?;
    for position in 0..2 {
        app.core()
            .add_track_to_playlist(playlist.id, track.id, position)
            .await?;
    }
    app.core()
        .set_track_rating_half_steps(track.id, Some(7))
        .await?;
    app.core().set_track_favorite(track.id, true).await?;
    let before = app.core().track_info(track.id).await?;
    let mut edit = before.metadata.clone();
    edit.title = "Edited remotely".into();
    let edited = app
        .core()
        .save_track_metadata(track.id, edit, false)
        .await?;
    assert_eq!(edited.track.title, "Edited remotely");
    assert!(
        app.core()
            .save_track_metadata(track.id, before.metadata.clone(), true)
            .await
            .is_err()
    );
    app.core().undo_track_metadata(track.id).await?;
    app.files().write_silent_wav("survivor.wav")?;
    let root = app.files().library_dir().to_string_lossy().into_owned();
    app.core().scan_library(vec![root.clone()]).await?;
    app.core().scan_library(vec![root]).await?;
    let repairs = app.core().analyze_library_repairs().await?;
    assert!(!repairs.broken_files.iter().any(|t| t.id == track.id));
    let app = app.restart().await?;
    let restored = app.core().track(track.id).await?;
    assert!(restored.file_path.is_none());
    assert_eq!(restored.rating_half_steps, Some(7));
    assert!(restored.is_favorite);
    assert_eq!(
        app.core()
            .playlist_tracks(playlist.id)
            .await?
            .iter()
            .map(|t| t.id)
            .collect::<Vec<_>>(),
        vec![track.id, track.id]
    );
    let c = rusqlite::Connection::open(app.files().database_path())?;
    assert_eq!(
        c.query_row(
            "SELECT COUNT(*) FROM track_sources WHERE song_id=?1",
            [track.id],
            |r| r.get::<_, i64>(0)
        )?,
        0
    );
    assert!(!c.prepare("PRAGMA foreign_key_check")?.exists([])?);
    Ok(())
}
#[tokio::test]
async fn queue_resolves_only_selected_identity_and_keeps_remote_and_duplicate_occurrences() -> Result
{
    let app = TestCore::open().await?;
    let remote = app
        .core()
        .save_remote_track(remote(CatalogItemKind::AudioTrack))
        .await?;
    app.core()
        .add_to_queue_with_context(remote.id, "playlist:7#0".into())
        .await?;
    app.files().write_silent_wav("local.wav")?;
    app.core()
        .scan_library(vec![
            app.files().library_dir().to_string_lossy().into_owned(),
        ])
        .await?;
    let local = app
        .all_tracks_via_pages()
        .await?
        .into_iter()
        .find(|t| t.file_path.is_some())
        .unwrap();
    app.core()
        .add_to_queue_with_context(local.id, "playlist:7#1".into())
        .await?;
    app.core()
        .add_to_queue_with_context(local.id, "playlist:7#2".into())
        .await?;
    let new = app.files().library_dir().join("relinked.wav");
    std::fs::copy(local.file_path.as_ref().unwrap(), &new)?;
    let c = rusqlite::Connection::open(app.files().database_path())?;
    c.create_scalar_function(
        "durvald_local_path_key",
        1,
        rusqlite::functions::FunctionFlags::SQLITE_UTF8
            | rusqlite::functions::FunctionFlags::SQLITE_DETERMINISTIC,
        |ctx| ctx.get::<String>(0),
    )?;
    c.execute("UPDATE track_sources SET local_path=?2,local_path_key=?2 WHERE song_id=?1 AND provider='local'",rusqlite::params![local.id,new.to_string_lossy()])?;
    std::fs::remove_file(local.file_path.unwrap())?;
    let queue = app.core().queue().await?;
    assert_eq!(
        queue.iter().map(|q| q.track_id).collect::<Vec<_>>(),
        vec![remote.id, local.id, local.id]
    );
    assert_ne!(queue[1].occurrence_id, queue[2].occurrence_id);
    app.core().move_queue_item(2, 1).await?;
    assert_eq!(
        app.core().queue().await?[1].occurrence_id,
        queue[2].occurrence_id
    );
    app.core().move_queue_item(1, 2).await?;
    assert!(matches!(
        app.core().play_queue_item(0).await,
        Err(CoreError::Playback { .. })
    ));
    assert_eq!(app.core().queue().await?, queue);
    let app = app.restart().await?;
    assert_eq!(app.core().queue().await?, queue);
    let playing = app.core().play_queue_item(1).await?;
    assert_eq!(playing.current_track.as_ref().map(|t| t.id), Some(local.id));
    assert_eq!(playing.source_context, "playlist:7#1");
    let next = app.core().play_queue_item(1).await?;
    assert_eq!(next.source_context, "playlist:7#2");
    Ok(())
}
#[tokio::test]
async fn scanner_removes_only_missing_local_origin_when_remote_origin_remains() -> Result {
    let app = TestCore::open().await?;
    let lost = app.files().write_silent_wav("gone.wav")?;
    app.files().write_silent_wav("survivor.wav")?;
    let root = app.files().library_dir().to_string_lossy().into_owned();
    app.core().scan_library(vec![root.clone()]).await?;
    let local = app
        .all_tracks_via_pages()
        .await?
        .into_iter()
        .find(|t| t.file_path.as_deref() == std::fs::canonicalize(&lost).unwrap().to_str())
        .unwrap();
    app.core().set_track_favorite(local.id, true).await?;
    let c = rusqlite::Connection::open(app.files().database_path())?;
    c.create_scalar_function(
        "durvald_local_path_key",
        1,
        rusqlite::functions::FunctionFlags::SQLITE_UTF8
            | rusqlite::functions::FunctionFlags::SQLITE_DETERMINISTIC,
        |ctx| ctx.get::<String>(0),
    )?;
    c.execute("INSERT INTO track_sources(song_id,provider,external_id,canonical_url,association_origin) VALUES(?1,'test','1','https://example.org/audio/1','test')",[local.id])?;
    std::fs::remove_file(lost)?;
    app.core().scan_library(vec![root]).await?;
    let track = app.core().track(local.id).await?;
    assert!(track.file_path.is_none());
    assert!(track.is_favorite);
    assert_eq!(
        c.query_row(
            "SELECT COUNT(*) FROM missing_tracks WHERE original_song_id=?1",
            [local.id],
            |r| r.get::<_, i64>(0)
        )?,
        0
    );
    let app = app.restart().await?;
    assert!(app.core().track(local.id).await?.file_path.is_none());
    Ok(())
}

#[tokio::test]
async fn legacy_queue_occurrence_upgrade_is_durable_without_playback_commands() -> Result {
    let app = TestCore::open().await?;
    let remote = app
        .core()
        .save_remote_track(remote(CatalogItemKind::Recording))
        .await?;
    app.core()
        .add_to_queue_with_context(remote.id, "playlist:7#0".into())
        .await?;
    let c = rusqlite::Connection::open(app.files().database_path())?;
    c.execute(
        "UPDATE last_session SET source_context=?1",
        [r#"{"version":1,"contexts":["playlist:7#0"]}"#],
    )?;
    let app = app.restart().await?;
    let first = app.core().queue().await?;
    assert!(!first[0].occurrence_id.is_empty());
    let app = app.restart().await?;
    assert_eq!(app.core().queue().await?, first);
    Ok(())
}
