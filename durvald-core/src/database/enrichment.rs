//! Synchronous enrichment persistence. Call through a blocking task, never over HTTP.

use crate::api::*;
use crate::enrichment::models::{CacheValidators, ProfileSnapshot};
use crate::enrichment::policy::{MAX_JSON_BYTES, normalize_language, normalized_settings};
use rusqlite::{Connection, OptionalExtension, params};
use serde::de::DeserializeOwned;

fn storage(error: impl std::fmt::Display) -> CoreError {
    CoreError::Storage {
        message: format!("Enrichment storage: {error}"),
    }
}

fn invalid(message: &str) -> CoreError {
    CoreError::InvalidInput {
        message: message.into(),
    }
}

fn decode_enum<T: DeserializeOwned>(value: String) -> CoreResult<T> {
    serde_json::from_value(serde_json::Value::String(value)).map_err(storage)
}

pub fn read_settings(conn: &Connection) -> CoreResult<EnrichmentSettings> {
    conn.query_row(
        "SELECT enabled, offline, preferred_language FROM enrichment_settings WHERE id = 1",
        [],
        |row| {
            Ok(EnrichmentSettings {
                enabled: row.get(0)?,
                offline: row.get(1)?,
                preferred_language: row.get(2)?,
            })
        },
    )
    .map_err(storage)
}

pub fn write_settings(conn: &Connection, settings: EnrichmentSettings) -> CoreResult<()> {
    let settings = normalized_settings(settings)?;
    let changed = conn.execute(
        "UPDATE enrichment_settings SET enabled = ?1, offline = ?2, preferred_language = ?3 WHERE id = 1",
        params![settings.enabled, settings.offline, settings.preferred_language],
    ).map_err(storage)?;
    if changed != 1 {
        return Err(storage("Missing settings row"));
    }
    Ok(())
}

/// An empty cache is a valid result for an existing artist, including offline.
pub fn read_artist_details(
    conn: &Connection,
    artist_id: i64,
    language: &str,
    now: i64,
) -> CoreResult<ArtistDetails> {
    if artist_id < 0 {
        return Err(invalid("Artist ID must be non-negative"));
    }
    let language = normalize_language(language)?;
    let tx = conn.unchecked_transaction().map_err(storage)?;
    let row = tx
        .query_row(
            "SELECT a.name, COALESCE(s.identity_status, 'unresolved'), s.musicbrainz_id,
                COALESCE(s.generation, 0)
         FROM artists a LEFT JOIN artist_enrichment_state s USING (artist_id)
         WHERE a.artist_id = ?1",
            [artist_id],
            |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, Option<String>>(2)?,
                    r.get::<_, i64>(3)?,
                ))
            },
        )
        .optional()
        .map_err(storage)?
        .ok_or_else(|| CoreError::NotFound {
            message: format!("Artist {artist_id} not found"),
        })?;
    let mut details = ArtistDetails {
        artist: Artist {
            id: artist_id,
            name: row.0,
        },
        identity_status: decode_enum(row.1)?,
        musicbrainz_id: row.2,
        identity_generation: u64::try_from(row.3).map_err(storage)?,
        requested_language: language.clone(),
        sources: Vec::new(),
    };
    {
        let mut stmt = tx
            .prepare(
                "SELECT provider, language, payload_version, payload, fetched_at, expires_at
             FROM artist_profile_sources
             WHERE artist_id = ?1 AND generation = ?2 AND language IN (?3, 'und')
             ORDER BY provider, language",
            )
            .map_err(storage)?;
        let mut rows = stmt
            .query(params![artist_id, row.3, language])
            .map_err(storage)?;
        while let Some(row) = rows.next().map_err(storage)? {
            let version: i64 = row.get(2).map_err(storage)?;
            if version != 1 {
                return Err(storage("Unsupported profile payload version"));
            }
            let payload: String = row.get(3).map_err(storage)?;
            if payload.len() > MAX_JSON_BYTES {
                return Err(storage("Profile payload exceeds size limit"));
            }
            let expires_at = row.get(5).map_err(storage)?;
            details.sources.push(ArtistProfileSource {
                provider: decode_enum(row.get(0).map_err(storage)?)?,
                language: row.get(1).map_err(storage)?,
                profile: serde_json::from_str(&payload).map_err(storage)?,
                fetched_at: row.get(4).map_err(storage)?,
                expires_at,
                stale: now >= expires_at,
            });
        }
    }
    tx.commit().map_err(storage)?;
    Ok(details)
}

fn validate_date(value: &Option<ArtistPartialDate>) -> CoreResult<()> {
    if let Some(value) = value {
        let valid = value.day.is_none() || value.month.is_some();
        if !valid
            || chrono::NaiveDate::from_ymd_opt(
                value.year,
                u32::from(value.month.unwrap_or(1)),
                u32::from(value.day.unwrap_or(1)),
            )
            .is_none()
        {
            return Err(invalid("Invalid partial artist date"));
        }
    }
    Ok(())
}

/// Returns false if the identity changed or a newer snapshot already won.
/// The caller must treat false as discarded work, never as a successful refresh.
pub fn store_profile(conn: &Connection, snapshot: &ProfileSnapshot) -> CoreResult<bool> {
    if snapshot.artist_id < 0 || snapshot.expires_at < snapshot.fetched_at {
        return Err(invalid("Invalid profile artist ID or expiry"));
    }
    let generation = i64::try_from(snapshot.identity_generation)
        .map_err(|_| invalid("Identity generation is out of range"))?;
    let language = normalize_language(&snapshot.language)?;
    validate_date(&snapshot.profile.birth_date)?;
    validate_date(&snapshot.profile.formation_date)?;
    if (snapshot.profile.entity_kind == ArtistEntityKind::Person
        && (snapshot.profile.formation_date.is_some()
            || snapshot.profile.formation_place.is_some()))
        || (snapshot.profile.entity_kind == ArtistEntityKind::Group
            && (snapshot.profile.birth_date.is_some() || snapshot.profile.birth_place.is_some()))
    {
        return Err(invalid(
            "Birth and formation fields conflict with artist kind",
        ));
    }
    let payload = serde_json::to_string(&snapshot.profile).map_err(storage)?;
    if payload.len() > MAX_JSON_BYTES {
        return Err(invalid("Profile payload exceeds size limit"));
    }
    let tx = conn.unchecked_transaction().map_err(storage)?;
    // INSERT SELECT cannot create an orphan when a concurrent scan removed the artist.
    tx.execute(
        "INSERT OR IGNORE INTO artist_enrichment_state (artist_id)
         SELECT artist_id FROM artists WHERE artist_id = ?1",
        [snapshot.artist_id],
    )
    .map_err(storage)?;
    let current: Option<i64> = tx
        .query_row(
            "SELECT generation FROM artist_enrichment_state WHERE artist_id = ?1",
            [snapshot.artist_id],
            |r| r.get(0),
        )
        .optional()
        .map_err(storage)?;
    let Some(current) = current else {
        return Err(CoreError::NotFound {
            message: format!("Artist {} not found", snapshot.artist_id),
        });
    };
    if current != generation {
        return Ok(false);
    }
    let changed = tx.execute(
        "INSERT INTO artist_profile_sources
         (artist_id, provider, language, generation, payload_version, payload, fetched_at, expires_at, etag, last_modified)
         VALUES (?1, ?2, ?3, ?4, 1, ?5, ?6, ?7, ?8, ?9)
         ON CONFLICT (artist_id, provider, language) DO UPDATE SET
            generation = excluded.generation, payload_version = excluded.payload_version,
            payload = excluded.payload, fetched_at = excluded.fetched_at,
            expires_at = excluded.expires_at, etag = excluded.etag, last_modified = excluded.last_modified
         WHERE artist_profile_sources.generation != excluded.generation
            OR artist_profile_sources.fetched_at <= excluded.fetched_at",
        params![snapshot.artist_id, snapshot.provider.as_str(), language, generation, payload,
            snapshot.fetched_at, snapshot.expires_at, snapshot.validators.etag, snapshot.validators.last_modified],
    ).map_err(storage)?;
    tx.commit().map_err(storage)?;
    Ok(changed == 1)
}

pub fn profile_validators(
    conn: &Connection,
    artist_id: i64,
    provider: EnrichmentProvider,
    language: &str,
) -> CoreResult<Option<CacheValidators>> {
    let language = normalize_language(language)?;
    conn.query_row(
        "SELECT p.etag, p.last_modified FROM artist_profile_sources p
         JOIN artist_enrichment_state s ON s.artist_id = p.artist_id AND s.generation = p.generation
         WHERE p.artist_id = ?1 AND p.provider = ?2 AND p.language = ?3",
        params![artist_id, provider.as_str(), language],
        |r| {
            Ok(CacheValidators {
                etag: r.get(0)?,
                last_modified: r.get(1)?,
            })
        },
    )
    .optional()
    .map_err(storage)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn database() -> Connection {
        let mut conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("PRAGMA foreign_keys = ON;").unwrap();
        crate::database::operations::create_tables(&conn).unwrap();
        crate::database::migrations::migrate_enrichment(&mut conn).unwrap();
        conn.execute(
            "INSERT INTO artists (artist_id, name) VALUES (7, 'An artist')",
            [],
        )
        .unwrap();
        conn
    }

    fn snapshot() -> ProfileSnapshot {
        ProfileSnapshot {
            artist_id: 7,
            identity_generation: 0,
            provider: EnrichmentProvider::Wikipedia,
            language: "pt-BR".into(),
            fetched_at: 100,
            expires_at: 200,
            validators: CacheValidators {
                etag: Some("\"v1\"".into()),
                last_modified: None,
            },
            profile: ArtistProfile {
                entity_kind: ArtistEntityKind::Person,
                birth_date: Some(ArtistPartialDate {
                    year: 1965,
                    month: None,
                    day: None,
                }),
                birth_place: None,
                formation_date: None,
                formation_place: None,
                origin_place: None,
                biography: Some("A biography".into()),
                attribution: EnrichmentAttribution {
                    source_url: "https://pt.wikipedia.org/wiki/Example".into(),
                    author: None,
                    license_name: Some("CC BY-SA".into()),
                    license_url: None,
                    revision: Some("123".into()),
                },
            },
        }
    }

    #[test]
    fn cache_round_trip_keeps_precision_provenance_and_expired_data() {
        let conn = database();
        let profile = snapshot();
        assert!(store_profile(&conn, &profile).unwrap());
        let details = read_artist_details(&conn, 7, "PT-br", 200).unwrap();
        assert_eq!(details.sources.len(), 1);
        assert_eq!(details.sources[0].profile, profile.profile);
        assert!(details.sources[0].stale);
        assert!(
            read_artist_details(&conn, 7, "en", 100)
                .unwrap()
                .sources
                .is_empty()
        );
        assert_eq!(
            profile_validators(&conn, 7, profile.provider, "pt-br").unwrap(),
            Some(profile.validators)
        );
        assert!(matches!(
            read_artist_details(&conn, 999, "pt", 0),
            Err(CoreError::NotFound { .. })
        ));
    }

    #[test]
    fn replacement_removes_missing_fields_and_rejects_outdated_work() {
        let conn = database();
        let mut profile = snapshot();
        store_profile(&conn, &profile).unwrap();
        profile.profile.biography = None;
        profile.fetched_at = 150;
        store_profile(&conn, &profile).unwrap();
        assert!(!store_profile(&conn, &snapshot()).unwrap());
        assert!(
            read_artist_details(&conn, 7, "pt-br", 160).unwrap().sources[0]
                .profile
                .biography
                .is_none()
        );
        conn.execute("UPDATE artist_enrichment_state SET generation = 1", [])
            .unwrap();
        assert!(!store_profile(&conn, &profile).unwrap());
        assert!(
            read_artist_details(&conn, 7, "pt-br", 160)
                .unwrap()
                .sources
                .is_empty()
        );
        assert!(
            profile_validators(&conn, 7, profile.provider, "pt-br")
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn deleting_artist_cascades_without_creating_local_releases() {
        let conn = database();
        store_profile(&conn, &snapshot()).unwrap();
        assert_eq!(
            conn.query_row("SELECT COUNT(*) FROM releases", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            0
        );
        conn.execute("DELETE FROM artists WHERE artist_id = 7", [])
            .unwrap();
        assert_eq!(
            conn.query_row("SELECT COUNT(*) FROM artist_profile_sources", [], |r| r
                .get::<_, i64>(0))
                .unwrap(),
            0
        );
        assert!(matches!(
            store_profile(&conn, &snapshot()),
            Err(CoreError::NotFound { .. })
        ));
    }

    #[test]
    fn invalid_settings_and_dates_do_not_change_persisted_data() {
        let conn = database();
        let settings = EnrichmentSettings {
            preferred_language: "../en".into(),
            ..Default::default()
        };
        assert!(write_settings(&conn, settings).is_err());
        assert_eq!(read_settings(&conn).unwrap(), EnrichmentSettings::default());
        let mut profile = snapshot();
        profile.profile.birth_date = Some(ArtistPartialDate {
            year: 2023,
            month: Some(2),
            day: Some(29),
        });
        assert!(store_profile(&conn, &profile).is_err());
        assert!(
            read_artist_details(&conn, 7, "pt-br", 0)
                .unwrap()
                .sources
                .is_empty()
        );
    }
}
