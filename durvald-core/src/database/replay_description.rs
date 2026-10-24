//! Deterministic musical summaries, with explicit ownership of generated text.
use std::collections::{BTreeMap, BTreeSet};

use icu_normalizer::ComposingNormalizer;
use rusqlite::{Connection, OptionalExtension, params};

use super::{models::SongItem, operations::DatabaseResult};

pub(crate) const FALLBACK: &str =
    "As músicas da sua retrospectiva, equilibrando reproduções e tempo ouvido.";

fn key(name: &str) -> String {
    ComposingNormalizer::new_nfc()
        .normalize(
            &name
                .split_whitespace()
                .collect::<Vec<_>>()
                .join(" ")
                .to_lowercase(),
        )
        .into_owned()
}

pub(crate) fn generate(
    conn: &Connection,
    period: &str,
    tracks: &[SongItem],
) -> DatabaseResult<String> {
    super::classification::refresh(conn)
        .map_err(|error| super::operations::DatabaseError::Custom(error.to_string()))?;
    let ids = tracks
        .iter()
        .map(|track| track.song_id)
        .collect::<BTreeSet<_>>();
    // Each song has one vote per normalized name, including when that name
    // occurs in both vocabularies. Album inheritance stays identifiable.
    let mut counts: BTreeMap<String, (String, usize, bool)> = BTreeMap::new();
    let mut classified = 0usize;
    let mut statement = conn.prepare(
        "SELECT g.name,x.origin FROM track_genres x JOIN genres g USING(genre_id) WHERE x.song_id=?1
         UNION ALL
         SELECT s.name,x.origin FROM track_styles x JOIN styles s USING(style_id) WHERE x.song_id=?1",
    )?;
    for id in &ids {
        let rows = statement.query_map([id], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?;
        let mut terms: BTreeMap<String, (String, bool)> = BTreeMap::new();
        for row in rows {
            let (name, origin) = row?;
            let normalized = key(&name);
            if normalized.is_empty() {
                continue;
            }
            let entry = terms.entry(normalized).or_insert((name.clone(), true));
            if name < entry.0 {
                entry.0 = name;
            }
            entry.1 &= origin == "album";
        }
        if !terms.is_empty() {
            classified += 1;
        }
        for (key, (name, inherited)) in terms {
            let entry = counts.entry(key).or_insert((name.clone(), 0, false));
            if name < entry.0 {
                entry.0 = name;
            }
            entry.1 += 1;
            entry.2 |= inherited;
        }
    }
    // A solitary tag or less than one quarter of the actual selection is
    // insufficient evidence for a musical characterization.
    if classified < 2 || classified * 4 < ids.len() {
        return Ok(FALLBACK.into());
    }
    let mut ranked = counts.into_iter().collect::<Vec<_>>();
    ranked.sort_by(|a, b| b.1.1.cmp(&a.1.1).then_with(|| a.0.cmp(&b.0)));
    ranked.truncate(3);
    let names = ranked
        .iter()
        .map(|(_, value)| value.0.as_str())
        .collect::<Vec<_>>();
    let scope = match period {
        "daily" => "Seu dia",
        "weekly" => "Sua semana",
        "monthly" => "Seu mês",
        _ => "Seu ano",
    };
    let mut text = match names.as_slice() {
        [a] => format!("{scope} ao som de {a}."),
        [a, b] => format!("{scope} entre {a} e {b}."),
        [a, b, c] => format!("{scope} entre {a} e {b}, com passagens por {c}."),
        _ => return Ok(FALLBACK.into()),
    };
    if ranked.iter().any(|(_, value)| value.2) {
        text.push_str(" Inclui classificações herdadas dos álbuns.");
    }
    Ok(text)
}

fn selection(tracks: &[SongItem]) -> String {
    tracks
        .iter()
        .map(|track| track.song_id)
        .collect::<BTreeSet<_>>()
        .into_iter()
        .map(|id| id.to_string())
        .collect::<Vec<_>>()
        .join(",")
}

pub(crate) fn initialize(
    conn: &Connection,
    id: u64,
    period: &str,
    tracks: &[SongItem],
) -> DatabaseResult<()> {
    let text = generate(conn, period, tracks)?;
    conn.execute("INSERT INTO replay_descriptions(playlist_id,generated_text,selection,managed) VALUES(?1,?2,?3,1)
        ON CONFLICT(playlist_id) DO UPDATE SET generated_text=excluded.generated_text,selection=excluded.selection,managed=1",
        params![id, text, selection(tracks)])?;
    conn.execute(
        "UPDATE playlists SET description=?2,updated_at=CURRENT_TIMESTAMP WHERE id=?1",
        params![id, text],
    )?;
    Ok(())
}

pub(crate) fn unmanage(conn: &Connection, id: u64) -> DatabaseResult<()> {
    conn.execute(
        "INSERT OR IGNORE INTO replay_descriptions(playlist_id,generated_text,selection,managed)
        SELECT id,COALESCE(description,''),'',0 FROM playlists WHERE id=?1",
        [id],
    )?;
    Ok(())
}

pub(crate) fn refresh(
    conn: &Connection,
    id: u64,
    period: &str,
    tracks: &[SongItem],
    live: bool,
) -> DatabaseResult<()> {
    let owned: Option<(String, bool)> = conn
        .query_row(
            "SELECT selection,managed FROM replay_descriptions WHERE playlist_id=?1",
            [id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?;
    match owned {
        Some((previous, true)) if live && previous != selection(tracks) => {
            initialize(conn, id, period, tracks)
        }
        None => {
            // Adopt only the exact old application default, never arbitrary
            // existing text or a description the user deliberately cleared.
            let text: Option<String> = conn.query_row(
                "SELECT description FROM playlists WHERE id=?1",
                [id],
                |row| row.get(0),
            )?;
            if text.as_deref() == Some(FALLBACK) {
                initialize(conn, id, period, tracks)?;
            } else {
                unmanage(conn, id)?;
            }
            Ok(())
        }
        _ => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        api::{
            ClassificationKind, ClassificationTarget, ReplayPeriod, ReplayRequest, ReplaySaveMode,
        },
        database::{classification, operations, retrospective_playlists},
    };

    fn setup() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        operations::create_tables(&conn).unwrap();
        conn.execute("INSERT INTO artists(artist_id,name) VALUES(1,'Artist')", [])
            .unwrap();
        conn.execute("INSERT INTO releases(release_id,title,artist_id,artist_name) VALUES(1,'Album',1,'Artist')", []).unwrap();
        for id in 1..=12u64 {
            conn.execute("INSERT INTO songs(song_id,title,artist_id,artist_name,release_id,release_title,track_number,disc_number,duration,file_path)
                VALUES(?1,?2,1,'Artist',1,'Album',1,1,180,?3)", params![id, format!("Track {id}"), format!("/{id}.flac")]).unwrap();
        }
        conn
    }

    fn set(conn: &Connection, id: i64, kind: ClassificationKind, names: &[&str]) {
        classification::set(
            conn,
            ClassificationTarget::Track,
            id,
            kind,
            Some(names.iter().map(|s| s.to_string()).collect()),
        )
        .unwrap();
    }
    fn songs(conn: &Connection, ids: &[u64]) -> Vec<SongItem> {
        operations::get_songs_by_ids(conn, ids).unwrap()
    }
    fn play(conn: &Connection, id: u64) {
        conn.execute("INSERT INTO play_history(song_id,played_at,play_duration) VALUES(?1,'1970-01-01T00:16:40+00:00',180)", [id]).unwrap();
    }
    fn live(conn: &Connection, description: &str) -> u64 {
        for id in 1..=5 {
            play(conn, id);
        }
        let def = retrospective_playlists::definition(
            &ReplayRequest {
                period: ReplayPeriod::Daily,
                start_at: 900,
                end_at: 1100,
            },
            ReplaySaveMode::Live,
            false,
            None,
            1000,
        )
        .unwrap();
        operations::create_smart_playlist(conn, "Replay".into(), description.into(), &def)
            .unwrap()
            .id
    }
    fn description(conn: &Connection, id: u64) -> String {
        operations::get_playlist_by_id(conn, id)
            .unwrap()
            .description
    }

    #[test]
    fn selected_tracks_only_with_unique_votes_and_stable_ties() {
        let conn = setup();
        for id in [1, 2] {
            set(&conn, id, ClassificationKind::Genre, &["Jazz"]);
            set(&conn, id, ClassificationKind::Style, &["Jazz"]);
        }
        for id in [3, 4] {
            set(&conn, id, ClassificationKind::Genre, &["Soul"]);
        }
        set(&conn, 5, ClassificationKind::Style, &["Funk"]);
        for id in 6..=12 {
            set(&conn, id, ClassificationKind::Genre, &["Rock"]);
        }
        let mut selected = songs(&conn, &[1, 2, 3, 4, 5]);
        selected.extend([selected[0].clone(), selected[0].clone()]);
        assert_eq!(
            generate(&conn, "monthly", &selected).unwrap(),
            "Seu mês entre Jazz e Soul, com passagens por Funk."
        );
        let mut reversed = selected.clone();
        reversed.reverse();
        assert_eq!(
            generate(&conn, "monthly", &selected).unwrap(),
            generate(&conn, "monthly", &reversed).unwrap()
        );
        assert!(
            generate(&conn, "weekly", &selected)
                .unwrap()
                .starts_with("Sua semana")
        );
        assert!(
            generate(&conn, "yearly", &selected)
                .unwrap()
                .starts_with("Seu ano")
        );
    }

    #[test]
    fn sparse_metadata_falls_back_and_inheritance_remains_explicit() {
        let conn = setup();
        let selected = songs(&conn, &(1..=10).collect::<Vec<_>>());
        assert_eq!(generate(&conn, "daily", &selected).unwrap(), FALLBACK);
        for id in [1, 2] {
            set(&conn, id, ClassificationKind::Style, &["Ambient"]);
        }
        assert_eq!(generate(&conn, "daily", &selected).unwrap(), FALLBACK);
        classification::set(
            &conn,
            ClassificationTarget::Release,
            1,
            ClassificationKind::Genre,
            Some(vec!["Jazz".into()]),
        )
        .unwrap();
        set(&conn, 1, ClassificationKind::Genre, &[]);
        let text = generate(&conn, "daily", &selected).unwrap();
        assert_eq!(
            text,
            "Seu dia entre Jazz e Ambient. Inclui classificações herdadas dos álbuns."
        );
    }

    #[test]
    fn live_refreshes_membership_but_preserves_manual_text_and_clearing() {
        let conn = setup();
        for id in 1..=5 {
            set(&conn, id, ClassificationKind::Genre, &["Jazz"]);
        }
        for id in 6..=12 {
            set(&conn, id, ClassificationKind::Genre, &["Soul"]);
        }
        let id = live(&conn, "");
        assert_eq!(description(&conn, id), "Seu dia ao som de Jazz.");
        for track in 6..=12 {
            for _ in 0..3 {
                play(&conn, track);
            }
        }
        retrospective_playlists::finalize(&conn, 1050).unwrap();
        assert!(description(&conn, id).starts_with("Seu dia entre Soul e Jazz"));
        conn.execute("UPDATE playlists SET name='Renamed' WHERE id=?1", [id])
            .unwrap();
        assert!(
            conn.query_row(
                "SELECT managed FROM replay_descriptions WHERE playlist_id=?1",
                [id],
                |r| r.get::<_, bool>(0)
            )
            .unwrap()
        );
        conn.execute(
            "UPDATE playlists SET description='Minha seleção' WHERE id=?1",
            [id],
        )
        .unwrap();
        for _ in 0..10 {
            play(&conn, 1);
        }
        retrospective_playlists::finalize(&conn, 1050).unwrap();
        assert_eq!(description(&conn, id), "Minha seleção");
        conn.execute("UPDATE playlists SET description='' WHERE id=?1", [id])
            .unwrap();
        retrospective_playlists::finalize(&conn, 1050).unwrap();
        assert_eq!(description(&conn, id), "");
    }

    #[test]
    fn snapshots_freeze_custom_text_survives_and_old_default_is_adopted_once() {
        let conn = setup();
        for id in 1..=5 {
            set(&conn, id, ClassificationKind::Genre, &["Jazz"]);
        }
        let id = live(&conn, "Meu texto");
        retrospective_playlists::finalize(&conn, 1050).unwrap();
        assert_eq!(description(&conn, id), "Meu texto");
        // Simulate an older installation without ownership metadata.
        conn.execute("DELETE FROM replay_descriptions WHERE playlist_id=?1", [id])
            .unwrap();
        conn.execute(
            "UPDATE playlists SET description=?2 WHERE id=?1",
            params![id, FALLBACK],
        )
        .unwrap();
        retrospective_playlists::finalize(&conn, 1050).unwrap();
        assert_eq!(description(&conn, id), "Seu dia ao som de Jazz.");
        let tracks = songs(&conn, &[1, 2, 3, 4, 5]);
        retrospective_playlists::materialize(&conn, id, &tracks).unwrap();
        for track in 6..=12 {
            play(&conn, track);
        }
        retrospective_playlists::finalize(&conn, 1200).unwrap();
        assert_eq!(description(&conn, id), "Seu dia ao som de Jazz.");
        conn.execute("DELETE FROM replay_descriptions WHERE playlist_id=?1", [id])
            .unwrap();
        conn.execute(
            "UPDATE playlists SET description=?2 WHERE id=?1",
            params![id, FALLBACK],
        )
        .unwrap();
        retrospective_playlists::finalize(&conn, 1200).unwrap();
        assert_eq!(description(&conn, id), "Seu dia ao som de Jazz.");
        operations::create_tables(&conn).unwrap();
        assert_eq!(description(&conn, id), "Seu dia ao som de Jazz.");
        conn.execute("DELETE FROM playlists WHERE id=?1", [id])
            .unwrap();
        assert_eq!(
            conn.query_row("SELECT COUNT(*) FROM replay_descriptions", [], |row| row
                .get::<_, i64>(0))
                .unwrap(),
            0
        );
    }

    #[test]
    fn automatic_closing_uses_final_selection_and_freezes_the_summary() {
        let conn = setup();
        for id in 1..=5 {
            set(&conn, id, ClassificationKind::Genre, &["Jazz"]);
        }
        for id in 6..=12 {
            set(&conn, id, ClassificationKind::Genre, &["Soul"]);
        }
        let id = live(&conn, "");
        let mut def = operations::get_smart_playlist_definition(&conn, id)
            .unwrap()
            .unwrap();
        let mut config = retrospective_playlists::config(&def).unwrap().unwrap();
        config.close_automatically = true;
        def.rules[0].value = serde_json::to_string(&config).unwrap();
        conn.execute(
            "UPDATE smart_playlist_definitions SET rules_json=?2 WHERE playlist_id=?1",
            params![id, serde_json::to_string(&def.rules).unwrap()],
        )
        .unwrap();
        for track in 6..=12 {
            for _ in 0..3 {
                play(&conn, track);
            }
        }
        retrospective_playlists::finalize(&conn, 1200).unwrap();
        assert!(description(&conn, id).starts_with("Seu dia entre Soul e Jazz"));
        assert!(
            operations::get_smart_playlist_definition(&conn, id)
                .unwrap()
                .is_none()
        );
        let frozen = description(&conn, id);
        for _ in 0..20 {
            play(&conn, 1);
        }
        retrospective_playlists::finalize(&conn, 1300).unwrap();
        assert_eq!(description(&conn, id), frozen);
    }
}
