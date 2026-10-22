//! Personal categories live only in the library, never in embedded file metadata.
use crate::api::{CoreError, CoreResult, UserTag, UserTagLibrary, UserTagLink};
use rusqlite::{Connection, OptionalExtension, Transaction, TransactionBehavior, params};
use std::collections::BTreeSet;

fn storage(error: rusqlite::Error) -> CoreError {
    super::storage_error("Personal tags", error)
}
fn invalid(message: &str) -> CoreError {
    CoreError::InvalidInput {
        message: message.into(),
    }
}
fn missing() -> CoreError {
    CoreError::NotFound {
        message: "Tag or library item not found".into(),
    }
}

pub(crate) fn migrate(conn: &Connection) -> rusqlite::Result<()> {
    let tx = Transaction::new_unchecked(conn, TransactionBehavior::Immediate)?;
    tx.execute_batch("CREATE TABLE IF NOT EXISTS user_tags (
        tag_id INTEGER PRIMARY KEY, name TEXT NOT NULL, normalized_name TEXT NOT NULL UNIQUE,
        CHECK(length(trim(name)) BETWEEN 1 AND 80));
        CREATE TABLE IF NOT EXISTS track_user_tags (
            song_id INTEGER NOT NULL REFERENCES songs(song_id) ON DELETE CASCADE,
            tag_id INTEGER NOT NULL REFERENCES user_tags(tag_id) ON DELETE CASCADE,
            PRIMARY KEY(song_id, tag_id));
        CREATE INDEX IF NOT EXISTS idx_track_user_tags_tag ON track_user_tags(tag_id, song_id);
        CREATE TABLE IF NOT EXISTS release_user_tags (
            release_id INTEGER NOT NULL REFERENCES releases(release_id) ON DELETE CASCADE,
            tag_id INTEGER NOT NULL REFERENCES user_tags(tag_id) ON DELETE CASCADE,
            PRIMARY KEY(release_id, tag_id));
        CREATE INDEX IF NOT EXISTS idx_release_user_tags_tag ON release_user_tags(tag_id, release_id);
        CREATE TABLE IF NOT EXISTS missing_track_user_tags (
            missing_id INTEGER NOT NULL REFERENCES missing_tracks(missing_id) ON DELETE CASCADE,
            tag_id INTEGER NOT NULL REFERENCES user_tags(tag_id) ON DELETE CASCADE,
            PRIMARY KEY(missing_id,tag_id));
        CREATE INDEX IF NOT EXISTS idx_missing_user_tags_tag ON missing_track_user_tags(tag_id,missing_id);")?;
    tx.commit()
}

pub(crate) fn normalized_name(name: &str) -> CoreResult<(String, String)> {
    if name.chars().any(char::is_control) {
        return Err(invalid("Tag names cannot contain control characters"));
    }
    let name = name.split_whitespace().collect::<Vec<_>>().join(" ");
    if name.is_empty() || name.chars().count() > 80 {
        return Err(invalid("Tag names must contain 1 to 80 characters"));
    }
    let key = name.to_lowercase();
    Ok((name, key))
}

pub(crate) fn create(conn: &Connection, name: String) -> CoreResult<UserTag> {
    let (name, key) = normalized_name(&name)?;
    // Creation doubles as autocomplete's create-or-select, including concurrent callers.
    conn.execute("INSERT INTO user_tags(name,normalized_name) VALUES(?1,?2) ON CONFLICT(normalized_name) DO NOTHING", params![name,key]).map_err(storage)?;
    conn.query_row(
        "SELECT tag_id,name FROM user_tags WHERE normalized_name=?1",
        [key],
        |r| {
            Ok(UserTag {
                id: r.get(0)?,
                name: r.get(1)?,
            })
        },
    )
    .map_err(storage)
}

pub(crate) fn rename(conn: &Connection, id: i64, name: String) -> CoreResult<UserTag> {
    let (name, key) = normalized_name(&name)?;
    let tx = Transaction::new_unchecked(conn, TransactionBehavior::Immediate).map_err(storage)?;
    let conflict: bool = tx
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM user_tags WHERE normalized_name=?1 AND tag_id!=?2)",
            params![key, id],
            |r| r.get(0),
        )
        .map_err(storage)?;
    if conflict {
        return Err(invalid("A tag with this name already exists"));
    }
    if tx
        .execute(
            "UPDATE user_tags SET name=?1,normalized_name=?2 WHERE tag_id=?3",
            params![name, key, id],
        )
        .map_err(storage)?
        == 0
    {
        return Err(missing());
    }
    tx.commit().map_err(storage)?;
    Ok(UserTag { id, name })
}

pub(crate) fn delete(conn: &Connection, id: i64) -> CoreResult<()> {
    if conn
        .execute("DELETE FROM user_tags WHERE tag_id=?1", [id])
        .map_err(storage)?
        == 0
    {
        return Err(missing());
    }
    Ok(())
}

pub(crate) fn update_links(
    conn: &Connection,
    tag_id: i64,
    track_ids: Vec<i64>,
    release_ids: Vec<i64>,
    attached: bool,
) -> CoreResult<()> {
    if track_ids.len() + release_ids.len() > 10_000 {
        return Err(invalid("Select at most 10000 items per operation"));
    }
    let tx = Transaction::new_unchecked(conn, TransactionBehavior::Immediate).map_err(storage)?;
    if tx
        .query_row(
            "SELECT tag_id FROM user_tags WHERE tag_id=?1",
            [tag_id],
            |r| r.get::<_, i64>(0),
        )
        .optional()
        .map_err(storage)?
        .is_none()
    {
        return Err(missing());
    }
    for (table, column, entity, ids) in [
        ("track_user_tags", "song_id", "songs", track_ids),
        ("release_user_tags", "release_id", "releases", release_ids),
    ] {
        for id in ids.into_iter().collect::<BTreeSet<_>>() {
            let exists: bool = tx
                .query_row(
                    &format!("SELECT EXISTS(SELECT 1 FROM {entity} WHERE {column}=?1)"),
                    [id],
                    |r| r.get(0),
                )
                .map_err(storage)?;
            if !exists {
                return Err(missing());
            }
            let sql = if attached {
                format!("INSERT OR IGNORE INTO {table}({column},tag_id) VALUES(?1,?2)")
            } else {
                format!("DELETE FROM {table} WHERE {column}=?1 AND tag_id=?2")
            };
            tx.execute(&sql, params![id, tag_id]).map_err(storage)?;
        }
    }
    tx.commit().map_err(storage)
}

pub(crate) fn library(conn: &Connection) -> CoreResult<UserTagLibrary> {
    // A consistent snapshot prevents a concurrent rename/delete from splitting the indexes.
    let tx = Transaction::new_unchecked(conn, TransactionBehavior::Deferred).map_err(storage)?;
    let tags = tx
        .prepare("SELECT tag_id,name FROM user_tags ORDER BY normalized_name,tag_id")
        .map_err(storage)?
        .query_map([], |r| {
            Ok(UserTag {
                id: r.get(0)?,
                name: r.get(1)?,
            })
        })
        .map_err(storage)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(storage)?;
    fn links(conn: &Connection, table: &str, column: &str) -> CoreResult<Vec<UserTagLink>> {
        conn.prepare(&format!(
            "SELECT tag_id,{column} FROM {table} ORDER BY tag_id,{column}"
        ))
        .map_err(storage)?
        .query_map([], |r| {
            Ok(UserTagLink {
                tag_id: r.get(0)?,
                item_id: r.get(1)?,
            })
        })
        .map_err(storage)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(storage)
    }
    let result = UserTagLibrary {
        tags,
        track_links: links(&tx, "track_user_tags", "song_id")?,
        release_links: links(&tx, "release_user_tags", "release_id")?,
    };
    tx.commit().map_err(storage)?;
    Ok(result)
}

pub(crate) fn matching_items(
    conn: &Connection,
    ids: Vec<i64>,
    match_all: bool,
    releases: bool,
) -> CoreResult<Vec<i64>> {
    let ids: BTreeSet<_> = ids.into_iter().collect();
    if ids.len() > 100 {
        return Err(invalid("Select at most 100 filter tags"));
    }
    let (entity, table, column) = if releases {
        ("releases", "release_user_tags", "release_id")
    } else {
        ("songs", "track_user_tags", "song_id")
    };
    if ids.is_empty() {
        return conn
            .prepare(&format!("SELECT {column} FROM {entity} ORDER BY {column}"))
            .map_err(storage)?
            .query_map([], |r| r.get(0))
            .map_err(storage)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(storage);
    }
    let placeholders = vec!["?"; ids.len()].join(",");
    let having = if match_all {
        format!(" HAVING COUNT(DISTINCT tag_id)={}", ids.len())
    } else {
        String::new()
    };
    conn.prepare(&format!("SELECT {column} FROM {table} WHERE tag_id IN ({placeholders}) GROUP BY {column}{having} ORDER BY {column}")).map_err(storage)?
        .query_map(rusqlite::params_from_iter(ids), |r|r.get(0)).map_err(storage)?.collect::<Result<Vec<_>,_>>().map_err(storage)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> Connection {
        let c = Connection::open_in_memory().unwrap();
        c.execute_batch("PRAGMA foreign_keys=ON").unwrap();
        super::super::operations::create_tables(&c).unwrap();
        c.execute("INSERT INTO artists(artist_id,name) VALUES(1,'Artist')", [])
            .unwrap();
        c.execute("INSERT INTO releases(release_id,title,artist_id,artist_name,created_at) VALUES(1,'Album',1,'Artist','2026-01-01')", []).unwrap();
        for id in 1..=3 {
            c.execute("INSERT INTO songs(song_id,title,artist_id,artist_name,release_id,release_title,track_number,duration,file_path,created_at) VALUES(?1,'Track',1,'Artist',1,'Album',1,180,?2,'2026-01-01')",params![id,format!("/test/{id}.flac")]).unwrap();
        }
        c
    }
    #[test]
    fn names_are_validated_and_create_is_case_insensitive() {
        let c = fixture();
        let a = create(&c, "  Para   Ouvir  ".into()).unwrap();
        assert_eq!(a.name, "Para Ouvir");
        assert_eq!(create(&c, "para ouvir".into()).unwrap().id, a.id);
        for value in ["", "   ", "a\nb", &"x".repeat(81)] {
            assert!(create(&c, value.into()).is_err());
        }
        let b = create(&c, "Viagem".into()).unwrap();
        assert!(rename(&c, b.id, "PARA OUVIR".into()).is_err());
        assert!(rename(&c, 999, "Novo".into()).is_err());
    }
    #[test]
    fn bulk_associations_filters_rename_detach_and_delete_are_independent() {
        let c = fixture();
        let a = create(&c, "Noite".into()).unwrap();
        let b = create(&c, "Calmo".into()).unwrap();
        update_links(&c, a.id, vec![1, 1, 2], vec![1], true).unwrap();
        update_links(&c, b.id, vec![2, 3], vec![], true).unwrap();
        assert_eq!(
            matching_items(&c, vec![a.id, b.id], false, false).unwrap(),
            vec![1, 2, 3]
        );
        assert_eq!(
            matching_items(&c, vec![a.id, b.id], true, false).unwrap(),
            vec![2]
        );
        assert_eq!(matching_items(&c, vec![a.id], true, true).unwrap(), vec![1]);
        assert!(
            matching_items(&c, vec![a.id, 999], true, false)
                .unwrap()
                .is_empty()
        );
        rename(&c, a.id, "Noturno".into()).unwrap();
        assert_eq!(library(&c).unwrap().track_links.len(), 4);
        update_links(&c, a.id, vec![1], vec![], false).unwrap();
        assert_eq!(
            matching_items(&c, vec![a.id], true, false).unwrap(),
            vec![2]
        );
        delete(&c, a.id).unwrap();
        let state = library(&c).unwrap();
        assert_eq!(state.tags.len(), 1);
        assert_eq!(state.track_links.len(), 2);
        assert!(state.release_links.is_empty());
    }
    #[test]
    fn invalid_batch_rolls_back_and_rescan_preserves_personal_categories() {
        let c = fixture();
        let a = create(&c, "Favoritos pessoais".into()).unwrap();
        assert!(update_links(&c, a.id, vec![1, 999], vec![], true).is_err());
        assert!(library(&c).unwrap().track_links.is_empty());
        update_links(&c, a.id, vec![1], vec![1], true).unwrap();
        c.execute(
            "UPDATE songs SET title='Rescan',rating_half_steps=4 WHERE song_id=1",
            [],
        )
        .unwrap();
        super::super::operations::create_tables(&c).unwrap();
        let expected = library(&c).unwrap();
        assert_eq!(expected.track_links.len(), 1);
        assert_eq!(expected.release_links.len(), 1);
        let file = tempfile::NamedTempFile::new().unwrap();
        // Reopen a real database to exercise durable storage, not just a cached snapshot.
        let disk = Connection::open(file.path()).unwrap();
        super::super::operations::create_tables(&disk).unwrap();
        create(&disk, "Persistida".into()).unwrap();
        drop(disk);
        assert_eq!(
            library(&Connection::open(file.path()).unwrap())
                .unwrap()
                .tags[0]
                .name,
            "Persistida"
        );
        c.execute("DELETE FROM songs WHERE song_id=1", []).unwrap();
        assert!(library(&c).unwrap().track_links.is_empty());
        assert_eq!(library(&c).unwrap().release_links.len(), 1);
    }
}

#[cfg(test)]
mod smart_rule_tests {
    use super::*;
    use crate::api::{SmartPlaylistDefinition, SmartPlaylistRule};
    #[test]
    fn smart_rules_keep_identity_after_rename_and_distinguish_album_from_track() {
        let c = Connection::open_in_memory().unwrap();
        super::super::operations::create_tables(&c).unwrap();
        c.execute("INSERT INTO artists(artist_id,name) VALUES(1,'Artist')", [])
            .unwrap();
        c.execute("INSERT INTO releases(release_id,title,artist_id,artist_name) VALUES(1,'Album',1,'Artist')",[]).unwrap();
        for id in 1..=2 {
            c.execute("INSERT INTO songs(song_id,title,artist_id,artist_name,release_id,release_title,track_number,duration,file_path) VALUES(?1,'Track',1,'Artist',1,'Album',1,180,?2)",params![id,format!("/test/{id}.flac")]).unwrap();
        }
        let tag = create(&c, "Noite".into()).unwrap();
        update_links(&c, tag.id, vec![1], vec![1], true).unwrap();
        let definition = |field: &str, comparison: &str, value: String| SmartPlaylistDefinition {
            match_all: true,
            rules: vec![SmartPlaylistRule {
                field: field.into(),
                comparison: comparison.into(),
                value,
            }],
            limit: None,
            sort_by: "title".into(),
            descending: false,
        };
        let rule = definition("user_tag", "equals", tag.id.to_string());
        let before = super::super::operations::get_smart_playlist_tracks(&c, &rule).unwrap();
        assert_eq!(before.len(), 1);
        rename(&c, tag.id, "Noturno".into()).unwrap();
        assert_eq!(
            super::super::operations::get_smart_playlist_tracks(&c, &rule)
                .unwrap()
                .len(),
            1
        );
        assert_eq!(
            super::super::operations::get_smart_playlist_tracks(
                &c,
                &definition("release_user_tag", "equals", tag.id.to_string())
            )
            .unwrap()
            .len(),
            2
        );
        assert_eq!(
            super::super::operations::get_smart_playlist_tracks(
                &c,
                &definition("user_tag", "is_empty", String::new())
            )
            .unwrap()
            .len(),
            1
        );
        assert!(
            super::super::operations::get_smart_playlist_tracks(
                &c,
                &definition("user_tag", "equals", "invalid".into())
            )
            .is_err()
        );
    }
}
