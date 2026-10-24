//! Album identities and ordering, independent of playlist songs and listening intent.
use crate::api::*;
use rusqlite::{Connection, OptionalExtension, params, params_from_iter, types::Value};
use std::collections::BTreeSet;

fn storage(e: impl std::fmt::Display) -> CoreError {
    super::storage_error("Album collections", e.to_string())
}
fn invalid(message: &str) -> CoreError {
    CoreError::InvalidInput {
        message: message.into(),
    }
}
fn missing() -> CoreError {
    CoreError::NotFound {
        message: "Collection or album not found".into(),
    }
}

pub(crate) fn migrate(c: &Connection) -> rusqlite::Result<()> {
    c.execute_batch("CREATE TABLE IF NOT EXISTS album_collections (
        id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT NOT NULL,description TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
        CREATE TABLE IF NOT EXISTS album_collection_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,collection_id INTEGER NOT NULL REFERENCES album_collections(id) ON DELETE CASCADE,
        release_id INTEGER REFERENCES releases(release_id) ON DELETE SET NULL,title TEXT NOT NULL,artist TEXT NOT NULL,
        artwork_id TEXT,position INTEGER NOT NULL,UNIQUE(collection_id,release_id));
        CREATE INDEX IF NOT EXISTS idx_album_collection_order ON album_collection_items(collection_id,position,id);
        CREATE TABLE IF NOT EXISTS album_collection_rules (
        collection_id INTEGER PRIMARY KEY REFERENCES album_collections(id) ON DELETE CASCADE,
        definition TEXT NOT NULL CHECK(json_valid(definition)));
        CREATE TRIGGER IF NOT EXISTS album_collection_release_deleted AFTER DELETE ON releases BEGIN
            UPDATE album_collection_items SET release_id=NULL WHERE release_id=OLD.release_id;
        END;
        CREATE TRIGGER IF NOT EXISTS album_collection_deleted AFTER DELETE ON album_collections BEGIN
            DELETE FROM album_collection_items WHERE collection_id=OLD.id;
            DELETE FROM album_collection_rules WHERE collection_id=OLD.id;
        END;")
}

fn definition(c: &Connection, id: i64) -> CoreResult<Option<AlbumCollectionDefinition>> {
    c.query_row(
        "SELECT definition FROM album_collection_rules WHERE collection_id=?1",
        [id],
        |r| r.get::<_, String>(0),
    )
    .optional()
    .map_err(storage)?
    .map(|json| serde_json::from_str(&json).map_err(storage))
    .transpose()
}

fn predicate(rule: &SmartPlaylistRule, values: &mut Vec<Value>) -> CoreResult<String> {
    let id = || {
        rule.value
            .parse::<i64>()
            .ok()
            .filter(|n| *n > 0)
            .ok_or_else(|| invalid("Invalid classification or tag identity"))
    };
    let sql = match (rule.field.as_str(), rule.comparison.as_str()) {
        ("genre" | "style", "equals") => {
            let (table, key) = if rule.field == "genre" {
                ("release_genres", "genre_id")
            } else {
                ("release_styles", "style_id")
            };
            values.push(Value::Integer(id()?));
            format!(
                "EXISTS(SELECT 1 FROM {table} x WHERE x.release_id=r.release_id AND x.{key}=? AND x.origin!='contains_tracks')"
            )
        }
        ("album_tag", "equals") => {
            values.push(Value::Integer(id()?));
            "EXISTS(SELECT 1 FROM release_user_tags x WHERE x.release_id=r.release_id AND x.tag_id=?)".into()
        }
        ("track_tag", "equals") => {
            values.push(Value::Integer(id()?));
            "EXISTS(SELECT 1 FROM songs s JOIN track_user_tags x USING(song_id) WHERE s.release_id=r.release_id AND NOT s.is_hidden AND x.tag_id=?)".into()
        }
        ("artist", "contains") => {
            if rule.value.trim().is_empty() || rule.value.chars().count() > 200 {
                return Err(invalid("Invalid artist filter"));
            }
            values.push(Value::Text(rule.value.trim().into()));
            "instr(lower(r.artist_name),lower(?))>0".into()
        }
        ("year", "at_least" | "at_most") => {
            let year = rule
                .value
                .parse::<i64>()
                .map_err(|_| invalid("Invalid year"))?;
            if !(1000..=3000).contains(&year) {
                return Err(invalid("Invalid year"));
            }
            values.push(Value::Integer(year));
            format!(
                "CAST(substr(r.release_date,1,4) AS INTEGER){}?",
                if rule.comparison == "at_least" {
                    ">="
                } else {
                    "<="
                }
            )
        }
        ("rating", "at_least") => {
            let rating = rule
                .value
                .parse::<i64>()
                .map_err(|_| invalid("Invalid album rating"))?;
            if !(0..=10).contains(&rating) {
                return Err(invalid("Invalid album rating"));
            }
            values.push(Value::Integer(rating));
            "r.rating_half_steps>=?".into()
        }
        ("played", "equals") => {
            if !matches!(rule.value.as_str(), "true" | "false") {
                return Err(invalid("Invalid listening state"));
            }
            format!(
                "{}EXISTS(SELECT 1 FROM songs s JOIN play_history h USING(song_id) WHERE s.release_id=r.release_id)",
                if rule.value == "true" { "" } else { "NOT " }
            )
        }
        _ => return Err(invalid("Unsupported album collection rule")),
    };
    Ok(sql)
}

fn smart_ids(c: &Connection, def: &AlbumCollectionDefinition) -> CoreResult<Vec<i64>> {
    if def.rules.is_empty() || def.rules.len() > 20 {
        return Err(invalid("Use between 1 and 20 album rules"));
    }
    let order = match def.sort_by.as_str() {
        "title" => "r.title COLLATE NOCASE",
        "artist" => "r.artist_name COLLATE NOCASE,r.title COLLATE NOCASE",
        "year" => "r.release_date",
        "rating" => "r.rating_half_steps",
        _ => return Err(invalid("Invalid album ordering")),
    };
    let direction = if def.descending { "DESC" } else { "ASC" };
    let order = order
        .split(',')
        .map(|column| format!("{column} {direction}"))
        .collect::<Vec<_>>()
        .join(",");
    let mut values = Vec::new();
    let predicates = def
        .rules
        .iter()
        .map(|rule| predicate(rule, &mut values))
        .collect::<CoreResult<Vec<_>>>()?;
    let sql = format!(
        "SELECT r.release_id FROM releases r WHERE NOT r.is_hidden
        AND EXISTS(SELECT 1 FROM songs s WHERE s.release_id=r.release_id AND NOT s.is_hidden)
        AND ({}) ORDER BY {},r.release_id",
        predicates.join(if def.match_all { " AND " } else { " OR " }),
        order
    );
    c.prepare(&sql)
        .map_err(storage)?
        .query_map(params_from_iter(values), |row| row.get(0))
        .map_err(storage)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(storage)
}

fn item(
    c: &Connection,
    id: i64,
    release_id: Option<i64>,
    title: String,
    artist: String,
    artwork_id: Option<String>,
) -> CoreResult<AlbumCollectionItem> {
    let available = if let Some(release_id) = release_id {
        c.query_row(
            "SELECT EXISTS(SELECT 1 FROM releases r WHERE r.release_id=?1 AND NOT r.is_hidden
            AND EXISTS(SELECT 1 FROM songs s WHERE s.release_id=r.release_id AND NOT s.is_hidden))",
            [release_id],
            |r| r.get::<_, bool>(0),
        )
        .map_err(storage)?
    } else {
        false
    };
    let release = if available {
        Some(
            super::operations::get_release_by_id(c, &release_id.unwrap().to_string())
                .map_err(storage)
                .map(crate::infrastructure::sqlite::catalog_release::release_from_row)
                .map(crate::application::library::release_from_catalog)?,
        )
    } else {
        None
    };
    Ok(AlbumCollectionItem {
        id,
        title: release.as_ref().map(|r| r.title.clone()).unwrap_or(title),
        artist: release.as_ref().map(|r| r.artist.clone()).unwrap_or(artist),
        artwork_id: release
            .as_ref()
            .and_then(|r| r.artwork_id.clone())
            .or(artwork_id),
        release,
    })
}

fn read(c: &Connection, id: i64) -> CoreResult<AlbumCollectionPage> {
    let (name, description): (String, String) = c
        .query_row(
            "SELECT name,description FROM album_collections WHERE id=?1",
            [id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()
        .map_err(storage)?
        .ok_or_else(missing)?;
    let def = definition(c, id)?;
    let items = if let Some(def) = &def {
        super::classification::refresh(c)?;
        smart_ids(c, def)?
            .into_iter()
            .map(|id| item(c, id, Some(id), String::new(), String::new(), None))
            .collect::<CoreResult<Vec<_>>>()?
    } else {
        let rows = c.prepare("SELECT id,release_id,title,artist,artwork_id FROM album_collection_items WHERE collection_id=?1 ORDER BY position,id").map_err(storage)?
            .query_map([id], |r| Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?))).map_err(storage)?
            .collect::<Result<Vec<_>,_>>().map_err(storage)?;
        rows.into_iter()
            .map(|(id, r, t, a, art)| item(c, id, r, t, a, art))
            .collect::<CoreResult<Vec<_>>>()?
    };
    Ok(AlbumCollectionPage {
        collection: AlbumCollection {
            id,
            name,
            description,
            definition: def,
            album_count: items.len() as u64,
            artwork_id: items.iter().find_map(|i| i.artwork_id.clone()),
        },
        items,
    })
}

pub(crate) fn page(c: &Connection, id: i64) -> CoreResult<AlbumCollectionPage> {
    let tx = c.unchecked_transaction().map_err(storage)?;
    let result = read(&tx, id)?;
    tx.commit().map_err(storage)?;
    Ok(result)
}
pub(crate) fn list(c: &Connection) -> CoreResult<Vec<AlbumCollection>> {
    let tx = c.unchecked_transaction().map_err(storage)?;
    let ids = tx
        .prepare("SELECT id FROM album_collections ORDER BY name COLLATE NOCASE,id")
        .map_err(storage)?
        .query_map([], |r| r.get::<_, i64>(0))
        .map_err(storage)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(storage)?;
    let result = ids
        .into_iter()
        .map(|id| read(&tx, id).map(|page| page.collection))
        .collect::<CoreResult<Vec<_>>>()?;
    tx.commit().map_err(storage)?;
    Ok(result)
}
pub(crate) fn save(
    c: &Connection,
    id: Option<i64>,
    name: String,
    description: String,
    def: Option<AlbumCollectionDefinition>,
) -> CoreResult<AlbumCollection> {
    let name = name.trim();
    if name.is_empty()
        || name.chars().count() > 120
        || name.chars().any(char::is_control)
        || description.chars().count() > 2000
    {
        return Err(invalid("Invalid collection name or description"));
    }
    let tx = c.unchecked_transaction().map_err(storage)?;
    if let Some(def) = &def {
        super::classification::refresh(&tx)?;
        smart_ids(&tx, def)?;
    }
    let id = if let Some(id) = id {
        let old = read(&tx, id)?;
        if old.collection.definition.is_some() != def.is_some() {
            return Err(invalid("A collection cannot change its membership mode"));
        }
        tx.execute("UPDATE album_collections SET name=?2,description=?3,updated_at=CURRENT_TIMESTAMP WHERE id=?1",params![id,name,description]).map_err(storage)?;
        id
    } else {
        tx.execute(
            "INSERT INTO album_collections(name,description) VALUES(?1,?2)",
            params![name, description],
        )
        .map_err(storage)?;
        tx.last_insert_rowid()
    };
    if let Some(def) = def {
        tx.execute("INSERT INTO album_collection_rules(collection_id,definition) VALUES(?1,?2) ON CONFLICT(collection_id) DO UPDATE SET definition=excluded.definition",params![id,serde_json::to_string(&def).map_err(storage)?]).map_err(storage)?;
    }
    let result = read(&tx, id)?.collection;
    tx.commit().map_err(storage)?;
    Ok(result)
}
fn manual(c: &Connection, id: i64) -> CoreResult<()> {
    if !c
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM album_collections WHERE id=?1)",
            [id],
            |r| r.get::<_, bool>(0),
        )
        .map_err(storage)?
    {
        return Err(missing());
    }
    if definition(c, id)?.is_some() {
        return Err(invalid(
            "Smart collection membership is controlled by its rules",
        ));
    }
    Ok(())
}
pub(crate) fn add(c: &Connection, id: i64, release_id: i64) -> CoreResult<()> {
    let tx = c.unchecked_transaction().map_err(storage)?;
    manual(&tx, id)?;
    let release = item(&tx, 0, Some(release_id), String::new(), String::new(), None)?
        .release
        .ok_or_else(missing)?;
    tx.execute("INSERT OR IGNORE INTO album_collection_items(collection_id,release_id,title,artist,artwork_id,position)
        VALUES(?1,?2,?3,?4,?5,COALESCE((SELECT MAX(position)+1 FROM album_collection_items WHERE collection_id=?1),0))",
        params![id,release_id,release.title,release.artist,release.artwork_id]).map_err(storage)?;
    tx.commit().map_err(storage)
}
pub(crate) fn remove(c: &Connection, id: i64, item: i64) -> CoreResult<()> {
    manual(c, id)?;
    if c.execute(
        "DELETE FROM album_collection_items WHERE collection_id=?1 AND id=?2",
        params![id, item],
    )
    .map_err(storage)?
        == 0
    {
        return Err(missing());
    }
    Ok(())
}
pub(crate) fn reorder(c: &Connection, id: i64, items: Vec<i64>) -> CoreResult<()> {
    let tx = c.unchecked_transaction().map_err(storage)?;
    manual(&tx, id)?;
    let current = read(&tx, id)?
        .items
        .into_iter()
        .map(|i| i.id)
        .collect::<BTreeSet<_>>();
    let requested = items.iter().copied().collect::<BTreeSet<_>>();
    if current != requested || items.len() != requested.len() {
        return Err(invalid(
            "Ordering must contain every collection item exactly once",
        ));
    }
    for (position, item) in items.into_iter().enumerate() {
        tx.execute(
            "UPDATE album_collection_items SET position=?3 WHERE collection_id=?1 AND id=?2",
            params![id, item, position as i64],
        )
        .map_err(storage)?;
    }
    tx.commit().map_err(storage)
}
pub(crate) fn delete(c: &Connection, id: i64) -> CoreResult<()> {
    if c.execute("DELETE FROM album_collections WHERE id=?1", [id])
        .map_err(storage)?
        == 0
    {
        return Err(missing());
    }
    Ok(())
}
pub(crate) fn tracks(c: &Connection, id: i64) -> CoreResult<Vec<Track>> {
    let tx = c.unchecked_transaction().map_err(storage)?;
    let mut tracks = Vec::new();
    for item in read(&tx, id)?.items {
        if let Some(release) = item.release {
            let mut rows = super::operations::get_songs_by_release_id(&tx, &release.id.to_string())
                .map_err(storage)?;
            rows.retain(|s| !s.is_hidden);
            rows.sort_by_key(|s| (s.disc_number, s.track_number, s.song_id));
            tracks.extend(
                rows.into_iter()
                    .map(crate::infrastructure::sqlite::catalog_track::track_from_row)
                    .map(crate::application::library::track_from_catalog),
            );
        }
    }
    tx.commit().map_err(storage)?;
    Ok(tracks)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn setup() -> Connection {
        let mut c = Connection::open_in_memory().unwrap();
        super::super::operations::create_tables(&c).unwrap();
        crate::database::migrations::migrate_enrichment(&mut c).unwrap();
        c.execute("INSERT INTO artists(artist_id,name) VALUES(1,'Artist')", [])
            .unwrap();
        for id in 1..=3 {
            c.execute("INSERT INTO releases(release_id,title,artist_id,artist_name,release_date,rating_half_steps) VALUES(?1,?2,1,'Artist','2001-01-01',8)",params![id,format!("Album {id}")]).unwrap();
            for (n, disc, number) in [(1, 2, 1), (2, 1, 2), (3, 1, 1)] {
                c.execute("INSERT INTO songs(song_id,title,artist_id,artist_name,release_id,release_title,disc_number,track_number,duration,file_path) VALUES(?1,'Track',1,'Artist',?2,'Album',?3,?4,180,?5)",params![id*10+n,id,disc,number,format!("/{id}/{n}.flac")]).unwrap();
            }
        }
        c
    }
    fn smart(rules: Vec<SmartPlaylistRule>, all: bool) -> AlbumCollectionDefinition {
        AlbumCollectionDefinition {
            match_all: all,
            rules,
            sort_by: "title".into(),
            descending: false,
        }
    }
    fn rule(field: &str, value: &str) -> SmartPlaylistRule {
        SmartPlaylistRule {
            field: field.into(),
            comparison: "equals".into(),
            value: value.into(),
        }
    }
    #[test]
    fn manual_identity_order_atomic_reorder_unavailable_and_independent_membership() {
        let c = setup();
        let a = save(&c, None, "First".into(), "Description".into(), None).unwrap();
        let b = save(&c, None, "Second".into(), "".into(), None).unwrap();
        add(&c, a.id, 2).unwrap();
        add(&c, a.id, 1).unwrap();
        add(&c, a.id, 2).unwrap();
        add(&c, b.id, 2).unwrap();
        let p = page(&c, a.id).unwrap();
        assert_eq!(p.items.len(), 2);
        assert_eq!(
            tracks(&c, a.id)
                .unwrap()
                .iter()
                .map(|t| t.id)
                .collect::<Vec<_>>(),
            [23, 22, 21, 13, 12, 11]
        );
        assert!(reorder(&c, a.id, vec![p.items[0].id, p.items[0].id]).is_err());
        reorder(&c, a.id, vec![p.items[1].id, p.items[0].id]).unwrap();
        assert_eq!(
            page(&c, a.id).unwrap().items[0]
                .release
                .as_ref()
                .unwrap()
                .id,
            1
        );
        c.execute("DELETE FROM songs WHERE release_id=1", [])
            .unwrap();
        c.execute("DELETE FROM releases WHERE release_id=1", [])
            .unwrap();
        let p = page(&c, a.id).unwrap();
        assert!(p.items[0].release.is_none());
        assert_eq!(p.items[0].title, "Album 1");
        assert_eq!(tracks(&c, a.id).unwrap().len(), 3);
        remove(&c, a.id, p.items[0].id).unwrap();
        delete(&c, a.id).unwrap();
        assert_eq!(page(&c, b.id).unwrap().items.len(), 1);
        assert_eq!(
            c.query_row("SELECT COUNT(*) FROM playlists", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            0
        );
    }
    #[test]
    fn smart_album_and_track_tags_are_distinct_and_deleted_ids_do_not_broaden_results() {
        let c = setup();
        let tag = crate::database::user_tags::create(&c, "Trip".into()).unwrap();
        c.execute(
            "INSERT INTO release_user_tags(release_id,tag_id) VALUES(1,?1)",
            [tag.id],
        )
        .unwrap();
        c.execute(
            "INSERT INTO track_user_tags(song_id,tag_id) VALUES(21,?1)",
            [tag.id],
        )
        .unwrap();
        let a = save(
            &c,
            None,
            "Album tags".into(),
            "".into(),
            Some(smart(vec![rule("album_tag", &tag.id.to_string())], true)),
        )
        .unwrap();
        let b = save(
            &c,
            None,
            "Track tags".into(),
            "".into(),
            Some(smart(vec![rule("track_tag", &tag.id.to_string())], true)),
        )
        .unwrap();
        assert_eq!(
            page(&c, a.id).unwrap().items[0]
                .release
                .as_ref()
                .unwrap()
                .id,
            1
        );
        assert_eq!(
            page(&c, b.id).unwrap().items[0]
                .release
                .as_ref()
                .unwrap()
                .id,
            2
        );
        assert!(add(&c, a.id, 3).is_err());
        assert!(reorder(&c, b.id, vec![]).is_err());
        c.execute(
            "UPDATE user_tags SET name='Renamed' WHERE tag_id=?1",
            [tag.id],
        )
        .unwrap();
        assert_eq!(page(&c, a.id).unwrap().items.len(), 1);
        c.execute("DELETE FROM release_user_tags WHERE tag_id=?1", [tag.id])
            .unwrap();
        c.execute("DELETE FROM track_user_tags WHERE tag_id=?1", [tag.id])
            .unwrap();
        c.execute("DELETE FROM user_tags WHERE tag_id=?1", [tag.id])
            .unwrap();
        assert!(page(&c, a.id).unwrap().items.is_empty());
    }
    #[test]
    fn smart_classification_filters_dynamic_results_and_invalid_edits_rollback() {
        let c = setup();
        crate::database::classification::set(
            &c,
            ClassificationTarget::Release,
            1,
            ClassificationKind::Genre,
            Some(vec!["Jazz".into()]),
        )
        .unwrap();
        let terms = crate::database::classification::terms(&c).unwrap();
        let genre = terms.iter().find(|t| t.name == "Jazz").unwrap();
        let a = save(
            &c,
            None,
            "Jazz".into(),
            "".into(),
            Some(smart(vec![rule("genre", &genre.id.to_string())], true)),
        )
        .unwrap();
        assert_eq!(a.album_count, 1);
        crate::database::classification::set(
            &c,
            ClassificationTarget::Track,
            21,
            ClassificationKind::Genre,
            Some(vec!["Jazz".into()]),
        )
        .unwrap();
        assert_eq!(
            page(&c, a.id).unwrap().items.len(),
            1,
            "A genre present only on a track must not become an album genre rule match"
        );
        crate::database::classification::set(
            &c,
            ClassificationTarget::Release,
            2,
            ClassificationKind::Genre,
            Some(vec!["Jazz".into()]),
        )
        .unwrap();
        assert_eq!(page(&c, a.id).unwrap().items.len(), 2);
        let bad = smart(vec![rule("unknown", "ignored")], true);
        assert!(save(&c, Some(a.id), "Wrong".into(), "".into(), Some(bad)).is_err());
        assert_eq!(page(&c, a.id).unwrap().collection.name, "Jazz");
        c.execute("UPDATE releases SET is_hidden=1 WHERE release_id=1", [])
            .unwrap();
        assert_eq!(page(&c, a.id).unwrap().items.len(), 1);
        super::super::operations::create_tables(&c).unwrap();
        assert_eq!(list(&c).unwrap().len(), 1);
    }

    #[test]
    fn smart_artist_year_rating_listening_and_any_all_combinations() {
        let c = setup();
        let count = |rules: Vec<SmartPlaylistRule>, all| {
            let tx = c.unchecked_transaction().unwrap();
            let ids = smart_ids(&tx, &smart(rules, all)).unwrap();
            tx.commit().unwrap();
            ids.len()
        };
        let filter = |field: &str, comparison: &str, value: &str| SmartPlaylistRule {
            field: field.into(),
            comparison: comparison.into(),
            value: value.into(),
        };
        assert_eq!(count(vec![filter("artist", "contains", "Artist")], true), 3);
        assert_eq!(
            count(
                vec![filter("artist", "contains", "Artist' OR 1=1 --")],
                true
            ),
            0
        );
        assert_eq!(count(vec![filter("year", "at_least", "2002")], true), 0);
        assert_eq!(count(vec![filter("year", "at_most", "2000")], true), 0);
        assert_eq!(
            count(
                vec![
                    filter("year", "at_least", "2000"),
                    filter("year", "at_most", "2002")
                ],
                true
            ),
            3
        );
        assert_eq!(count(vec![filter("rating", "at_least", "9")], true), 0);
        assert_eq!(count(vec![rule("played", "false")], true), 3);
        c.execute("INSERT INTO play_history(song_id,played_at,play_duration) VALUES(11,'2001-01-01T00:00:00Z',180)",[]).unwrap();
        assert_eq!(count(vec![rule("played", "true")], true), 1);
        assert_eq!(count(vec![rule("played", "false")], true), 2);
        let rules = vec![rule("played", "true"), filter("rating", "at_least", "9")];
        assert_eq!(count(rules.clone(), true), 0);
        assert_eq!(count(rules, false), 1);
    }
}
