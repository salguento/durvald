//! Internal SQLite fixtures; application tests consume ready-to-use adapters.
use crate::infrastructure::sqlite::playlists::SqlitePlaylistRepository;
use std::sync::Arc;
pub(crate) fn replay_repositories(
    now: i64,
) -> (SqlitePlaylistRepository, SqlitePlaylistRepository) {
    let manager = r2d2_sqlite::SqliteConnectionManager::memory();
    let pool = Arc::new(r2d2::Pool::builder().max_size(1).build(manager).unwrap());
    {
        let conn = pool.get().unwrap();
        crate::database::operations::create_tables(&conn).unwrap();
        for id in 1..=12 {
            conn.execute("INSERT INTO songs(song_id,title,artist_id,artist_name,release_id,release_title,track_number,disc_number,duration,file_path)
                    VALUES(?1,?2,1,'Artist',1,'Album',1,1,180,?3)", rusqlite::params![id, format!("Track {id}"), format!("/music/{id}.mp3")]).unwrap();
            conn.execute(
                "INSERT INTO play_history(song_id,played_at,play_duration) VALUES(?1,?2,180)",
                rusqlite::params![
                    id,
                    chrono::DateTime::from_timestamp(now - 100, 0)
                        .unwrap()
                        .to_rfc3339()
                ],
            )
            .unwrap();
        }
    }

    (
        SqlitePlaylistRepository::new(pool.clone()),
        SqlitePlaylistRepository::new(pool),
    )
}
