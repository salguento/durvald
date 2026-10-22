//! Persistent intent to listen, independent of playback history and file availability.
use crate::api::{Artist, CoreError, CoreResult, ExternalReleaseGroup, ListenListEntry};
use rusqlite::{Connection, OptionalExtension, Row, Transaction, TransactionBehavior, params};

fn storage(e: impl std::fmt::Display) -> CoreError {
    CoreError::Storage {
        message: format!("Listen list: {e}"),
    }
}
fn missing() -> CoreError {
    CoreError::NotFound {
        message: "Listen list item or release not found".into(),
    }
}

pub(crate) fn migrate(conn: &Connection) -> rusqlite::Result<()> {
    conn.execute_batch("CREATE TABLE IF NOT EXISTS listen_list_entries (
        entry_id INTEGER PRIMARY KEY AUTOINCREMENT,
        release_id INTEGER REFERENCES releases(release_id) ON DELETE SET NULL,
        external_mbid TEXT,
        external_release_json TEXT CHECK(external_release_json IS NULL OR json_valid(external_release_json)),
        external_artist_json TEXT CHECK(external_artist_json IS NULL OR json_valid(external_artist_json)),
        title TEXT NOT NULL, artist TEXT NOT NULL, artwork_id TEXT,
        added_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
        heard_at TEXT);
        CREATE UNIQUE INDEX IF NOT EXISTS idx_listen_list_release ON listen_list_entries(release_id) WHERE release_id IS NOT NULL;
        CREATE UNIQUE INDEX IF NOT EXISTS idx_listen_list_external ON listen_list_entries(external_mbid) WHERE external_mbid IS NOT NULL;
        CREATE INDEX IF NOT EXISTS idx_listen_list_pending ON listen_list_entries(heard_at,added_at DESC,entry_id DESC);")
}

fn entry(row: &Row<'_>) -> rusqlite::Result<ListenListEntry> {
    fn decode<T: serde::de::DeserializeOwned>(
        row: &Row<'_>,
        index: usize,
    ) -> rusqlite::Result<Option<T>> {
        row.get::<_, Option<String>>(index)?
            .map(|json| {
                serde_json::from_str(&json).map_err(|e| {
                    rusqlite::Error::FromSqlConversionFailure(
                        index,
                        rusqlite::types::Type::Text,
                        Box::new(e),
                    )
                })
            })
            .transpose()
    }
    Ok(ListenListEntry {
        id: row.get(0)?,
        local_release_id: row.get(1)?,
        title: row.get(2)?,
        artist: row.get(3)?,
        artwork_id: row.get(4)?,
        added_at: row.get(5)?,
        heard_at: row.get(6)?,
        external_release: decode(row, 7)?,
        external_artist: decode(row, 8)?,
    })
}
const SELECT: &str = "SELECT e.entry_id,e.release_id,COALESCE(r.title,e.title),COALESCE(r.artist_name,e.artist),
    COALESCE(NULLIF(r.artwork,''),e.artwork_id),e.added_at,e.heard_at,e.external_release_json,e.external_artist_json
    FROM listen_list_entries e LEFT JOIN releases r ON r.release_id=e.release_id";
fn read(conn: &Connection, id: i64) -> CoreResult<ListenListEntry> {
    conn.query_row(&format!("{SELECT} WHERE e.entry_id=?1"), [id], entry)
        .optional()
        .map_err(storage)?
        .ok_or_else(missing)
}
pub(crate) fn list(conn: &Connection) -> CoreResult<Vec<ListenListEntry>> {
    conn.prepare(&format!(
        "{SELECT} ORDER BY e.added_at DESC,e.entry_id DESC"
    ))
    .map_err(storage)?
    .query_map([], entry)
    .map_err(storage)?
    .collect::<Result<Vec<_>, _>>()
    .map_err(storage)
}
fn merge_entry(conn: &Connection, keep: i64, old: i64) -> CoreResult<()> {
    let previous = read(conn, old)?;
    let mbid = previous
        .external_release
        .as_ref()
        .map(|r| r.musicbrainz_id.clone());
    let release = previous
        .external_release
        .map(|r| serde_json::to_string(&r))
        .transpose()
        .map_err(storage)?;
    let artist = previous
        .external_artist
        .map(|a| serde_json::to_string(&a))
        .transpose()
        .map_err(storage)?;
    conn.execute("DELETE FROM listen_list_entries WHERE entry_id=?1", [old])
        .map_err(storage)?;
    conn.execute("UPDATE listen_list_entries SET added_at=MIN(added_at,?2),heard_at=COALESCE(heard_at,?3),
        external_mbid=COALESCE(external_mbid,?4),external_release_json=COALESCE(external_release_json,?5),
        external_artist_json=COALESCE(external_artist_json,?6) WHERE entry_id=?1",
        params![keep,previous.added_at,previous.heard_at,mbid,release,artist]).map_err(storage)?;
    Ok(())
}

fn add_local_in_transaction(conn: &Connection, id: i64) -> CoreResult<i64> {
    let exists: bool = conn
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM releases WHERE release_id=?1)",
            [id],
            |r| r.get(0),
        )
        .map_err(storage)?;
    if !exists {
        return Err(missing());
    }
    conn.execute("INSERT INTO listen_list_entries(release_id,title,artist,artwork_id)
        SELECT release_id,COALESCE(title,''),artist_name,NULLIF(artwork,'') FROM releases WHERE release_id=?1
        ON CONFLICT(release_id) WHERE release_id IS NOT NULL DO NOTHING",[id]).map_err(storage)?;
    let saved: i64 = conn
        .query_row(
            "SELECT entry_id FROM listen_list_entries WHERE release_id=?1",
            [id],
            |r| r.get(0),
        )
        .map_err(storage)?;
    if conn
        .table_exists(None, "local_release_external_ids")
        .map_err(storage)?
    {
        let external: Option<i64> = conn.query_row("SELECT e.entry_id FROM listen_list_entries e
            JOIN local_release_external_ids x ON x.release_group_mbid=e.external_mbid
            WHERE x.release_id=?1 AND (SELECT COUNT(*) FROM local_release_external_ids y WHERE y.release_group_mbid=x.release_group_mbid)=1",
            [id],|r|r.get(0)).optional().map_err(storage)?;
        if let Some(old) = external.filter(|old| *old != saved) {
            merge_entry(conn, saved, old)?;
        }
    }
    Ok(saved)
}
pub(crate) fn add_local(conn: &Connection, id: i64) -> CoreResult<ListenListEntry> {
    let tx = Transaction::new_unchecked(conn, TransactionBehavior::Immediate).map_err(storage)?;
    let entry_id = add_local_in_transaction(&tx, id)?;
    let result = read(&tx, entry_id)?;
    tx.commit().map_err(storage)?;
    Ok(result)
}
pub(crate) fn add_external(
    conn: &Connection,
    artist_id: i64,
    mut release: ExternalReleaseGroup,
) -> CoreResult<ListenListEntry> {
    let mbid =
        crate::enrichment::identity::normalize_mbid(&release.musicbrainz_id).ok_or_else(|| {
            CoreError::InvalidInput {
                message: "Invalid release-group identifier".into(),
            }
        })?;
    release.musicbrainz_id = mbid.clone();
    if release.title.trim().is_empty() || release.title.chars().count() > 1000 {
        return Err(CoreError::InvalidInput {
            message: "A release title is required".into(),
        });
    }
    let tx = Transaction::new_unchecked(conn, TransactionBehavior::Immediate).map_err(storage)?;
    let artist = tx
        .query_row(
            "SELECT artist_id,name FROM artists WHERE artist_id=?1",
            [artist_id],
            |r| {
                Ok(Artist {
                    id: r.get(0)?,
                    name: r.get(1)?,
                })
            },
        )
        .optional()
        .map_err(storage)?
        .ok_or_else(missing)?;
    let existing: Option<i64> = tx
        .query_row(
            "SELECT entry_id FROM listen_list_entries WHERE external_mbid=?1",
            [&mbid],
            |r| r.get(0),
        )
        .optional()
        .map_err(storage)?;
    let entry_id = if let Some(local) = release.local_release_id {
        let verified: bool = tx.query_row("SELECT EXISTS(SELECT 1 FROM local_release_external_ids WHERE release_id=?1 AND release_group_mbid=?2)",params![local,mbid],|r|r.get(0)).map_err(storage)?;
        if !verified {
            return Err(CoreError::InvalidInput {
                message: "Unverified local release link".into(),
            });
        }

        // Only an explicit identifier-based link may reconcile local and online entries.
        let local_entry = add_local_in_transaction(&tx, local)?;
        let remaining: Option<i64> = tx
            .query_row(
                "SELECT entry_id FROM listen_list_entries WHERE external_mbid=?1",
                [&mbid],
                |r| r.get(0),
            )
            .optional()
            .map_err(storage)?;
        if let Some(old) = remaining.filter(|old| *old != local_entry) {
            merge_entry(&tx, local_entry, old)?;
        }
        local_entry
    } else if let Some(existing) = existing {
        existing
    } else {
        let artwork = release
            .artwork
            .as_ref()
            .map(|a| a.image.managed_path.clone());
        tx.execute("INSERT INTO listen_list_entries(external_mbid,title,artist,artwork_id) VALUES(?1,?2,?3,?4)",params![mbid,release.title,artist.name,artwork]).map_err(storage)?;
        tx.last_insert_rowid()
    };
    tx.execute("UPDATE listen_list_entries SET external_mbid=?2,external_release_json=?3,external_artist_json=?4 WHERE entry_id=?1",
        params![entry_id,mbid,serde_json::to_string(&release).map_err(storage)?,serde_json::to_string(&artist).map_err(storage)?]).map_err(storage)?;
    let result = read(&tx, entry_id)?;
    tx.commit().map_err(storage)?;
    Ok(result)
}
pub(crate) fn set_heard(conn: &Connection, id: i64, heard: bool) -> CoreResult<()> {
    if conn.execute("UPDATE listen_list_entries SET heard_at=CASE WHEN ?2 THEN COALESCE(heard_at,strftime('%Y-%m-%dT%H:%M:%fZ','now')) ELSE NULL END WHERE entry_id=?1",params![id,heard]).map_err(storage)?==0 { return Err(missing()); }
    Ok(())
}
pub(crate) fn remove(conn: &Connection, id: i64) -> CoreResult<()> {
    if conn
        .execute("DELETE FROM listen_list_entries WHERE entry_id=?1", [id])
        .map_err(storage)?
        == 0
    {
        return Err(missing());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> Connection {
        let mut c = Connection::open_in_memory().unwrap();
        c.execute_batch("PRAGMA foreign_keys=ON").unwrap();
        crate::database::operations::create_tables(&c).unwrap();
        crate::database::migrations::migrate_enrichment(&mut c).unwrap();
        c.execute("INSERT INTO artists(artist_id,name) VALUES(1,'Artist')", [])
            .unwrap();
        c.execute("INSERT INTO releases(release_id,title,artist_id,artist_name) VALUES(1,'Album',1,'Artist')",[]).unwrap();
        c
    }
    fn external() -> ExternalReleaseGroup {
        serde_json::from_value(serde_json::json!({"primary_artist_mbid":null,"musicbrainz_id":"12345678-1234-1234-1234-123456789ABC","title":"Online album","primary_type":"Album","secondary_types":[],"first_release_date":null,"local_release_id":null,"artwork":null,"attribution":{"source_url":"https://musicbrainz.org/release-group/12345678-1234-1234-1234-123456789abc","author":null,"license_name":null,"license_url":null,"revision":null}})).unwrap()
    }
    #[test]
    fn local_entries_are_unique_heard_is_explicit_and_removal_does_not_touch_catalog() {
        let c = fixture();
        let saved = add_local(&c, 1).unwrap();
        set_heard(&c, saved.id, true).unwrap();
        let repeat = add_local(&c, 1).unwrap();
        assert_eq!(saved.id, repeat.id);
        assert_eq!(saved.added_at, repeat.added_at);
        assert!(repeat.heard_at.is_some());
        set_heard(&c, saved.id, false).unwrap();
        assert!(list(&c).unwrap()[0].heard_at.is_none());
        remove(&c, saved.id).unwrap();
        assert!(list(&c).unwrap().is_empty());
        assert!(add_local(&c, 999).is_err());
        assert_eq!(
            c.query_row("SELECT COUNT(*) FROM releases", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            1
        );
    }
    #[test]
    fn online_entries_persist_snapshots_and_link_only_verified_identifiers() {
        let c = fixture();
        let saved = add_external(&c, 1, external()).unwrap();
        assert!(saved.local_release_id.is_none());
        assert_eq!(saved.artist, "Artist");
        assert_eq!(add_external(&c, 1, external()).unwrap().id, saved.id);
        let mut linked = external();
        linked.local_release_id = Some(1);
        assert!(add_external(&c, 1, linked.clone()).is_err());
        assert_eq!(list(&c).unwrap().len(), 1);
        c.execute("INSERT INTO local_release_external_ids(release_id,release_group_mbid,origin,updated_at) VALUES(1,?1,'manual',0)",[external().musicbrainz_id.to_lowercase()]).unwrap();
        set_heard(&c, saved.id, true).unwrap();
        add_local(&c, 1).unwrap();
        let merged = add_external(&c, 1, linked).unwrap();
        assert_eq!(list(&c).unwrap().len(), 1);
        assert_eq!(merged.local_release_id, Some(1));
        assert!(merged.heard_at.is_some());
        let mut invalid = external();
        invalid.musicbrainz_id = "invalid".into();
        assert!(add_external(&c, 1, invalid).is_err());
        assert!(add_external(&c, 999, external()).is_err());
    }
    #[test]
    fn deleting_local_metadata_retains_saved_intent_and_cannot_attach_reused_ids() {
        let c = fixture();
        let entry = add_local(&c, 1).unwrap();
        c.execute("DELETE FROM releases WHERE release_id=1", [])
            .unwrap();
        let retained = list(&c).unwrap().remove(0);
        assert_eq!(retained.id, entry.id);
        assert_eq!(retained.title, "Album");
        assert!(retained.local_release_id.is_none());
        c.execute("INSERT INTO releases(release_id,title,artist_id,artist_name) VALUES(1,'Different album',1,'Artist')",[]).unwrap();
        add_local(&c, 1).unwrap();
        assert_eq!(list(&c).unwrap().len(), 2);
        assert!(
            list(&c)
                .unwrap()
                .iter()
                .find(|e| e.id == entry.id)
                .unwrap()
                .local_release_id
                .is_none()
        );
    }
}
