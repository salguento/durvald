//! Indexed offline projection. Raw metadata and explicit decisions remain separate.
use crate::api::*;
use icu_normalizer::ComposingNormalizer;
use rusqlite::{Connection, OptionalExtension, Transaction, TransactionBehavior, params};
use std::collections::BTreeSet;

fn storage(e: impl std::fmt::Display) -> CoreError {
    CoreError::Storage {
        message: format!("Classification: {e}"),
    }
}
fn invalid(message: &str) -> CoreError {
    CoreError::InvalidInput {
        message: message.into(),
    }
}
fn missing() -> CoreError {
    CoreError::NotFound {
        message: "Classification or library item not found".into(),
    }
}
fn key(s: &str) -> String {
    ComposingNormalizer::new_nfc()
        .normalize(
            &s.split_whitespace()
                .collect::<Vec<_>>()
                .join(" ")
                .to_lowercase(),
        )
        .into_owned()
}
fn names(values: Vec<String>) -> CoreResult<Vec<String>> {
    if values.len() > 100 {
        return Err(invalid("At most 100 classification terms per field"));
    }
    let mut seen = BTreeSet::new();
    let mut result = Vec::new();
    for name in values {
        let name = name.split_whitespace().collect::<Vec<_>>().join(" ");
        if name.is_empty() || name.chars().count() > 100 || name.chars().any(char::is_control) {
            return Err(invalid(
                "Term names must have 1 to 100 characters and no control characters",
            ));
        }
        if seen.insert(key(&name)) {
            result.push(name);
        }
    }
    Ok(result)
}
fn vocabulary(k: ClassificationKind) -> (&'static str, &'static str) {
    match k {
        ClassificationKind::Genre => ("genres", "genre"),
        ClassificationKind::Style => ("styles", "style"),
    }
}
fn entity(t: ClassificationTarget) -> CoreResult<(&'static str, &'static str, &'static str)> {
    match t {
        ClassificationTarget::Release => Ok(("release", "release_id", "releases")),
        ClassificationTarget::Track => Ok(("track", "song_id", "songs")),
        ClassificationTarget::Artist => Err(invalid(
            "Artist classification is an aggregate of library content",
        )),
    }
}

pub(crate) fn migrate(c: &Connection) -> rusqlite::Result<()> {
    let tx = Transaction::new_unchecked(c, TransactionBehavior::Immediate)?;
    tx.execute_batch("CREATE TABLE IF NOT EXISTS track_file_classification(song_id INTEGER PRIMARY KEY REFERENCES songs(song_id) ON DELETE CASCADE,genres TEXT NOT NULL CHECK(json_valid(genres)),styles TEXT NOT NULL CHECK(json_valid(styles)));
        CREATE TABLE IF NOT EXISTS styles(style_id INTEGER PRIMARY KEY,name TEXT NOT NULL,description TEXT);
        CREATE TABLE IF NOT EXISTS classification_state(id INTEGER PRIMARY KEY CHECK(id=1),dirty INTEGER NOT NULL);
        INSERT OR IGNORE INTO classification_state VALUES(1,1);
        CREATE TABLE IF NOT EXISTS style_genres(style_id INTEGER NOT NULL REFERENCES styles(style_id) ON DELETE CASCADE,
            genre_id INTEGER NOT NULL REFERENCES genres(genre_id) ON DELETE CASCADE,origin TEXT NOT NULL DEFAULT 'manual',PRIMARY KEY(style_id,genre_id));
        CREATE INDEX IF NOT EXISTS idx_style_genres_reverse ON style_genres(genre_id,style_id);")?;
    for (table, prefix) in [("genres", "genre"), ("styles", "style")] {
        tx.execute_batch(&format!("CREATE TABLE IF NOT EXISTS {prefix}_keys(normalized_name TEXT PRIMARY KEY,{prefix}_id INTEGER NOT NULL REFERENCES {table}({prefix}_id) ON DELETE CASCADE);"))?;
        let legacy = tx
            .prepare(&format!(
                "SELECT {prefix}_id,name FROM {table} WHERE name IS NOT NULL ORDER BY {prefix}_id"
            ))?
            .query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)))?
            .collect::<Result<Vec<_>, _>>()?;
        // Preserve every legacy ID and spelling. New lookups use the oldest exact normalized key.
        for (id, name) in legacy {
            tx.execute(
                &format!("INSERT OR IGNORE INTO {prefix}_keys VALUES(?1,?2)"),
                params![key(&name), id],
            )?;
        }
        for (scope, id, target) in [
            ("track", "song_id", "songs"),
            ("release", "release_id", "releases"),
        ] {
            tx.execute_batch(&format!("CREATE TABLE IF NOT EXISTS {scope}_{prefix}_decisions({id} INTEGER PRIMARY KEY REFERENCES {target}({id}) ON DELETE CASCADE,names TEXT NOT NULL CHECK(json_valid(names)));
                CREATE TABLE IF NOT EXISTS {scope}_{table}({id} INTEGER NOT NULL REFERENCES {target}({id}) ON DELETE CASCADE,{prefix}_id INTEGER NOT NULL REFERENCES {table}({prefix}_id) ON DELETE CASCADE,origin TEXT NOT NULL,PRIMARY KEY({id},{prefix}_id));
                CREATE INDEX IF NOT EXISTS idx_{scope}_{table}_reverse ON {scope}_{table}({prefix}_id,{id});"))?;
            tx.execute_batch(&format!("CREATE TABLE IF NOT EXISTS missing_track_{prefix}_decisions(missing_id INTEGER PRIMARY KEY REFERENCES missing_tracks(missing_id) ON DELETE CASCADE,names TEXT NOT NULL CHECK(json_valid(names)));"))?;
            for op in ["INSERT", "UPDATE", "DELETE"] {
                tx.execute_batch(&format!("CREATE TRIGGER IF NOT EXISTS classification_{scope}_{prefix}_{op} AFTER {op} ON {scope}_{prefix}_decisions BEGIN UPDATE classification_state SET dirty=1 WHERE id=1; END;"))?;
            }
        }
    }
    for table in [
        "track_metadata_cache",
        "track_file_classification",
        "local_release_metadata",
        "songs",
        "releases",
    ] {
        for (op, update) in [
            ("INSERT", ""),
            ("DELETE", ""),
            (
                "UPDATE",
                match table {
                    "songs" => " OF release_id,is_hidden,artist_id",
                    "releases" => " OF is_hidden,artist_id",
                    _ => "",
                },
            ),
        ] {
            tx.execute_batch(&format!("CREATE TRIGGER IF NOT EXISTS classification_{table}_{op} AFTER {op}{update} ON {table} BEGIN UPDATE classification_state SET dirty=1 WHERE id=1; END;"))?;
        }
    }
    tx.commit()
}
fn ensure_term(c: &Connection, k: ClassificationKind, name: &str) -> CoreResult<i64> {
    let (table, p) = vocabulary(k);
    let normalized = key(name);
    if let Some(id) = c
        .query_row(
            &format!("SELECT {p}_id FROM {p}_keys WHERE normalized_name=?1"),
            [&normalized],
            |r| r.get(0),
        )
        .optional()
        .map_err(storage)?
    {
        return Ok(id);
    }
    c.execute(&format!("INSERT INTO {table}(name) VALUES(?1)"), [name])
        .map_err(storage)?;
    let id = c.last_insert_rowid();
    c.execute(
        &format!("INSERT INTO {p}_keys VALUES(?1,?2)"),
        params![normalized, id],
    )
    .map_err(storage)?;
    Ok(id)
}
fn insert(
    c: &Connection,
    k: ClassificationKind,
    scope: &str,
    id: i64,
    values: Vec<String>,
    origin: &str,
) -> CoreResult<()> {
    let (table, _) = vocabulary(k);
    for value in values {
        if let Ok(values) = names(vec![value]) {
            for name in values {
                let term = ensure_term(c, k, &name)?;
                c.execute(
                    &format!("INSERT OR IGNORE INTO {scope}_{table} VALUES(?1,?2,?3)"),
                    params![id, term, origin],
                )
                .map_err(storage)?;
            }
        }
    }
    Ok(())
}
/// Refresh the projection inside the caller's existing transaction.
pub(crate) fn refresh(c: &Connection) -> CoreResult<()> {
    let dirty: bool = c
        .query_row(
            "SELECT dirty FROM classification_state WHERE id=1",
            [],
            |r| r.get(0),
        )
        .map_err(storage)?;
    if !dirty {
        return Ok(());
    }
    for k in [ClassificationKind::Genre, ClassificationKind::Style] {
        let (table, p) = vocabulary(k);
        c.execute(&format!("DELETE FROM track_{table}"), [])
            .map_err(storage)?;
        c.execute(&format!("DELETE FROM release_{table}"), [])
            .map_err(storage)?;
        for (scope, id) in [("release", "release_id"), ("track", "song_id")] {
            let decisions = c
                .prepare(&format!("SELECT {id},names FROM {scope}_{p}_decisions"))
                .map_err(storage)?
                .query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)))
                .map_err(storage)?
                .collect::<Result<Vec<_>, _>>()
                .map_err(storage)?;
            for (id, json) in decisions {
                insert(
                    c,
                    k,
                    scope,
                    id,
                    serde_json::from_str(&json).map_err(storage)?,
                    "manual",
                )?;
            }
        }
        if k == ClassificationKind::Genre {
            let rows=c.prepare("SELECT m.release_id,m.genres FROM local_release_metadata m WHERE NOT EXISTS(SELECT 1 FROM release_genre_decisions d WHERE d.release_id=m.release_id)").map_err(storage)?.query_map([],|r|Ok((r.get::<_,i64>(0)?,r.get::<_,String>(1)?))).map_err(storage)?.collect::<Result<Vec<_>,_>>().map_err(storage)?;
            for (id, json) in rows {
                insert(
                    c,
                    k,
                    "release",
                    id,
                    serde_json::from_str(&json).map_err(storage)?,
                    "legacy_release",
                )?;
            }
        }
        let rows=c.prepare(&format!("SELECT s.song_id,c.payload,c.is_override,f.genres,f.styles FROM songs s
            LEFT JOIN track_metadata_cache c USING(song_id) LEFT JOIN track_file_classification f USING(song_id)
            WHERE NOT EXISTS(SELECT 1 FROM track_{p}_decisions d WHERE d.song_id=s.song_id)")).map_err(storage)?
            .query_map([],|r|Ok((r.get::<_,i64>(0)?,r.get::<_,Option<String>>(1)?,r.get::<_,Option<bool>>(2)?,r.get::<_,Option<String>>(3)?,r.get::<_,Option<String>>(4)?)))
            .map_err(storage)?.collect::<Result<Vec<_>,_>>().map_err(storage)?;
        for (id, payload, edited, genres, styles) in rows {
            let cached: serde_json::Value = payload
                .as_deref()
                .and_then(|s| serde_json::from_str(s).ok())
                .unwrap_or_default();
            let values: Vec<String> = if k == ClassificationKind::Genre && edited == Some(true) {
                cached
                    .get("genre")
                    .and_then(|v| v.as_str())
                    .filter(|s| !s.trim().is_empty())
                    .map(str::to_owned)
                    .into_iter()
                    .collect()
            } else {
                let file = if k == ClassificationKind::Genre {
                    genres
                } else {
                    styles
                };
                match file {
                    Some(json) => serde_json::from_str(&json).map_err(storage)?,
                    None if k == ClassificationKind::Genre => cached
                        .get("genre")
                        .and_then(|v| v.as_str())
                        .filter(|s| !s.trim().is_empty())
                        .map(str::to_owned)
                        .into_iter()
                        .collect(),
                    None => Vec::new(),
                }
            };
            insert(
                c,
                k,
                "track",
                id,
                values,
                if k == ClassificationKind::Genre && edited == Some(true) {
                    "metadata_edit"
                } else {
                    "file"
                },
            )?;
        }
        // Inherit only in the complete absence of direct evidence or an explicit decision.
        c.execute(&format!("INSERT OR IGNORE INTO track_{table}
            SELECT s.song_id,r.{p}_id,'album' FROM songs s JOIN release_{table} r USING(release_id)
            WHERE NOT EXISTS(SELECT 1 FROM track_{table} t WHERE t.song_id=s.song_id)
            AND NOT EXISTS(SELECT 1 FROM track_{p}_decisions d WHERE d.song_id=s.song_id)
            AND ('{p}'!='genre' OR NOT EXISTS(SELECT 1 FROM track_metadata_cache m WHERE m.song_id=s.song_id AND m.is_override=1))"),[]).map_err(storage)?;
        // Discovery membership is distinct from classifying the whole release.
        c.execute(&format!("INSERT OR IGNORE INTO release_{table}
            SELECT s.release_id,t.{p}_id,'contains_tracks' FROM songs s JOIN track_{table} t USING(song_id)
            WHERE NOT s.is_hidden"),[]).map_err(storage)?;
    }
    c.execute("UPDATE classification_state SET dirty=0 WHERE id=1", [])
        .map_err(storage)?;
    Ok(())
}
fn transaction<T>(c: &Connection, f: impl FnOnce(&Connection) -> CoreResult<T>) -> CoreResult<T> {
    let tx = Transaction::new_unchecked(c, TransactionBehavior::Immediate).map_err(storage)?;
    refresh(&tx)?;
    let result = f(&tx)?;
    tx.commit().map_err(storage)?;
    Ok(result)
}
fn term(c: &Connection, k: ClassificationKind, id: i64) -> CoreResult<ClassificationTerm> {
    let (table, p) = vocabulary(k);
    if id == 0 {
        let (releases,tracks,artists):(u64,u64,u64)=c.query_row(&format!("SELECT
            (SELECT COUNT(*) FROM releases r WHERE NOT r.is_hidden AND NOT EXISTS(SELECT 1 FROM release_{table} x WHERE x.release_id=r.release_id) AND EXISTS(SELECT 1 FROM songs s WHERE s.release_id=r.release_id AND NOT s.is_hidden)),
            (SELECT COUNT(*) FROM songs s JOIN releases r USING(release_id) WHERE NOT s.is_hidden AND NOT r.is_hidden AND NOT EXISTS(SELECT 1 FROM track_{table} x WHERE x.song_id=s.song_id)),
            (SELECT COUNT(DISTINCT r.artist_id) FROM releases r WHERE NOT r.is_hidden AND NOT EXISTS(SELECT 1 FROM release_{table} x WHERE x.release_id=r.release_id) AND EXISTS(SELECT 1 FROM songs s WHERE s.release_id=r.release_id AND NOT s.is_hidden))"),[],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?))).map_err(storage)?;
        return Ok(ClassificationTerm {
            id,
            kind: k,
            name: if k == ClassificationKind::Genre {
                "Sem gênero"
            } else {
                "Sem estilo"
            }
            .into(),
            description: None,
            release_count: releases,
            track_count: tracks,
            artist_count: artists,
            artwork_id: None,
        });
    }
    c.query_row(&format!("SELECT v.name,v.description,
        (SELECT COUNT(*) FROM release_{table} x JOIN releases r USING(release_id) WHERE x.{p}_id=v.{p}_id AND NOT r.is_hidden AND EXISTS(SELECT 1 FROM songs s WHERE s.release_id=r.release_id AND NOT s.is_hidden)),
        (SELECT COUNT(*) FROM track_{table} x JOIN songs s USING(song_id) JOIN releases r USING(release_id) WHERE x.{p}_id=v.{p}_id AND NOT s.is_hidden AND NOT r.is_hidden),
        (SELECT COUNT(DISTINCT r.artist_id) FROM release_{table} x JOIN releases r USING(release_id) WHERE x.{p}_id=v.{p}_id AND NOT r.is_hidden AND EXISTS(SELECT 1 FROM songs s WHERE s.release_id=r.release_id AND NOT s.is_hidden)),
        (SELECT NULLIF(r.artwork,'') FROM release_{table} x JOIN releases r USING(release_id) WHERE x.{p}_id=v.{p}_id AND NOT r.is_hidden AND NULLIF(r.artwork,'') IS NOT NULL ORDER BY r.release_id LIMIT 1)
        FROM {table} v WHERE v.{p}_id=?1"),[id],|r|Ok(ClassificationTerm{id,kind:k,name:r.get(0)?,description:r.get(1)?,release_count:r.get(2)?,track_count:r.get(3)?,artist_count:r.get(4)?,artwork_id:r.get(5)?})).optional().map_err(storage)?.ok_or_else(missing)
}
fn ids(c: &Connection, sql: &str, values: impl rusqlite::Params) -> CoreResult<Vec<i64>> {
    c.prepare(sql)
        .map_err(storage)?
        .query_map(values, |r| r.get(0))
        .map_err(storage)?
        .collect::<Result<_, _>>()
        .map_err(storage)
}
pub(crate) fn terms(c: &Connection) -> CoreResult<Vec<ClassificationTerm>> {
    transaction(c, |c| {
        let mut result = Vec::new();
        for k in [ClassificationKind::Genre, ClassificationKind::Style] {
            let (t, p) = vocabulary(k);
            for id in ids(c, &format!("SELECT {p}_id FROM {t} ORDER BY {p}_id"), [])? {
                let t = term(c, k, id)?;
                if t.release_count + t.track_count > 0 {
                    result.push(t);
                }
            }
        }
        result.sort_by_key(|t| (key(&t.name), t.id));
        Ok(result)
    })
}
pub(crate) fn links(
    c: &Connection,
    target: ClassificationTarget,
    id: i64,
) -> CoreResult<Vec<ClassificationLink>> {
    transaction(c, |c| {
        let mut result = Vec::new();
        for k in [ClassificationKind::Genre, ClassificationKind::Style] {
            let (table, p) = vocabulary(k);
            let sql = match target {
                ClassificationTarget::Release => {
                    format!("SELECT {p}_id,origin FROM release_{table} WHERE release_id=?1")
                }
                ClassificationTarget::Track => {
                    format!("SELECT {p}_id,origin FROM track_{table} WHERE song_id=?1")
                }
                ClassificationTarget::Artist => format!(
                    "SELECT DISTINCT t.{p}_id,'aggregate' FROM release_{table} t JOIN releases r USING(release_id) WHERE r.artist_id=?1 AND NOT r.is_hidden AND EXISTS(SELECT 1 FROM songs s WHERE s.release_id=r.release_id AND NOT s.is_hidden)"
                ),
            };
            let rows = c
                .prepare(&sql)
                .map_err(storage)?
                .query_map([id], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)))
                .map_err(storage)?
                .collect::<Result<Vec<_>, _>>()
                .map_err(storage)?;
            for (id, origin) in rows {
                result.push(ClassificationLink {
                    term: term(c, k, id)?,
                    origin,
                });
            }
        }
        result.sort_by_key(|l| key(&l.term.name));
        Ok(result)
    })
}
fn matches(query: &str, title: &str, artist: &str) -> bool {
    let q = key(query);
    q.is_empty() || key(title).contains(&q) || key(artist).contains(&q)
}
fn release(c: &Connection, id: i64) -> CoreResult<Release> {
    super::operations::get_release_by_id(c, &id.to_string())
        .map(crate::infrastructure::sqlite::catalog_release::release_from_row)
        .map(crate::application::library::release_from_catalog)
        .map_err(storage)
}
fn track(c: &Connection, id: i64) -> CoreResult<Track> {
    super::operations::get_song_by_id(c, &id.to_string())
        .map_err(storage)?
        .into_iter()
        .next()
        .map(crate::infrastructure::sqlite::catalog_track::track_from_row)
        .map(crate::application::library::track_from_catalog)
        .ok_or_else(missing)
}
fn track_ids(c: &Connection, k: ClassificationKind, id: i64, query: &str) -> CoreResult<Vec<i64>> {
    let (t, p) = vocabulary(k);
    let rows=c.prepare(&format!("SELECT s.song_id,s.title,s.artist_name FROM songs s JOIN releases r USING(release_id) WHERE ((?1=0 AND NOT EXISTS(SELECT 1 FROM track_{t} x WHERE x.song_id=s.song_id)) OR EXISTS(SELECT 1 FROM track_{t} x WHERE x.song_id=s.song_id AND x.{p}_id=?1)) AND NOT s.is_hidden AND NOT r.is_hidden ORDER BY r.artist_name COLLATE NOCASE,r.title COLLATE NOCASE,s.disc_number,s.track_number,s.song_id")).map_err(storage)?.query_map([id],|r|Ok((r.get::<_,i64>(0)?,r.get::<_,String>(1)?,r.get::<_,String>(2)?))).map_err(storage)?.collect::<Result<Vec<_>,_>>().map_err(storage)?;
    Ok(rows
        .into_iter()
        .filter(|(_, title, artist)| matches(query, title, artist))
        .map(|r| r.0)
        .collect())
}
pub(crate) fn tracks(
    c: &Connection,
    k: ClassificationKind,
    id: i64,
    query: String,
) -> CoreResult<Vec<Track>> {
    transaction(c, |c| {
        term(c, k, id)?;
        let ids = track_ids(c, k, id, &query)?;
        let mut resolved = std::collections::HashMap::new();
        for chunk in ids.chunks(400) {
            let rows = super::operations::get_songs_by_ids(
                c,
                &chunk.iter().map(|id| *id as u64).collect::<Vec<_>>(),
            )
            .map_err(storage)?;
            for row in rows {
                let track = crate::application::library::track_from_catalog(
                    crate::infrastructure::sqlite::catalog_track::track_from_row(row),
                );
                resolved.insert(track.id, track);
            }
        }
        ids.into_iter()
            .map(|id| resolved.remove(&id).ok_or_else(missing))
            .collect()
    })
}
pub(crate) fn page(
    c: &Connection,
    k: ClassificationKind,
    id: i64,
    query: String,
    offset: u64,
    size: u64,
) -> CoreResult<ClassificationPage> {
    transaction(c, |c| {
        if size == 0 || size > 200 || offset > i64::MAX as u64 {
            return Err(invalid("Page size must be between 1 and 200"));
        }
        let selected_term = term(c, k, id)?;
        let (table, p) = vocabulary(k);
        let mut related_terms = Vec::new();
        let related = if k == ClassificationKind::Genre {
            ids(
                c,
                "SELECT style_id FROM style_genres WHERE genre_id=?1 ORDER BY style_id",
                [id],
            )?
        } else {
            ids(
                c,
                "SELECT genre_id FROM style_genres WHERE style_id=?1 ORDER BY genre_id",
                [id],
            )?
        };
        for id in related {
            let t = term(
                c,
                if k == ClassificationKind::Genre {
                    ClassificationKind::Style
                } else {
                    ClassificationKind::Genre
                },
                id,
            )?;
            if t.release_count + t.track_count > 0 {
                related_terms.push(t);
            }
        }
        let rows=c.prepare(&format!("SELECT r.release_id,r.title,r.artist_name,r.artist_id,COALESCE((SELECT origin FROM release_{table} x WHERE x.release_id=r.release_id AND x.{p}_id=?1),'unclassified'),r.rating_half_steps,r.suggest_less FROM releases r WHERE ((?1=0 AND NOT EXISTS(SELECT 1 FROM release_{table} x WHERE x.release_id=r.release_id)) OR EXISTS(SELECT 1 FROM release_{table} x WHERE x.release_id=r.release_id AND x.{p}_id=?1)) AND NOT r.is_hidden AND EXISTS(SELECT 1 FROM songs s WHERE s.release_id=r.release_id AND NOT s.is_hidden) ORDER BY r.title COLLATE NOCASE,r.release_id")).map_err(storage)?.query_map([id],|r|Ok((r.get::<_,i64>(0)?,r.get::<_,String>(1)?,r.get::<_,String>(2)?,r.get::<_,i64>(3)?,r.get::<_,String>(4)?,r.get::<_,Option<u8>>(5)?,r.get::<_,bool>(6)?))).map_err(storage)?.collect::<Result<Vec<_>,_>>().map_err(storage)?;
        let mut artist_ids = BTreeSet::new();
        let mut release_ids = Vec::new();
        let mut contains_tracks_release_ids = Vec::new();
        let mut rated = Vec::new();
        for (id, title, artist, aid, origin, rating, suggest_less) in rows {
            if matches(&query, &artist, "") {
                artist_ids.insert(aid);
            }
            if matches(&query, &title, &artist) {
                release_ids.push(id);
                if origin == "contains_tracks" {
                    contains_tracks_release_ids.push(id);
                }
            }
            if !suggest_less && rating.is_some_and(|n| n >= 8) {
                rated.push((id, rating));
            }
        }
        rated.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
        rated.truncate(20);
        let rated = rated
            .into_iter()
            .map(|r| release(c, r.0))
            .collect::<CoreResult<Vec<_>>>()?;
        let track_ids = track_ids(c, k, id, &query)?;
        let total_tracks = track_ids.len() as u64;
        let total_releases = release_ids.len() as u64;
        let total_artists = artist_ids.len() as u64;
        let releases = release_ids
            .into_iter()
            .skip(offset as usize)
            .take(size as usize)
            .map(|id| release(c, id))
            .collect::<CoreResult<_>>()?;
        let tracks = track_ids
            .into_iter()
            .skip(offset as usize)
            .take(size as usize)
            .map(|id| track(c, id))
            .collect::<CoreResult<_>>()?;
        let mut artists = artist_ids
            .into_iter()
            .map(|id| {
                let a = super::operations::get_artist_by_id(c, &id.to_string()).map_err(storage)?;
                Ok(Artist {
                    id: a.artist_id as i64,
                    name: a.artist_name,
                })
            })
            .collect::<CoreResult<Vec<_>>>()?;
        artists.sort_by_key(|a| (key(&a.name), a.id));
        let artists = artists
            .into_iter()
            .skip(offset as usize)
            .take(size as usize)
            .collect();
        Ok(ClassificationPage {
            term: selected_term,
            related_terms,
            releases,
            tracks,
            artists,
            total_releases,
            total_tracks,
            total_artists,
            well_rated: rated,
            contains_tracks_release_ids,
        })
    })
}
pub(crate) fn set(
    c: &Connection,
    target: ClassificationTarget,
    id: i64,
    k: ClassificationKind,
    values: Option<Vec<String>>,
) -> CoreResult<()> {
    let (scope, field, table) = entity(target)?;
    let (_, p) = vocabulary(k);
    let values = values.map(names).transpose()?;
    let tx = Transaction::new_unchecked(c, TransactionBehavior::Immediate).map_err(storage)?;
    if !tx
        .query_row(
            &format!("SELECT EXISTS(SELECT 1 FROM {table} WHERE {field}=?1)"),
            [id],
            |r| r.get::<_, bool>(0),
        )
        .map_err(storage)?
    {
        return Err(missing());
    }
    match values {
        Some(values) => {
            tx.execute(&format!("INSERT INTO {scope}_{p}_decisions VALUES(?1,?2) ON CONFLICT({field}) DO UPDATE SET names=excluded.names"),params![id,serde_json::to_string(&values).map_err(storage)?]).map_err(storage)?;
        }
        None => {
            tx.execute(
                &format!("DELETE FROM {scope}_{p}_decisions WHERE {field}=?1"),
                [id],
            )
            .map_err(storage)?;
        }
    }
    tx.commit().map_err(storage)
}
pub(crate) fn set_relations(c: &Connection, style_id: i64, genre_ids: Vec<i64>) -> CoreResult<()> {
    transaction(c, |c| {
        term(c, ClassificationKind::Style, style_id)?;
        if genre_ids.len() > 100 {
            return Err(invalid("At most 100 related genres"));
        }
        for id in &genre_ids {
            term(c, ClassificationKind::Genre, *id)?;
        }
        c.execute("DELETE FROM style_genres WHERE style_id=?1", [style_id])
            .map_err(storage)?;
        for id in genre_ids.into_iter().collect::<BTreeSet<_>>() {
            c.execute(
                "INSERT INTO style_genres(style_id,genre_id) VALUES(?1,?2)",
                params![style_id, id],
            )
            .map_err(storage)?;
        }
        Ok(())
    })
}

/// Separate file evidence preserves multiple values without punctuation heuristics.
pub(crate) fn cache_file(
    c: &Connection,
    path: &str,
    genres: &[String],
    styles: &[String],
) -> rusqlite::Result<()> {
    c.execute("INSERT INTO track_file_classification(song_id,genres,styles) SELECT song_id,?2,?3 FROM songs WHERE file_path=?1
        ON CONFLICT(song_id) DO UPDATE SET genres=excluded.genres,styles=excluded.styles",
        params![path,serde_json::to_string(genres).unwrap(),serde_json::to_string(styles).unwrap()])?;
    Ok(())
}
/// Archive decisions with the missing identity; never attach by a title guess.
pub(crate) fn archive(c: &Connection) -> rusqlite::Result<()> {
    for p in ["genre", "style"] {
        c.execute(&format!("INSERT OR IGNORE INTO missing_track_{p}_decisions SELECT m.missing_id,d.names FROM missing_tracks m
            JOIN songs s ON s.song_id=m.original_song_id AND s.file_path=m.file_path JOIN track_{p}_decisions d USING(song_id)"),[])?;
    }
    Ok(())
}
pub(crate) fn restore(
    c: &Connection,
    source: i64,
    target: i64,
    archived: bool,
) -> rusqlite::Result<()> {
    for p in ["genre", "style"] {
        let table = if archived {
            format!("missing_track_{p}_decisions")
        } else {
            format!("track_{p}_decisions")
        };
        let field = if archived { "missing_id" } else { "song_id" };
        // An existing explicit target decision wins, including its empty exclusion.
        c.execute(&format!("INSERT OR IGNORE INTO track_{p}_decisions SELECT ?2,names FROM {table} WHERE {field}=?1"),params![source,target])?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn db() -> Connection {
        let c = Connection::open_in_memory().unwrap();
        c.execute_batch("PRAGMA foreign_keys=ON").unwrap();
        crate::database::operations::create_tables(&c).unwrap();
        c.execute_batch("INSERT INTO artists(artist_id,name) VALUES(1,'Artist'),(2,'Other');
            INSERT INTO releases(release_id,title,artist_id,artist_name,rating_half_steps) VALUES(1,'Alpha',1,'Artist',9),(2,'Beta',2,'Other',10);
            INSERT INTO songs(song_id,title,artist_id,artist_name,release_id,release_title,file_path,track_number,disc_number,duration) VALUES(1,'One',1,'Artist',1,'Alpha','/one',1,1,180),(2,'Two',1,'Artist',1,'Alpha','/two',2,1,180),(3,'Three',2,'Other',2,'Beta','/three',1,1,180);
            INSERT INTO track_metadata_cache(song_id,payload) VALUES(1,'{\"genre\":\"  Rock / Pop  \"}'),(2,'{\"genre\":\"rock / pop\"}'),(3,'{\"genre\":\"Jazz\"}');").unwrap();
        c
    }
    #[test]
    fn indexed_large_library_pages_and_playback_do_not_stop_at_first_page() {
        let c = db();
        let tx = c.unchecked_transaction().unwrap();
        for id in 4..=5003 {
            tx.execute("INSERT INTO songs(song_id,title,artist_id,artist_name,release_id,release_title,file_path,track_number,disc_number,duration) VALUES(?1,'Large',1,'Artist',1,'Alpha',?2,1,1,180)",params![id,format!("/{id}")]).unwrap();
        }
        tx.commit().unwrap();
        set(
            &c,
            ClassificationTarget::Release,
            1,
            ClassificationKind::Genre,
            Some(vec!["Electronic".into()]),
        )
        .unwrap();
        let start = std::time::Instant::now();
        let t = terms(&c)
            .unwrap()
            .into_iter()
            .find(|t| t.name == "Electronic")
            .unwrap();
        assert_eq!(t.track_count, 5000);
        let p = page(&c, t.kind, t.id, "".into(), 100, 100).unwrap();
        assert_eq!(p.tracks.len(), 100);
        assert_eq!(p.total_tracks, 5000);
        assert_eq!(tracks(&c, t.kind, t.id, "".into()).unwrap().len(), 5000);
        let plan: String = c
            .query_row(
                "EXPLAIN QUERY PLAN SELECT song_id FROM track_genres WHERE genre_id=?1",
                [t.id],
                |r| r.get(3),
            )
            .unwrap();
        assert!(plan.contains("idx_track_genres_reverse"));
        eprintln!("classification 5003-track fixture: {:?}", start.elapsed());
    }
    #[test]
    fn multivalue_file_styles_inheritance_and_empty_metadata_override() {
        let c = db();
        cache_file(
            &c,
            "/one",
            &["Jazz".into(), "Soul".into()],
            &["Bossa Nova".into()],
        )
        .unwrap();
        let links = links(&c, ClassificationTarget::Track, 1).unwrap();
        assert_eq!(links.len(), 3);
        set(
            &c,
            ClassificationTarget::Release,
            1,
            ClassificationKind::Genre,
            Some(vec!["Electronic".into(), "Rock".into()]),
        )
        .unwrap();
        c.execute("DELETE FROM track_metadata_cache WHERE song_id=2", [])
            .unwrap();
        assert_eq!(
            super::links(&c, ClassificationTarget::Track, 2)
                .unwrap()
                .iter()
                .filter(|l| l.origin == "album")
                .count(),
            2
        );
        c.execute(
            "INSERT INTO track_metadata_cache VALUES(2,'{\"genre\":\"\"}',1)",
            [],
        )
        .unwrap();
        assert!(
            super::links(&c, ClassificationTarget::Track, 2)
                .unwrap()
                .iter()
                .all(|l| l.term.kind != ClassificationKind::Genre)
        );
        assert_eq!(
            page(&c, ClassificationKind::Genre, 0, "".into(), 0, 20)
                .unwrap()
                .total_tracks,
            1
        );
        assert!(!terms(&c).unwrap().iter().any(|t| t.id == 0));
    }
    #[test]
    fn normalized_ids_legacy_and_punctuation_survive_rebuild_and_migration() {
        let c = db();
        c.execute(
            "INSERT INTO genres(genre_id,name,description) VALUES(42,'Rock / Pop','Preserved')",
            [],
        )
        .unwrap();
        migrate(&c).unwrap();
        migrate(&c).unwrap();
        let list = terms(&c).unwrap();
        assert_eq!(list.len(), 2);
        let rock = list.iter().find(|t| t.id == 42).unwrap();
        assert_eq!(rock.track_count, 2);
        assert_eq!(rock.release_count, 1);
        assert_eq!(rock.artist_count, 1);
        assert_eq!(rock.description.as_deref(), Some("Preserved"));
        assert_eq!(key(" E\u{301}LETRÔNICA  "), key("életrônica"));
        c.execute(
            "UPDATE track_metadata_cache SET payload='{\"genre\":\"ROCK / POP\"}' WHERE song_id=1",
            [],
        )
        .unwrap();
        assert!(terms(&c).unwrap().iter().any(|t| t.id == 42));
    }
    #[test]
    fn direct_inherited_contains_and_manual_exclusion_are_distinct() {
        let c = db();
        set(
            &c,
            ClassificationTarget::Release,
            1,
            ClassificationKind::Genre,
            Some(vec!["Electronic".into()]),
        )
        .unwrap();
        let one = links(&c, ClassificationTarget::Track, 1).unwrap();
        assert_eq!(one[0].origin, "file");
        assert_eq!(one[0].term.name, "Rock / Pop");
        let album = links(&c, ClassificationTarget::Release, 1).unwrap();
        assert!(album.iter().any(|l| l.origin == "manual"));
        assert!(album.iter().any(|l| l.origin == "contains_tracks"));
        c.execute("DELETE FROM track_metadata_cache WHERE song_id=2", [])
            .unwrap();
        let two = links(&c, ClassificationTarget::Track, 2).unwrap();
        assert_eq!(two[0].origin, "album");
        set(
            &c,
            ClassificationTarget::Track,
            2,
            ClassificationKind::Genre,
            Some(vec![]),
        )
        .unwrap();
        assert!(
            links(&c, ClassificationTarget::Track, 2)
                .unwrap()
                .is_empty()
        );
        c.execute(
            "INSERT INTO track_metadata_cache(song_id,payload) VALUES(2,'{\"genre\":\"Jazz\"}')",
            [],
        )
        .unwrap();
        assert!(
            links(&c, ClassificationTarget::Track, 2)
                .unwrap()
                .is_empty()
        );
        set(
            &c,
            ClassificationTarget::Track,
            2,
            ClassificationKind::Genre,
            None,
        )
        .unwrap();
        assert_eq!(
            links(&c, ClassificationTarget::Track, 2).unwrap()[0]
                .term
                .name,
            "Jazz"
        );
        set(
            &c,
            ClassificationTarget::Release,
            1,
            ClassificationKind::Genre,
            None,
        )
        .unwrap();
        assert!(
            links(&c, ClassificationTarget::Release, 1)
                .unwrap()
                .iter()
                .all(|l| l.origin == "contains_tracks")
        );
    }
    #[test]
    fn styles_do_not_become_genres_or_gain_parents_by_cooccurrence() {
        let c = db();
        set(
            &c,
            ClassificationTarget::Release,
            1,
            ClassificationKind::Style,
            Some(vec!["Art Pop".into()]),
        )
        .unwrap();
        let style = terms(&c)
            .unwrap()
            .into_iter()
            .find(|t| t.kind == ClassificationKind::Style)
            .unwrap();
        assert_eq!(style.track_count, 2);
        let data = page(&c, ClassificationKind::Style, style.id, "".into(), 0, 1).unwrap();
        assert!(data.related_terms.is_empty());
        assert_eq!(data.total_tracks, 2);
        assert_eq!(data.tracks.len(), 1);
        assert_eq!(
            tracks(&c, ClassificationKind::Style, style.id, "".into())
                .unwrap()
                .len(),
            2
        );
        let genre = terms(&c)
            .unwrap()
            .into_iter()
            .find(|t| t.kind == ClassificationKind::Genre)
            .unwrap();
        assert!(set_relations(&c, style.id, vec![genre.id, 9999]).is_err());
        assert!(
            page(&c, ClassificationKind::Style, style.id, "".into(), 0, 20)
                .unwrap()
                .related_terms
                .is_empty()
        );
        set_relations(&c, style.id, vec![genre.id]).unwrap();
        assert_eq!(
            page(&c, ClassificationKind::Style, style.id, "".into(), 0, 20)
                .unwrap()
                .related_terms
                .len(),
            1
        );
    }
    #[test]
    fn counts_pagination_ratings_and_hidden_content_use_same_membership() {
        let c = db();
        set(
            &c,
            ClassificationTarget::Track,
            3,
            ClassificationKind::Genre,
            Some(vec!["Rock / Pop".into()]),
        )
        .unwrap();
        let term = terms(&c).unwrap().remove(0);
        assert_eq!(term.release_count, 2);
        assert_eq!(term.track_count, 3);
        let first = page(&c, term.kind, term.id, "".into(), 0, 1).unwrap();
        assert_eq!(first.total_releases, 2);
        assert_eq!(first.releases.len(), 1);
        assert_eq!(first.well_rated[0].id, 2);
        assert_eq!(first.contains_tracks_release_ids.len(), 2);
        let second = page(&c, term.kind, term.id, "".into(), 1, 1).unwrap();
        assert_ne!(first.releases[0].id, second.releases[0].id);
        assert_eq!(
            page(&c, term.kind, term.id, "Artist".into(), 0, 20)
                .unwrap()
                .total_tracks,
            2
        );
        c.execute("UPDATE releases SET is_hidden=1 WHERE release_id=2", [])
            .unwrap();
        let list = terms(&c).unwrap();
        assert_eq!(list[0].track_count, 2);
        assert_eq!(list[0].release_count, 1);
        assert_eq!(
            page(&c, term.kind, term.id, "".into(), 0, 20)
                .unwrap()
                .total_tracks,
            2
        );
        assert!(page(&c, term.kind, term.id, "".into(), 0, 201).is_err());
        assert!(
            set(
                &c,
                ClassificationTarget::Release,
                1,
                term.kind,
                Some(vec!["".into()])
            )
            .is_err()
        );
    }
}
