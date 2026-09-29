use std::{collections::BTreeMap, fs::File, io::Read, path::Path};

use rusqlite::{Connection, OptionalExtension, params};
use sha2::{Digest, Sha256};

use crate::api::{
    CoreError, CoreResult, DuplicateTrackGroup, LibraryRepairAnalysis, LibraryRepairSuggestion,
    LibraryRepairTrack,
};

fn storage(error: impl ToString) -> CoreError {
    CoreError::Storage {
        message: error.to_string(),
    }
}

fn content_hash(path: &str) -> CoreResult<(String, u64)> {
    let mut file = File::open(path).map_err(storage)?;
    let size = file.metadata().map_err(storage)?.len();
    let mut digest = Sha256::new();
    let mut buffer = [0_u8; 128 * 1024];
    loop {
        let read = file.read(&mut buffer).map_err(storage)?;
        if read == 0 {
            break;
        }
        digest.update(&buffer[..read]);
    }
    Ok((format!("{:x}", digest.finalize()), size))
}

fn track(row: &rusqlite::Row<'_>, missing: bool) -> rusqlite::Result<LibraryRepairTrack> {
    Ok(LibraryRepairTrack {
        id: row.get(0)?,
        title: row.get(1)?,
        artist: row.get(2)?,
        release: row.get(3)?,
        file_path: row.get(4)?,
        rating: row.get(5)?,
        is_favorite: row.get(6)?,
        is_missing: missing,
    })
}

pub(crate) fn analyze(conn: &Connection) -> CoreResult<LibraryRepairAnalysis> {
    let live: Vec<LibraryRepairTrack> = conn.prepare(
        "SELECT song_id,title,artist_name,release_title,file_path,rating,is_favorite FROM songs ORDER BY song_id"
    ).map_err(storage)?.query_map([], |r| track(r, false)).map_err(storage)?
        .collect::<Result<_, _>>().map_err(storage)?;
    for item in &live {
        if Path::new(&item.file_path).is_file() {
            if let Ok((hash, size)) = content_hash(&item.file_path) {
                conn.execute(
                    "INSERT INTO track_file_identity(song_id,content_hash,file_size) VALUES(?1,?2,?3)
                     ON CONFLICT(song_id) DO UPDATE SET content_hash=excluded.content_hash,
                        file_size=excluded.file_size,hashed_at=CURRENT_TIMESTAMP",
                    params![item.id, hash, size as i64],
                ).map_err(storage)?;
            }
        }
    }
    let mut broken: Vec<LibraryRepairTrack> = live
        .iter()
        .filter(|t| !Path::new(&t.file_path).is_file())
        .cloned()
        .collect();
    let archived: Vec<LibraryRepairTrack> = conn.prepare(
        "SELECT missing_id,title,artist_name,release_title,file_path,rating,is_favorite FROM missing_tracks ORDER BY missing_id"
    ).map_err(storage)?.query_map([], |r| track(r, true)).map_err(storage)?
        .collect::<Result<_, _>>().map_err(storage)?;
    broken.extend(archived.clone());

    let mut suggestions = Vec::new();
    for missing in &archived {
        let identity: (String,String,String,i64,i64,i64,Option<String>) = conn.query_row(
            "SELECT title,artist_name,release_title,track_number,disc_number,duration,content_hash
             FROM missing_tracks WHERE missing_id=?1", [missing.id],
            |r| Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?,r.get(5)?,r.get(6)?))
        ).map_err(storage)?;
        let mut statement = conn.prepare(
            "SELECT s.song_id,i.content_hash FROM songs s LEFT JOIN track_file_identity i USING(song_id)
             WHERE lower(s.title)=lower(?1) AND lower(s.artist_name)=lower(?2)
               AND lower(s.release_title)=lower(?3) AND s.track_number=?4
               AND s.disc_number=?5 AND abs(s.duration-?6)<=2"
        ).map_err(storage)?;
        for candidate in statement
            .query_map(
                params![
                    identity.0, identity.1, identity.2, identity.3, identity.4, identity.5
                ],
                |r| Ok((r.get::<_, i64>(0)?, r.get::<_, Option<String>>(1)?)),
            )
            .map_err(storage)?
        {
            let (candidate_id, hash) = candidate.map_err(storage)?;
            let exact_hash = identity.6.is_some() && identity.6 == hash;
            suggestions.push(LibraryRepairSuggestion {
                missing_id: missing.id,
                candidate_track_id: candidate_id,
                confidence: if exact_hash { 1.0 } else { 0.85 },
                reason: if exact_hash {
                    "Hash de conteúdo e metadados idênticos".into()
                } else {
                    "Título, artista, álbum, posição e duração coincidem".into()
                },
            });
        }
    }

    let mut hash_groups: BTreeMap<String, Vec<i64>> = BTreeMap::new();
    let mut stmt = conn
        .prepare("SELECT song_id,content_hash FROM track_file_identity ORDER BY song_id")
        .map_err(storage)?;
    for row in stmt
        .query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)))
        .map_err(storage)?
    {
        let (id, hash) = row.map_err(storage)?;
        hash_groups.entry(hash).or_default().push(id);
    }
    let mut duplicate_groups = Vec::new();
    for ids in hash_groups.values().filter(|ids| ids.len() > 1) {
        let tracks = ids
            .iter()
            .filter_map(|id| live.iter().find(|t| t.id == *id).cloned())
            .collect();
        duplicate_groups.push(DuplicateTrackGroup {
            tracks,
            reason: "Hash de conteúdo idêntico".into(),
        });
    }
    Ok(LibraryRepairAnalysis {
        broken_files: broken,
        relink_suggestions: suggestions,
        duplicate_groups,
    })
}

pub(crate) fn merge(
    conn: &Connection,
    source_id: i64,
    target_id: i64,
    source_is_missing: bool,
) -> CoreResult<()> {
    if source_id == target_id && !source_is_missing {
        return Err(CoreError::InvalidInput {
            message: "Source and target must differ".into(),
        });
    }
    let tx = conn.unchecked_transaction().map_err(storage)?;
    let target_exists: bool = tx
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM songs WHERE song_id=?1)",
            [target_id],
            |r| r.get(0),
        )
        .map_err(storage)?;
    if !target_exists {
        return Err(CoreError::NotFound {
            message: "Target track not found".into(),
        });
    }
    if source_is_missing {
        let preferences: Option<(i64,Option<String>,Option<u8>,bool,bool,bool)> = tx.query_row(
            "SELECT play_count,last_played,rating,is_favorite,is_hidden,suggest_less FROM missing_tracks WHERE missing_id=?1",
            [source_id], |r| Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?,r.get(5)?))
        ).optional().map_err(storage)?;
        let Some(p) = preferences else {
            return Err(CoreError::NotFound {
                message: "Missing track record not found".into(),
            });
        };
        tx.execute(
            "UPDATE songs SET play_count=play_count+?2,
            last_played=CASE WHEN last_played IS NULL THEN ?3 WHEN ?3 IS NULL THEN last_played ELSE MAX(last_played,?3) END,
            rating=CASE WHEN rating IS NULL THEN ?4 WHEN ?4 IS NULL THEN rating ELSE MAX(rating,?4) END,is_favorite=is_favorite OR ?5,
            is_hidden=is_hidden OR ?6,suggest_less=suggest_less OR ?7 WHERE song_id=?1",
            params![target_id, p.0, p.1, p.2, p.3, p.4, p.5],
        )
        .map_err(storage)?;
        tx.execute("INSERT OR IGNORE INTO playlist_songs(playlist_id,song_id,position,added_at)
            SELECT playlist_id,?2,position,added_at FROM missing_playlist_songs WHERE missing_id=?1",
            params![source_id,target_id]).map_err(storage)?;
        tx.execute(
            "INSERT INTO play_history(song_id,played_at,play_duration)
            SELECT ?2,played_at,play_duration FROM missing_play_history WHERE missing_id=?1",
            params![source_id, target_id],
        )
        .map_err(storage)?;
        tx.execute(
            "DELETE FROM missing_tracks WHERE missing_id=?1",
            [source_id],
        )
        .map_err(storage)?;
    } else {
        tx.execute("UPDATE songs SET play_count=play_count+(SELECT play_count FROM songs WHERE song_id=?2),
            last_played=CASE
                WHEN last_played IS NULL THEN (SELECT last_played FROM songs WHERE song_id=?2)
                WHEN (SELECT last_played FROM songs WHERE song_id=?2) IS NULL THEN last_played
                ELSE MAX(last_played,(SELECT last_played FROM songs WHERE song_id=?2)) END,
            rating=CASE
                WHEN rating IS NULL THEN (SELECT rating FROM songs WHERE song_id=?2)
                WHEN (SELECT rating FROM songs WHERE song_id=?2) IS NULL THEN rating
                ELSE MAX(rating,(SELECT rating FROM songs WHERE song_id=?2)) END,
            is_favorite=is_favorite OR (SELECT is_favorite FROM songs WHERE song_id=?2),
            is_hidden=is_hidden OR (SELECT is_hidden FROM songs WHERE song_id=?2),
            suggest_less=suggest_less OR (SELECT suggest_less FROM songs WHERE song_id=?2) WHERE song_id=?1",
            params![target_id,source_id]).map_err(storage)?;
        tx.execute(
            "INSERT OR IGNORE INTO playlist_songs(playlist_id,song_id,position,added_at)
            SELECT playlist_id,?2,position,added_at FROM playlist_songs WHERE song_id=?1",
            params![source_id, target_id],
        )
        .map_err(storage)?;
        tx.execute(
            "UPDATE play_history SET song_id=?2 WHERE song_id=?1",
            params![source_id, target_id],
        )
        .map_err(storage)?;
        tx.execute("DELETE FROM songs WHERE song_id=?1", [source_id])
            .map_err(storage)?;
    }
    tx.commit().map_err(storage)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn database() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("PRAGMA foreign_keys = ON;").unwrap();
        crate::database::operations::create_tables(&conn).unwrap();
        conn.execute("INSERT INTO playlists(id,name) VALUES(1,'Favoritas')", [])
            .unwrap();
        conn
    }

    fn insert_song(conn: &Connection, id: i64, path: &str, rating: Option<u8>) {
        conn.execute(
            "INSERT INTO songs(song_id,title,artist_id,artist_name,release_id,release_title,
                track_number,disc_number,duration,file_path,play_count,rating)
             VALUES(?1,'Faixa',1,'Artista',1,'Álbum',1,1,180,?2,0,?3)",
            params![id, path, rating],
        )
        .unwrap();
    }

    #[test]
    fn merging_live_duplicates_preserves_library_relationships_and_preferences() {
        let conn = database();
        insert_song(&conn, 1, "/music/target.flac", Some(2));
        insert_song(&conn, 2, "/music/source.flac", Some(5));
        conn.execute(
            "UPDATE songs SET play_count=3,last_played='2025-01-01',is_favorite=1 WHERE song_id=1",
            [],
        )
        .unwrap();
        conn.execute(
            "UPDATE songs SET play_count=4,last_played='2026-01-01',is_hidden=1,suggest_less=1 WHERE song_id=2",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO playlist_songs(playlist_id,song_id,position) VALUES(1,2,3)",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO play_history(song_id,played_at,play_duration) VALUES(2,'2026-01-01',90)",
            [],
        )
        .unwrap();

        merge(&conn, 2, 1, false).unwrap();

        let values: (i64, String, Option<u8>, bool, bool, bool) = conn
            .query_row(
                "SELECT play_count,last_played,rating,is_favorite,is_hidden,suggest_less FROM songs WHERE song_id=1",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?, row.get(5)?)),
            )
            .unwrap();
        assert_eq!(values, (7, "2026-01-01".into(), Some(5), true, true, true));
        assert_eq!(
            conn.query_row("SELECT COUNT(*) FROM songs WHERE song_id=2", [], |row| row
                .get::<_, i64>(
                0
            ))
            .unwrap(),
            0
        );
        assert_eq!(
            conn.query_row("SELECT song_id FROM playlist_songs", [], |row| row
                .get::<_, i64>(0))
                .unwrap(),
            1
        );
        assert_eq!(
            conn.query_row("SELECT song_id FROM play_history", [], |row| row
                .get::<_, i64>(0))
                .unwrap(),
            1
        );
    }

    #[test]
    fn relinking_missing_track_restores_preserved_data_without_inventing_rating() {
        let conn = database();
        insert_song(&conn, 1, "/music/moved.flac", None);
        conn.execute(
            "INSERT INTO missing_tracks(missing_id,original_song_id,title,artist_name,release_title,
                track_number,disc_number,duration,file_path,play_count,last_played,rating,
                is_favorite,is_hidden,suggest_less)
             VALUES(7,9,'Faixa','Artista','Álbum',1,1,180,'/old/place.flac',6,NULL,NULL,1,0,0)",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO missing_playlist_songs(missing_id,playlist_id,position) VALUES(7,1,2)",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO missing_play_history(missing_id,original_history_id,played_at,play_duration)
             VALUES(7,11,'2024-01-01',120)",
            [],
        )
        .unwrap();

        merge(&conn, 7, 1, true).unwrap();

        let values: (i64, Option<String>, Option<u8>, bool) = conn
            .query_row(
                "SELECT play_count,last_played,rating,is_favorite FROM songs WHERE song_id=1",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .unwrap();
        assert_eq!(values, (6, None, None, true));
        assert_eq!(
            conn.query_row("SELECT song_id FROM playlist_songs", [], |row| row
                .get::<_, i64>(0))
                .unwrap(),
            1
        );
        assert_eq!(
            conn.query_row("SELECT song_id FROM play_history", [], |row| row
                .get::<_, i64>(0))
                .unwrap(),
            1
        );
        assert_eq!(
            conn.query_row("SELECT COUNT(*) FROM missing_tracks", [], |row| row
                .get::<_, i64>(0))
                .unwrap(),
            0
        );
    }
}
