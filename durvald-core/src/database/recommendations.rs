//! Offline, deterministic album discovery. Scores are heuristics, never predictions.
use crate::api::*;
use rusqlite::{Connection, params};
use std::collections::{BTreeMap, BTreeSet};

const DAY: i64 = 86_400;
fn storage(e: impl std::fmt::Display) -> CoreError {
    CoreError::Storage {
        message: format!("Local recommendations: {e}"),
    }
}

pub(crate) fn migrate(c: &Connection) -> rusqlite::Result<()> {
    c.execute_batch("CREATE TABLE IF NOT EXISTS recommendation_dismissals (
        release_id INTEGER PRIMARY KEY REFERENCES releases(release_id) ON DELETE CASCADE,until_at INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS recommendation_impressions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,release_id INTEGER REFERENCES releases(release_id) ON DELETE SET NULL,
        day INTEGER NOT NULL,shown_at INTEGER NOT NULL,opened_at INTEGER,listened_at INTEGER,UNIQUE(release_id,day));
        CREATE INDEX IF NOT EXISTS idx_recommendation_opened ON recommendation_impressions(release_id,opened_at);
        CREATE INDEX IF NOT EXISTS idx_recommendation_day ON recommendation_impressions(day);
        CREATE TRIGGER IF NOT EXISTS recommendation_release_deleted AFTER DELETE ON releases BEGIN
            DELETE FROM recommendation_dismissals WHERE release_id=OLD.release_id;
            UPDATE recommendation_impressions SET release_id=NULL WHERE release_id=OLD.release_id;
        END;
        CREATE TRIGGER IF NOT EXISTS recommendation_listened AFTER INSERT ON play_history
        WHEN NEW.play_duration>0 AND (NEW.play_duration>=30 OR EXISTS(
            SELECT 1 FROM songs WHERE song_id=NEW.song_id AND duration>0 AND NEW.play_duration>=duration*0.5)) BEGIN
            UPDATE recommendation_impressions SET listened_at=COALESCE(listened_at,unixepoch(NEW.played_at))
            WHERE id=(SELECT i.id FROM recommendation_impressions i JOIN songs s ON s.release_id=i.release_id
                WHERE s.song_id=NEW.song_id AND i.opened_at IS NOT NULL
                  AND unixepoch(NEW.played_at) BETWEEN i.opened_at AND i.opened_at+86400
                ORDER BY i.opened_at DESC,i.id DESC LIMIT 1);
        END;")
}

#[derive(Default)]
struct Album {
    id: i64,
    artist_id: i64,
    artist: String,
    favorite: bool,
    rating: Option<u8>,
    favorite_tracks: u32,
    rated_tracks: u32,
    plays: u64,
    last_played: Option<i64>,
    added: Option<i64>,
    history_weight: f64,
    features: BTreeMap<String, String>,
    seen_recently: bool,
    dismissed: bool,
}

fn read_albums(c: &Connection, now: i64) -> CoreResult<BTreeMap<i64, Album>> {
    // Metadata-only availability follows the catalog, as do the other local
    // shelves. A missing/hidden release or a release with no eligible songs
    // cannot be suggested. Physical file errors remain a player/scanner concern.
    let mut albums = c.prepare("SELECT r.release_id,r.artist_id,r.artist_name,r.is_favorite,r.rating_half_steps,
        SUM(CASE WHEN s.is_favorite THEN 1 ELSE 0 END),SUM(CASE WHEN s.rating_half_steps>=8 THEN 1 ELSE 0 END),
        COALESCE(SUM(s.play_count),0),unixepoch(e.first_added_at),
        EXISTS(SELECT 1 FROM recommendation_dismissals d WHERE d.release_id=r.release_id AND d.until_at>?1),
        EXISTS(SELECT 1 FROM recommendation_impressions i WHERE i.release_id=r.release_id AND i.day>=?2 AND i.day<?3)
        FROM releases r JOIN songs s ON s.release_id=r.release_id
        LEFT JOIN release_library_entries e ON e.release_id=r.release_id
        WHERE NOT r.is_hidden AND NOT r.suggest_less AND (r.rating_half_steps IS NULL OR r.rating_half_steps>=4)
          AND NOT s.is_hidden AND NOT s.suggest_less
        GROUP BY r.release_id ORDER BY r.release_id").map_err(storage)?
        .query_map(params![now, now.div_euclid(DAY)-6, now.div_euclid(DAY)], |r| Ok(Album {
            id:r.get(0)?,artist_id:r.get(1)?,artist:r.get(2)?,favorite:r.get(3)?,rating:r.get(4)?,
            favorite_tracks:r.get(5)?,rated_tracks:r.get(6)?,plays:r.get(7)?,added:r.get(8)?,
            dismissed:r.get(9)?,seen_recently:r.get(10)?,..Album::default()
        })).map_err(storage)?.collect::<Result<Vec<_>,_>>().map_err(storage)?
        .into_iter().map(|a|(a.id,a)).collect::<BTreeMap<_,_>>();
    let history = c.prepare("SELECT s.release_id,COUNT(*),MAX(unixepoch(h.played_at)),
        SUM(CASE WHEN unixepoch(h.played_at)>=?1-15552000 THEN
            MIN(1.0,CAST(h.play_duration AS REAL)/MAX(1.0,COALESCE(s.duration,180)))*
            CASE WHEN unixepoch(h.played_at)>=?1-2592000 THEN 1.0 ELSE 0.4 END ELSE 0.0 END)
        FROM play_history h JOIN songs s USING(song_id)
        WHERE NOT s.is_hidden AND NOT s.suggest_less AND h.play_duration>0 AND unixepoch(h.played_at)<=?1
        GROUP BY s.release_id").map_err(storage)?
        .query_map([now], |r|Ok((r.get::<_,i64>(0)?,r.get::<_,u64>(1)?,r.get::<_,Option<i64>>(2)?,r.get::<_,f64>(3)?)))
        .map_err(storage)?.collect::<Result<Vec<_>,_>>().map_err(storage)?;
    for (id, plays, last, weight) in history {
        if let Some(a) = albums.get_mut(&id) {
            a.plays = a.plays.max(plays);
            a.last_played = last;
            a.history_weight = weight.ln_1p().min(4.0);
        }
    }
    for (table, terms, id, prefix) in [
        ("release_genres", "genres", "genre_id", "genre"),
        ("release_styles", "styles", "style_id", "style"),
    ] {
        let rows = c
            .prepare(&format!(
                "SELECT x.release_id,x.{id},v.name FROM {table} x JOIN {terms} v USING({id}) WHERE x.origin!='contains_tracks'
                 UNION SELECT s.release_id,x.{id},v.name FROM track_{terms} x JOIN songs s USING(song_id) JOIN {terms} v USING({id})
                 WHERE NOT s.is_hidden AND NOT s.suggest_less"
            ))
            .map_err(storage)?
            .query_map([], |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, i64>(1)?,
                    r.get::<_, String>(2)?,
                ))
            })
            .map_err(storage)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(storage)?;
        for (release, term, name) in rows {
            if let Some(a) = albums.get_mut(&release) {
                a.features.insert(format!("{prefix}:{term}"), name);
            }
        }
    }
    for (sql, prefix) in [
        (
            "SELECT x.release_id,x.tag_id,t.name FROM release_user_tags x JOIN user_tags t USING(tag_id)",
            "album_tag",
        ),
        (
            "SELECT DISTINCT s.release_id,x.tag_id,t.name FROM track_user_tags x JOIN songs s USING(song_id) JOIN user_tags t USING(tag_id) WHERE NOT s.is_hidden AND NOT s.suggest_less",
            "track_tag",
        ),
    ] {
        let rows = c
            .prepare(sql)
            .map_err(storage)?
            .query_map([], |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, i64>(1)?,
                    r.get::<_, String>(2)?,
                ))
            })
            .map_err(storage)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(storage)?;
        for (release, tag, name) in rows {
            if let Some(a) = albums.get_mut(&release) {
                a.features.insert(format!("{prefix}:{tag}"), name);
            }
        }
    }
    Ok(albums)
}

pub(crate) fn generate(c: &Connection, limit: u32, now: i64) -> CoreResult<LocalRecommendations> {
    if limit == 0 || limit > 24 {
        return Err(CoreError::InvalidInput {
            message: "Recommendation limit must be between 1 and 24".into(),
        });
    }
    let tx = c.unchecked_transaction().map_err(storage)?;
    super::classification::refresh(&tx)?;
    let albums = read_albums(&tx, now)?;
    let exploration = !albums.values().any(|a| a.last_played.is_some());
    let mut artist_weights: BTreeMap<i64, f64> = BTreeMap::new();
    let mut listened_artists = BTreeSet::new();
    let mut features: BTreeMap<String, f64> = BTreeMap::new();
    for a in albums.values().filter(|a| !a.dismissed) {
        let explicit = if a.favorite { 2.0 } else { 0.0 }
            + if a.rating.is_some_and(|r| r >= 8) {
                1.5
            } else {
                0.0
            }
            + if a.favorite_tracks > 0 { 1.0 } else { 0.0 }
            + if a.rated_tracks > 0 { 0.5 } else { 0.0 };
        let weight = a.history_weight + explicit;
        if a.history_weight > 0.0 {
            listened_artists.insert(a.artist_id);
        }
        *artist_weights.entry(a.artist_id).or_default() += weight;
        // Divide a seed's contribution among its features; dense metadata must
        // not make one album many times stronger than another seed.
        let contribution = weight / (a.features.len().max(1) as f64).sqrt();
        for key in a.features.keys() {
            *features.entry(key.clone()).or_default() += contribution;
        }
    }
    let mut scored = Vec::new();
    for a in albums.values() {
        if a.dismissed || a.last_played.is_some_and(|t| now - t < 2 * DAY) {
            continue;
        }
        // Subtract this album's own seed before looking up affinity. A favorite
        // must not appear to share genres/tags solely with itself.
        let explicit = if a.favorite { 2.0 } else { 0.0 }
            + if a.rating.is_some_and(|r| r >= 8) {
                1.5
            } else {
                0.0
            }
            + if a.favorite_tracks > 0 { 1.0 } else { 0.0 }
            + if a.rated_tracks > 0 { 0.5 } else { 0.0 };
        let own = a.history_weight + explicit;
        let artist =
            (artist_weights.get(&a.artist_id).copied().unwrap_or(0.0) - own).clamp(0.0, 4.0) * 3.0;
        let own_feature = own / (a.features.len().max(1) as f64).sqrt();
        let mut affinities = a
            .features
            .iter()
            .map(|(key, name)| {
                let weight =
                    (features.get(key).copied().unwrap_or(0.0) - own_feature).clamp(0.0, 4.0);
                (weight, key.as_str(), name.as_str())
            })
            .filter(|(weight, _, _)| *weight > 0.001)
            .collect::<Vec<_>>();
        affinities.sort_by(|a, b| b.0.total_cmp(&a.0).then_with(|| a.1.cmp(b.1)));
        let affinity = affinities.iter().take(3).map(|a| a.0).sum::<f64>().min(6.0);
        let recent = a.added.is_some_and(|t| t <= now && now - t <= 30 * DAY);
        let mut score = 8.0 / (1.0 + (a.plays as f64).ln_1p())
            + artist
            + affinity
            + if a.plays == 0 { 6.0 } else { 0.0 }
            + if recent { 3.0 } else { 0.0 }
            + if a.favorite { 6.0 } else { 0.0 }
            + if a.favorite_tracks > 0 { 2.0 } else { 0.0 }
            + a.rating
                .filter(|r| *r >= 8)
                .map_or(0.0, |r| f64::from(r - 6));
        if a.seen_recently {
            score -= 20.0;
        }
        // Small deterministic daily rotation, never a shuffle on every poll.
        let rotation = (a.id as u64)
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(now.div_euclid(DAY) as u64)
            .rotate_left(17)
            % 1000;
        score += rotation as f64 / 2000.0;
        let reason = if artist >= 1.5 && listened_artists.contains(&a.artist_id) {
            format!("De um artista que você ouve: {}", a.artist)
        } else if let Some((_, key, name)) = affinities.first() {
            let label = if key.starts_with("genre:") {
                "Gênero em comum"
            } else if key.starts_with("style:") {
                "Estilo em comum"
            } else if key.starts_with("album_tag:") {
                "Tag de álbum em comum"
            } else {
                "Tag de faixa em comum"
            };
            format!("{label}: {name}")
        } else if a.favorite {
            if a.plays <= 3 {
                "Um dos seus favoritos, ainda pouco ouvido".into()
            } else {
                "Um dos seus favoritos para revisitar".into()
            }
        } else if a.rating.is_some_and(|r| r >= 8) {
            "Bem avaliado por você".into()
        } else if a.favorite_tracks > 0 {
            "Inclui músicas que você favoritou".into()
        } else if recent {
            "Adicionado recentemente à sua biblioteca".into()
        } else if exploration {
            "Explore este álbum da sua biblioteca".into()
        } else if a.plays <= 3 {
            "Pouco ouvido na sua biblioteca".into()
        } else {
            "Um álbum para revisitar".into()
        };
        scored.push((score, a, reason));
    }
    scored.sort_by(|a, b| b.0.total_cmp(&a.0).then_with(|| a.1.id.cmp(&b.1.id)));
    let mut artist_counts = BTreeMap::new();
    let mut items = Vec::new();
    for (_, a, reason) in scored {
        let count = artist_counts.entry(a.artist_id).or_insert(0);
        if *count >= 2 {
            continue;
        }
        *count += 1;
        let release = super::operations::get_release_by_id(&tx, &a.id.to_string())
            .map_err(storage)
            .map(crate::infrastructure::sqlite::catalog_release::release_from_row)
            .map(crate::application::library::release_from_catalog)?;
        items.push(LocalAlbumRecommendation { release, reason });
        if items.len() >= limit as usize {
            break;
        }
    }
    tx.commit().map_err(storage)?;
    Ok(LocalRecommendations { items, exploration })
}

pub(crate) fn dismiss(c: &Connection, id: i64, now: i64) -> CoreResult<()> {
    if !c
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM releases WHERE release_id=?1)",
            [id],
            |r| r.get::<_, bool>(0),
        )
        .map_err(storage)?
    {
        return Err(CoreError::NotFound {
            message: "Release not found".into(),
        });
    }
    c.execute("INSERT INTO recommendation_dismissals(release_id,until_at) VALUES(?1,?2) ON CONFLICT(release_id) DO UPDATE SET until_at=excluded.until_at",params![id,now+30*DAY]).map_err(storage)?;
    Ok(())
}
pub(crate) fn restore(c: &Connection) -> CoreResult<()> {
    c.execute("DELETE FROM recommendation_dismissals", [])
        .map_err(storage)?;
    Ok(())
}
pub(crate) fn record(
    c: &Connection,
    id: i64,
    event: RecommendationEvent,
    now: i64,
) -> CoreResult<()> {
    let tx = c.unchecked_transaction().map_err(storage)?;
    tx.execute(
        "DELETE FROM recommendation_impressions WHERE day<?1",
        [now.div_euclid(DAY) - 90],
    )
    .map_err(storage)?;
    // Ignore stale cards after a catalog deletion or a negative preference.
    tx.execute("INSERT OR IGNORE INTO recommendation_impressions(release_id,day,shown_at)
        SELECT release_id,?2,?3 FROM releases WHERE release_id=?1 AND NOT is_hidden AND NOT suggest_less
          AND NOT EXISTS(SELECT 1 FROM recommendation_dismissals d WHERE d.release_id=?1 AND d.until_at>?3)",params![id,now.div_euclid(DAY),now]).map_err(storage)?;
    if event == RecommendationEvent::Opened {
        tx.execute("UPDATE recommendation_impressions SET opened_at=COALESCE(opened_at,?3) WHERE release_id=?1 AND day=?2",params![id,now.div_euclid(DAY),now]).map_err(storage)?;
    }
    tx.commit().map_err(storage)
}
pub(crate) fn metrics(c: &Connection, now: i64) -> CoreResult<RecommendationMetrics> {
    c.query_row("SELECT COUNT(*),COUNT(opened_at),COUNT(listened_at) FROM recommendation_impressions WHERE day>=?1",[now.div_euclid(DAY)-29],|r|Ok(RecommendationMetrics{shown:r.get(0)?,opened:r.get(1)?,listened:r.get(2)?})).map_err(storage)
}

#[cfg(test)]
mod tests {
    use super::*;
    const NOW: i64 = 1_800_000_000;
    fn setup(count: i64) -> Connection {
        let mut c = Connection::open_in_memory().unwrap();
        crate::database::operations::create_tables(&c).unwrap();
        crate::database::migrations::migrate_enrichment(&mut c).unwrap();
        for id in 1..=count {
            c.execute(
                "INSERT INTO artists(artist_id,name) VALUES(?1,?2)",
                params![id, format!("Artist {id}")],
            )
            .unwrap();
            c.execute(
                "INSERT INTO releases(release_id,title,artist_id,artist_name) VALUES(?1,?2,?1,?3)",
                params![id, format!("Album {id}"), format!("Artist {id}")],
            )
            .unwrap();
            c.execute("INSERT INTO songs(song_id,title,artist_id,artist_name,release_id,release_title,disc_number,track_number,duration,file_path,created_at)
                VALUES(?1,'Song',?1,'Artist',?1,'Album',1,1,180,?2,'2020-01-01')",params![id,format!("/{id}.flac")]).unwrap();
        }
        c
    }
    fn listen(c: &Connection, id: i64, at: i64, seconds: i64) {
        c.execute(
            "INSERT INTO play_history(song_id,played_at,play_duration) VALUES(?1,?2,?3)",
            params![
                id,
                chrono::DateTime::from_timestamp(at, 0)
                    .unwrap()
                    .to_rfc3339(),
                seconds
            ],
        )
        .unwrap();
    }
    fn ids(batch: &LocalRecommendations) -> Vec<i64> {
        batch.items.iter().map(|i| i.release.id).collect()
    }
    fn genre(c: &Connection, id: i64, name: &str) {
        crate::database::classification::set(
            c,
            ClassificationTarget::Release,
            id,
            ClassificationKind::Genre,
            Some(vec![name.into()]),
        )
        .unwrap();
    }

    #[test]
    fn cold_start_is_exploration_bounded_deterministic_and_negative_preferences_excluded() {
        let c = setup(10);
        c.execute("UPDATE releases SET is_hidden=1 WHERE release_id=4", [])
            .unwrap();
        c.execute("UPDATE releases SET suggest_less=1 WHERE release_id=5", [])
            .unwrap();
        c.execute(
            "UPDATE releases SET rating_half_steps=2 WHERE release_id=6",
            [],
        )
        .unwrap();
        c.execute("UPDATE songs SET suggest_less=1 WHERE release_id=7", [])
            .unwrap();
        c.execute("UPDATE songs SET is_hidden=1 WHERE release_id=8", [])
            .unwrap();
        c.execute("DELETE FROM songs WHERE release_id=9", [])
            .unwrap();
        let batch = generate(&c, 24, NOW).unwrap();
        assert!(batch.exploration);
        assert_eq!(
            ids(&batch).into_iter().collect::<BTreeSet<_>>(),
            [1, 2, 3, 10].into_iter().collect()
        );
        assert_eq!(batch, generate(&c, 24, NOW + 1).unwrap());
        assert_eq!(generate(&c, 2, NOW).unwrap().items.len(), 2);
        assert!(generate(&c, 0, NOW).is_err());
        assert!(generate(&c, 25, NOW).is_err());
    }
    #[test]
    fn listening_affinity_has_truthful_reasons_and_recent_plays_are_not_recommended() {
        let c = setup(5);
        c.execute(
            "UPDATE releases SET artist_id=1,artist_name='Artist 1' WHERE release_id=2",
            [],
        )
        .unwrap();
        genre(&c, 1, "Jazz");
        genre(&c, 3, "Jazz");
        for _ in 0..4 {
            listen(&c, 1, NOW - 3 * DAY, 180);
        }
        listen(&c, 4, NOW - 10, 180);
        let batch = generate(&c, 12, NOW).unwrap();
        assert!(!batch.exploration);
        assert_eq!(batch.items[0].release.id, 2);
        assert!(batch.items[0].reason.contains("artista que você ouve"));
        assert!(
            batch
                .items
                .iter()
                .any(|i| i.release.id == 3 && i.reason == "Gênero em comum: Jazz")
        );
        assert!(!ids(&batch).contains(&4));
    }
    #[test]
    fn favorites_ratings_styles_and_tags_enrich_affinity_without_self_evidence() {
        let c = setup(6);
        c.execute("UPDATE releases SET is_favorite=1 WHERE release_id=1", [])
            .unwrap();
        c.execute(
            "UPDATE releases SET rating_half_steps=10 WHERE release_id=6",
            [],
        )
        .unwrap();
        for id in [1, 2] {
            crate::database::classification::set(
                &c,
                ClassificationTarget::Release,
                id,
                ClassificationKind::Style,
                Some(vec!["Ambient".into()]),
            )
            .unwrap();
        }
        let tag = crate::database::user_tags::create(&c, "Night".into()).unwrap();
        for id in [1, 3] {
            c.execute(
                "INSERT INTO release_user_tags(release_id,tag_id) VALUES(?1,?2)",
                params![id, tag.id],
            )
            .unwrap();
        }
        for id in [1, 4] {
            c.execute(
                "INSERT INTO track_user_tags(song_id,tag_id) VALUES(?1,?2)",
                params![id, tag.id],
            )
            .unwrap();
        }
        let batch = generate(&c, 12, NOW).unwrap();
        assert!(batch.exploration);
        let reason = |id| {
            batch
                .items
                .iter()
                .find(|i| i.release.id == id)
                .unwrap()
                .reason
                .as_str()
        };
        assert!(
            reason(1).contains("favoritos"),
            "An album must not share metadata only with itself"
        );
        assert_eq!(reason(2), "Estilo em comum: Ambient");
        assert_eq!(reason(3), "Tag de álbum em comum: Night");
        assert_eq!(reason(4), "Tag de faixa em comum: Night");
        assert_eq!(reason(6), "Bem avaliado por você");
    }
    #[test]
    fn artist_diversity_dismissal_expiration_restore_and_recent_exposure_rotation() {
        let c = setup(8);
        c.execute("UPDATE releases SET artist_id=1 WHERE release_id<=6", [])
            .unwrap();
        let batch = generate(&c, 12, NOW).unwrap();
        assert_eq!(
            batch
                .items
                .iter()
                .filter(|i| i.release.artist_id == 1)
                .count(),
            2
        );
        assert_eq!(batch.items.len(), 4);
        let id = batch.items[0].release.id;
        dismiss(&c, id, NOW).unwrap();
        assert!(!ids(&generate(&c, 12, NOW).unwrap()).contains(&id));
        restore(&c).unwrap();
        assert!(ids(&generate(&c, 12, NOW).unwrap()).contains(&id));
        let c = setup(4);
        let first = generate(&c, 1, NOW).unwrap().items[0].release.id;
        record(&c, first, RecommendationEvent::Shown, NOW - DAY).unwrap();
        assert_ne!(generate(&c, 1, NOW).unwrap().items[0].release.id, first);
        dismiss(&c, 2, NOW).unwrap();
        assert!(!ids(&generate(&c, 12, NOW).unwrap()).contains(&2));
        assert!(ids(&generate(&c, 12, NOW + 31 * DAY).unwrap()).contains(&2));
    }
    #[test]
    fn local_metrics_deduplicate_views_and_attribute_only_meaningful_listens_after_opening() {
        let c = setup(3);
        record(&c, 1, RecommendationEvent::Shown, NOW).unwrap();
        record(&c, 1, RecommendationEvent::Shown, NOW + 1).unwrap();
        listen(&c, 1, NOW + 2, 180);
        assert_eq!(metrics(&c, NOW).unwrap().listened, 0);
        record(&c, 1, RecommendationEvent::Opened, NOW + 3).unwrap();
        listen(&c, 1, NOW + 4, 1);
        assert_eq!(metrics(&c, NOW).unwrap().listened, 0);
        listen(&c, 1, NOW + 10, 35);
        listen(&c, 1, NOW + 11, 180);
        listen(&c, 2, NOW + 12, 180);
        assert_eq!(
            metrics(&c, NOW).unwrap(),
            RecommendationMetrics {
                shown: 1,
                opened: 1,
                listened: 1
            }
        );
        record(&c, 3, RecommendationEvent::Opened, NOW).unwrap();
        listen(&c, 3, NOW + DAY + 1, 180);
        assert_eq!(metrics(&c, NOW + DAY + 1).unwrap().listened, 1);
        c.execute("DELETE FROM songs WHERE release_id=1", [])
            .unwrap();
        c.execute("DELETE FROM releases WHERE release_id=1", [])
            .unwrap();
        assert_eq!(
            metrics(&c, NOW).unwrap().shown,
            2,
            "Historical totals survive a catalog deletion without retaining its identity"
        );
        record(&c, 2, RecommendationEvent::Shown, NOW + 91 * DAY).unwrap();
        assert_eq!(metrics(&c, NOW + 91 * DAY).unwrap().shown, 1);
        crate::database::operations::create_tables(&c).unwrap();
    }
}
