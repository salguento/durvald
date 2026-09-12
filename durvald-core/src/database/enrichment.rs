//! Synchronous enrichment persistence. Call through a blocking task, never over HTTP.

use crate::api::*;
use crate::enrichment::models::{AssetSnapshot, CacheValidators, ProfileSnapshot};
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
    crate::database::identity::read(conn, artist_id)?;
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
        portrait: None,
        overrides: Vec::new(),
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
    details.portrait = tx
        .query_row(
            "SELECT provider, provider_id, source_url, managed_path, width, height,
                    attribution, fetched_at, expires_at
             FROM enrichment_assets
             WHERE artist_id = ?1 AND generation = ?2 AND provider = 'commons'",
            params![artist_id, row.3],
            |asset| {
                let attribution: String = asset.get(6)?;
                let expires_at: i64 = asset.get(8)?;
                Ok(ArtistImageReference {
                    provider: decode_enum(asset.get(0)?)
                        .map_err(|_| rusqlite::Error::InvalidQuery)?,
                    provider_id: asset.get(1)?,
                    source_url: asset.get(2)?,
                    managed_path: asset.get(3)?,
                    width: asset.get(4)?,
                    height: asset.get(5)?,
                    attribution: serde_json::from_str(&attribution)
                        .map_err(|_| rusqlite::Error::InvalidQuery)?,
                    fetched_at: asset.get(7)?,
                    expires_at,
                    stale: now >= expires_at,
                })
            },
        )
        .optional()
        .map_err(storage)?;
    {
        let mut stmt = tx
            .prepare(
                "SELECT field, language, value FROM artist_profile_overrides
                 WHERE artist_id = ?1 AND language IN (?2, 'und')
                 ORDER BY field, language",
            )
            .map_err(storage)?;
        let rows = stmt
            .query_map(params![artist_id, language], |override_row| {
                Ok((
                    override_row.get::<_, String>(0)?,
                    override_row.get::<_, String>(1)?,
                    override_row.get::<_, Option<String>>(2)?,
                ))
            })
            .map_err(storage)?;
        for row in rows {
            let (field, language, value) = row.map_err(storage)?;
            details.overrides.push(ArtistFieldOverride {
                field: decode_enum(field)?,
                language,
                value,
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

/// Renews a cached representation after a conditional request returned 304.
/// The generation guard prevents old in-flight work from reviving stale data.
pub fn touch_profile(
    conn: &Connection,
    artist_id: i64,
    generation: u64,
    provider: EnrichmentProvider,
    language: &str,
    fetched_at: i64,
    expires_at: i64,
    validators: &CacheValidators,
) -> CoreResult<bool> {
    if expires_at < fetched_at {
        return Err(invalid("Invalid profile expiry"));
    }
    let generation = i64::try_from(generation).map_err(storage)?;
    let language = normalize_language(language)?;
    let changed = conn
        .execute(
            "UPDATE artist_profile_sources SET fetched_at = ?5, expires_at = ?6,
                etag = ?7, last_modified = ?8
             WHERE artist_id = ?1 AND provider = ?2 AND language = ?3 AND generation = ?4
               AND EXISTS (
                 SELECT 1 FROM artist_enrichment_state s
                 WHERE s.artist_id = ?1 AND s.generation = ?4
               )",
            params![
                artist_id,
                provider.as_str(),
                language,
                generation,
                fetched_at,
                expires_at,
                validators.etag,
                validators.last_modified
            ],
        )
        .map_err(storage)?;
    Ok(changed == 1)
}

pub fn external_id(
    conn: &Connection,
    artist_id: i64,
    generation: u64,
    provider: EnrichmentProvider,
) -> CoreResult<Option<String>> {
    let generation = i64::try_from(generation).map_err(storage)?;
    conn.query_row(
        "SELECT external_id FROM artist_external_ids
         WHERE artist_id = ?1 AND provider = ?2 AND generation = ?3",
        params![artist_id, provider.as_str(), generation],
        |row| row.get(0),
    )
    .optional()
    .map_err(storage)
}

pub fn store_external_id(
    conn: &Connection,
    artist_id: i64,
    generation: u64,
    provider: EnrichmentProvider,
    external_id: &str,
    origin: &str,
    fetched_at: i64,
) -> CoreResult<bool> {
    let generation = i64::try_from(generation).map_err(storage)?;
    let tx = conn.unchecked_transaction().map_err(storage)?;
    let current: Option<i64> = tx
        .query_row(
            "SELECT generation FROM artist_enrichment_state WHERE artist_id = ?1",
            [artist_id],
            |row| row.get(0),
        )
        .optional()
        .map_err(storage)?;
    if current != Some(generation) {
        return Ok(false);
    }
    tx.execute(
        "INSERT INTO artist_external_ids
         (artist_id, provider, external_id, generation, origin, fetched_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)
         ON CONFLICT (artist_id, provider) DO UPDATE SET
           external_id = excluded.external_id, generation = excluded.generation,
           origin = excluded.origin, fetched_at = excluded.fetched_at",
        params![
            artist_id,
            provider.as_str(),
            external_id,
            generation,
            origin,
            fetched_at
        ],
    )
    .map_err(storage)?;
    tx.commit().map_err(storage)?;
    Ok(true)
}

pub fn replace_external_id(
    conn: &Connection,
    artist_id: i64,
    generation: u64,
    provider: EnrichmentProvider,
    external_id: Option<&str>,
    origin: &str,
    fetched_at: i64,
) -> CoreResult<bool> {
    let generation_i64 = i64::try_from(generation).map_err(storage)?;
    let current: Option<i64> = conn
        .query_row(
            "SELECT generation FROM artist_enrichment_state WHERE artist_id = ?1",
            [artist_id],
            |row| row.get(0),
        )
        .optional()
        .map_err(storage)?;
    if current != Some(generation_i64) {
        return Ok(false);
    }
    match external_id {
        Some(external_id) => store_external_id(
            conn,
            artist_id,
            generation,
            provider,
            external_id,
            origin,
            fetched_at,
        ),
        None => {
            conn.execute(
                "DELETE FROM artist_external_ids
                 WHERE artist_id = ?1 AND provider = ?2 AND generation = ?3",
                params![artist_id, provider.as_str(), generation_i64],
            )
            .map_err(storage)?;
            Ok(true)
        }
    }
}

/// Stores only metadata for an already validated managed file. A generation
/// mismatch leaves the file unreferenced so the caller can remove it safely.
pub fn store_asset(conn: &Connection, snapshot: &AssetSnapshot) -> CoreResult<bool> {
    if snapshot.artist_id < 0
        || snapshot.provider_id.trim().is_empty()
        || snapshot.source_url.trim().is_empty()
        || snapshot.managed_path.trim().is_empty()
        || !std::path::Path::new(&snapshot.managed_path).is_absolute()
        || snapshot.expires_at < snapshot.fetched_at
    {
        return Err(invalid("Invalid enrichment asset"));
    }
    let generation = i64::try_from(snapshot.identity_generation).map_err(storage)?;
    let attribution = serde_json::to_string(&snapshot.attribution).map_err(storage)?;
    let tx = conn.unchecked_transaction().map_err(storage)?;
    let current: Option<i64> = tx
        .query_row(
            "SELECT generation FROM artist_enrichment_state WHERE artist_id = ?1",
            [snapshot.artist_id],
            |row| row.get(0),
        )
        .optional()
        .map_err(storage)?;
    if current != Some(generation) {
        return Ok(false);
    }
    tx.execute(
        "INSERT INTO enrichment_assets
         (artist_id, provider, provider_id, generation, source_url, managed_path,
          width, height, attribution, fetched_at, expires_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
         ON CONFLICT (artist_id, provider) DO UPDATE SET
           provider_id = excluded.provider_id, generation = excluded.generation,
           source_url = excluded.source_url, managed_path = excluded.managed_path,
           width = excluded.width, height = excluded.height,
           attribution = excluded.attribution, fetched_at = excluded.fetched_at,
           expires_at = excluded.expires_at
         WHERE enrichment_assets.generation != excluded.generation
            OR enrichment_assets.fetched_at <= excluded.fetched_at",
        params![
            snapshot.artist_id,
            snapshot.provider.as_str(),
            snapshot.provider_id,
            generation,
            snapshot.source_url,
            snapshot.managed_path,
            snapshot.width,
            snapshot.height,
            attribution,
            snapshot.fetched_at,
            snapshot.expires_at,
        ],
    )
    .map_err(storage)?;
    tx.commit().map_err(storage)?;
    Ok(true)
}

pub fn asset_path(
    conn: &Connection,
    artist_id: i64,
    provider: EnrichmentProvider,
) -> CoreResult<Option<String>> {
    conn.query_row(
        "SELECT managed_path FROM enrichment_assets
         WHERE artist_id = ?1 AND provider = ?2",
        params![artist_id, provider.as_str()],
        |row| row.get(0),
    )
    .optional()
    .map_err(storage)
}

pub fn path_is_referenced(conn: &Connection, path: &str) -> CoreResult<bool> {
    conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM enrichment_assets WHERE managed_path = ?1)
             OR EXISTS(SELECT 1 FROM songs WHERE artwork = ?1)
             OR EXISTS(SELECT 1 FROM releases WHERE artwork = ?1)",
        [path],
        |row| row.get(0),
    )
    .map_err(storage)
}

/// Drops only asset rows belonging to obsolete identity generations and
/// returns paths that no remaining database row references.
pub fn collect_stale_asset_paths(conn: &Connection) -> CoreResult<Vec<String>> {
    let tx = conn.unchecked_transaction().map_err(storage)?;
    let paths = {
        let mut stmt = tx
            .prepare(
                "SELECT DISTINCT a.managed_path FROM enrichment_assets a
                 JOIN artist_enrichment_state s USING (artist_id)
                 WHERE a.generation != s.generation",
            )
            .map_err(storage)?;
        stmt.query_map([], |row| row.get::<_, String>(0))
            .map_err(storage)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(storage)?
    };
    tx.execute(
        "DELETE FROM enrichment_assets
         WHERE EXISTS (
           SELECT 1 FROM artist_enrichment_state s
           WHERE s.artist_id = enrichment_assets.artist_id
             AND s.generation != enrichment_assets.generation
         )",
        [],
    )
    .map_err(storage)?;
    let mut orphaned = Vec::new();
    for path in paths {
        let referenced: bool = tx
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM enrichment_assets WHERE managed_path = ?1)
                     OR EXISTS(SELECT 1 FROM songs WHERE artwork = ?1)
                     OR EXISTS(SELECT 1 FROM releases WHERE artwork = ?1)",
                [&path],
                |row| row.get(0),
            )
            .map_err(storage)?;
        if !referenced {
            orphaned.push(path);
        }
    }
    tx.commit().map_err(storage)?;
    Ok(orphaned)
}

pub fn set_override(
    conn: &Connection,
    artist_id: i64,
    mut value: ArtistFieldOverride,
) -> CoreResult<()> {
    crate::database::identity::read(conn, artist_id)?;
    value.language = override_language(value.field, &value.language)?;
    validate_override_value(value.field, value.value.as_deref())?;
    conn.execute(
        "INSERT INTO artist_profile_overrides (artist_id, field, language, value, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5)
         ON CONFLICT (artist_id, field, language) DO UPDATE SET
           value = excluded.value, updated_at = excluded.updated_at",
        params![
            artist_id,
            value.field.as_str(),
            value.language,
            value.value,
            chrono::Utc::now().timestamp()
        ],
    )
    .map_err(storage)?;
    Ok(())
}

pub fn clear_override(
    conn: &Connection,
    artist_id: i64,
    field: ArtistProfileField,
    language: &str,
) -> CoreResult<()> {
    crate::database::identity::read(conn, artist_id)?;
    let language = override_language(field, language)?;
    conn.execute(
        "DELETE FROM artist_profile_overrides
         WHERE artist_id = ?1 AND field = ?2 AND language = ?3",
        params![artist_id, field.as_str(), language],
    )
    .map_err(storage)?;
    Ok(())
}

fn override_language(field: ArtistProfileField, language: &str) -> CoreResult<String> {
    if field == ArtistProfileField::Biography {
        normalize_language(language)
    } else {
        Ok("und".into())
    }
}

fn validate_override_value(field: ArtistProfileField, value: Option<&str>) -> CoreResult<()> {
    let Some(value) = value else { return Ok(()) };
    let value = value.trim();
    if value.is_empty() || value.len() > MAX_JSON_BYTES {
        return Err(invalid("Override value is empty or too large"));
    }
    match field {
        ArtistProfileField::EntityKind => {
            if !matches!(value, "person" | "group" | "other" | "unknown") {
                return Err(invalid("Invalid artist entity kind override"));
            }
        }
        ArtistProfileField::BirthDate | ArtistProfileField::FormationDate => {
            parse_partial_date(value)?;
        }
        _ => {}
    }
    Ok(())
}

fn parse_partial_date(value: &str) -> CoreResult<ArtistPartialDate> {
    let fields: Vec<_> = value.split('-').collect();
    if !(1..=3).contains(&fields.len()) {
        return Err(invalid("Expected date as YYYY, YYYY-MM or YYYY-MM-DD"));
    }
    let date = ArtistPartialDate {
        year: fields[0]
            .parse()
            .map_err(|_| invalid("Invalid partial date year"))?,
        month: fields
            .get(1)
            .map(|v| v.parse())
            .transpose()
            .map_err(|_| invalid("Invalid partial date month"))?,
        day: fields
            .get(2)
            .map(|v| v.parse())
            .transpose()
            .map_err(|_| invalid("Invalid partial date day"))?,
    };
    validate_date(&Some(date.clone()))?;
    Ok(date)
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
        let renewed = CacheValidators {
            etag: Some("\"v2\"".into()),
            last_modified: Some("Sat, 12 Sep 2026 12:00:00 GMT".into()),
        };
        assert!(
            touch_profile(
                &conn,
                7,
                0,
                EnrichmentProvider::Wikipedia,
                "pt-br",
                200,
                300,
                &renewed,
            )
            .unwrap()
        );
        assert!(!read_artist_details(&conn, 7, "pt-br", 250).unwrap().sources[0].stale);
        assert_eq!(
            profile_validators(&conn, 7, profile.provider, "pt-br").unwrap(),
            Some(renewed)
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

    #[test]
    fn derived_external_ids_are_scoped_to_identity_generation() {
        let conn = database();
        crate::database::identity::read(&conn, 7).unwrap();
        assert!(
            store_external_id(
                &conn,
                7,
                0,
                EnrichmentProvider::Wikidata,
                "Q123",
                "musicbrainz_relation",
                100,
            )
            .unwrap()
        );
        assert_eq!(
            external_id(&conn, 7, 0, EnrichmentProvider::Wikidata).unwrap(),
            Some("Q123".into())
        );
        conn.execute("UPDATE artist_enrichment_state SET generation = 1", [])
            .unwrap();
        assert!(
            external_id(&conn, 7, 1, EnrichmentProvider::Wikidata)
                .unwrap()
                .is_none()
        );
        assert!(
            !store_external_id(
                &conn,
                7,
                0,
                EnrichmentProvider::Wikidata,
                "Q999",
                "musicbrainz_relation",
                101,
            )
            .unwrap()
        );
    }

    #[test]
    fn commons_asset_round_trip_is_generation_scoped_and_offline_readable() {
        let conn = database();
        crate::database::identity::read(&conn, 7).unwrap();
        let asset = AssetSnapshot {
            artist_id: 7,
            identity_generation: 0,
            provider: EnrichmentProvider::Commons,
            provider_id: "Portrait.jpg".into(),
            source_url: "https://commons.wikimedia.org/wiki/File:Portrait.jpg".into(),
            managed_path: "/managed/covers/hash.jpg".into(),
            width: Some(1200),
            height: Some(800),
            attribution: EnrichmentAttribution {
                source_url: "https://commons.wikimedia.org/wiki/File:Portrait.jpg".into(),
                author: Some("Photographer".into()),
                license_name: Some("CC BY-SA 4.0".into()),
                license_url: Some("https://creativecommons.org/licenses/by-sa/4.0/".into()),
                revision: None,
            },
            fetched_at: 100,
            expires_at: 200,
        };
        assert!(store_asset(&conn, &asset).unwrap());
        let portrait = read_artist_details(&conn, 7, "pt", 200)
            .unwrap()
            .portrait
            .unwrap();
        assert_eq!(portrait.provider_id, "Portrait.jpg");
        assert_eq!(portrait.managed_path, "/managed/covers/hash.jpg");
        assert_eq!(portrait.attribution, asset.attribution);
        assert!(portrait.stale);
        conn.execute("UPDATE artist_enrichment_state SET generation = 1", [])
            .unwrap();
        assert!(
            read_artist_details(&conn, 7, "pt", 200)
                .unwrap()
                .portrait
                .is_none()
        );
        assert!(!store_asset(&conn, &asset).unwrap());
        assert_eq!(
            collect_stale_asset_paths(&conn).unwrap(),
            vec!["/managed/covers/hash.jpg"]
        );
        assert_eq!(
            conn.query_row("SELECT COUNT(*) FROM enrichment_assets", [], |row| row
                .get::<_, i64>(0))
                .unwrap(),
            0
        );
    }

    #[test]
    fn manual_overrides_are_validated_language_scoped_and_generation_independent() {
        let conn = database();
        set_override(
            &conn,
            7,
            ArtistFieldOverride {
                field: ArtistProfileField::Biography,
                language: "PT-br".into(),
                value: Some("Biografia revisada".into()),
            },
        )
        .unwrap();
        set_override(
            &conn,
            7,
            ArtistFieldOverride {
                field: ArtistProfileField::BirthDate,
                language: "en".into(),
                value: Some("1965-07".into()),
            },
        )
        .unwrap();
        set_override(
            &conn,
            7,
            ArtistFieldOverride {
                field: ArtistProfileField::BirthPlace,
                language: "pt".into(),
                value: None,
            },
        )
        .unwrap();

        let details = read_artist_details(&conn, 7, "pt-BR", 0).unwrap();
        assert_eq!(details.overrides.len(), 3);
        assert!(details.overrides.iter().any(|value| {
            value.field == ArtistProfileField::Biography
                && value.language == "pt-br"
                && value.value.as_deref() == Some("Biografia revisada")
        }));
        assert!(details.overrides.iter().any(|value| {
            value.field == ArtistProfileField::BirthDate && value.language == "und"
        }));
        assert!(details.overrides.iter().any(|value| {
            value.field == ArtistProfileField::BirthPlace && value.value.is_none()
        }));
        assert!(
            read_artist_details(&conn, 7, "en", 0)
                .unwrap()
                .overrides
                .iter()
                .all(|value| value.field != ArtistProfileField::Biography)
        );

        conn.execute("UPDATE artist_enrichment_state SET generation = 1", [])
            .unwrap();
        assert_eq!(
            read_artist_details(&conn, 7, "pt-br", 0)
                .unwrap()
                .overrides
                .len(),
            3
        );
        clear_override(&conn, 7, ArtistProfileField::Biography, "pt-BR").unwrap();
        assert!(
            read_artist_details(&conn, 7, "pt-br", 0)
                .unwrap()
                .overrides
                .iter()
                .all(|value| value.field != ArtistProfileField::Biography)
        );
    }

    #[test]
    fn invalid_manual_overrides_are_rejected_without_writes() {
        let conn = database();
        for (field, value) in [
            (ArtistProfileField::BirthDate, "2023-02-29"),
            (ArtistProfileField::FormationDate, "2000-13"),
            (ArtistProfileField::EntityKind, "duo"),
            (ArtistProfileField::OriginPlace, "   "),
        ] {
            assert!(
                set_override(
                    &conn,
                    7,
                    ArtistFieldOverride {
                        field,
                        language: "pt".into(),
                        value: Some(value.into()),
                    },
                )
                .is_err()
            );
        }
        assert!(
            read_artist_details(&conn, 7, "pt", 0)
                .unwrap()
                .overrides
                .is_empty()
        );
    }
}
