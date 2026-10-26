//! Follow preferences and offline news projection of published MusicBrainz catalogs.
use crate::api::*;
use crate::enrichment::{
    identity::{normalize_mbid, normalized_match_text},
    models::ReleaseGroupSnapshot,
};
use chrono::NaiveDate;
use rusqlite::{Connection, OptionalExtension, params};
use std::collections::{BTreeMap, BTreeSet};

const DAY: i64 = 86_400;
fn storage(e: impl std::fmt::Display) -> CoreError {
    CoreError::Storage {
        message: format!("Artist news: {e}"),
    }
}
fn invalid(s: &str) -> CoreError {
    CoreError::InvalidInput { message: s.into() }
}
pub(crate) fn migrate(c: &Connection) -> rusqlite::Result<()> {
    c.execute_batch("CREATE TABLE IF NOT EXISTS artist_follows (
        artist_id INTEGER PRIMARY KEY REFERENCES artists(artist_id) ON DELETE CASCADE,
        active INTEGER NOT NULL DEFAULT 1,generation INTEGER NOT NULL DEFAULT 1,followed_at INTEGER NOT NULL,
        last_checked_at INTEGER,last_success_at INTEGER,next_refresh_at INTEGER,last_status TEXT,source_identity_generation INTEGER);
        CREATE TABLE IF NOT EXISTS artist_follow_migrations(version INTEGER PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS artist_news_items (
        mbid TEXT PRIMARY KEY,payload TEXT NOT NULL CHECK(json_valid(payload)),first_seen_at INTEGER NOT NULL,seen_at INTEGER,
        source_updated_at INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS artist_news_links (
        artist_id INTEGER NOT NULL REFERENCES artist_follows(artist_id) ON DELETE CASCADE,
        mbid TEXT NOT NULL REFERENCES artist_news_items(mbid) ON DELETE CASCADE,
        identity_generation INTEGER NOT NULL,catalog_generation INTEGER NOT NULL,PRIMARY KEY(artist_id,mbid));
        CREATE TRIGGER IF NOT EXISTS news_artist_deleted AFTER DELETE ON artists BEGIN
            DELETE FROM artist_news_links WHERE artist_id=OLD.artist_id;
            DELETE FROM artist_follows WHERE artist_id=OLD.artist_id;
        END;")
}

pub(crate) fn set_follow(c: &Connection, id: i64, follow: bool, now: i64) -> CoreResult<()> {
    if id < 0 {
        return Err(invalid("Invalid artist ID"));
    }
    if !c
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM artists WHERE artist_id=?1)",
            [id],
            |r| r.get::<_, bool>(0),
        )
        .map_err(storage)?
    {
        return Err(CoreError::NotFound {
            message: "Artist not found".into(),
        });
    }
    c.execute("INSERT INTO artist_follows(artist_id,active,followed_at) VALUES(?1,?2,?3)
        ON CONFLICT(artist_id) DO UPDATE SET active=excluded.active,generation=artist_follows.generation+1,
        followed_at=CASE WHEN excluded.active THEN excluded.followed_at ELSE artist_follows.followed_at END,
        next_refresh_at=NULL WHERE artist_follows.active!=excluded.active",params![id,follow,now]).map_err(storage)?;
    Ok(())
}
pub(crate) fn import_legacy(c: &Connection, ids: Vec<i64>, now: i64) -> CoreResult<()> {
    if ids.len() > 10_000 {
        return Err(invalid("Too many followed artists"));
    }
    let tx = c.unchecked_transaction().map_err(storage)?;
    let done = tx
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM artist_follow_migrations WHERE version=1)",
            [],
            |r| r.get::<_, bool>(0),
        )
        .map_err(storage)?;
    if !done {
        for id in ids
            .into_iter()
            .filter(|id| *id >= 0)
            .collect::<BTreeSet<_>>()
        {
            tx.execute("INSERT OR IGNORE INTO artist_follows(artist_id,followed_at) SELECT artist_id,?2 FROM artists WHERE artist_id=?1",params![id,now]).map_err(storage)?;
        }
        tx.execute(
            "INSERT INTO artist_follow_migrations(version) VALUES(1)",
            [],
        )
        .map_err(storage)?;
    }
    tx.commit().map_err(storage)
}
pub(crate) fn token(c: &Connection, id: i64) -> CoreResult<Option<u64>> {
    c.query_row(
        "SELECT generation FROM artist_follows WHERE artist_id=?1 AND active=1",
        [id],
        |r| r.get(0),
    )
    .optional()
    .map_err(storage)
}
pub(crate) fn current(c: &Connection, id: i64, generation: u64, identity: u64) -> CoreResult<bool> {
    Ok(token(c, id)? == Some(generation)
        && super::identity::read_persisted_inner(c, id)?.generation == identity)
}

pub(crate) fn followed(c: &Connection) -> CoreResult<Vec<FollowedArtist>> {
    let rows=c.prepare("SELECT f.artist_id,a.name,f.generation,f.followed_at,f.last_checked_at,f.last_success_at,
        f.next_refresh_at,f.last_status,f.source_identity_generation FROM artist_follows f JOIN artists a USING(artist_id)
        WHERE f.active=1 ORDER BY COALESCE(f.last_checked_at,0),a.name COLLATE NOCASE,f.artist_id").map_err(storage)?
        .query_map([],|r|Ok((r.get::<_,i64>(0)?,r.get::<_,String>(1)?,r.get::<_,u64>(2)?,r.get::<_,i64>(3)?,
            r.get::<_,Option<i64>>(4)?,r.get::<_,Option<i64>>(5)?,r.get::<_,Option<i64>>(6)?,r.get::<_,Option<String>>(7)?,r.get::<_,Option<u64>>(8)?)))
        .map_err(storage)?.collect::<Result<Vec<_>,_>>().map_err(storage)?;
    rows.into_iter().map(|(id,name,generation,at,checked,success,next,status,source_generation)| {
        let identity=super::identity::read_persisted_inner(c,id)?;
        let matching=source_generation==Some(identity.generation);
        let complete=c.query_row("SELECT active_remote_exhausted FROM artist_discography_state WHERE artist_id=?1 AND identity_generation=?2 AND active_generation>0",params![id,identity.generation],|r|r.get::<_,bool>(0)).optional().map_err(storage)?.unwrap_or(false);
        Ok(FollowedArtist{artist:Artist{id,name},generation,followed_at:at,identity,last_checked_at:checked,
            last_success_at:if matching{success}else{None},next_refresh_at:if matching{next}else{None},
            status:if matching{status.map(|s|serde_json::from_str(&s).map_err(storage)).transpose()?}else{None},catalog_complete:complete})
    }).collect()
}

/// Partial dates define intervals; they never acquire an invented day/month.
fn date_bounds(date: &ArtistPartialDate) -> Option<(NaiveDate, NaiveDate)> {
    if !(1000..=9998).contains(&date.year) || (date.month.is_none() && date.day.is_some()) {
        return None;
    }
    let start = NaiveDate::from_ymd_opt(
        date.year,
        date.month.unwrap_or(1).into(),
        date.day.unwrap_or(1).into(),
    )?;
    let end = if date.day.is_some() {
        start
    } else if let Some(month) = date.month {
        let (year, month) = if month == 12 {
            (date.year + 1, 1)
        } else {
            (date.year, month as u32 + 1)
        };
        NaiveDate::from_ymd_opt(year, month, 1)?.pred_opt()?
    } else {
        NaiveDate::from_ymd_opt(date.year + 1, 1, 1)?.pred_opt()?
    };
    Some((start, end))
}
fn kind(date: Option<&ArtistPartialDate>, now: i64) -> Option<ArtistNewsKind> {
    let (start, end) = date_bounds(date?)?;
    let today = chrono::DateTime::from_timestamp(now, 0)?.date_naive();
    if start < today.checked_sub_signed(chrono::Duration::days(90))?
        || end > today.checked_add_signed(chrono::Duration::days(365))?
    {
        return None;
    }
    Some(if start > today {
        ArtistNewsKind::Upcoming
    } else if end > today {
        ArtistNewsKind::PartialDate
    } else {
        ArtistNewsKind::Recent
    })
}

fn artwork(
    c: &Connection,
    artist: i64,
    generation: u64,
    mbid: &str,
    now: i64,
) -> CoreResult<Option<ExternalReleaseArtwork>> {
    let row=c.query_row("SELECT provider_id,source_url,managed_path,width,height,attribution,fetched_at,expires_at
        FROM enrichment_assets WHERE artist_id=?1 AND generation=?2 AND release_group_mbid=?3
        AND provider='cover_art_archive' AND artwork_scope='release_group' ORDER BY fetched_at DESC LIMIT 1",params![artist,generation,mbid],
        |r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?,r.get::<_,String>(5)?,r.get(6)?,r.get::<_,i64>(7)?))).optional().map_err(storage)?;
    row.map(
        |(
            provider_id,
            source_url,
            managed_path,
            width,
            height,
            attribution,
            fetched_at,
            expires_at,
        )| {
            Ok(ExternalReleaseArtwork {
                image: ArtistImageReference {
                    provider: EnrichmentProvider::CoverArtArchive,
                    provider_id,
                    source_url,
                    managed_path,
                    width,
                    height,
                    attribution: serde_json::from_str(&attribution).map_err(storage)?,
                    fetched_at,
                    expires_at,
                    stale: now >= expires_at,
                },
                scope: ExternalArtworkScope::ReleaseGroup,
            })
        },
    )
    .transpose()
}

/// Called within the feed transaction; only fully published generations qualify.
fn sync_cache(c: &Connection, now: i64) -> CoreResult<()> {
    let allowed = followed(c)?
        .into_iter()
        .filter(|f| {
            f.identity.status == ArtistIdentityStatus::Resolved && !f.identity.conflicting_tags
        })
        .map(|f| f.artist.id)
        .collect::<BTreeSet<_>>();
    let rows=c.prepare("SELECT f.artist_id,s.generation,d.active_generation,d.active_fetched_at,ar.snapshot_payload
        FROM artist_follows f JOIN artist_enrichment_state s USING(artist_id)
        JOIN artist_discography_state d ON d.artist_id=f.artist_id AND d.identity_generation=s.generation
        JOIN external_artist_release_groups ar ON ar.artist_id=f.artist_id AND ar.identity_generation=s.generation AND ar.catalog_generation=d.active_generation
        WHERE f.active=1 AND s.identity_status='resolved' AND d.active_generation>0
        ORDER BY f.artist_id,ar.release_group_mbid").map_err(storage)?
        .query_map([],|r|Ok((r.get::<_,i64>(0)?,r.get::<_,u64>(1)?,r.get::<_,u64>(2)?,r.get::<_,Option<i64>>(3)?,r.get::<_,String>(4)?)))
        .map_err(storage)?.collect::<Result<Vec<_>,_>>().map_err(storage)?;
    for (artist, identity, catalog, fetched, payload) in rows {
        if !allowed.contains(&artist) {
            continue;
        }
        let snapshot: ReleaseGroupSnapshot = serde_json::from_str(&payload).map_err(storage)?;
        if kind(snapshot.first_release_date.as_ref(), now).is_none() {
            continue;
        }
        let local=c.query_row("SELECT l.release_id FROM local_release_external_ids l JOIN releases r USING(release_id)
            WHERE l.release_group_mbid=?1 AND r.artist_id=?2 AND NOT r.is_hidden ORDER BY l.release_id LIMIT 1",params![snapshot.musicbrainz_id,artist],|r|r.get::<_,i64>(0)).optional().map_err(storage)?;
        let cached_artwork = artwork(c, artist, identity, &snapshot.musicbrainz_id, now)?;
        let release = ExternalReleaseGroup {
            primary_artist_mbid: snapshot.primary_artist_mbid,
            musicbrainz_id: snapshot.musicbrainz_id,
            title: snapshot.title,
            primary_type: snapshot.primary_type,
            secondary_types: snapshot.secondary_types,
            first_release_date: snapshot.first_release_date,
            local_release_id: local,
            artwork: cached_artwork,
            attribution: snapshot.attribution,
        };
        c.execute("INSERT INTO artist_news_items(mbid,payload,first_seen_at,source_updated_at) VALUES(?1,?2,?3,?4)
            ON CONFLICT(mbid) DO UPDATE SET payload=excluded.payload,source_updated_at=excluded.source_updated_at WHERE excluded.source_updated_at>=artist_news_items.source_updated_at",
            params![release.musicbrainz_id,serde_json::to_string(&release).map_err(storage)?,now,fetched.unwrap_or(now)]).map_err(storage)?;
        c.execute("INSERT INTO artist_news_links(artist_id,mbid,identity_generation,catalog_generation) VALUES(?1,?2,?3,?4)
            ON CONFLICT(artist_id,mbid) DO UPDATE SET identity_generation=excluded.identity_generation,catalog_generation=excluded.catalog_generation",
            params![artist,release.musicbrainz_id,identity,catalog]).map_err(storage)?;
    }
    c.execute("UPDATE artist_follows SET
        last_status=CASE WHEN source_identity_generation=(SELECT generation FROM artist_enrichment_state s WHERE s.artist_id=artist_follows.artist_id) THEN last_status ELSE NULL END,
        next_refresh_at=CASE WHEN source_identity_generation=(SELECT generation FROM artist_enrichment_state s WHERE s.artist_id=artist_follows.artist_id) THEN next_refresh_at ELSE NULL END,
        last_success_at=(SELECT d.active_fetched_at FROM artist_discography_state d JOIN artist_enrichment_state s ON s.artist_id=d.artist_id AND s.generation=d.identity_generation
        WHERE d.artist_id=artist_follows.artist_id AND d.active_generation>0),source_identity_generation=(SELECT generation FROM artist_enrichment_state s WHERE s.artist_id=artist_follows.artist_id)
        WHERE active=1 AND EXISTS(SELECT 1 FROM artist_discography_state d JOIN artist_enrichment_state s ON s.artist_id=d.artist_id AND s.generation=d.identity_generation
        WHERE d.artist_id=artist_follows.artist_id AND d.active_generation>0)",[]).map_err(storage)?;
    Ok(())
}

pub(crate) fn page(c: &Connection, q: ArtistNewsQuery, now: i64) -> CoreResult<ArtistNewsPage> {
    if q.limit == 0
        || q.limit > 100
        || q.query.chars().count() > 200
        || q.offset > i64::MAX as u64
        || !matches!(q.sort_by.as_str(), "date" | "artist")
    {
        return Err(invalid("Invalid news query"));
    }
    let tx = c.unchecked_transaction().map_err(storage)?;
    sync_cache(&tx, now)?;
    let rows=tx.prepare("SELECT n.mbid,n.payload,n.first_seen_at,n.seen_at,n.source_updated_at,f.artist_id,a.name
        FROM artist_news_items n JOIN artist_news_links l ON l.mbid=n.mbid JOIN artist_follows f ON f.artist_id=l.artist_id
        JOIN artists a ON a.artist_id=f.artist_id JOIN artist_enrichment_state s ON s.artist_id=f.artist_id AND s.generation=l.identity_generation
        JOIN artist_discography_state d ON d.artist_id=f.artist_id AND d.identity_generation=s.generation AND d.active_generation=l.catalog_generation
        WHERE f.active=1 AND s.identity_status='resolved' ORDER BY n.mbid,f.artist_id").map_err(storage)?
        .query_map([],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?,r.get::<_,i64>(2)?,r.get::<_,Option<i64>>(3)?,r.get::<_,i64>(4)?,r.get::<_,i64>(5)?,r.get::<_,String>(6)?)))
        .map_err(storage)?.collect::<Result<Vec<_>,_>>().map_err(storage)?;
    let followed_artists = followed(&tx)?;
    let allowed = followed_artists
        .iter()
        .filter(|f| {
            f.identity.status == ArtistIdentityStatus::Resolved && !f.identity.conflicting_tags
        })
        .map(|f| f.artist.id)
        .collect::<BTreeSet<_>>();
    let query = normalized_match_text(&q.query);
    let mut items = BTreeMap::new();
    for (id, payload, first_seen_at, seen, source_updated_at, artist_id, name) in rows {
        if !allowed.contains(&artist_id) {
            continue;
        }
        let release: ExternalReleaseGroup = serde_json::from_str(&payload).map_err(storage)?;
        let Some(kind) = kind(release.first_release_date.as_ref(), now) else {
            continue;
        };
        if q.unseen_only && seen.is_some() || q.kind.is_some_and(|k| k != kind) {
            continue;
        }
        if !query.is_empty()
            && !normalized_match_text(&format!("{} {name}", release.title)).contains(&query)
        {
            continue;
        }
        items.entry(id.clone()).or_insert(ArtistNewsItem {
            id,
            artist: Artist {
                id: artist_id,
                name,
            },
            release,
            kind,
            first_seen_at,
            seen: seen.is_some(),
            source_updated_at,
        });
    }
    let mut items = items.into_values().collect::<Vec<_>>();
    items.sort_by(|a, b| {
        let order = if q.sort_by == "artist" {
            normalized_match_text(&a.artist.name).cmp(&normalized_match_text(&b.artist.name))
        } else {
            date_bounds(a.release.first_release_date.as_ref().unwrap())
                .unwrap()
                .0
                .cmp(
                    &date_bounds(b.release.first_release_date.as_ref().unwrap())
                        .unwrap()
                        .0,
                )
        };
        (if q.descending { order.reverse() } else { order }).then_with(|| a.id.cmp(&b.id))
    });
    let total = items.len() as u64;
    let items = items
        .into_iter()
        .skip(q.offset as usize)
        .take(q.limit as usize)
        .collect::<Vec<_>>();
    let end = q.offset.saturating_add(items.len() as u64);
    let result = ArtistNewsPage {
        items,
        followed_artists,
        total,
        next_offset: (end < total).then_some(end),
    };
    tx.commit().map_err(storage)?;
    Ok(result)
}
pub(crate) fn set_seen(c: &Connection, mbid: String, seen: bool, now: i64) -> CoreResult<()> {
    let mbid = normalize_mbid(&mbid).ok_or_else(|| invalid("Invalid release group identity"))?;
    if c.execute(
        "UPDATE artist_news_items SET seen_at=CASE WHEN ?2 THEN ?3 ELSE NULL END WHERE mbid=?1",
        params![mbid, seen, now],
    )
    .map_err(storage)?
        == 0
    {
        return Err(CoreError::NotFound {
            message: "News item not found".into(),
        });
    }
    Ok(())
}
pub(crate) fn finish(
    c: &Connection,
    id: i64,
    generation: u64,
    identity: u64,
    status: ArtistRefreshStatus,
    retry: Option<u64>,
    now: i64,
) -> CoreResult<bool> {
    let tx = rusqlite::Transaction::new_unchecked(c, rusqlite::TransactionBehavior::Immediate)
        .map_err(storage)?;
    if !current(&tx, id, generation, identity)? {
        return Ok(false);
    }
    let delay = match status {
        ArtistRefreshStatus::Updated
        | ArtistRefreshStatus::Unchanged
        | ArtistRefreshStatus::NotFound => DAY,
        ArtistRefreshStatus::Partial => 30,
        ArtistRefreshStatus::RateLimited => retry.unwrap_or(900).max(60).min(7 * DAY as u64) as i64,
        ArtistRefreshStatus::NeedsIdentity => DAY,
        ArtistRefreshStatus::Disabled | ArtistRefreshStatus::Offline => 0,
        _ => 900,
    };
    tx.execute("UPDATE artist_follows SET last_checked_at=?2,last_status=?3,next_refresh_at=?4,source_identity_generation=?5 WHERE artist_id=?1",
        params![id,now,serde_json::to_string(&status).map_err(storage)?,now+delay,identity]).map_err(storage)?;
    tx.commit().map_err(storage)?;
    Ok(true)
}
pub(crate) fn clear_provider(c: &Connection) -> CoreResult<()> {
    let tx = c.unchecked_transaction().map_err(storage)?;
    // News is projected from the published artist catalog. Invalidating that
    // backing cache prevents the next offline read from recreating cleared items.
    tx.execute("DELETE FROM external_artist_release_groups", [])
        .map_err(storage)?;
    tx.execute("DELETE FROM artist_discography_state", [])
        .map_err(storage)?;
    tx.execute("DELETE FROM artist_news_links", [])
        .map_err(storage)?;
    tx.execute("DELETE FROM artist_news_items", [])
        .map_err(storage)?;
    tx.execute(
        "UPDATE artist_follows SET last_success_at=NULL,next_refresh_at=NULL,last_status=NULL",
        [],
    )
    .map_err(storage)?;
    tx.commit().map_err(storage)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::database::enrichment::{begin_discography_snapshot, store_discography_page};
    use crate::enrichment::models::{CacheValidators, DiscographyPageSnapshot};
    const MBID: &str = "11111111-1111-4111-8111-111111111111";
    fn now() -> i64 {
        NaiveDate::from_ymd_opt(2026, 10, 26)
            .unwrap()
            .and_hms_opt(12, 0, 0)
            .unwrap()
            .and_utc()
            .timestamp()
    }
    fn database() -> Connection {
        let mut c = Connection::open_in_memory().unwrap();
        c.execute_batch("PRAGMA foreign_keys=ON").unwrap();
        super::super::operations::create_tables(&c).unwrap();
        super::super::migrations::migrate_enrichment(&mut c).unwrap();
        for id in [7, 8] {
            c.execute(
                "INSERT INTO artists(artist_id,name) VALUES(?1,?2)",
                params![id, format!("Artista {id}")],
            )
            .unwrap();
            c.execute("INSERT INTO artist_enrichment_state(artist_id,generation,identity_status,musicbrainz_id,confirmed_musicbrainz_id) VALUES(?1,0,'resolved','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')",[id]).unwrap();
        }
        c
    }
    fn query() -> ArtistNewsQuery {
        ArtistNewsQuery {
            query: String::new(),
            unseen_only: false,
            kind: None,
            sort_by: "date".into(),
            descending: true,
            offset: 0,
            limit: 40,
        }
    }
    fn date(year: i32, month: Option<u8>, day: Option<u8>) -> ArtistPartialDate {
        ArtistPartialDate { year, month, day }
    }
    fn publish(
        c: &Connection,
        artist: i64,
        id: &str,
        date: Option<ArtistPartialDate>,
        complete: bool,
    ) {
        let catalog = begin_discography_snapshot(c, artist, 0).unwrap().unwrap();
        store_discography_page(
            c,
            &DiscographyPageSnapshot {
                artist_id: artist,
                identity_generation: 0,
                catalog_generation: catalog,
                provider_offset: 0,
                groups: vec![ReleaseGroupSnapshot {
                    primary_artist_mbid: None,
                    musicbrainz_id: id.into(),
                    title: "Álbum novo".into(),
                    primary_type: Some("Album".into()),
                    secondary_types: vec![],
                    first_release_date: date,
                    genres: vec![],
                    composers: vec![],
                    producers: vec![],
                    attribution: EnrichmentAttribution {
                        source_url: format!("https://musicbrainz.org/release-group/{id}"),
                        author: None,
                        license_name: None,
                        license_url: None,
                        revision: None,
                    },
                }],
                remote_total: if complete { 1 } else { 2 },
                remote_next_offset: if complete { None } else { Some(1) },
                remote_exhausted: complete,
                fetched_at: now() - 3600,
                expires_at: now() + 3600,
                validators: CacheValidators::default(),
            },
        )
        .unwrap();
    }
    #[test]
    fn dates_use_release_intervals_never_insertion_time() {
        assert_eq!(
            kind(Some(&date(2026, Some(10), Some(20))), now()),
            Some(ArtistNewsKind::Recent)
        );
        assert_eq!(
            kind(Some(&date(2026, Some(11), None)), now()),
            Some(ArtistNewsKind::Upcoming)
        );
        assert_eq!(
            kind(Some(&date(2026, Some(10), None)), now()),
            Some(ArtistNewsKind::PartialDate)
        );
        assert_eq!(kind(Some(&date(2020, None, None)), now()), None);
        assert_eq!(kind(Some(&date(2026, None, None)), now()), None);
        assert_eq!(kind(Some(&date(2026, Some(2), Some(30))), now()), None);
        assert_eq!(kind(None, now()), None);
        let c = database();
        set_follow(&c, 7, true, now()).unwrap();
        publish(&c, 7, MBID, Some(date(2020, Some(1), Some(1))), true);
        assert_eq!(page(&c, query(), now()).unwrap().total, 0);
    }
    #[test]
    fn published_feed_deduplicates_and_preserves_seen_offline() {
        let c = database();
        for artist in [7, 8] {
            set_follow(&c, artist, true, now()).unwrap();
            publish(&c, artist, MBID, Some(date(2026, Some(10), Some(20))), true);
        }
        let feed = page(&c, query(), now()).unwrap();
        assert_eq!(feed.total, 1);
        assert_eq!(feed.followed_artists.len(), 2);
        assert_eq!(feed.items[0].source_updated_at, now() - 3600);
        assert!(!feed.items[0].seen);
        set_seen(&c, MBID.into(), true, now()).unwrap();
        let mut unseen = query();
        unseen.unseen_only = true;
        assert_eq!(page(&c, unseen, now()).unwrap().total, 0);
        assert!(page(&c, query(), now()).unwrap().items[0].seen);
        set_follow(&c, 7, false, now()).unwrap();
        assert_eq!(page(&c, query(), now()).unwrap().total, 1);
        set_follow(&c, 8, false, now()).unwrap();
        assert_eq!(page(&c, query(), now()).unwrap().total, 0);
        set_follow(&c, 7, true, now()).unwrap();
        assert!(page(&c, query(), now()).unwrap().items[0].seen);
    }
    #[test]
    fn incomplete_and_obsolete_catalogs_are_not_published() {
        let c = database();
        set_follow(&c, 7, true, now()).unwrap();
        publish(&c, 7, MBID, Some(date(2026, Some(10), Some(20))), false);
        assert_eq!(page(&c, query(), now()).unwrap().total, 0);
        // Finish the staged snapshot before testing identity invalidation.
        c.execute("DELETE FROM artist_discography_state WHERE artist_id=7", [])
            .unwrap();
        publish(&c, 7, MBID, Some(date(2026, Some(10), Some(20))), true);
        assert_eq!(page(&c, query(), now()).unwrap().total, 1);
        c.execute(
            "UPDATE artist_enrichment_state SET generation=1 WHERE artist_id=7",
            [],
        )
        .unwrap();
        assert_eq!(page(&c, query(), now()).unwrap().total, 0);
    }
    #[test]
    fn legacy_import_is_once_and_stale_refresh_cannot_revive_unfollowed_artist() {
        let c = database();
        import_legacy(&c, vec![7, 7, 999], now()).unwrap();
        assert_eq!(followed(&c).unwrap().len(), 1);
        let original = token(&c, 7).unwrap().unwrap();
        set_follow(&c, 7, false, now()).unwrap();
        import_legacy(&c, vec![7, 8], now()).unwrap();
        assert!(followed(&c).unwrap().is_empty());
        assert!(
            !finish(
                &c,
                7,
                original,
                0,
                ArtistRefreshStatus::Updated,
                None,
                now()
            )
            .unwrap()
        );
        set_follow(&c, 7, true, now()).unwrap();
        assert!(
            !finish(
                &c,
                7,
                original,
                0,
                ArtistRefreshStatus::Updated,
                None,
                now()
            )
            .unwrap()
        );
        let generation = token(&c, 7).unwrap().unwrap();
        assert!(
            finish(
                &c,
                7,
                generation,
                0,
                ArtistRefreshStatus::RateLimited,
                Some(300),
                now()
            )
            .unwrap()
        );
        assert_eq!(followed(&c).unwrap()[0].next_refresh_at, Some(now() + 300));
        assert!(
            finish(
                &c,
                7,
                generation,
                0,
                ArtistRefreshStatus::Offline,
                None,
                now()
            )
            .unwrap()
        );
        assert_eq!(followed(&c).unwrap()[0].next_refresh_at, Some(now()));
    }
    #[test]
    fn query_filters_paginates_and_provider_clear_keeps_follow_preferences() {
        let c = database();
        set_follow(&c, 7, true, now()).unwrap();
        publish(&c, 7, MBID, Some(date(2026, Some(11), Some(2))), true);
        let mut q = query();
        q.query = "ÁLBUM".into();
        assert_eq!(page(&c, q, now()).unwrap().total, 1);
        let mut q = query();
        q.kind = Some(ArtistNewsKind::Recent);
        assert_eq!(page(&c, q, now()).unwrap().total, 0);
        let mut q = query();
        q.offset = 1;
        let p = page(&c, q, now()).unwrap();
        assert!(p.items.is_empty());
        assert_eq!(p.next_offset, None);
        clear_provider(&c).unwrap();
        assert_eq!(followed(&c).unwrap().len(), 1);
        assert_eq!(page(&c, query(), now()).unwrap().total, 0);
        assert_eq!(
            c.query_row("SELECT COUNT(*) FROM artist_news_items", [], |r| r
                .get::<_, i64>(0))
                .unwrap(),
            0
        );
    }
}
