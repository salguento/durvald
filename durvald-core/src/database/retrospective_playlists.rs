//! Versioned retrospective rule persisted through the existing smart-playlist contract.
use std::collections::HashMap;

pub(crate) use crate::domain::replay::{Definition, config, definition, policy};
use rusqlite::{Connection, OptionalExtension, params};

use crate::{
    api::{ReplayPeriod, ReplayRequest, ReplaySaveMode, SmartPlaylistDefinition},
    database::{
        models::SongItem,
        operations::{self, DatabaseError, DatabaseResult},
    },
};

pub(crate) struct PreparedReplay {
    pub tracks: Vec<SongItem>,
    pub eligible_count: u32,
    pub saved_id: Option<u64>,
}

pub(crate) fn preview(
    conn: &Connection,
    request: &ReplayRequest,
    now: i64,
) -> DatabaseResult<PreparedReplay> {
    let mut def = definition(request, ReplaySaveMode::Snapshot, true, None, now)
        .map_err(DatabaseError::Custom)?;
    let config = config(&def).map_err(DatabaseError::Custom)?.unwrap();
    migrate_legacy_origins(conn)?;
    finalize(conn, now)?;
    let saved_id = saved_playlist_id(conn, &config)?;
    // Rank once with the scope maximum, then truncate to its standard. This is
    // sufficient to decide eligibility without transferring all history to UI.
    let (_, minimum, standard, maximum) = policy(request.period);
    def.limit = Some(maximum);
    let mut selected = tracks(conn, &def, now)?;
    let eligible_count = selected.len() as u32;
    if eligible_count < minimum {
        selected.clear();
    } else {
        selected.truncate(standard as usize);
    }
    if let Some(id) = saved_id {
        selected = operations::get_smart_playlist_definition(conn, id)?
            .map(|definition| operations::get_smart_playlist_tracks(conn, &definition))
            .unwrap_or_else(|| operations::get_playlist_tracks(conn, id))?;
    }
    Ok(PreparedReplay {
        tracks: selected,
        eligible_count,
        saved_id,
    })
}

/// One-time import of older Swift-generated PNG provenance. Runtime identity
/// uses the database origin, never artwork or editable playlist names.
pub(crate) fn migrate_legacy_origins(conn: &Connection) -> DatabaseResult<()> {
    // Completed installations do not acquire a write lock for previews.
    if conn.query_row(
        "SELECT COUNT(*) FROM retrospective_playlist_migrations WHERE version=1",
        [],
        |row| row.get::<_, i64>(0),
    )? > 0
    {
        return Ok(());
    }
    let tx = rusqlite::Transaction::new_unchecked(conn, rusqlite::TransactionBehavior::Immediate)?;
    if tx.query_row(
        "SELECT COUNT(*) FROM retrospective_playlist_migrations WHERE version=1",
        [],
        |row| row.get::<_, i64>(0),
    )? > 0
    {
        return Ok(());
    }
    let rows = {
        let mut statement = tx.prepare("SELECT id,cover FROM playlists ORDER BY id")?;
        statement
            .query_map([], |row| {
                Ok((row.get::<_, u64>(0)?, row.get::<_, Option<Vec<u8>>>(1)?))
            })?
            .collect::<Result<Vec<_>, _>>()?
    };
    for (id, cover) in rows {
        let live = operations::get_smart_playlist_definition(&tx, id)?
            .and_then(|definition| config(&definition).ok().flatten());
        let value = live.or_else(|| cover.as_deref().and_then(legacy_png_origin));
        if let Some(value) = value {
            tx.execute("INSERT OR IGNORE INTO retrospective_playlist_origins(playlist_id,period,start_at,end_at) VALUES(?1,?2,?3,?4)",
                params![id, value.period, value.start_at, value.end_at])?;
        }
    }
    tx.execute(
        "INSERT INTO retrospective_playlist_migrations(version) VALUES(1)",
        [],
    )?;
    tx.commit()?;
    Ok(())
}

fn legacy_png_origin(bytes: &[u8]) -> Option<Definition> {
    let mut decoder = png::Decoder::new(std::io::Cursor::new(bytes));
    decoder.set_limits(png::Limits { bytes: 64 * 1024 });
    let reader = decoder.read_info().ok()?;
    let info = reader.info();
    let descriptions = info
        .uncompressed_latin1_text
        .iter()
        .filter(|chunk| chunk.keyword == "Description")
        .map(|chunk| chunk.text.clone());
    let utf8 = info.utf8_text.iter().filter_map(|chunk| {
        if !matches!(chunk.keyword.as_str(), "Description" | "XML:com.adobe.xmp") {
            return None;
        }
        let text = chunk.get_text().ok()?;
        if text.len() >= 16_384 {
            return None;
        }
        if chunk.keyword == "Description" {
            return Some(text);
        }
        // ImageIO writes PNG Description into XMP's dc:description, rather
        // than necessarily emitting a standalone Description text chunk.
        let document = scraper::Html::parse_fragment(&text);
        let selector = scraper::Selector::parse("dc\\:description rdf\\:li").ok()?;
        document
            .select(&selector)
            .next()
            .map(|element| element.text().collect::<String>())
    });
    let text = descriptions.chain(utf8).find(|text| text.len() < 16_384)?;
    let value: serde_json::Value = serde_json::from_str(&text).ok()?;
    if value["version"].as_u64()? != 1 {
        return None;
    }
    let period = match value["period"].as_str()? {
        "daily" => ReplayPeriod::Daily,
        "weekly" => ReplayPeriod::Weekly,
        "monthly" => ReplayPeriod::Monthly,
        "yearly" => ReplayPeriod::Yearly,
        _ => return None,
    };
    // Swift Codable Date uses seconds since 2001-01-01.
    let start = value["start"].as_f64()? + 978_307_200.0;
    let end = value["end"].as_f64()? + 978_307_200.0;
    if !start.is_finite() || !end.is_finite() || start < i64::MIN as f64 || end > i64::MAX as f64 {
        return None;
    }
    let request = ReplayRequest {
        period,
        start_at: start as i64,
        end_at: end as i64,
    };
    let def = definition(&request, ReplaySaveMode::Snapshot, true, None, 0).ok()?;
    config(&def).ok().flatten()
}

/// Provenance is independent of editable names/covers and smart rules. It
/// survives materialization and makes creation idempotent across core restarts.
pub(crate) fn remember_origin(
    conn: &Connection,
    id: u64,
    value: &Definition,
) -> DatabaseResult<()> {
    conn.execute(
        "INSERT INTO retrospective_playlist_origins(playlist_id,period,start_at,end_at)
         VALUES(?1,?2,?3,?4)",
        params![id, value.period, value.start_at, value.end_at],
    )?;
    Ok(())
}

pub(crate) fn saved_playlist_id(
    conn: &Connection,
    value: &Definition,
) -> DatabaseResult<Option<u64>> {
    let id = conn.query_row(
        "SELECT o.playlist_id FROM retrospective_playlist_origins o JOIN playlists p ON p.id=o.playlist_id
         WHERE o.period=?1 AND o.start_at=?2 AND o.end_at=?3",
        params![value.period, value.start_at, value.end_at], |row| row.get(0),
    ).optional()?;
    if id.is_some() {
        return Ok(id);
    }
    // Older live playlists already carry enough provenance in their rule.
    let mut statement = conn.prepare("SELECT playlist_id FROM smart_playlist_definitions WHERE sort_by='retrospective_score' ORDER BY playlist_id")?;
    let ids = statement
        .query_map([], |row| row.get::<_, u64>(0))?
        .collect::<Result<Vec<_>, _>>()?;
    for id in ids {
        if let Some(definition) = operations::get_smart_playlist_definition(conn, id)? {
            if let Some(existing) = config(&definition).map_err(DatabaseError::Custom)? {
                if (existing.period, existing.start_at, existing.end_at)
                    == (value.period.clone(), value.start_at, value.end_at)
                {
                    remember_origin(conn, id, value)?;
                    return Ok(Some(id));
                }
            }
        }
    }
    Ok(None)
}

/// Full listens contribute 0.85...1.30 points. Partial listens contribute their
/// completion fraction; overreported duration never counts as extra listens.
pub(crate) fn contribution(duration: f64, listened: f64) -> f64 {
    let duration = if duration.is_finite() && duration > 0.0 {
        duration
    } else {
        180.0
    };
    if !listened.is_finite() || listened <= 0.0 {
        return 0.0;
    }
    let completion = listened.min(duration) / duration;
    completion * (0.7 + 0.3 * (duration / 180.0).clamp(0.25, 4.0).sqrt())
}

pub(crate) fn tracks(
    conn: &Connection,
    definition: &SmartPlaylistDefinition,
    now: i64,
) -> DatabaseResult<Vec<SongItem>> {
    let config = config(definition)
        .map_err(DatabaseError::Custom)?
        .ok_or_else(|| DatabaseError::Custom("Missing retrospective rule".into()))?;
    let observed = if operations::history_source_projection(conn)? == "NULL, NULL" {
        "s.duration"
    } else {
        "COALESCE(h.effective_duration_seconds,s.duration)"
    };
    let mut statement = conn.prepare(&format!(
        "SELECT h.song_id,{observed},h.play_duration,unixepoch(h.played_at)
         FROM play_history h JOIN songs s USING(song_id)
         WHERE unixepoch(h.played_at)>=?1 AND unixepoch(h.played_at)<?2
            AND unixepoch(h.played_at)<=?3 AND s.is_hidden=0 ORDER BY h.history_id"
    ))?;
    let mut scores = HashMap::<u64, (f64, i64)>::new();
    let rows = statement.query_map(params![config.start_at, config.end_at, now], |row| {
        Ok((
            row.get::<_, u64>(0)?,
            row.get::<_, f64>(1)?,
            row.get::<_, Option<f64>>(2)?.unwrap_or(0.0),
            row.get::<_, i64>(3)?,
        ))
    })?;
    for row in rows {
        let (id, duration, listened, played_at) = row?;
        let score = contribution(duration, listened);
        if score <= 0.0 {
            continue;
        }
        let total = scores.entry(id).or_insert((0.0, played_at));
        total.0 += score;
        total.1 = total.1.max(played_at);
    }
    let mut ranking: Vec<_> = scores.into_iter().collect();
    ranking.sort_by(|a, b| {
        b.1.0
            .total_cmp(&a.1.0)
            .then_with(|| b.1.1.cmp(&a.1.1))
            .then_with(|| a.0.cmp(&b.0))
    });
    ranking.truncate(definition.limit.unwrap_or(0) as usize);
    let ids: Vec<_> = ranking.into_iter().map(|entry| entry.0).collect();
    let mut indexed: HashMap<_, _> = operations::get_songs_by_ids(conn, &ids)?
        .into_iter()
        .map(|track| (track.song_id, track))
        .collect();
    Ok(ids
        .into_iter()
        .filter_map(|id| indexed.remove(&id))
        .collect())
}

pub(crate) fn materialize(conn: &Connection, id: u64, tracks: &[SongItem]) -> DatabaseResult<()> {
    conn.execute("DELETE FROM playlist_songs WHERE playlist_id=?1", [id])?;
    for (position, track) in tracks.iter().enumerate() {
        operations::add_track_to_playlist_songs(conn, id, track.song_id, position as u64)?;
    }
    conn.execute(
        "DELETE FROM smart_playlist_definitions WHERE playlist_id=?1",
        [id],
    )?;
    conn.execute(
        "UPDATE playlists SET updated_at=CURRENT_TIMESTAMP WHERE id=?1",
        [id],
    )?;
    Ok(())
}

/// Runs on reads/startup too: a period that closed while the app was shut down
/// freezes exactly once, atomically, using its final bounded history.
pub(crate) fn finalize(conn: &Connection, now: i64) -> DatabaseResult<()> {
    let tx = conn.unchecked_transaction()?;
    let ids = {
        let mut statement = tx.prepare("SELECT playlist_id FROM smart_playlist_definitions WHERE sort_by='retrospective_score'")?;
        statement
            .query_map([], |row| row.get::<_, u64>(0))?
            .collect::<Result<Vec<_>, _>>()?
    };
    for id in ids {
        let Some(definition) = operations::get_smart_playlist_definition(&tx, id)? else {
            continue;
        };
        let value = config(&definition).map_err(DatabaseError::Custom)?.unwrap();
        let tracks = tracks(&tx, &definition, now)?;
        super::replay_description::refresh(&tx, id, &value.period, &tracks, value.mode == "live")?;
        if value.mode == "live" && value.close_automatically && now >= value.end_at {
            materialize(&tx, id, &tracks)?;
        }
    }
    let legacy = {
        let mut statement = tx.prepare("SELECT o.playlist_id,o.period FROM retrospective_playlist_origins o
            WHERE NOT EXISTS(SELECT 1 FROM replay_descriptions d WHERE d.playlist_id=o.playlist_id)
              AND NOT EXISTS(SELECT 1 FROM smart_playlist_definitions s WHERE s.playlist_id=o.playlist_id)")?;
        statement
            .query_map([], |row| {
                Ok((row.get::<_, u64>(0)?, row.get::<_, String>(1)?))
            })?
            .collect::<Result<Vec<_>, _>>()?
    };
    for (id, period) in legacy {
        let tracks = operations::get_playlist_tracks(&tx, id)?;
        super::replay_description::refresh(&tx, id, &period, &tracks, false)?;
    }
    tx.commit()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::SmartPlaylistRule;

    fn definition(start: i64, end: i64, mode: &str, close: bool) -> SmartPlaylistDefinition {
        SmartPlaylistDefinition {
            match_all: true,
            rules: vec![SmartPlaylistRule {
                field: "retrospective".into(),
                comparison: "equals".into(),
                value: serde_json::to_string(&Definition {
                    version: 1,
                    period: "daily".into(),
                    start_at: start,
                    end_at: end,
                    mode: mode.into(),
                    close_automatically: close,
                    artwork_base64: None,
                })
                .unwrap(),
            }],
            limit: Some(10),
            sort_by: "retrospective_score".into(),
            descending: true,
        }
    }
    fn setup(count: u64, at: i64) -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        operations::create_tables(&conn).unwrap();
        for id in 1..=count {
            conn.execute("INSERT INTO songs(song_id,title,artist_id,artist_name,release_id,release_title,track_number,disc_number,duration,file_path)
                VALUES(?1,?2,1,'Artist',1,'Album',1,1,180,?3)",params![id,format!("Track {id}"),format!("/music/{id}.mp3")]).unwrap();
            play(&conn, id, at, 180);
        }
        conn
    }
    fn play(conn: &Connection, id: u64, at: i64, duration: u64) {
        let date = chrono::DateTime::from_timestamp(at, 0)
            .unwrap()
            .to_rfc3339();
        conn.execute(
            "INSERT INTO play_history(song_id,played_at,play_duration) VALUES(?1,?2,?3)",
            params![id, date, duration],
        )
        .unwrap();
    }
    fn ids(tracks: Vec<SongItem>) -> Vec<u64> {
        tracks.into_iter().map(|track| track.song_id).collect()
    }

    #[test]
    fn replay_api_owns_scope_policy_readonly_preview_and_saved_membership() {
        for (period, minimum, standard, maximum) in [
            (ReplayPeriod::Daily, 5, 10, 25),
            (ReplayPeriod::Weekly, 10, 25, 50),
            (ReplayPeriod::Monthly, 20, 50, 100),
            (ReplayPeriod::Yearly, 50, 100, 200),
        ] {
            for count in [minimum - 1, minimum, standard - 1, standard, maximum + 10] {
                let conn = setup(count as u64, 1000);
                let request = ReplayRequest {
                    period,
                    start_at: 900,
                    end_at: 1200,
                };
                let selected = preview(&conn, &request, 1100).unwrap();
                assert_eq!(selected.eligible_count, count.min(maximum));
                assert!(selected.saved_id.is_none());
                assert!(
                    operations::get_all_playlists_with_track_counts(&conn)
                        .unwrap()
                        .is_empty()
                );
                let def =
                    super::definition(&request, ReplaySaveMode::Live, true, None, 1100).unwrap();
                assert_eq!(def.limit, Some(standard));
                if count < minimum {
                    assert!(selected.tracks.is_empty());
                    assert!(
                        operations::create_smart_playlist(
                            &conn,
                            "Replay".into(),
                            String::new(),
                            &def
                        )
                        .is_err()
                    );
                } else {
                    assert_eq!(selected.tracks.len(), count.min(standard) as usize);
                    let expected = ids(selected.tracks);
                    let saved = operations::create_smart_playlist(
                        &conn,
                        "Replay".into(),
                        String::new(),
                        &def,
                    )
                    .unwrap();
                    let actual = preview(&conn, &request, 1300).unwrap();
                    assert_eq!(actual.saved_id, Some(saved.id));
                    assert_eq!(ids(actual.tracks), expected);
                }
            }
        }
    }

    #[test]
    fn replay_api_forces_closed_and_future_periods_to_snapshot_and_validates_requests() {
        let request = ReplayRequest {
            period: ReplayPeriod::Daily,
            start_at: 900,
            end_at: 1200,
        };
        for now in [800, 1300] {
            let def = super::definition(&request, ReplaySaveMode::Live, false, None, now).unwrap();
            assert_eq!(config(&def).unwrap().unwrap().mode, "snapshot");
        }
        let def = super::definition(&request, ReplaySaveMode::Live, false, None, 1000).unwrap();
        let config = config(&def).unwrap().unwrap();
        assert_eq!(config.mode, "live");
        assert!(!config.close_automatically);
        for (start_at, end_at) in [(1000, 1000), (1200, 900), (0, 90001)] {
            let request = ReplayRequest {
                period: ReplayPeriod::Daily,
                start_at,
                end_at,
            };
            assert!(
                super::definition(&request, ReplaySaveMode::Snapshot, true, None, 1000).is_err()
            );
        }
    }

    #[test]
    fn replay_api_migrates_legacy_png_provenance_once_then_uses_database_identity() {
        use base64::Engine;
        for apple_xmp in [false, true] {
            let conn = setup(5, 1000);
            let mut bytes = Vec::new();
            {
                let mut encoder = png::Encoder::new(&mut bytes, 1, 1);
                encoder.set_color(png::ColorType::Rgba);
                encoder.set_depth(png::BitDepth::Eight);
                let json = serde_json::json!({ "version": 1, "period": "daily",
                "start": 900.0 - 978307200.0, "end": 1200.0 - 978307200.0 })
                .to_string();
                let (keyword, value) = if apple_xmp {
                    (
                        "XML:com.adobe.xmp",
                        format!(
                            r#"<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:description><rdf:Alt><rdf:li xml:lang="x-default">{json}</rdf:li></rdf:Alt></dc:description></rdf:Description></rdf:RDF></x:xmpmeta>"#
                        ),
                    )
                } else {
                    ("Description", json)
                };
                encoder.add_itxt_chunk(keyword.into(), value).unwrap();
                let mut writer = encoder.write_header().unwrap();
                writer.write_image_data(&[0, 0, 0, 255]).unwrap();
            }
            let saved = operations::create_playlist(
                &conn,
                "Renamed legacy playlist".into(),
                base64::engine::general_purpose::STANDARD.encode(&bytes),
                String::new(),
            )
            .unwrap();
            operations::add_track_to_playlist_songs(&conn, saved.id, 1, 0).unwrap();
            let request = ReplayRequest {
                period: ReplayPeriod::Daily,
                start_at: 900,
                end_at: 1200,
            };
            let result = preview(&conn, &request, 1100).unwrap();
            assert_eq!(result.saved_id, Some(saved.id));
            assert_eq!(ids(result.tracks), vec![1]);
            operations::update_playlist(
                &conn,
                saved.id,
                "Another name".into(),
                String::new(),
                String::new(),
            )
            .unwrap();
            assert_eq!(
                preview(&conn, &request, 1300).unwrap().saved_id,
                Some(saved.id)
            );
            assert_eq!(
                conn.query_row(
                    "SELECT COUNT(*) FROM retrospective_playlist_migrations",
                    [],
                    |row| row.get::<_, i64>(0)
                )
                .unwrap(),
                1
            );
        }
    }

    #[test]
    fn saved_origin_survives_reopening_editing_and_live_finalization() {
        let now = chrono::Utc::now().timestamp();
        for mode in ["snapshot", "live"] {
            let directory = tempfile::tempdir().unwrap();
            let path = directory.path().join("replay.db");
            let seed = setup(5, now - 100);
            seed.execute("VACUUM INTO ?1", [path.to_str().unwrap()])
                .unwrap();
            drop(seed);
            let conn = Connection::open(&path).unwrap();
            let def = definition(now - 200, now + 200, mode, true);
            let saved =
                operations::create_smart_playlist(&conn, "Replay".into(), String::new(), &def)
                    .unwrap();
            if mode == "live" {
                finalize(&conn, now + 500).unwrap();
            }
            operations::update_playlist(
                &conn,
                saved.id,
                "Renamed".into(),
                "Edited".into(),
                String::new(),
            )
            .unwrap();
            drop(conn);

            let conn = Connection::open(&path).unwrap();
            operations::create_tables(&conn).unwrap();
            // Even if history no longer meets the minimum, an existing snapshot
            // must be returned untouched instead of regenerated.
            conn.execute("DELETE FROM play_history", []).unwrap();
            let repeated =
                operations::create_smart_playlist(&conn, "Duplicate".into(), String::new(), &def)
                    .unwrap();
            assert_eq!(repeated.id, saved.id);
            assert_eq!(repeated.name, "Renamed");
            assert_eq!(
                operations::get_all_playlists_with_track_counts(&conn)
                    .unwrap()
                    .len(),
                1
            );
            assert_eq!(
                operations::get_playlist_tracks(&conn, saved.id)
                    .unwrap()
                    .len(),
                5
            );
            assert!(
                operations::get_smart_playlist_definition(&conn, saved.id)
                    .unwrap()
                    .is_none()
            );
            operations::delete_playlist(&conn, saved.id).unwrap();
            assert_eq!(
                conn.query_row(
                    "SELECT COUNT(*) FROM retrospective_playlist_origins",
                    [],
                    |row| row.get::<_, i64>(0)
                )
                .unwrap(),
                0
            );
            for id in 1..=5 {
                play(&conn, id, now - 100, 180);
            }
            let recreated =
                operations::create_smart_playlist(&conn, "Recreated".into(), String::new(), &def)
                    .unwrap();
            assert_eq!(recreated.name, "Recreated");
        }
    }

    #[test]
    fn legacy_live_rules_recover_missing_origin_without_a_duplicate() {
        let now = chrono::Utc::now().timestamp();
        let conn = setup(5, now - 100);
        let def = definition(now - 200, now + 200, "live", true);
        let saved =
            operations::create_smart_playlist(&conn, "Legacy".into(), String::new(), &def).unwrap();
        conn.execute("DELETE FROM retrospective_playlist_origins", [])
            .unwrap();
        let repeated =
            operations::create_smart_playlist(&conn, "Duplicate".into(), String::new(), &def)
                .unwrap();
        assert_eq!(saved.id, repeated.id);
        assert_eq!(
            conn.query_row(
                "SELECT COUNT(*) FROM retrospective_playlist_origins",
                [],
                |row| row.get::<_, i64>(0)
            )
            .unwrap(),
            1
        );
    }

    #[test]
    fn score_bounds_completion_caps_and_duration_balance() {
        assert!((contribution(10.0, 10.0) - 0.85).abs() < 1e-10);
        assert!((contribution(180.0, 180.0) - 1.0).abs() < 1e-10);
        assert!((contribution(7200.0, 7200.0) - 1.3).abs() < 1e-10);
        assert_eq!(contribution(180.0, 1000.0), 1.0);
        assert_eq!(contribution(0.0, 180.0), 1.0);
        assert_eq!(contribution(180.0, 0.0), 0.0);
        assert_eq!(contribution(180.0, f64::NAN), 0.0);
        assert!((contribution(180.0, 90.0) - 0.5).abs() < 1e-10);
        assert!(contribution(7200.0, 180.0) < contribution(180.0, 180.0));
        assert!(2.0 * contribution(180.0, 180.0) > contribution(7200.0, 7200.0));
    }
    #[test]
    fn ranking_uses_history_not_lifetime_counts_and_excludes_boundaries_hidden_and_future() {
        let conn = setup(6, 1000);
        conn.execute("UPDATE songs SET play_count=999 WHERE song_id=1", [])
            .unwrap();
        conn.execute("UPDATE songs SET is_hidden=1 WHERE song_id=6", [])
            .unwrap();
        play(&conn, 2, 1001, 180);
        play(&conn, 3, 999, 180);
        play(&conn, 3, 2000, 180);
        play(&conn, 3, 1500, 180);
        let def = definition(1000, 2000, "live", true);
        assert_eq!(ids(tracks(&conn, &def, 1100).unwrap()), vec![2, 1, 3, 4, 5]);
        assert_eq!(ids(tracks(&conn, &def, 2000).unwrap()), vec![3, 2, 1, 4, 5]);
        assert!(
            operations::get_all_playlists_with_track_counts(&conn)
                .unwrap()
                .is_empty()
        );
    }
    #[test]
    fn snapshots_are_atomic_fixed_and_deduplicated() {
        let now = chrono::Utc::now().timestamp();
        let conn = setup(5, now - 100);
        let def = definition(now - 200, now + 200, "snapshot", true);
        let playlist =
            operations::create_smart_playlist(&conn, "Snapshot".into(), String::new(), &def)
                .unwrap();
        assert!(
            operations::get_smart_playlist_definition(&conn, playlist.id)
                .unwrap()
                .is_none()
        );
        let original = ids(operations::get_playlist_tracks(&conn, playlist.id).unwrap());
        play(&conn, 5, now, 180);
        assert_eq!(
            ids(operations::get_playlist_tracks(&conn, playlist.id).unwrap()),
            original
        );
        assert_eq!(original, vec![1, 2, 3, 4, 5]);
        let sparse = setup(4, now - 100);
        assert!(
            operations::create_smart_playlist(&sparse, "Insufficient".into(), String::new(), &def)
                .is_err()
        );
        assert!(
            operations::get_all_playlists_with_track_counts(&sparse)
                .unwrap()
                .is_empty()
        );
    }
    #[test]
    fn live_updates_then_finalizes_once_at_end_even_after_restart() {
        let now = chrono::Utc::now().timestamp();
        let conn = setup(5, now - 100);
        let def = definition(now - 200, now + 200, "live", true);
        let playlist =
            operations::create_smart_playlist(&conn, "Live".into(), String::new(), &def).unwrap();
        assert!(
            operations::get_smart_playlist_definition(&conn, playlist.id)
                .unwrap()
                .is_some()
        );
        play(&conn, 5, now - 1, 180);
        assert_eq!(ids(tracks(&conn, &def, now).unwrap())[0], 5);
        finalize(&conn, now + 199).unwrap();
        assert!(
            operations::get_smart_playlist_definition(&conn, playlist.id)
                .unwrap()
                .is_some()
        );
        finalize(&conn, now + 200).unwrap();
        assert!(
            operations::get_smart_playlist_definition(&conn, playlist.id)
                .unwrap()
                .is_none()
        );
        let frozen = ids(operations::get_playlist_tracks(&conn, playlist.id).unwrap());
        play(&conn, 4, now, 180);
        play(&conn, 4, now, 180);
        finalize(&conn, now + 1000).unwrap();
        assert_eq!(
            ids(operations::get_playlist_tracks(&conn, playlist.id).unwrap()),
            frozen
        );
        assert_eq!(frozen.len(), 5);
    }
    #[test]
    fn optional_finalization_can_be_disabled_and_user_can_freeze_explicitly() {
        let now = chrono::Utc::now().timestamp();
        let conn = setup(5, now - 100);
        let mut def = definition(now - 200, now + 200, "live", false);
        let playlist =
            operations::create_smart_playlist(&conn, "Live".into(), String::new(), &def).unwrap();
        finalize(&conn, now + 500).unwrap();
        assert!(
            operations::get_smart_playlist_definition(&conn, playlist.id)
                .unwrap()
                .is_some()
        );
        def.rules[0].value = serde_json::to_string(&Definition {
            mode: "snapshot".into(),
            ..config(&def).unwrap().unwrap()
        })
        .unwrap();
        operations::update_smart_playlist(&conn, playlist.id, "Fixed".into(), String::new(), &def)
            .unwrap();
        assert!(
            operations::get_smart_playlist_definition(&conn, playlist.id)
                .unwrap()
                .is_none()
        );
        assert_eq!(
            operations::get_playlist_tracks(&conn, playlist.id)
                .unwrap()
                .len(),
            5
        );
    }
    #[test]
    fn generated_cover_is_saved_atomically_and_survives_live_finalization() {
        use base64::Engine;
        let now = chrono::Utc::now().timestamp();
        let mut png = std::io::Cursor::new(Vec::new());
        image::DynamicImage::new_rgb8(2, 2)
            .write_to(&mut png, image::ImageFormat::Png)
            .unwrap();
        let bytes = png.into_inner();
        for mode in ["live", "snapshot"] {
            let conn = setup(5, now - 100);
            let mut def = definition(now - 200, now + 200, mode, true);
            let value = Definition {
                artwork_base64: Some(base64::engine::general_purpose::STANDARD.encode(&bytes)),
                ..config(&def).unwrap().unwrap()
            };
            def.rules[0].value = serde_json::to_string(&value).unwrap();
            let playlist =
                operations::create_smart_playlist(&conn, "Replay".into(), String::new(), &def)
                    .unwrap();
            assert_eq!(playlist.cover.as_deref(), Some(bytes.as_slice()));
            if let Some(stored) =
                operations::get_smart_playlist_definition(&conn, playlist.id).unwrap()
            {
                assert!(config(&stored).unwrap().unwrap().artwork_base64.is_none());
            }
            finalize(&conn, now + 500).unwrap();
            assert_eq!(
                operations::get_playlist_by_id(&conn, playlist.id)
                    .unwrap()
                    .cover
                    .as_deref(),
                Some(bytes.as_slice())
            );
        }
        let conn = setup(5, now - 100);
        let mut invalid = definition(now - 200, now + 200, "snapshot", true);
        let value = Definition {
            artwork_base64: Some("invalid image".into()),
            ..config(&invalid).unwrap().unwrap()
        };
        invalid.rules[0].value = serde_json::to_string(&value).unwrap();
        assert!(
            operations::create_smart_playlist(&conn, "Bad cover".into(), String::new(), &invalid)
                .is_err()
        );
        assert!(
            operations::get_all_playlists_with_track_counts(&conn)
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn scope_limits_are_enforced_and_results_capped() {
        let conn = setup(220, 1000);
        for (period, min, max) in [
            ("daily", 5, 25),
            ("weekly", 10, 50),
            ("monthly", 20, 100),
            ("yearly", 50, 200),
        ] {
            let mut def = definition(900, 1100, "snapshot", true);
            let value = Definition {
                period: period.into(),
                ..config(&def).unwrap().unwrap()
            };
            def.rules[0].value = serde_json::to_string(&value).unwrap();
            for limit in [min - 1, max + 1] {
                def.limit = Some(limit);
                assert!(operations::validate_smart_playlist_definition(&def).is_err());
            }
            def.limit = Some(max);
            assert_eq!(tracks(&conn, &def, 1100).unwrap().len(), max as usize);
        }
        let mut invalid = definition(900, 1100, "snapshot", true);
        invalid.rules[0].value = "{}".into();
        assert!(operations::validate_smart_playlist_definition(&invalid).is_err());
    }
}
