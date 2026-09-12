use crate::api::*;
use crate::metadata::AudioMetadata;
use rusqlite::{Connection, OptionalExtension, Transaction, TransactionBehavior, params};
use std::collections::BTreeSet;

fn storage(error: impl std::fmt::Display) -> CoreError {
    CoreError::Storage {
        message: format!("Identity storage: {error}"),
    }
}

/// Called inside the scan's transaction. Legacy standalone database utilities
/// may run without the optional enrichment schema.
pub fn replace_tags(conn: &Connection, song_id: i64, song: &AudioMetadata) -> rusqlite::Result<()> {
    if !conn.table_exists(None, "song_musicbrainz_tags")? {
        return Ok(());
    }
    let payload = serde_json::to_string(&song.musicbrainz).expect("serializable tags");
    conn.execute(
        "INSERT INTO song_musicbrainz_tags VALUES (?1, ?2)
        ON CONFLICT(song_id) DO UPDATE SET payload = excluded.payload",
        params![song_id, payload],
    )?;
    let mut desired = BTreeSet::new();
    let album_names: Vec<String> = song.album_artist.iter().cloned().collect();
    for (role, names, ids) in [
        (
            "track_artist",
            &song.track_artists,
            &song.musicbrainz.track_artists,
        ),
        (
            "album_artist",
            &album_names,
            &song.musicbrainz.album_artists,
        ),
    ] {
        // Do not guess a positional correspondence from split display credits.
        let ids: BTreeSet<_> = ids
            .iter()
            .filter_map(|id| crate::enrichment::identity::normalize_mbid(id))
            .collect();
        let uncertain = names.len() != 1 || ids.len() != 1;
        for name in names {
            let artist_id: Option<i64> = conn
                .query_row(
                    "SELECT artist_id FROM artists WHERE name = ?1",
                    [name],
                    |r| r.get(0),
                )
                .optional()?;
            if let Some(artist_id) = artist_id {
                for id in &ids {
                    desired.insert((artist_id, role.to_string(), id.clone(), uncertain));
                }
            }
        }
    }
    let existing: BTreeSet<(i64, String, String, bool)> = conn.prepare(
        "SELECT artist_id, role, musicbrainz_id, uncertain FROM artist_tag_evidence WHERE song_id = ?1")?
        .query_map([song_id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))?
        .collect::<rusqlite::Result<_>>()?;
    for (artist, role, id, _) in existing.difference(&desired) {
        conn.execute("DELETE FROM artist_tag_evidence WHERE song_id = ?1 AND artist_id = ?2 AND role = ?3 AND musicbrainz_id = ?4", params![song_id, artist, role, id])?;
    }
    for (artist, role, id, uncertain) in desired.difference(&existing) {
        conn.execute(
            "INSERT INTO artist_tag_evidence VALUES (?1, ?2, ?3, ?4, ?5)",
            params![song_id, artist, role, id, uncertain],
        )?;
    }
    Ok(())
}

fn ensure(conn: &Connection, artist_id: i64) -> CoreResult<()> {
    if artist_id < 0 {
        return Err(CoreError::InvalidInput {
            message: "Artist ID must be non-negative".into(),
        });
    }
    let exists: bool = conn
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM artists WHERE artist_id = ?1)",
            [artist_id],
            |r| r.get(0),
        )
        .map_err(storage)?;
    if !exists {
        return Err(CoreError::NotFound {
            message: format!("Artist {artist_id} not found"),
        });
    }
    conn.execute(
        "INSERT OR IGNORE INTO artist_enrichment_state(artist_id) VALUES (?1)",
        [artist_id],
    )
    .map_err(storage)?;
    Ok(())
}

fn read_inner(conn: &Connection, artist_id: i64) -> CoreResult<ArtistIdentity> {
    ensure(conn, artist_id)?;
    let (old_status, old_id, generation, confirmed, suppress): (String, Option<String>, u64, Option<String>, bool) = conn.query_row(
        "SELECT identity_status, musicbrainz_id, generation, confirmed_musicbrainz_id, suppress_tags FROM artist_enrichment_state WHERE artist_id = ?1", [artist_id],
        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?))).map_err(storage)?;
    let evidence: Vec<(String, bool)> = conn.prepare("SELECT DISTINCT musicbrainz_id, uncertain FROM artist_tag_evidence WHERE artist_id = ?1").map_err(storage)?
        .query_map([artist_id], |r| Ok((r.get(0)?, r.get(1)?))).map_err(storage)?.collect::<rusqlite::Result<_>>().map_err(storage)?;
    let ids: BTreeSet<String> = evidence.iter().map(|(id, _)| id.clone()).collect();
    let conflict = ids.len() > 1
        || evidence.iter().any(|(_, uncertain)| *uncertain)
        || confirmed
            .as_ref()
            .is_some_and(|manual| ids.iter().any(|id| id != manual));
    let (status, id, origin) = if conflict {
        (ArtistIdentityStatus::Ambiguous, None, None)
    } else if let Some(manual) = &confirmed {
        (
            ArtistIdentityStatus::Resolved,
            Some(manual.clone()),
            Some(ArtistIdentityOrigin::Manual),
        )
    } else if !suppress && ids.len() == 1 {
        (
            ArtistIdentityStatus::Resolved,
            ids.first().cloned(),
            Some(ArtistIdentityOrigin::Tag),
        )
    } else {
        let status = match old_status.as_str() {
            "ambiguous" => ArtistIdentityStatus::Ambiguous,
            "not_found" => ArtistIdentityStatus::NotFound,
            _ => ArtistIdentityStatus::Unresolved,
        };
        (status, None, None)
    };
    let status_text = serde_json::to_value(status)
        .map_err(storage)?
        .as_str()
        .unwrap()
        .to_owned();
    let origin_text = origin.map(|o| match o {
        ArtistIdentityOrigin::Tag => "tag",
        ArtistIdentityOrigin::Manual => "manual",
    });
    let changed = old_status != status_text || old_id != id;
    conn.execute("UPDATE artist_enrichment_state SET identity_status = ?2, musicbrainz_id = ?3, identity_origin = ?4, generation = generation + ?5 WHERE artist_id = ?1",
        params![artist_id, status_text, id, origin_text, i64::from(changed)]).map_err(storage)?;
    Ok(ArtistIdentity {
        artist_id,
        status,
        musicbrainz_id: id,
        generation: generation + u64::from(changed),
        origin,
        confirmed_musicbrainz_id: confirmed,
        conflicting_tags: conflict,
    })
}

pub fn read(conn: &Connection, artist_id: i64) -> CoreResult<ArtistIdentity> {
    let tx = Transaction::new_unchecked(conn, TransactionBehavior::Immediate).map_err(storage)?;
    let result = read_inner(&tx, artist_id)?;
    tx.commit().map_err(storage)?;
    Ok(result)
}

pub fn confirm(
    conn: &Connection,
    artist_id: i64,
    mbid: Option<String>,
) -> CoreResult<ArtistIdentity> {
    let mbid = mbid
        .map(|id| {
            crate::enrichment::identity::normalize_mbid(&id).ok_or_else(|| {
                CoreError::InvalidInput {
                    message: "Invalid MusicBrainz artist ID".into(),
                }
            })
        })
        .transpose()?;
    let tx = Transaction::new_unchecked(conn, TransactionBehavior::Immediate).map_err(storage)?;
    ensure(&tx, artist_id)?;
    tx.execute("UPDATE artist_enrichment_state SET confirmed_musicbrainz_id = ?2, suppress_tags = ?3, identity_status = 'unresolved', musicbrainz_id = NULL, identity_origin = NULL, generation = generation + 1 WHERE artist_id = ?1", params![artist_id, mbid, mbid.is_none()]).map_err(storage)?;
    tx.execute(
        "DELETE FROM artist_identity_candidates WHERE artist_id = ?1",
        [artist_id],
    )
    .map_err(storage)?;
    let result = read_inner(&tx, artist_id)?;
    tx.commit().map_err(storage)?;
    Ok(result)
}

pub fn candidates(conn: &Connection, artist_id: i64) -> CoreResult<ArtistIdentityCandidates> {
    let tx = Transaction::new_unchecked(conn, TransactionBehavior::Immediate).map_err(storage)?;
    let identity = read_inner(&tx, artist_id)?;
    let cached: Option<(String, bool)> = tx.query_row("SELECT payload, truncated FROM artist_identity_candidates WHERE artist_id = ?1 AND generation = ?2", params![artist_id, identity.generation], |r| Ok((r.get(0)?, r.get(1)?))).optional().map_err(storage)?;
    let (candidates, truncated) = match cached {
        Some((payload, truncated)) => (serde_json::from_str(&payload).map_err(storage)?, truncated),
        None => {
            let mut candidates = Vec::new();
            let mut stmt = tx.prepare("SELECT musicbrainz_id, role, MAX(uncertain) FROM artist_tag_evidence WHERE artist_id = ?1 GROUP BY musicbrainz_id, role ORDER BY musicbrainz_id, role").map_err(storage)?;
            let evidence = stmt
                .query_map([artist_id], |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        r.get::<_, String>(1)?,
                        r.get::<_, bool>(2)?,
                    ))
                })
                .map_err(storage)?;
            for row in evidence {
                let (id, role, uncertain) = row.map_err(storage)?;
                candidates.push(ArtistIdentityCandidate {
                    musicbrainz_id: id,
                    name: String::new(),
                    aliases: Vec::new(),
                    entity_kind: ArtistEntityKind::Unknown,
                    disambiguation: String::new(),
                    evidence: vec![
                        format!("tag:{role}"),
                        if uncertain {
                            "uncertain_credit_mapping"
                        } else {
                            "single_artist_credit"
                        }
                        .into(),
                    ],
                });
            }
            (candidates, false)
        }
    };
    tx.commit().map_err(storage)?;
    Ok(ArtistIdentityCandidates {
        identity,
        candidates,
        lookup_status: ArtistIdentityLookupStatus::Updated,
        retry_after_seconds: None,
        truncated,
    })
}

pub fn store_candidates(
    conn: &Connection,
    artist_id: i64,
    generation: u64,
    candidates: &[ArtistIdentityCandidate],
    truncated: bool,
) -> CoreResult<bool> {
    let tx = Transaction::new_unchecked(conn, TransactionBehavior::Immediate).map_err(storage)?;
    let identity = read_inner(&tx, artist_id)?;
    if identity.generation != generation {
        return Ok(false);
    }
    let status = if candidates.is_empty() {
        "not_found"
    } else {
        "ambiguous"
    };
    // Searches only propose identities. Even a single exact-name result is ambiguous.
    let changed = tx.execute("UPDATE artist_enrichment_state SET identity_status = ?3, generation = generation + CASE WHEN identity_status != ?3 THEN 1 ELSE 0 END WHERE artist_id = ?1 AND generation = ?2 AND musicbrainz_id IS NULL",
        params![artist_id, generation, status]).map_err(storage)?;
    if changed != 1 {
        return Ok(false);
    }
    let current: u64 = tx
        .query_row(
            "SELECT generation FROM artist_enrichment_state WHERE artist_id = ?1",
            [artist_id],
            |r| r.get(0),
        )
        .map_err(storage)?;
    tx.execute("INSERT INTO artist_identity_candidates VALUES (?1, ?2, ?3, ?4) ON CONFLICT(artist_id) DO UPDATE SET generation = excluded.generation, payload = excluded.payload, truncated = excluded.truncated", params![artist_id, current, serde_json::to_string(candidates).map_err(storage)?, truncated]).map_err(storage)?;
    tx.commit().map_err(storage)?;
    Ok(true)
}

pub fn local_context(conn: &Connection, artist_id: i64) -> CoreResult<(String, Vec<String>)> {
    let name = conn
        .query_row(
            "SELECT name FROM artists WHERE artist_id = ?1",
            [artist_id],
            |r| r.get(0),
        )
        .map_err(storage)?;
    let releases = conn.prepare("SELECT DISTINCT r.title FROM releases r WHERE r.artist_id = ?1 OR EXISTS (SELECT 1 FROM songs s JOIN song_artists sa USING(song_id) WHERE s.release_id = r.release_id AND sa.artist_id = ?1) ORDER BY r.title LIMIT 50").map_err(storage)?
        .query_map([artist_id], |r| r.get(0)).map_err(storage)?.collect::<rusqlite::Result<_>>().map_err(storage)?;
    Ok((name, releases))
}

#[cfg(test)]
mod tests {
    use super::*;
    const A: &str = "11111111-1111-4111-8111-111111111111";
    const B: &str = "22222222-2222-4222-8222-222222222222";

    fn database() -> Connection {
        let mut conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("PRAGMA foreign_keys = ON").unwrap();
        crate::database::operations::create_tables(&conn).unwrap();
        crate::database::migrations::migrate_enrichment(&mut conn).unwrap();
        conn.execute_batch("INSERT INTO artists(artist_id, name) VALUES (1, 'Same Name');
            INSERT INTO releases(release_id, title, artist_id, artist_name) VALUES (1, 'Album', 1, 'Same Name');
            INSERT INTO songs(song_id, title, artist_id, artist_name, release_id, release_title, track_number, duration, file_path) VALUES (1, 'One', 1, 'Same Name', 1, 'Album', 1, 180, '/one'), (2, 'Two', 1, 'Same Name', 1, 'Album', 2, 180, '/two');").unwrap();
        conn
    }
    fn evidence(conn: &Connection, song: i64, id: &str) {
        conn.execute(
            "INSERT INTO artist_tag_evidence VALUES (?1, 1, 'track_artist', ?2, 0)",
            params![song, id],
        )
        .unwrap();
    }
    #[test]
    fn tag_conflict_invalidates_inflight_work_and_never_selects_a_homonym() {
        let conn = database();
        evidence(&conn, 1, A);
        let resolved = read(&conn, 1).unwrap();
        assert_eq!(resolved.musicbrainz_id.as_deref(), Some(A));
        evidence(&conn, 2, B);
        let conflict = read(&conn, 1).unwrap();
        assert!(conflict.conflicting_tags);
        assert_eq!(conflict.status, ArtistIdentityStatus::Ambiguous);
        assert!(conflict.musicbrainz_id.is_none());
        assert!(conflict.generation > resolved.generation);
        assert!(!store_candidates(&conn, 1, resolved.generation, &[], false).unwrap());
        conn.execute("DELETE FROM songs WHERE song_id = 2", [])
            .unwrap();
        assert_eq!(read(&conn, 1).unwrap().musicbrainz_id.as_deref(), Some(A));
    }
    #[test]
    fn manual_choice_survives_conflicting_tags_and_clear_suppresses_reassociation() {
        let conn = database();
        let manual = confirm(&conn, 1, Some(B.into())).unwrap();
        evidence(&conn, 1, A);
        let conflict = read(&conn, 1).unwrap();
        assert_eq!(conflict.confirmed_musicbrainz_id.as_deref(), Some(B));
        assert!(conflict.conflicting_tags);
        conn.execute("DELETE FROM artist_tag_evidence", []).unwrap();
        let restored = read(&conn, 1).unwrap();
        assert_eq!(restored.musicbrainz_id, manual.musicbrainz_id);
        assert_eq!(restored.origin, Some(ArtistIdentityOrigin::Manual));
        evidence(&conn, 1, B);
        let cleared = confirm(&conn, 1, None).unwrap();
        assert!(cleared.musicbrainz_id.is_none());
        assert!(read(&conn, 1).unwrap().musicbrainz_id.is_none());
        assert!(!store_candidates(&conn, 1, manual.generation, &[], false).unwrap());
    }
    #[test]
    fn name_search_never_confirms_even_one_candidate_and_old_generation_is_discarded() {
        let conn = database();
        let unresolved = read(&conn, 1).unwrap();
        let candidate = ArtistIdentityCandidate {
            musicbrainz_id: A.into(),
            name: "Same Name".into(),
            aliases: vec![],
            entity_kind: ArtistEntityKind::Person,
            disambiguation: "Homonym".into(),
            evidence: vec!["exact_name".into(), "local_release_title:Album".into()],
        };
        assert!(
            store_candidates(&conn, 1, unresolved.generation, &[candidate.clone()], true).unwrap()
        );
        let cached = candidates(&conn, 1).unwrap();
        assert_eq!(cached.identity.status, ArtistIdentityStatus::Ambiguous);
        assert_eq!(cached.candidates, vec![candidate]);
        assert!(cached.truncated);
        confirm(&conn, 1, Some(B.into())).unwrap();
        assert!(!store_candidates(&conn, 1, cached.identity.generation, &[], false).unwrap());
        assert!(candidates(&conn, 1).unwrap().candidates.is_empty());
        assert!(confirm(&conn, 1, Some("../../artist".into())).is_err());
        conn.execute("DELETE FROM artists WHERE artist_id = 1", [])
            .unwrap();
        assert!(matches!(read(&conn, 1), Err(CoreError::NotFound { .. })));
    }
    #[test]
    fn identical_rescan_preserves_generation_and_role_ambiguity_is_explicit() {
        let conn = database();
        let mut metadata: AudioMetadata = serde_json::from_value(serde_json::json!({
            "title":"One", "artist":"Same Name", "track_artists":["Same Name"],
            "album_artist":"Same Name", "release":"Album", "duration":180,
            "all_fields":{}, "file_path":"/one"
        }))
        .unwrap();
        metadata.musicbrainz.track_artists = vec![A.into()];
        metadata.musicbrainz.track_artists.push(A.into()); // Repeated identical IDs are not a conflict.
        metadata.musicbrainz.recordings = vec![B.into()];
        replace_tags(&conn, 1, &metadata).unwrap();
        let first = read(&conn, 1).unwrap();
        replace_tags(&conn, 1, &metadata).unwrap();
        assert_eq!(read(&conn, 1).unwrap(), first);
        metadata.musicbrainz.album_artists = vec![B.into()];
        replace_tags(&conn, 1, &metadata).unwrap();
        assert!(read(&conn, 1).unwrap().conflicting_tags);
        metadata.musicbrainz.album_artists.clear();
        metadata.musicbrainz.track_artists = vec![A.into(), B.into()];
        replace_tags(&conn, 1, &metadata).unwrap();
        assert!(read(&conn, 1).unwrap().conflicting_tags);
        let payload: String = conn
            .query_row(
                "SELECT payload FROM song_musicbrainz_tags WHERE song_id = 1",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(
            serde_json::from_str::<crate::metadata::MusicBrainzTags>(&payload).unwrap(),
            metadata.musicbrainz
        );
    }
}
