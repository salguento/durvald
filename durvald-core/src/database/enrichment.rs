//! Synchronous enrichment persistence. Call through a blocking task, never over HTTP.

use crate::api::*;
use crate::enrichment::identity::normalized_match_text;
use crate::enrichment::models::{
    AssetSnapshot, CacheValidators, CachedProviderFailure, DiscographyBuildState,
    DiscographyPageSnapshot, DiscographyRefreshState, ExternalArtworkNegativeSnapshot,
    ExternalArtworkRefreshPlan, ExternalArtworkRefreshTarget, ExternalArtworkSnapshot,
    ExternalArtworkStoreOutcome, ExternalReleaseDetailsSnapshot, LocalReleaseMatchContext,
    LocalReleaseTrackContext, MatchedReleaseMetadata, PopularTracksSnapshot, ProfileSnapshot,
    ProviderFailureSnapshot, ReleaseGroupSnapshot,
};
use crate::enrichment::policy::{MAX_JSON_BYTES, normalize_language, normalized_settings};
use rusqlite::{Connection, OptionalExtension, Transaction, TransactionBehavior, params};
use serde::de::DeserializeOwned;

fn storage(error: impl std::fmt::Display + 'static) -> CoreError {
    crate::database::storage_error("Enrichment storage", error)
}

fn invalid(message: &str) -> CoreError {
    CoreError::InvalidInput {
        message: message.into(),
    }
}

fn decode_enum<T: DeserializeOwned>(value: String) -> CoreResult<T> {
    serde_json::from_value(serde_json::Value::String(value)).map_err(storage)
}

pub fn active_provider_failure(
    conn: &Connection,
    artist_id: i64,
    identity_generation: u64,
    provider: EnrichmentProvider,
    operation: &str,
    resource_key: &str,
    now: i64,
) -> CoreResult<Option<CachedProviderFailure>> {
    if artist_id < 0 || operation.is_empty() || resource_key.len() != 32 {
        return Err(invalid("Invalid provider failure lookup"));
    }
    let generation = i64::try_from(identity_generation).map_err(storage)?;
    conn.query_row(
        "SELECT error_code, retry_after_seconds
         FROM enrichment_provider_failures
         WHERE artist_id = ?1 AND provider = ?2 AND operation = ?3
           AND resource_key = ?4 AND identity_generation = ?5 AND expires_at > ?6",
        params![
            artist_id,
            provider.as_str(),
            operation,
            resource_key,
            generation,
            now
        ],
        |row| {
            let retry_after = row.get::<_, Option<i64>>(1)?;
            Ok(CachedProviderFailure {
                error_code: row.get(0)?,
                retry_after_seconds: retry_after.and_then(|value| u64::try_from(value).ok()),
            })
        },
    )
    .optional()
    .map_err(storage)
}

pub fn store_provider_failure(
    conn: &Connection,
    snapshot: &ProviderFailureSnapshot,
) -> CoreResult<bool> {
    if snapshot.artist_id < 0
        || snapshot.operation.is_empty()
        || snapshot.operation.len() > 64
        || snapshot.resource_key.len() != 32
        || snapshot.error_code.is_empty()
        || snapshot.error_code.len() > 64
        || snapshot.expires_at < snapshot.recorded_at
    {
        return Err(invalid("Invalid provider failure snapshot"));
    }
    let generation = i64::try_from(snapshot.identity_generation).map_err(storage)?;
    let retry_after = snapshot
        .retry_after_seconds
        .map(i64::try_from)
        .transpose()
        .map_err(storage)?;
    let tx = conn.unchecked_transaction().map_err(storage)?;
    let current = tx
        .query_row(
            "SELECT generation FROM artist_enrichment_state WHERE artist_id = ?1",
            [snapshot.artist_id],
            |row| row.get::<_, i64>(0),
        )
        .optional()
        .map_err(storage)?;
    if current != Some(generation) {
        tx.rollback().map_err(storage)?;
        return Ok(false);
    }
    tx.execute(
        "INSERT INTO enrichment_provider_failures
         (artist_id, provider, operation, resource_key, identity_generation,
          error_code, retry_after_seconds, recorded_at, expires_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
         ON CONFLICT (artist_id, provider, operation) DO UPDATE SET
           resource_key = excluded.resource_key,
           identity_generation = excluded.identity_generation,
           error_code = excluded.error_code,
           retry_after_seconds = excluded.retry_after_seconds,
           recorded_at = excluded.recorded_at,
           expires_at = excluded.expires_at",
        params![
            snapshot.artist_id,
            snapshot.provider.as_str(),
            snapshot.operation,
            snapshot.resource_key,
            generation,
            snapshot.error_code,
            retry_after,
            snapshot.recorded_at,
            snapshot.expires_at,
        ],
    )
    .map_err(storage)?;
    tx.commit().map_err(storage)?;
    Ok(true)
}

pub fn clear_provider_failure(
    conn: &Connection,
    artist_id: i64,
    identity_generation: u64,
    provider: EnrichmentProvider,
    operation: &str,
) -> CoreResult<()> {
    let generation = i64::try_from(identity_generation).map_err(storage)?;
    conn.execute(
        "DELETE FROM enrichment_provider_failures
         WHERE artist_id = ?1 AND provider = ?2 AND operation = ?3
           AND identity_generation = ?4",
        params![artist_id, provider.as_str(), operation, generation],
    )
    .map_err(storage)?;
    Ok(())
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
             WHERE artist_id = ?1 AND generation = ?2
               AND provider IN ('last_fm', 'commons') AND catalog_key = ''
             ORDER BY CASE provider WHEN 'last_fm' THEN 0 ELSE 1 END
             LIMIT 1",
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
#[allow(clippy::too_many_arguments)]
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
         (artist_id, provider, catalog_key, provider_id, generation, source_url, managed_path,
          width, height, attribution, fetched_at, expires_at)
         VALUES (?1, ?2, '', ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
         ON CONFLICT (artist_id, provider, catalog_key) DO UPDATE SET
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

/// Stores an external catalog cover without ever writing `releases.artwork`.
/// Exact-release artwork is accepted only when the local identifier mapping
/// proves that the edition belongs to this artist and release-group.
pub fn store_external_artwork(
    conn: &Connection,
    snapshot: &ExternalArtworkSnapshot,
) -> CoreResult<ExternalArtworkStoreOutcome> {
    let release_group_mbid =
        crate::enrichment::identity::normalize_mbid(&snapshot.release_group_mbid)
            .ok_or_else(|| invalid("Invalid release-group MBID"))?;
    let exact_release_mbid = snapshot
        .exact_release_mbid
        .as_deref()
        .map(|value| {
            crate::enrichment::identity::normalize_mbid(value)
                .ok_or_else(|| invalid("Invalid release MBID"))
        })
        .transpose()?;
    let scope = match snapshot.scope {
        ExternalArtworkScope::ExactRelease if exact_release_mbid.is_some() => "exact_release",
        ExternalArtworkScope::ReleaseGroup if exact_release_mbid.is_none() => "release_group",
        _ => return Err(invalid("Artwork scope does not match its identifiers")),
    };
    if snapshot.artist_id < 0
        || snapshot.provider_id.trim().is_empty()
        || snapshot.provider_id.len() > 100
        || snapshot.source_url.trim().is_empty()
        || snapshot.managed_path.trim().is_empty()
        || !std::path::Path::new(&snapshot.managed_path).is_absolute()
        || snapshot.width == 0
        || snapshot.height == 0
        || snapshot.width > crate::metadata::MAX_ARTWORK_DIMENSION
        || snapshot.height > crate::metadata::MAX_ARTWORK_DIMENSION
        || snapshot.expires_at < snapshot.fetched_at
    {
        return Err(invalid("Invalid external artwork snapshot"));
    }
    let generation = i64::try_from(snapshot.identity_generation).map_err(storage)?;
    let catalog_key = exact_release_mbid.as_ref().map_or_else(
        || format!("release-group:{release_group_mbid}"),
        |release| format!("release:{release}"),
    );
    let attribution = serde_json::to_string(&snapshot.attribution).map_err(storage)?;
    if attribution.len() > MAX_JSON_BYTES {
        return Err(invalid("Artwork attribution exceeds size limit"));
    }

    let tx = conn.unchecked_transaction().map_err(storage)?;
    let current_catalog: bool = tx
        .query_row(
            "SELECT EXISTS(
               SELECT 1 FROM external_artist_release_groups ar
               JOIN artist_discography_state d USING (artist_id)
               JOIN artist_enrichment_state s USING (artist_id)
               WHERE ar.artist_id = ?1 AND ar.release_group_mbid = ?2
                 AND ar.identity_generation = ?3
                 AND ar.catalog_generation = d.active_generation
                 AND d.identity_generation = ?3 AND s.generation = ?3
             )",
            params![snapshot.artist_id, release_group_mbid, generation],
            |row| row.get(0),
        )
        .map_err(storage)?;
    if !current_catalog {
        return Ok(ExternalArtworkStoreOutcome {
            stored: false,
            orphaned_path: None,
        });
    }
    if let Some(release_mbid) = &exact_release_mbid {
        let confirmed_local_edition: bool = tx
            .query_row(
                "SELECT EXISTS(
                   SELECT 1 FROM local_release_external_ids l
                   JOIN releases r ON r.release_id = l.release_id
                   WHERE r.artist_id = ?1 AND l.release_group_mbid = ?2
                     AND l.release_mbid = ?3
                 )",
                params![snapshot.artist_id, release_group_mbid, release_mbid],
                |row| row.get(0),
            )
            .map_err(storage)?;
        if !confirmed_local_edition {
            return Err(invalid("Exact artwork has no confirmed local release"));
        }
    }
    let previous_path = tx
        .query_row(
            "SELECT managed_path FROM enrichment_assets
             WHERE artist_id = ?1 AND provider = 'cover_art_archive'
               AND catalog_key = ?2",
            params![snapshot.artist_id, catalog_key],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .map_err(storage)?;
    let changed = tx
        .execute(
            "INSERT INTO enrichment_assets
             (artist_id, provider, catalog_key, provider_id, generation,
              release_group_mbid, exact_release_mbid, artwork_scope,
              source_url, managed_path, width, height, attribution,
              fetched_at, expires_at)
             VALUES (?1, 'cover_art_archive', ?2, ?3, ?4, ?5, ?6, ?7,
                     ?8, ?9, ?10, ?11, ?12, ?13, ?14)
             ON CONFLICT (artist_id, provider, catalog_key) DO UPDATE SET
               provider_id = excluded.provider_id,
               generation = excluded.generation,
               release_group_mbid = excluded.release_group_mbid,
               exact_release_mbid = excluded.exact_release_mbid,
               artwork_scope = excluded.artwork_scope,
               source_url = excluded.source_url,
               managed_path = excluded.managed_path,
               width = excluded.width, height = excluded.height,
               attribution = excluded.attribution,
               fetched_at = excluded.fetched_at,
               expires_at = excluded.expires_at
             WHERE enrichment_assets.generation != excluded.generation
                OR enrichment_assets.fetched_at <= excluded.fetched_at",
            params![
                snapshot.artist_id,
                catalog_key,
                snapshot.provider_id,
                generation,
                release_group_mbid,
                exact_release_mbid,
                scope,
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
    let orphaned_path = if changed == 1 {
        previous_path
            .filter(|path| path != &snapshot.managed_path)
            .map(|path| {
                let referenced: bool = tx
                    .query_row(
                        "SELECT EXISTS(
                           SELECT 1 FROM enrichment_assets WHERE managed_path = ?1
                         ) OR EXISTS(
                           SELECT 1 FROM songs WHERE artwork = ?1
                         ) OR EXISTS(
                           SELECT 1 FROM releases WHERE artwork = ?1
                         )",
                        [&path],
                        |row| row.get(0),
                    )
                    .map_err(storage)?;
                Ok((!referenced).then_some(path))
            })
            .transpose()?
            .flatten()
    } else {
        None
    };
    if changed == 1 {
        tx.execute(
            "DELETE FROM external_artwork_negative_results
             WHERE artist_id = ?1 AND catalog_key = ?2",
            params![snapshot.artist_id, catalog_key],
        )
        .map_err(storage)?;
    }
    tx.commit().map_err(storage)?;
    Ok(ExternalArtworkStoreOutcome {
        stored: changed == 1,
        orphaned_path,
    })
}

/// Persists a bounded negative cover lookup only while the target still
/// belongs to the active identity and catalog snapshot. Old generations and
/// changed local release MBIDs are therefore ignored without blocking a new
/// lookup.
pub fn store_external_artwork_negative_result(
    conn: &Connection,
    snapshot: &ExternalArtworkNegativeSnapshot,
) -> CoreResult<bool> {
    let release_group_mbid =
        crate::enrichment::identity::normalize_mbid(&snapshot.release_group_mbid)
            .ok_or_else(|| invalid("Invalid release-group MBID"))?;
    let exact_release_mbid = snapshot
        .exact_release_mbid
        .as_deref()
        .map(|value| {
            crate::enrichment::identity::normalize_mbid(value)
                .ok_or_else(|| invalid("Invalid release MBID"))
        })
        .transpose()?;
    if snapshot.artist_id < 0
        || snapshot.expires_at < snapshot.recorded_at
        || snapshot.last_error.is_empty()
        || snapshot.last_error.len() > 64
        || !snapshot
            .last_error
            .bytes()
            .all(|value| value.is_ascii_alphanumeric() || matches!(value, b'_' | b'-'))
    {
        return Err(invalid("Invalid external artwork negative result"));
    }
    let identity_generation = i64::try_from(snapshot.identity_generation).map_err(storage)?;
    let catalog_generation = i64::try_from(snapshot.catalog_generation).map_err(storage)?;
    if catalog_generation <= 0 {
        return Err(invalid("Invalid external artwork catalog generation"));
    }
    let catalog_key = exact_release_mbid.as_ref().map_or_else(
        || format!("release-group:{release_group_mbid}"),
        |release| format!("release:{release}"),
    );

    let tx = conn.unchecked_transaction().map_err(storage)?;
    let current_target = tx
        .query_row(
            "SELECT d.active_generation,
                    (SELECT l.release_mbid
                     FROM local_release_external_ids l
                     JOIN releases r ON r.release_id = l.release_id
                     WHERE r.artist_id = ?1
                       AND l.release_group_mbid = ar.release_group_mbid
                       AND l.release_mbid IS NOT NULL
                     ORDER BY l.release_id LIMIT 1)
             FROM external_artist_release_groups ar
             JOIN artist_discography_state d USING (artist_id)
             JOIN artist_enrichment_state s USING (artist_id)
             WHERE ar.artist_id = ?1 AND ar.release_group_mbid = ?2
               AND ar.identity_generation = ?3
               AND ar.catalog_generation = ?4
               AND d.identity_generation = ?3
               AND d.active_generation = ?4
               AND s.generation = ?3",
            params![
                snapshot.artist_id,
                release_group_mbid,
                identity_generation,
                catalog_generation
            ],
            |row| Ok((row.get::<_, i64>(0)?, row.get::<_, Option<String>>(1)?)),
        )
        .optional()
        .map_err(storage)?;
    let Some((active_generation, current_exact_release_mbid)) = current_target else {
        tx.commit().map_err(storage)?;
        return Ok(false);
    };
    if active_generation != catalog_generation || current_exact_release_mbid != exact_release_mbid {
        tx.commit().map_err(storage)?;
        return Ok(false);
    }
    tx.execute(
        "INSERT INTO external_artwork_negative_results
         (artist_id, catalog_key, release_group_mbid, exact_release_mbid,
          identity_generation, catalog_generation, result, recorded_at, expires_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
         ON CONFLICT (artist_id, catalog_key) DO UPDATE SET
           release_group_mbid = excluded.release_group_mbid,
           exact_release_mbid = excluded.exact_release_mbid,
           identity_generation = excluded.identity_generation,
           catalog_generation = excluded.catalog_generation,
           result = excluded.result,
           recorded_at = excluded.recorded_at,
           expires_at = excluded.expires_at
         WHERE external_artwork_negative_results.identity_generation != excluded.identity_generation
            OR external_artwork_negative_results.catalog_generation != excluded.catalog_generation
            OR external_artwork_negative_results.recorded_at <= excluded.recorded_at",
        params![
            snapshot.artist_id,
            catalog_key,
            release_group_mbid,
            exact_release_mbid,
            identity_generation,
            catalog_generation,
            snapshot.result.as_str(),
            snapshot.recorded_at,
            snapshot.expires_at,
        ],
    )
    .map_err(storage)?;
    let queue_state = match snapshot.result {
        crate::enrichment::models::ExternalArtworkNegativeResult::NotFound => "absent",
        crate::enrichment::models::ExternalArtworkNegativeResult::InvalidImage
        | crate::enrichment::models::ExternalArtworkNegativeResult::TemporaryFailure => "blocked",
    };
    tx.execute(
        "UPDATE external_artwork_queue
         SET state = ?3, next_attempt_at = ?4, last_error = ?5, updated_at = ?6
         WHERE artist_id = ?1 AND catalog_key = ?2
           AND identity_generation = ?7 AND catalog_generation = ?8",
        params![
            snapshot.artist_id,
            catalog_key,
            queue_state,
            snapshot.expires_at,
            snapshot.last_error,
            snapshot.recorded_at,
            identity_generation,
            catalog_generation,
        ],
    )
    .map_err(storage)?;
    tx.commit().map_err(storage)?;
    Ok(true)
}

pub fn complete_external_artwork_queue_target(
    conn: &Connection,
    artist_id: i64,
    identity_generation: u64,
    catalog_generation: u64,
    catalog_key: &str,
    now: i64,
) -> CoreResult<bool> {
    if artist_id < 0 || catalog_key.len() > 128 {
        return Err(invalid("Invalid external artwork queue target"));
    }
    let identity_generation = i64::try_from(identity_generation).map_err(storage)?;
    let catalog_generation = i64::try_from(catalog_generation).map_err(storage)?;
    let changed = conn
        .execute(
            "UPDATE external_artwork_queue
             SET state = 'completed', next_attempt_at = NULL,
                 last_error = NULL, updated_at = ?5
             WHERE artist_id = ?1 AND catalog_key = ?2
               AND identity_generation = ?3 AND catalog_generation = ?4
               AND EXISTS(
                 SELECT 1 FROM artist_enrichment_state s
                 JOIN artist_discography_state d USING (artist_id)
                 WHERE s.artist_id = ?1 AND s.generation = ?3
                   AND d.identity_generation = ?3 AND d.active_generation = ?4
               )",
            params![
                artist_id,
                catalog_key,
                identity_generation,
                catalog_generation,
                now
            ],
        )
        .map_err(storage)?;
    Ok(changed == 1)
}

pub fn external_artwork_queue_progress(
    conn: &Connection,
    artist_id: i64,
    identity_generation: u64,
) -> CoreResult<CoverRefreshProgress> {
    let identity_generation = i64::try_from(identity_generation).map_err(storage)?;
    conn.query_row(
        "SELECT
           COALESCE(SUM(q.state = 'completed'), 0),
           COALESCE(SUM(q.state IN ('pending', 'in_progress')), 0),
           COALESCE(SUM(q.state = 'absent'), 0),
           COALESCE(SUM(q.state = 'blocked'), 0)
         FROM artist_discography_state d
         LEFT JOIN external_artwork_queue q
           ON q.artist_id = d.artist_id
          AND q.identity_generation = d.identity_generation
          AND q.catalog_generation = d.active_generation
         WHERE d.artist_id = ?1 AND d.identity_generation = ?2",
        params![artist_id, identity_generation],
        |row| {
            Ok(CoverRefreshProgress {
                completed: row.get(0)?,
                pending: row.get(1)?,
                absent: row.get(2)?,
                temporarily_blocked: row.get(3)?,
            })
        },
    )
    .optional()
    .map(|progress| progress.unwrap_or_default())
    .map_err(storage)
}

pub fn asset_path(
    conn: &Connection,
    artist_id: i64,
    provider: EnrichmentProvider,
) -> CoreResult<Option<String>> {
    conn.query_row(
        "SELECT managed_path FROM enrichment_assets
         WHERE artist_id = ?1 AND provider = ?2 AND catalog_key = ''",
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

/// Removes every snapshot and cached failure owned by one provider. Managed
/// image paths are returned only when no local or remote row still references
/// them, so the caller can safely remove the corresponding files.
pub fn clear_provider_data(
    conn: &Connection,
    provider: EnrichmentProvider,
) -> CoreResult<Vec<String>> {
    let tx = conn.unchecked_transaction().map_err(storage)?;
    let provider = provider.as_str();
    let paths = provider_asset_paths(&tx, provider, None)?;
    for statement in [
        "DELETE FROM artist_profile_sources WHERE provider = ?1",
        "DELETE FROM enrichment_assets WHERE provider = ?1",
        "DELETE FROM artist_popular_tracks WHERE provider = ?1",
        "DELETE FROM enrichment_provider_failures WHERE provider = ?1",
        "DELETE FROM artist_external_ids WHERE provider = ?1",
    ] {
        tx.execute(statement, [provider]).map_err(storage)?;
    }
    let orphaned = unreferenced_paths(&tx, paths)?;
    tx.commit().map_err(storage)?;
    Ok(orphaned)
}

/// Bounds provider snapshots by artist recency while retaining expired data
/// for offline use. Failures alone do not keep an artist in the retained set.
pub fn prune_provider_snapshots(
    conn: &Connection,
    provider: EnrichmentProvider,
    retained_artists: usize,
) -> CoreResult<Vec<String>> {
    if retained_artists == 0 {
        return Err(invalid("Provider retention must keep at least one artist"));
    }
    let retained_artists = i64::try_from(retained_artists).map_err(storage)?;
    let tx = conn.unchecked_transaction().map_err(storage)?;
    let provider_name = provider.as_str();
    let artist_ids = {
        let mut statement = tx
            .prepare(
                "SELECT artist_id
                 FROM (
                     SELECT artist_id, fetched_at FROM artist_profile_sources WHERE provider = ?1
                     UNION ALL
                     SELECT artist_id, fetched_at FROM enrichment_assets WHERE provider = ?1
                     UNION ALL
                     SELECT artist_id, fetched_at FROM artist_popular_tracks WHERE provider = ?1
                 )
                 GROUP BY artist_id
                 ORDER BY MAX(fetched_at) DESC, artist_id DESC
                 LIMIT -1 OFFSET ?2",
            )
            .map_err(storage)?;
        statement
            .query_map(params![provider_name, retained_artists], |row| {
                row.get::<_, i64>(0)
            })
            .map_err(storage)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(storage)?
    };
    let paths = provider_asset_paths(&tx, provider_name, Some(&artist_ids))?;
    for artist_id in artist_ids {
        for statement in [
            "DELETE FROM artist_profile_sources WHERE provider = ?1 AND artist_id = ?2",
            "DELETE FROM enrichment_assets WHERE provider = ?1 AND artist_id = ?2",
            "DELETE FROM artist_popular_tracks WHERE provider = ?1 AND artist_id = ?2",
            "DELETE FROM enrichment_provider_failures WHERE provider = ?1 AND artist_id = ?2",
            "DELETE FROM artist_external_ids WHERE provider = ?1 AND artist_id = ?2",
        ] {
            tx.execute(statement, params![provider_name, artist_id])
                .map_err(storage)?;
        }
    }
    let orphaned = unreferenced_paths(&tx, paths)?;
    tx.commit().map_err(storage)?;
    Ok(orphaned)
}

pub fn clear_provider_failures(conn: &Connection, provider: EnrichmentProvider) -> CoreResult<()> {
    conn.execute(
        "DELETE FROM enrichment_provider_failures WHERE provider = ?1",
        [provider.as_str()],
    )
    .map_err(storage)?;
    Ok(())
}

fn provider_asset_paths(
    conn: &Connection,
    provider: &str,
    artist_ids: Option<&[i64]>,
) -> CoreResult<Vec<String>> {
    let mut statement = conn
        .prepare(
            "SELECT DISTINCT managed_path FROM enrichment_assets
             WHERE provider = ?1 AND (?2 IS NULL OR artist_id = ?2)",
        )
        .map_err(storage)?;
    match artist_ids {
        None => statement
            .query_map(params![provider, Option::<i64>::None], |row| row.get(0))
            .map_err(storage)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(storage),
        Some(artist_ids) => {
            let mut paths = std::collections::BTreeSet::new();
            for artist_id in artist_ids {
                let rows = statement
                    .query_map(params![provider, artist_id], |row| row.get::<_, String>(0))
                    .map_err(storage)?;
                for path in rows {
                    paths.insert(path.map_err(storage)?);
                }
            }
            Ok(paths.into_iter().collect())
        }
    }
}

fn unreferenced_paths(conn: &Connection, paths: Vec<String>) -> CoreResult<Vec<String>> {
    let mut orphaned = Vec::new();
    for path in paths {
        if !path_is_referenced(conn, &path)? {
            orphaned.push(path);
        }
    }
    Ok(orphaned)
}

/// Selects only missing or expired cover fallbacks from the visible catalog.
/// Exact local editions prefer their exact asset, then a release-group asset.
pub fn external_artwork_refresh_plan(
    conn: &Connection,
    artist_id: i64,
    identity_generation: u64,
    now: i64,
    force: bool,
) -> CoreResult<ExternalArtworkRefreshPlan> {
    if artist_id < 0 {
        return Err(invalid("Artist ID must be non-negative"));
    }
    let generation = i64::try_from(identity_generation).map_err(storage)?;
    // This is a read snapshot.  Acquiring a RESERVED write lock here used to
    // make cover planning contend with scans and enrichment publication even
    // though the plan does not mutate the catalog.
    let tx = Transaction::new_unchecked(conn, TransactionBehavior::Deferred).map_err(storage)?;
    let state = tx
        .query_row(
            "SELECT d.active_generation, d.building_generation
             FROM artist_discography_state d
             JOIN artist_enrichment_state s USING (artist_id)
             WHERE d.artist_id = ?1 AND d.identity_generation = ?2
               AND s.generation = ?2",
            params![artist_id, generation],
            |row| Ok((row.get::<_, i64>(0)?, row.get::<_, Option<i64>>(1)?)),
        )
        .optional()
        .map_err(storage)?;
    let Some((active_generation, building_generation)) = state else {
        tx.commit().map_err(storage)?;
        return Ok(ExternalArtworkRefreshPlan {
            targets: Vec::new(),
            catalog_pending: false,
            queue_has_more: false,
            progress: CoverRefreshProgress::default(),
        });
    };
    let mut catalog_targets = Vec::new();
    if active_generation > 0 {
        let mut stmt = tx
            .prepare(
                "SELECT ar.release_group_mbid,
                        (SELECT l.release_mbid
                         FROM local_release_external_ids l
                         JOIN releases r ON r.release_id = l.release_id
                         WHERE r.artist_id = ?1
                           AND l.release_group_mbid = ar.release_group_mbid
                           AND l.release_mbid IS NOT NULL
                         ORDER BY l.release_id LIMIT 1)
                 FROM external_artist_release_groups ar
                 WHERE ar.artist_id = ?1 AND ar.identity_generation = ?2
                   AND ar.catalog_generation = ?3
                 ORDER BY ar.provider_position, ar.release_group_mbid",
            )
            .map_err(storage)?;
        catalog_targets = stmt
            .query_map(params![artist_id, generation, active_generation], |row| {
                Ok(ExternalArtworkRefreshTarget {
                    catalog_generation: u64::try_from(active_generation).map_err(|_| {
                        rusqlite::Error::IntegralValueOutOfRange(0, active_generation)
                    })?,
                    catalog_key: String::new(),
                    release_group_mbid: row.get(0)?,
                    exact_release_mbid: row.get(1)?,
                    attempt_count: 0,
                })
            })
            .map_err(storage)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(storage)?;
    }
    let mut expiries = std::collections::HashMap::new();
    {
        let mut stmt = tx
            .prepare(
                "SELECT catalog_key, expires_at FROM enrichment_assets
                 WHERE artist_id = ?1 AND provider = 'cover_art_archive'
                   AND generation = ?2",
            )
            .map_err(storage)?;
        for row in stmt
            .query_map(params![artist_id, generation], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
            })
            .map_err(storage)?
        {
            let (key, expires_at) = row.map_err(storage)?;
            expiries.insert(key, expires_at);
        }
    }
    let mut negative_expiries = std::collections::HashMap::new();
    {
        let mut stmt = tx
            .prepare(
                "SELECT catalog_key, expires_at
                 FROM external_artwork_negative_results
                 WHERE artist_id = ?1 AND identity_generation = ?2
                   AND catalog_generation = ?3",
            )
            .map_err(storage)?;
        for row in stmt
            .query_map(params![artist_id, generation, active_generation], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
            })
            .map_err(storage)?
        {
            let (key, expires_at) = row.map_err(storage)?;
            negative_expiries.insert(key, expires_at);
        }
    }
    let targets = catalog_targets
        .into_iter()
        .map(|mut target| {
            target.catalog_key = target.exact_release_mbid.as_ref().map_or_else(
                || format!("release-group:{}", target.release_group_mbid),
                |release| format!("release:{release}"),
            );
            target
        })
        .filter(|target| {
            if force {
                return true;
            }
            let group_key = format!("release-group:{}", target.release_group_mbid);
            let exact_expiry = target
                .exact_release_mbid
                .as_ref()
                .and_then(|release| expiries.get(&format!("release:{release}")).copied());
            let preferred_expiry = exact_expiry.or_else(|| expiries.get(&group_key).copied());
            if preferred_expiry.is_some_and(|expires_at| now < expires_at) {
                return false;
            }
            let negative_key = target
                .exact_release_mbid
                .as_ref()
                .map_or_else(|| group_key, |release| format!("release:{release}"));
            negative_expiries
                .get(&negative_key)
                .is_none_or(|expires_at| now >= *expires_at)
        })
        .collect();
    tx.commit().map_err(storage)?;
    Ok(ExternalArtworkRefreshPlan {
        targets,
        catalog_pending: building_generation.is_some(),
        queue_has_more: false,
        progress: CoverRefreshProgress::default(),
    })
}

/// Synchronizes the durable cover queue with the active catalog and claims a
/// small rotating batch. An interrupted `in_progress` item becomes pending on
/// the next call, so application restarts do not strand work.
pub fn dequeue_external_artwork_batch(
    conn: &Connection,
    artist_id: i64,
    identity_generation: u64,
    now: i64,
    force: bool,
) -> CoreResult<ExternalArtworkRefreshPlan> {
    const BATCH_LIMIT: i64 = 10;
    if artist_id < 0 {
        return Err(invalid("Artist ID must be non-negative"));
    }
    let identity_generation = i64::try_from(identity_generation).map_err(storage)?;
    let tx = conn.unchecked_transaction().map_err(storage)?;
    let state = tx
        .query_row(
            "SELECT d.active_generation, d.building_generation
             FROM artist_discography_state d
             JOIN artist_enrichment_state s USING (artist_id)
             WHERE d.artist_id = ?1 AND d.identity_generation = ?2
               AND s.generation = ?2 AND d.active_generation > 0",
            params![artist_id, identity_generation],
            |row| Ok((row.get::<_, i64>(0)?, row.get::<_, Option<i64>>(1)?)),
        )
        .optional()
        .map_err(storage)?;
    let Some((catalog_generation, building_generation)) = state else {
        tx.execute(
            "DELETE FROM external_artwork_queue WHERE artist_id = ?1",
            [artist_id],
        )
        .map_err(storage)?;
        tx.execute(
            "DELETE FROM artist_artwork_queue_state WHERE artist_id = ?1",
            [artist_id],
        )
        .map_err(storage)?;
        tx.commit().map_err(storage)?;
        return Ok(ExternalArtworkRefreshPlan {
            targets: Vec::new(),
            catalog_pending: false,
            queue_has_more: false,
            progress: CoverRefreshProgress::default(),
        });
    };

    tx.execute(
        "DELETE FROM external_artwork_queue
         WHERE artist_id = ?1
           AND (identity_generation != ?2 OR catalog_generation != ?3)",
        params![artist_id, identity_generation, catalog_generation],
    )
    .map_err(storage)?;
    tx.execute(
        "INSERT INTO artist_artwork_queue_state
         (artist_id, identity_generation, catalog_generation, cursor_position, updated_at)
         VALUES (?1, ?2, ?3, -1, ?4)
         ON CONFLICT (artist_id) DO UPDATE SET
           cursor_position = CASE
             WHEN identity_generation != excluded.identity_generation
               OR catalog_generation != excluded.catalog_generation
             THEN -1 ELSE cursor_position END,
           identity_generation = excluded.identity_generation,
           catalog_generation = excluded.catalog_generation,
           updated_at = excluded.updated_at",
        params![artist_id, identity_generation, catalog_generation, now],
    )
    .map_err(storage)?;

    let catalog_rows = {
        let mut stmt = tx
            .prepare(
                "SELECT ar.provider_position, ar.release_group_mbid,
                        (SELECT l.release_mbid
                         FROM local_release_external_ids l
                         JOIN releases r ON r.release_id = l.release_id
                         WHERE r.artist_id = ?1
                           AND l.release_group_mbid = ar.release_group_mbid
                           AND l.release_mbid IS NOT NULL
                         ORDER BY l.release_id LIMIT 1)
                 FROM external_artist_release_groups ar
                 WHERE ar.artist_id = ?1 AND ar.identity_generation = ?2
                   AND ar.catalog_generation = ?3
                 ORDER BY ar.provider_position, ar.release_group_mbid",
            )
            .map_err(storage)?;
        stmt.query_map(
            params![artist_id, identity_generation, catalog_generation],
            |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, Option<String>>(2)?,
                ))
            },
        )
        .map_err(storage)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(storage)?
    };
    let mut active_keys = std::collections::HashSet::new();
    for (provider_position, release_group_mbid, exact_release_mbid) in catalog_rows {
        let group_key = format!("release-group:{release_group_mbid}");
        let catalog_key = exact_release_mbid
            .as_ref()
            .map_or_else(|| group_key.clone(), |release| format!("release:{release}"));
        active_keys.insert(catalog_key.clone());
        let has_fresh_asset: bool = tx
            .query_row(
                "SELECT EXISTS(
                   SELECT 1 FROM enrichment_assets
                   WHERE artist_id = ?1 AND provider = 'cover_art_archive'
                     AND generation = ?2 AND expires_at > ?3
                     AND catalog_key IN (?4, ?5)
                 )",
                params![artist_id, identity_generation, now, catalog_key, group_key],
                |row| row.get(0),
            )
            .map_err(storage)?;
        let negative = tx
            .query_row(
                "SELECT result, expires_at
                 FROM external_artwork_negative_results
                 WHERE artist_id = ?1 AND catalog_key = ?2
                   AND identity_generation = ?3 AND catalog_generation = ?4
                   AND expires_at > ?5",
                params![
                    artist_id,
                    catalog_key,
                    identity_generation,
                    catalog_generation,
                    now
                ],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)),
            )
            .optional()
            .map_err(storage)?;
        let (queue_state, next_attempt_at, last_error) = if has_fresh_asset {
            ("completed", None, None)
        } else if let Some((result, expires_at)) = negative {
            let state = if result == "not_found" {
                "absent"
            } else {
                "blocked"
            };
            (state, Some(expires_at), Some(result))
        } else {
            ("pending", None, None)
        };
        tx.execute(
            "INSERT INTO external_artwork_queue
             (artist_id, catalog_key, release_group_mbid, exact_release_mbid,
              identity_generation, catalog_generation, provider_position, state,
              attempt_count, next_attempt_at, last_error, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 0, ?9, ?10, ?11)
             ON CONFLICT (artist_id, catalog_key) DO UPDATE SET
               release_group_mbid = excluded.release_group_mbid,
               exact_release_mbid = excluded.exact_release_mbid,
               identity_generation = excluded.identity_generation,
               catalog_generation = excluded.catalog_generation,
               provider_position = excluded.provider_position,
               state = excluded.state,
               attempt_count = CASE
                 WHEN external_artwork_queue.identity_generation = excluded.identity_generation
                   AND external_artwork_queue.catalog_generation = excluded.catalog_generation
                 THEN external_artwork_queue.attempt_count ELSE 0 END,
               next_attempt_at = excluded.next_attempt_at,
               last_error = COALESCE(excluded.last_error, external_artwork_queue.last_error),
               updated_at = excluded.updated_at",
            params![
                artist_id,
                catalog_key,
                release_group_mbid,
                exact_release_mbid,
                identity_generation,
                catalog_generation,
                provider_position,
                queue_state,
                next_attempt_at,
                last_error,
                now,
            ],
        )
        .map_err(storage)?;
    }
    let existing_keys = {
        let mut stmt = tx
            .prepare(
                "SELECT catalog_key FROM external_artwork_queue
                 WHERE artist_id = ?1 AND identity_generation = ?2
                   AND catalog_generation = ?3",
            )
            .map_err(storage)?;
        stmt.query_map(
            params![artist_id, identity_generation, catalog_generation],
            |row| row.get::<_, String>(0),
        )
        .map_err(storage)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(storage)?
    };
    for key in existing_keys {
        if !active_keys.contains(&key) {
            tx.execute(
                "DELETE FROM external_artwork_queue WHERE artist_id = ?1 AND catalog_key = ?2",
                params![artist_id, key],
            )
            .map_err(storage)?;
        }
    }

    let cursor: i64 = tx
        .query_row(
            "SELECT cursor_position FROM artist_artwork_queue_state WHERE artist_id = ?1",
            [artist_id],
            |row| row.get(0),
        )
        .map_err(storage)?;
    let claimed = {
        let mut stmt = tx
            .prepare(
                "SELECT catalog_key, release_group_mbid, exact_release_mbid,
                        provider_position, attempt_count
                 FROM external_artwork_queue
                 WHERE artist_id = ?1 AND identity_generation = ?2
                   AND catalog_generation = ?3
                   AND (?4 OR state = 'pending'
                     OR (state IN ('absent', 'blocked') AND next_attempt_at <= ?5))
                 ORDER BY CASE WHEN provider_position > ?6 THEN 0 ELSE 1 END,
                          provider_position, catalog_key
                 LIMIT ?7",
            )
            .map_err(storage)?;
        stmt.query_map(
            params![
                artist_id,
                identity_generation,
                catalog_generation,
                force,
                now,
                cursor,
                BATCH_LIMIT
            ],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, Option<String>>(2)?,
                    row.get::<_, i64>(3)?,
                    row.get::<_, u32>(4)?,
                ))
            },
        )
        .map_err(storage)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(storage)?
    };
    let mut targets = Vec::with_capacity(claimed.len());
    for (catalog_key, release_group_mbid, exact_release_mbid, position, attempts) in &claimed {
        tx.execute(
            "UPDATE external_artwork_queue
             SET state = 'in_progress', attempt_count = attempt_count + 1,
                 next_attempt_at = NULL, updated_at = ?3
             WHERE artist_id = ?1 AND catalog_key = ?2",
            params![artist_id, catalog_key, now],
        )
        .map_err(storage)?;
        targets.push(ExternalArtworkRefreshTarget {
            catalog_generation: u64::try_from(catalog_generation).map_err(storage)?,
            catalog_key: catalog_key.clone(),
            release_group_mbid: release_group_mbid.clone(),
            exact_release_mbid: exact_release_mbid.clone(),
            attempt_count: attempts.saturating_add(1),
        });
        let _ = position;
    }
    if let Some((_, _, _, position, _)) = claimed.last() {
        tx.execute(
            "UPDATE artist_artwork_queue_state
             SET cursor_position = ?2, updated_at = ?3 WHERE artist_id = ?1",
            params![artist_id, position, now],
        )
        .map_err(storage)?;
    }
    let (completed, pending, absent, blocked): (u64, u64, u64, u64) = tx
        .query_row(
            "SELECT
               COALESCE(SUM(state = 'completed'), 0),
               COALESCE(SUM(state IN ('pending', 'in_progress')), 0),
               COALESCE(SUM(state = 'absent'), 0),
               COALESCE(SUM(state = 'blocked'), 0)
             FROM external_artwork_queue
             WHERE artist_id = ?1 AND identity_generation = ?2
               AND catalog_generation = ?3",
            params![artist_id, identity_generation, catalog_generation],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )
        .map_err(storage)?;
    let eligible_count: u64 = tx
        .query_row(
            "SELECT COUNT(*) FROM external_artwork_queue
             WHERE artist_id = ?1 AND identity_generation = ?2
               AND catalog_generation = ?3
               AND (?4 OR state = 'pending'
                 OR (state IN ('absent', 'blocked') AND next_attempt_at <= ?5))",
            params![
                artist_id,
                identity_generation,
                catalog_generation,
                force,
                now
            ],
            |row| row.get(0),
        )
        .map_err(storage)?;
    tx.commit().map_err(storage)?;
    Ok(ExternalArtworkRefreshPlan {
        queue_has_more: eligible_count > 0,
        targets,
        catalog_pending: building_generation.is_some(),
        progress: CoverRefreshProgress {
            completed,
            pending,
            absent,
            temporarily_blocked: blocked,
        },
    })
}

/// Starts or resumes a hidden catalog generation. Returning `None` means the
/// artist identity changed before the write could begin.
pub fn begin_discography_snapshot(
    conn: &Connection,
    artist_id: i64,
    identity_generation: u64,
) -> CoreResult<Option<u64>> {
    if artist_id < 0 {
        return Err(invalid("Artist ID must be non-negative"));
    }
    let identity_generation = i64::try_from(identity_generation).map_err(storage)?;
    crate::database::identity::read(conn, artist_id)?;
    let tx = conn.unchecked_transaction().map_err(storage)?;
    let current: i64 = tx
        .query_row(
            "SELECT generation FROM artist_enrichment_state WHERE artist_id = ?1",
            [artist_id],
            |row| row.get(0),
        )
        .map_err(storage)?;
    if current != identity_generation {
        return Ok(None);
    }
    let state = tx
        .query_row(
            "SELECT identity_generation, active_generation, building_generation
             FROM artist_discography_state WHERE artist_id = ?1",
            [artist_id],
            |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, Option<i64>>(2)?,
                ))
            },
        )
        .optional()
        .map_err(storage)?;
    if let Some((state_identity, _, Some(building))) = state {
        if state_identity == identity_generation {
            return u64::try_from(building).map(Some).map_err(storage);
        }
    }
    let active = state.map_or(0, |(_, active, _)| active);
    let building = active
        .checked_add(1)
        .ok_or_else(|| invalid("Catalog generation is out of range"))?;
    tx.execute(
        "INSERT INTO artist_discography_state
         (artist_id, identity_generation, active_generation, building_generation,
          building_next_offset)
         VALUES (?1, ?2, 0, ?3, 0)
         ON CONFLICT (artist_id) DO UPDATE SET
           active_generation = CASE
             WHEN artist_discography_state.identity_generation != excluded.identity_generation
             THEN 0 ELSE artist_discography_state.active_generation END,
           active_remote_next_offset = CASE
             WHEN artist_discography_state.identity_generation != excluded.identity_generation
             THEN NULL ELSE artist_discography_state.active_remote_next_offset END,
           active_remote_total = CASE
             WHEN artist_discography_state.identity_generation != excluded.identity_generation
             THEN NULL ELSE artist_discography_state.active_remote_total END,
           active_remote_exhausted = CASE
             WHEN artist_discography_state.identity_generation != excluded.identity_generation
             THEN 0 ELSE artist_discography_state.active_remote_exhausted END,
           active_fetched_at = CASE
             WHEN artist_discography_state.identity_generation != excluded.identity_generation
             THEN NULL ELSE artist_discography_state.active_fetched_at END,
           active_expires_at = CASE
             WHEN artist_discography_state.identity_generation != excluded.identity_generation
             THEN NULL ELSE artist_discography_state.active_expires_at END,
           active_etag = CASE
             WHEN artist_discography_state.identity_generation != excluded.identity_generation
             THEN NULL ELSE artist_discography_state.active_etag END,
           active_last_modified = CASE
             WHEN artist_discography_state.identity_generation != excluded.identity_generation
             THEN NULL ELSE artist_discography_state.active_last_modified END,
           identity_generation = excluded.identity_generation,
           building_generation = excluded.building_generation,
           building_next_offset = 0, building_remote_total = NULL,
           building_fetched_at = NULL,
           building_expires_at = NULL, building_etag = NULL,
           building_last_modified = NULL",
        params![artist_id, identity_generation, building],
    )
    .map_err(storage)?;
    tx.execute(
        "DELETE FROM external_artist_release_groups
         WHERE artist_id = ?1 AND catalog_generation = ?2",
        params![artist_id, building],
    )
    .map_err(storage)?;
    tx.commit().map_err(storage)?;
    u64::try_from(building).map(Some).map_err(storage)
}

/// Returns the durable cursor for an unpublished generation, allowing a later
/// bounded refresh to resume without exposing partially fetched rows.
pub fn discography_build_state(
    conn: &Connection,
    artist_id: i64,
    identity_generation: u64,
) -> CoreResult<Option<DiscographyBuildState>> {
    if artist_id < 0 {
        return Err(invalid("Artist ID must be non-negative"));
    }
    let identity_generation = i64::try_from(identity_generation).map_err(storage)?;
    let state = conn
        .query_row(
            "SELECT d.building_generation, d.building_next_offset,
                    d.building_remote_total, d.building_etag,
                    d.building_last_modified
             FROM artist_discography_state d
             JOIN artist_enrichment_state s USING (artist_id)
             WHERE d.artist_id = ?1 AND d.identity_generation = ?2
               AND s.generation = ?2 AND d.building_generation IS NOT NULL
               AND d.building_next_offset IS NOT NULL",
            params![artist_id, identity_generation],
            |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, Option<i64>>(2)?,
                    row.get::<_, Option<String>>(3)?,
                    row.get::<_, Option<String>>(4)?,
                ))
            },
        )
        .optional()
        .map_err(storage)?;
    state
        .map(
            |(generation, next_offset, remote_total, etag, last_modified)| {
                Ok(DiscographyBuildState {
                    catalog_generation: u64::try_from(generation).map_err(storage)?,
                    next_offset: u64::try_from(next_offset).map_err(storage)?,
                    remote_total: remote_total
                        .map(u64::try_from)
                        .transpose()
                        .map_err(storage)?,
                    validators: CacheValidators {
                        etag,
                        last_modified,
                    },
                })
            },
        )
        .transpose()
}

/// Returns the active cache validators together with any durable hidden cursor.
pub fn discography_refresh_state(
    conn: &Connection,
    artist_id: i64,
    identity_generation: u64,
) -> CoreResult<Option<DiscographyRefreshState>> {
    if artist_id < 0 {
        return Err(invalid("Artist ID must be non-negative"));
    }
    let generation = i64::try_from(identity_generation).map_err(storage)?;
    let current =
        i64::try_from(crate::database::identity::read_persisted_inner(conn, artist_id)?.generation)
            .map_err(storage)?;
    if current != generation {
        return Ok(None);
    }
    let state = conn
        .query_row(
            "SELECT active_generation, active_expires_at, active_etag,
                    active_last_modified, building_generation,
                    building_next_offset, building_remote_total,
                    building_etag, building_last_modified
             FROM artist_discography_state
             WHERE artist_id = ?1 AND identity_generation = ?2",
            params![artist_id, generation],
            |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, Option<i64>>(1)?,
                    row.get::<_, Option<String>>(2)?,
                    row.get::<_, Option<String>>(3)?,
                    row.get::<_, Option<i64>>(4)?,
                    row.get::<_, Option<i64>>(5)?,
                    row.get::<_, Option<i64>>(6)?,
                    row.get::<_, Option<String>>(7)?,
                    row.get::<_, Option<String>>(8)?,
                ))
            },
        )
        .optional()
        .map_err(storage)?;
    let Some((
        active_generation,
        active_expires_at,
        active_etag,
        active_last_modified,
        building_generation,
        building_next_offset,
        building_remote_total,
        building_etag,
        building_last_modified,
    )) = state
    else {
        return Ok(Some(DiscographyRefreshState {
            active_generation: 0,
            active_expires_at: None,
            active_validators: CacheValidators::default(),
            building: None,
        }));
    };
    let building = match (building_generation, building_next_offset) {
        (Some(catalog_generation), Some(next_offset)) => Some(DiscographyBuildState {
            catalog_generation: u64::try_from(catalog_generation).map_err(storage)?,
            next_offset: u64::try_from(next_offset).map_err(storage)?,
            remote_total: building_remote_total
                .map(u64::try_from)
                .transpose()
                .map_err(storage)?,
            validators: CacheValidators {
                etag: building_etag,
                last_modified: building_last_modified,
            },
        }),
        (None, None) => None,
        _ => return Err(storage("Inconsistent discography build state")),
    };
    Ok(Some(DiscographyRefreshState {
        active_generation: u64::try_from(active_generation).map_err(storage)?,
        active_expires_at,
        active_validators: CacheValidators {
            etag: active_etag,
            last_modified: active_last_modified,
        },
        building,
    }))
}

/// Extends a published snapshot after a conditional 304 without exposing or
/// mutating any hidden generation.
pub fn revalidate_discography(
    conn: &Connection,
    artist_id: i64,
    identity_generation: u64,
    active_generation: u64,
    fetched_at: i64,
    expires_at: i64,
    validators: &CacheValidators,
) -> CoreResult<bool> {
    if artist_id < 0 || active_generation == 0 || expires_at < fetched_at {
        return Err(invalid("Invalid discography revalidation"));
    }
    let identity_generation = i64::try_from(identity_generation).map_err(storage)?;
    let active_generation = i64::try_from(active_generation).map_err(storage)?;
    let changed = conn
        .execute(
            "UPDATE artist_discography_state SET
               active_fetched_at = ?4, active_expires_at = ?5,
               active_etag = ?6, active_last_modified = ?7
             WHERE artist_id = ?1 AND identity_generation = ?2
               AND active_generation = ?3 AND building_generation IS NULL
               AND EXISTS (
                 SELECT 1 FROM artist_enrichment_state s
                 WHERE s.artist_id = ?1 AND s.generation = ?2
               )",
            params![
                artist_id,
                identity_generation,
                active_generation,
                fetched_at,
                expires_at,
                validators.etag,
                validators.last_modified,
            ],
        )
        .map_err(storage)?;
    Ok(changed == 1)
}

/// Abandons only the matching unpublished generation. The active catalog is
/// never touched, and a superseded identity cannot discard newer work.
pub fn discard_discography_snapshot(
    conn: &Connection,
    artist_id: i64,
    identity_generation: u64,
    catalog_generation: u64,
) -> CoreResult<bool> {
    if artist_id < 0 || catalog_generation == 0 {
        return Err(invalid("Invalid discography generation"));
    }
    let identity_generation = i64::try_from(identity_generation).map_err(storage)?;
    let catalog_generation = i64::try_from(catalog_generation).map_err(storage)?;
    let tx = conn.unchecked_transaction().map_err(storage)?;
    let changed = tx
        .execute(
            "UPDATE artist_discography_state SET
               building_generation = NULL, building_next_offset = NULL,
               building_remote_total = NULL, building_fetched_at = NULL,
               building_expires_at = NULL, building_etag = NULL,
               building_last_modified = NULL
             WHERE artist_id = ?1 AND identity_generation = ?2
               AND building_generation = ?3
               AND EXISTS (
                 SELECT 1 FROM artist_enrichment_state s
                 WHERE s.artist_id = ?1 AND s.generation = ?2
               )",
            params![artist_id, identity_generation, catalog_generation],
        )
        .map_err(storage)?;
    if changed == 1 {
        tx.execute(
            "DELETE FROM external_artist_release_groups
             WHERE artist_id = ?1 AND identity_generation = ?2
               AND catalog_generation = ?3",
            params![artist_id, identity_generation, catalog_generation],
        )
        .map_err(storage)?;
    }
    tx.commit().map_err(storage)?;
    Ok(changed == 1)
}

/// Persists one provider page. Incomplete pages remain hidden; the last page
/// atomically publishes the generation and removes older artist relations.
pub fn store_discography_page(
    conn: &Connection,
    snapshot: &DiscographyPageSnapshot,
) -> CoreResult<bool> {
    if snapshot.artist_id < 0
        || snapshot.catalog_generation == 0
        || snapshot.expires_at < snapshot.fetched_at
        || snapshot.remote_exhausted != snapshot.remote_next_offset.is_none()
        || snapshot.groups.len() > 100
        || snapshot
            .provider_offset
            .checked_add(snapshot.groups.len() as u64)
            .is_none_or(|end| {
                snapshot.remote_total < end
                    || (snapshot.remote_exhausted && end < snapshot.remote_total)
                    || snapshot
                        .remote_next_offset
                        .is_some_and(|next| next != end || end >= snapshot.remote_total)
            })
    {
        return Err(invalid("Invalid discography snapshot"));
    }
    let identity_generation = i64::try_from(snapshot.identity_generation).map_err(storage)?;
    let catalog_generation = i64::try_from(snapshot.catalog_generation).map_err(storage)?;
    let provider_offset = i64::try_from(snapshot.provider_offset).map_err(storage)?;
    let remote_next_offset = snapshot
        .remote_next_offset
        .map(i64::try_from)
        .transpose()
        .map_err(storage)?;
    let remote_total = i64::try_from(snapshot.remote_total).map_err(storage)?;
    let mut identifiers = std::collections::HashSet::new();
    for group in &snapshot.groups {
        if crate::enrichment::identity::normalize_mbid(&group.musicbrainz_id).is_none()
            || group.title.trim().is_empty()
            || group.title.len() > MAX_JSON_BYTES
            || group
                .primary_type
                .as_ref()
                .is_some_and(|value| value.trim().is_empty() || value.len() > 100)
            || group
                .secondary_types
                .iter()
                .any(|value| value.trim().is_empty() || value.len() > 100)
            || [&group.genres, &group.composers, &group.producers]
                .into_iter()
                .any(|values| {
                    values.len() > 100
                        || values
                            .iter()
                            .any(|value| value.trim().is_empty() || value.len() > 500)
                })
            || group.attribution.source_url.trim().is_empty()
            || !identifiers.insert(group.musicbrainz_id.to_ascii_lowercase())
        {
            return Err(invalid("Invalid or duplicate release-group"));
        }
        validate_date(&group.first_release_date)?;
    }

    let tx = conn.unchecked_transaction().map_err(storage)?;
    let current = tx
        .query_row(
            "SELECT s.generation, d.identity_generation, d.building_generation,
                    d.building_next_offset, d.building_remote_total
             FROM artist_enrichment_state s
             JOIN artist_discography_state d USING (artist_id)
             WHERE s.artist_id = ?1",
            [snapshot.artist_id],
            |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, Option<i64>>(2)?,
                    row.get::<_, Option<i64>>(3)?,
                    row.get::<_, Option<i64>>(4)?,
                ))
            },
        )
        .optional()
        .map_err(storage)?;
    let Some((
        current_identity,
        state_identity,
        building_generation,
        building_offset,
        building_total,
    )) = current
    else {
        return Ok(false);
    };
    if current_identity != identity_generation
        || state_identity != identity_generation
        || building_generation != Some(catalog_generation)
        || building_offset != Some(provider_offset)
    {
        return Ok(false);
    }
    if building_total.is_some_and(|total| total != remote_total) {
        return Err(invalid("Discography total changed during snapshot"));
    }
    for (index, group) in snapshot.groups.iter().enumerate() {
        let musicbrainz_id = group.musicbrainz_id.to_ascii_lowercase();
        let secondary_types = serde_json::to_string(&group.secondary_types).map_err(storage)?;
        let attribution = serde_json::to_string(&group.attribution).map_err(storage)?;
        let snapshot_payload = serde_json::to_string(group).map_err(storage)?;
        if secondary_types.len() > MAX_JSON_BYTES
            || attribution.len() > MAX_JSON_BYTES
            || snapshot_payload.len() > MAX_JSON_BYTES
        {
            return Err(invalid("Release-group metadata exceeds size limit"));
        }
        let already_staged: bool = tx
            .query_row(
                "SELECT EXISTS(
                   SELECT 1 FROM external_artist_release_groups
                   WHERE artist_id = ?1 AND catalog_generation = ?2
                     AND release_group_mbid = ?3
                 )",
                params![snapshot.artist_id, catalog_generation, musicbrainz_id],
                |row| row.get(0),
            )
            .map_err(storage)?;
        if already_staged {
            return Err(invalid("Duplicate release-group across discography pages"));
        }
        let (year, month, day) = group
            .first_release_date
            .as_ref()
            .map_or((None, None, None), |date| {
                (Some(date.year), date.month, date.day)
            });
        tx.execute(
            "INSERT INTO external_release_groups
             (musicbrainz_id, title, primary_type, secondary_types,
              first_release_year, first_release_month, first_release_day,
              attribution, fetched_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
             ON CONFLICT (musicbrainz_id) DO UPDATE SET
               title = excluded.title, primary_type = excluded.primary_type,
               secondary_types = excluded.secondary_types,
               first_release_year = excluded.first_release_year,
               first_release_month = excluded.first_release_month,
               first_release_day = excluded.first_release_day,
               attribution = excluded.attribution, fetched_at = excluded.fetched_at
             WHERE external_release_groups.fetched_at <= excluded.fetched_at",
            params![
                musicbrainz_id,
                group.title.trim(),
                group.primary_type,
                secondary_types,
                year,
                month,
                day,
                attribution,
                snapshot.fetched_at
            ],
        )
        .map_err(storage)?;
        let index = i64::try_from(index).map_err(storage)?;
        let position = provider_offset
            .checked_add(index)
            .ok_or_else(|| invalid("Provider position is out of range"))?;
        tx.execute(
            "INSERT INTO external_artist_release_groups
             (artist_id, release_group_mbid, identity_generation,
              catalog_generation, provider_position, snapshot_payload)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)
             ON CONFLICT (artist_id, catalog_generation, release_group_mbid) DO UPDATE SET
               identity_generation = excluded.identity_generation,
               provider_position = excluded.provider_position,
               snapshot_payload = excluded.snapshot_payload",
            params![
                snapshot.artist_id,
                musicbrainz_id,
                identity_generation,
                catalog_generation,
                position,
                snapshot_payload
            ],
        )
        .map_err(storage)?;
    }
    if snapshot.remote_exhausted {
        let staged_count: i64 = tx
            .query_row(
                "SELECT COUNT(*) FROM external_artist_release_groups
                 WHERE artist_id = ?1 AND identity_generation = ?2
                   AND catalog_generation = ?3",
                params![snapshot.artist_id, identity_generation, catalog_generation],
                |row| row.get(0),
            )
            .map_err(storage)?;
        if staged_count != remote_total {
            return Err(invalid("Incomplete discography snapshot"));
        }
    }
    let changed = tx
        .execute(
            "UPDATE artist_discography_state SET
               active_generation = CASE WHEN ?5 THEN ?3 ELSE active_generation END,
               active_remote_next_offset = CASE WHEN ?5 THEN ?4 ELSE active_remote_next_offset END,
               active_remote_total = CASE WHEN ?5 THEN ?11 ELSE active_remote_total END,
               active_remote_exhausted = CASE WHEN ?5 THEN 1 ELSE active_remote_exhausted END,
               active_fetched_at = CASE WHEN ?5 THEN ?6 ELSE active_fetched_at END,
               active_expires_at = CASE WHEN ?5 THEN ?7 ELSE active_expires_at END,
               active_etag = CASE WHEN ?5 THEN ?8 ELSE active_etag END,
               active_last_modified = CASE WHEN ?5 THEN ?9 ELSE active_last_modified END,
               building_generation = CASE WHEN ?5 THEN NULL ELSE building_generation END,
               building_next_offset = CASE WHEN ?5 THEN NULL ELSE ?4 END,
               building_remote_total = CASE WHEN ?5 THEN NULL ELSE ?11 END,
               building_fetched_at = CASE WHEN ?5 THEN NULL ELSE ?6 END,
               building_expires_at = CASE WHEN ?5 THEN NULL ELSE ?7 END,
               building_etag = CASE WHEN ?5 THEN NULL ELSE ?8 END,
               building_last_modified = CASE WHEN ?5 THEN NULL ELSE ?9 END
             WHERE artist_id = ?1 AND identity_generation = ?2
               AND building_generation = ?3 AND building_next_offset = ?10",
            params![
                snapshot.artist_id,
                identity_generation,
                catalog_generation,
                remote_next_offset,
                snapshot.remote_exhausted,
                snapshot.fetched_at,
                snapshot.expires_at,
                snapshot.validators.etag,
                snapshot.validators.last_modified,
                provider_offset,
                remote_total
            ],
        )
        .map_err(storage)?;
    if changed != 1 {
        return Ok(false);
    }
    if snapshot.remote_exhausted {
        tx.execute(
            "DELETE FROM external_artist_release_groups
             WHERE artist_id = ?1 AND catalog_generation != ?2",
            params![snapshot.artist_id, catalog_generation],
        )
        .map_err(storage)?;
    }
    tx.commit().map_err(storage)?;
    Ok(true)
}

pub fn local_release_match_contexts(
    conn: &Connection,
    artist_id: i64,
    identity_generation: u64,
    include_attempted: bool,
) -> CoreResult<Vec<LocalReleaseMatchContext>> {
    let generation = i64::try_from(identity_generation).map_err(storage)?;
    let (artist_mbid, artist_name, catalog_generation): (String, String, i64) = conn
        .query_row(
            "SELECT s.musicbrainz_id, a.name, d.active_generation
             FROM artist_enrichment_state s
             JOIN artists a USING (artist_id)
             JOIN artist_discography_state d USING (artist_id)
             WHERE s.artist_id = ?1 AND s.identity_status = 'resolved'
               AND s.generation = ?2 AND d.identity_generation = ?2
               AND d.active_generation > 0",
            params![artist_id, generation],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .map_err(storage)?;
    let catalog = {
        let mut statement = conn
            .prepare(
                "SELECT ar.release_group_mbid, ar.snapshot_payload
                 FROM external_artist_release_groups ar
                 WHERE ar.artist_id = ?1 AND ar.identity_generation = ?2
                   AND ar.catalog_generation = ?3",
            )
            .map_err(storage)?;
        statement
            .query_map(params![artist_id, generation, catalog_generation], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })
            .map_err(storage)?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(storage)?
    };
    let catalog = catalog
        .into_iter()
        .map(|(id, payload)| {
            serde_json::from_str::<ReleaseGroupSnapshot>(&payload)
                .map(|group| (id, group))
                .map_err(storage)
        })
        .collect::<CoreResult<Vec<_>>>()?;
    let releases = {
        let mut statement = conn
            .prepare(
                "SELECT r.release_id, r.title, ids.release_mbid,
                        ids.release_group_mbid, ids.origin
                 FROM releases r
                 LEFT JOIN local_release_external_ids ids ON ids.release_id = r.release_id
                 WHERE r.artist_id = ?1
                   AND (?3 OR NOT EXISTS (
                     SELECT 1 FROM local_release_metadata_attempts attempt
                     WHERE attempt.release_id = r.release_id
                       AND attempt.identity_generation = ?2
                   ))
                 ORDER BY r.release_id",
            )
            .map_err(storage)?;
        statement
            .query_map(params![artist_id, generation, include_attempted], |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, Option<String>>(2)?,
                    row.get::<_, Option<String>>(3)?,
                    row.get::<_, Option<String>>(4)?,
                ))
            })
            .map_err(storage)?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(storage)?
    };
    let mut contexts = Vec::new();
    for (release_id, title, release_mbid, group_mbid, origin) in releases {
        let mut candidates: Vec<ReleaseGroupSnapshot> = if origin.as_deref() == Some("tag") {
            catalog
                .iter()
                .filter(|(id, _)| group_mbid.as_deref() == Some(id.as_str()))
                .map(|(_, group)| group.clone())
                .collect()
        } else {
            let normalized_title = normalized_match_text(&title);
            catalog
                .iter()
                .filter(|(_, group)| normalized_match_text(&group.title) == normalized_title)
                .map(|(_, group)| group.clone())
                .collect()
        };
        if candidates.len() > 1 {
            let album_candidates = candidates
                .iter()
                .filter(|group| {
                    group
                        .primary_type
                        .as_deref()
                        .is_some_and(|kind| kind.eq_ignore_ascii_case("album"))
                })
                .cloned()
                .collect::<Vec<_>>();
            if album_candidates.len() == 1 {
                candidates = album_candidates;
            }
        }
        if candidates.is_empty() {
            continue;
        }
        let tracks = {
            let mut statement = conn
                .prepare(
                    "SELECT title, disc_number, track_number, duration
                     FROM songs WHERE release_id = ?1
                     ORDER BY disc_number, track_number, song_id",
                )
                .map_err(storage)?;
            statement
                .query_map([release_id], |row| {
                    Ok(LocalReleaseTrackContext {
                        title: row.get(0)?,
                        disc_number: row.get(1)?,
                        track_number: row.get(2)?,
                        duration_seconds: row.get::<_, f64>(3)?.max(0.0).round() as u64,
                    })
                })
                .map_err(storage)?
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(storage)?
        };
        if tracks.is_empty() {
            continue;
        }
        contexts.push(LocalReleaseMatchContext {
            release_id,
            artist_id,
            artist_mbid: artist_mbid.clone(),
            artist_name: artist_name.clone(),
            title,
            tagged_release_mbid: (origin.as_deref() == Some("tag"))
                .then_some(release_mbid)
                .flatten(),
            tagged_release_group_mbid: (origin.as_deref() == Some("tag"))
                .then_some(group_mbid)
                .flatten(),
            candidate_release_groups: candidates,
            tracks,
        });
    }
    Ok(contexts)
}

pub fn reset_local_release_metadata_attempts(conn: &Connection, artist_id: i64) -> CoreResult<()> {
    conn.execute(
        "DELETE FROM local_release_metadata_attempts WHERE artist_id = ?1",
        [artist_id],
    )
    .map_err(storage)?;
    Ok(())
}

pub fn mark_local_release_metadata_attempted(
    conn: &Connection,
    release_id: i64,
    artist_id: i64,
    identity_generation: u64,
    attempted_at: i64,
) -> CoreResult<()> {
    conn.execute(
        "INSERT INTO local_release_metadata_attempts
         (release_id, artist_id, identity_generation, attempted_at)
         VALUES (?1, ?2, ?3, ?4)
         ON CONFLICT(release_id) DO UPDATE SET
           artist_id = excluded.artist_id,
           identity_generation = excluded.identity_generation,
           attempted_at = excluded.attempted_at",
        params![
            release_id,
            artist_id,
            i64::try_from(identity_generation).map_err(storage)?,
            attempted_at
        ],
    )
    .map_err(storage)?;
    Ok(())
}

pub fn store_matched_release_metadata(
    conn: &Connection,
    snapshot: &MatchedReleaseMetadata,
) -> CoreResult<bool> {
    let generation = i64::try_from(snapshot.identity_generation).map_err(storage)?;
    let tx = conn.unchecked_transaction().map_err(storage)?;
    let current: bool = tx
        .query_row(
            "SELECT EXISTS(
                SELECT 1 FROM artist_enrichment_state s
                JOIN artist_discography_state d USING (artist_id)
                JOIN external_artist_release_groups ar
                  ON ar.artist_id = s.artist_id
                 AND ar.identity_generation = s.generation
                 AND ar.catalog_generation = d.active_generation
                 AND ar.release_group_mbid = ?3
                JOIN releases r ON r.release_id = ?4 AND r.artist_id = s.artist_id
                WHERE s.artist_id = ?1 AND s.generation = ?2
                  AND s.identity_status = 'resolved'
            )",
            params![
                snapshot.artist_id,
                generation,
                snapshot.release_group_mbid,
                snapshot.release_id
            ],
            |row| row.get(0),
        )
        .map_err(storage)?;
    if !current {
        return Ok(false);
    }
    let origin: Option<String> = tx
        .query_row(
            "SELECT origin FROM local_release_external_ids WHERE release_id = ?1",
            [snapshot.release_id],
            |row| row.get(0),
        )
        .optional()
        .map_err(storage)?;
    if origin.as_deref() != Some("tag") {
        tx.execute(
            "INSERT INTO local_release_external_ids
             (release_id, release_mbid, release_group_mbid, origin, updated_at)
             VALUES (?1, ?2, ?3, 'catalog_exact', ?4)
             ON CONFLICT(release_id) DO UPDATE SET
               release_mbid = excluded.release_mbid,
               release_group_mbid = excluded.release_group_mbid,
               origin = excluded.origin, updated_at = excluded.updated_at
             WHERE local_release_external_ids.origin = 'catalog_exact'",
            params![
                snapshot.release_id,
                snapshot.release_mbid,
                snapshot.release_group_mbid,
                snapshot.fetched_at
            ],
        )
        .map_err(storage)?;
    }
    let group = tx
        .query_row(
            "SELECT snapshot_payload FROM external_artist_release_groups
             WHERE artist_id = ?1 AND identity_generation = ?2
               AND release_group_mbid = ?3
             ORDER BY catalog_generation DESC LIMIT 1",
            params![snapshot.artist_id, generation, snapshot.release_group_mbid],
            |row| row.get::<_, String>(0),
        )
        .map_err(storage)
        .and_then(|payload| {
            serde_json::from_str::<ReleaseGroupSnapshot>(&payload).map_err(storage)
        })?;
    let genres = if snapshot.genres.is_empty() {
        group.genres.clone()
    } else {
        snapshot.genres.clone()
    };
    // The album header represents the work/release group, not a particular
    // pressing. Keep its original release year even after an exact edition is
    // identified (for example, a 2003 reissue of a 1975 album).
    let release_date = group
        .first_release_date
        .as_ref()
        .map(format_release_group_date)
        .or_else(|| snapshot.release_date.clone());
    tx.execute(
        "INSERT INTO local_release_metadata
         (release_id, artist_id, identity_generation, release_group_mbid,
          release_mbid, match_kind, release_date, genres, composers, producers,
          source_url, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
         ON CONFLICT(release_id) DO UPDATE SET
           artist_id = excluded.artist_id,
           identity_generation = excluded.identity_generation,
           release_group_mbid = excluded.release_group_mbid,
           release_mbid = excluded.release_mbid,
           match_kind = excluded.match_kind,
           release_date = excluded.release_date,
           genres = excluded.genres,
           composers = excluded.composers,
           producers = excluded.producers,
           source_url = excluded.source_url,
           updated_at = excluded.updated_at",
        params![
            snapshot.release_id,
            snapshot.artist_id,
            generation,
            snapshot.release_group_mbid,
            snapshot.release_mbid,
            if origin.as_deref() == Some("tag") {
                "tag"
            } else {
                "catalog_exact"
            },
            release_date,
            serde_json::to_string(&genres).map_err(storage)?,
            serde_json::to_string(&snapshot.composers).map_err(storage)?,
            serde_json::to_string(&snapshot.producers).map_err(storage)?,
            snapshot.source_url,
            snapshot.fetched_at,
        ],
    )
    .map_err(storage)?;
    tx.commit().map_err(storage)?;
    Ok(true)
}

fn format_release_group_date(date: &ArtistPartialDate) -> String {
    match (date.month, date.day) {
        (Some(month), Some(day)) => format!("{:04}-{month:02}-{day:02}", date.year),
        (Some(month), None) => format!("{:04}-{month:02}", date.year),
        _ => format!("{:04}", date.year),
    }
}

pub fn read_discography(
    conn: &Connection,
    artist_id: i64,
    page_size: u64,
    offset: u64,
    now: i64,
) -> CoreResult<ArtistDiscographyPage> {
    if artist_id < 0 || page_size == 0 || page_size > 200 || offset > i64::MAX as u64 {
        return Err(invalid("Invalid discography page"));
    }
    // Identity, active generation and its rows belong to one SQLite snapshot;
    // a concurrent final-page publication cannot produce a mixed/empty page.
    // A deferred transaction still gives all queries below one consistent
    // snapshot, without taking a RESERVED writer lock for a read operation.
    let tx = Transaction::new_unchecked(conn, TransactionBehavior::Deferred).map_err(storage)?;
    let identity = crate::database::identity::read_persisted_inner(&tx, artist_id)?;
    let state = tx
        .query_row(
            "SELECT active_generation, active_remote_next_offset,
                    active_remote_exhausted, active_expires_at, active_remote_total,
                    active_fetched_at
             FROM artist_discography_state
             WHERE artist_id = ?1 AND identity_generation = ?2",
            params![
                artist_id,
                i64::try_from(identity.generation).map_err(storage)?
            ],
            |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, Option<i64>>(1)?,
                    row.get::<_, bool>(2)?,
                    row.get::<_, Option<i64>>(3)?,
                    row.get::<_, Option<i64>>(4)?,
                    row.get::<_, Option<i64>>(5)?,
                ))
            },
        )
        .optional()
        .map_err(storage)?;
    let Some((
        catalog_generation,
        remote_next_offset,
        remote_exhausted,
        expires_at,
        remote_total,
        last_success_at,
    )) = state
    else {
        tx.commit().map_err(storage)?;
        return Ok(ArtistDiscographyPage {
            artist_id,
            identity_generation: identity.generation,
            catalog_generation: 0,
            items: Vec::new(),
            next_offset: None,
            remote_exhausted: false,
            remote_next_offset: Some(0),
            remote_total: None,
            last_success_at: None,
            stale: true,
        });
    };
    if catalog_generation == 0 {
        tx.commit().map_err(storage)?;
        return Ok(ArtistDiscographyPage {
            artist_id,
            identity_generation: identity.generation,
            catalog_generation: 0,
            items: Vec::new(),
            next_offset: None,
            remote_exhausted: false,
            remote_next_offset: Some(0),
            remote_total: None,
            last_success_at: None,
            stale: true,
        });
    }
    let query_limit = page_size.saturating_add(1);
    let mut stmt = tx
        .prepare(
            "WITH catalog AS (
               SELECT ar.*,
                      (SELECT l.release_id FROM local_release_external_ids l
                       JOIN releases local_release ON local_release.release_id = l.release_id
                       WHERE l.release_group_mbid = ar.release_group_mbid
                         AND local_release.artist_id = ?1
                       ORDER BY l.release_id LIMIT 1) AS local_release_id
               FROM external_artist_release_groups ar
               WHERE ar.artist_id = ?1 AND ar.identity_generation = ?2
                 AND ar.catalog_generation = ?3
             )
             SELECT catalog.snapshot_payload, catalog.local_release_id,
                    a.provider, a.provider_id, a.source_url, a.managed_path,
                    a.width, a.height, a.attribution, a.fetched_at, a.expires_at,
                    a.artwork_scope
             FROM catalog
             LEFT JOIN local_release_external_ids local_ids
               ON local_ids.release_id = catalog.local_release_id
             LEFT JOIN releases local_release
               ON local_release.release_id = catalog.local_release_id
             LEFT JOIN enrichment_assets a ON a.artist_id = catalog.artist_id
               AND a.release_group_mbid = catalog.release_group_mbid
               AND a.generation = catalog.identity_generation
               AND a.provider = 'cover_art_archive'
               AND COALESCE(TRIM(local_release.artwork), '') = ''
               AND a.catalog_key = (
                 SELECT a2.catalog_key FROM enrichment_assets a2
                 WHERE a2.artist_id = catalog.artist_id
                   AND a2.release_group_mbid = catalog.release_group_mbid
                   AND a2.generation = catalog.identity_generation
                   AND a2.provider = 'cover_art_archive'
                   AND (a2.artwork_scope = 'release_group'
                        OR (a2.artwork_scope = 'exact_release'
                            AND a2.exact_release_mbid = local_ids.release_mbid))
                 ORDER BY CASE a2.artwork_scope WHEN 'exact_release' THEN 0 ELSE 1 END
                 LIMIT 1
               )
             ORDER BY catalog.provider_position, catalog.release_group_mbid
             LIMIT ?4 OFFSET ?5",
        )
        .map_err(storage)?;
    let mut rows = stmt
        .query(params![
            artist_id,
            i64::try_from(identity.generation).map_err(storage)?,
            catalog_generation,
            i64::try_from(query_limit).map_err(storage)?,
            i64::try_from(offset).map_err(storage)?
        ])
        .map_err(storage)?;
    let mut items = Vec::new();
    while let Some(row) = rows.next().map_err(storage)? {
        let snapshot: ReleaseGroupSnapshot =
            serde_json::from_str(&row.get::<_, String>(0).map_err(storage)?).map_err(storage)?;
        let artwork_provider: Option<String> = row.get(2).map_err(storage)?;
        let artwork = if let Some(provider) = artwork_provider {
            let expires_at: i64 = row.get(10).map_err(storage)?;
            let scope: String = row.get(11).map_err(storage)?;
            Some(ExternalReleaseArtwork {
                image: ArtistImageReference {
                    provider: decode_enum(provider)?,
                    provider_id: row.get(3).map_err(storage)?,
                    source_url: row.get(4).map_err(storage)?,
                    managed_path: row.get(5).map_err(storage)?,
                    width: row.get(6).map_err(storage)?,
                    height: row.get(7).map_err(storage)?,
                    attribution: serde_json::from_str(&row.get::<_, String>(8).map_err(storage)?)
                        .map_err(storage)?,
                    fetched_at: row.get(9).map_err(storage)?,
                    expires_at,
                    stale: now >= expires_at,
                },
                scope: decode_enum(scope)?,
            })
        } else {
            None
        };
        items.push(ExternalReleaseGroup {
            musicbrainz_id: snapshot.musicbrainz_id,
            title: snapshot.title,
            primary_type: snapshot.primary_type,
            secondary_types: snapshot.secondary_types,
            first_release_date: snapshot.first_release_date,
            local_release_id: row.get(1).map_err(storage)?,
            artwork,
            attribution: snapshot.attribution,
        });
    }
    let has_more = items.len() > page_size as usize;
    items.truncate(page_size as usize);
    let result = ArtistDiscographyPage {
        artist_id,
        identity_generation: identity.generation,
        catalog_generation: u64::try_from(catalog_generation).map_err(storage)?,
        items,
        next_offset: has_more.then(|| offset.saturating_add(page_size)),
        remote_exhausted,
        remote_next_offset: remote_next_offset
            .map(u64::try_from)
            .transpose()
            .map_err(storage)?,
        remote_total: remote_total
            .map(u64::try_from)
            .transpose()
            .map_err(storage)?,
        last_success_at,
        stale: expires_at.is_none_or(|expires_at| now >= expires_at),
    };
    drop(rows);
    drop(stmt);
    tx.commit().map_err(storage)?;
    Ok(result)
}

/// Returns a release group only when it belongs to the artist's currently
/// published identity/catalog generation.
pub fn release_group_snapshot(
    conn: &Connection,
    artist_id: i64,
    release_group_mbid: &str,
) -> CoreResult<Option<ReleaseGroupSnapshot>> {
    if artist_id < 0 {
        return Err(invalid("Artist ID must be non-negative"));
    }
    let identity = crate::database::identity::read_persisted_inner(conn, artist_id)?;
    let payload = conn
        .query_row(
            "SELECT ar.snapshot_payload
             FROM external_artist_release_groups ar
             JOIN artist_discography_state d
               ON d.artist_id = ar.artist_id
              AND d.identity_generation = ar.identity_generation
              AND d.active_generation = ar.catalog_generation
             WHERE ar.artist_id = ?1 AND ar.identity_generation = ?2
               AND ar.release_group_mbid = ?3",
            params![
                artist_id,
                i64::try_from(identity.generation).map_err(storage)?,
                release_group_mbid
            ],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .map_err(storage)?;
    payload
        .map(|payload| serde_json::from_str(&payload).map_err(storage))
        .transpose()
}

pub fn external_release_details(
    conn: &Connection,
    artist_id: i64,
    release_group_mbid: &str,
) -> CoreResult<Option<ExternalReleaseDetailsSnapshot>> {
    if artist_id < 0 {
        return Err(invalid("Artist ID must be non-negative"));
    }
    conn.query_row(
        "SELECT d.identity_generation, d.payload, d.fetched_at, d.expires_at,
                d.etag, d.last_modified
         FROM external_release_details d
         JOIN artist_enrichment_state s
           ON s.artist_id = d.artist_id AND s.generation = d.identity_generation
         JOIN artist_discography_state ds
           ON ds.artist_id = d.artist_id AND ds.identity_generation = d.identity_generation
         JOIN external_artist_release_groups ar
           ON ar.artist_id = d.artist_id
          AND ar.identity_generation = d.identity_generation
          AND ar.catalog_generation = ds.active_generation
          AND ar.release_group_mbid = d.release_group_mbid
         WHERE d.artist_id = ?1 AND d.release_group_mbid = ?2
           AND s.identity_status = 'resolved'",
        params![artist_id, release_group_mbid],
        |row| {
            let generation = row.get::<_, i64>(0)?;
            let payload = row.get::<_, String>(1)?;
            Ok((
                generation,
                payload,
                row.get(2)?,
                row.get(3)?,
                row.get(4)?,
                row.get(5)?,
            ))
        },
    )
    .optional()
    .map_err(storage)?
    .map(
        |(generation, payload, fetched_at, expires_at, etag, last_modified)| {
            Ok(ExternalReleaseDetailsSnapshot {
                artist_id,
                identity_generation: u64::try_from(generation).map_err(storage)?,
                details: serde_json::from_str(&payload).map_err(storage)?,
                fetched_at,
                expires_at,
                validators: CacheValidators {
                    etag,
                    last_modified,
                },
            })
        },
    )
    .transpose()
}

/// Stores details only while the release group still belongs to the current
/// published catalog. A generation race discards the network response.
pub fn store_external_release_details(
    conn: &Connection,
    snapshot: &ExternalReleaseDetailsSnapshot,
) -> CoreResult<bool> {
    if snapshot.artist_id < 0 || snapshot.expires_at < snapshot.fetched_at {
        return Err(invalid("Invalid external release details snapshot"));
    }
    let generation = i64::try_from(snapshot.identity_generation).map_err(storage)?;
    let payload = serde_json::to_string(&snapshot.details).map_err(storage)?;
    if payload.len() > MAX_JSON_BYTES {
        return Err(invalid(
            "External release details payload exceeds size limit",
        ));
    }
    let tx = conn.unchecked_transaction().map_err(storage)?;
    let current: bool = tx
        .query_row(
            "SELECT EXISTS(
                SELECT 1 FROM artist_enrichment_state s
                JOIN artist_discography_state ds USING (artist_id)
                JOIN external_artist_release_groups ar
                  ON ar.artist_id = s.artist_id
                 AND ar.identity_generation = s.generation
                 AND ar.catalog_generation = ds.active_generation
                 AND ar.release_group_mbid = ?3
                WHERE s.artist_id = ?1 AND s.generation = ?2
                  AND s.identity_status = 'resolved'
            )",
            params![
                snapshot.artist_id,
                generation,
                snapshot.details.release_group_mbid
            ],
            |row| row.get(0),
        )
        .map_err(storage)?;
    if !current {
        return Ok(false);
    }
    tx.execute(
        "INSERT INTO external_release_details
         (artist_id, release_group_mbid, identity_generation, payload_version,
          payload, fetched_at, expires_at, etag, last_modified)
         VALUES (?1, ?2, ?3, 1, ?4, ?5, ?6, ?7, ?8)
         ON CONFLICT (artist_id, release_group_mbid) DO UPDATE SET
           identity_generation = excluded.identity_generation,
           payload_version = excluded.payload_version,
           payload = excluded.payload, fetched_at = excluded.fetched_at,
           expires_at = excluded.expires_at, etag = excluded.etag,
           last_modified = excluded.last_modified
         WHERE external_release_details.identity_generation != excluded.identity_generation
            OR external_release_details.fetched_at <= excluded.fetched_at",
        params![
            snapshot.artist_id,
            snapshot.details.release_group_mbid,
            generation,
            payload,
            snapshot.fetched_at,
            snapshot.expires_at,
            snapshot.validators.etag,
            snapshot.validators.last_modified,
        ],
    )
    .map_err(storage)?;
    tx.commit().map_err(storage)?;
    Ok(true)
}

pub fn popular_tracks_snapshot(
    conn: &Connection,
    artist_id: i64,
) -> CoreResult<Option<PopularTracksSnapshot>> {
    if artist_id < 0 {
        return Err(invalid("Artist ID must be non-negative"));
    }
    conn.query_row(
        "SELECT p.identity_generation, p.payload_version, p.payload, p.fetched_at,
                p.expires_at, p.etag, p.last_modified
         FROM artist_popular_tracks p
         JOIN artist_enrichment_state s
           ON s.artist_id = p.artist_id AND s.generation = p.identity_generation
         WHERE p.artist_id = ?1 AND p.provider = 'last_fm'
           AND s.identity_status = 'resolved'",
        [artist_id],
        |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, i64>(1)?,
                row.get::<_, String>(2)?,
                row.get(3)?,
                row.get(4)?,
                row.get(5)?,
                row.get(6)?,
            ))
        },
    )
    .optional()
    .map_err(storage)?
    .map(
        |(generation, version, payload, fetched_at, expires_at, etag, last_modified)| {
            if version != 1 || payload.len() > MAX_JSON_BYTES {
                return Err(storage("Unsupported popular tracks payload"));
            }
            let items: Vec<ArtistPopularTrack> = serde_json::from_str(&payload).map_err(storage)?;
            Ok(PopularTracksSnapshot {
                artist_id,
                identity_generation: u64::try_from(generation).map_err(storage)?,
                items: match_popular_tracks_to_library(conn, artist_id, &items)?,
                fetched_at,
                expires_at,
                validators: CacheValidators {
                    etag,
                    last_modified,
                },
            })
        },
    )
    .transpose()
}

pub fn store_popular_tracks(
    conn: &Connection,
    snapshot: &PopularTracksSnapshot,
) -> CoreResult<bool> {
    if snapshot.artist_id < 0
        || snapshot.expires_at < snapshot.fetched_at
        || snapshot.items.len() > 10
    {
        return Err(invalid("Invalid popular tracks snapshot"));
    }
    for (index, item) in snapshot.items.iter().enumerate() {
        if item.rank != index as u32 + 1
            || item.title.trim().is_empty()
            || item.title.len() > 500
            || item.local_track_id.is_some_and(|id| id < 0)
        {
            return Err(invalid("Invalid popular track"));
        }
    }
    let generation = i64::try_from(snapshot.identity_generation).map_err(storage)?;
    let matched_items = match_popular_tracks_to_library(conn, snapshot.artist_id, &snapshot.items)?;
    let payload = serde_json::to_string(&matched_items).map_err(storage)?;
    if payload.len() > MAX_JSON_BYTES {
        return Err(invalid("Popular tracks payload exceeds size limit"));
    }
    let changed = conn
        .execute(
            "INSERT INTO artist_popular_tracks
             (artist_id, provider, identity_generation, payload_version, payload,
              fetched_at, expires_at, etag, last_modified)
             SELECT ?1, 'last_fm', ?2, 1, ?3, ?4, ?5, ?6, ?7
             WHERE EXISTS (
                 SELECT 1 FROM artist_enrichment_state
                 WHERE artist_id = ?1 AND generation = ?2 AND identity_status = 'resolved'
             )
             ON CONFLICT (artist_id, provider) DO UPDATE SET
               identity_generation = excluded.identity_generation,
               payload_version = excluded.payload_version,
               payload = excluded.payload,
               fetched_at = excluded.fetched_at,
               expires_at = excluded.expires_at,
               etag = excluded.etag,
               last_modified = excluded.last_modified
             WHERE artist_popular_tracks.identity_generation != excluded.identity_generation
                OR artist_popular_tracks.fetched_at <= excluded.fetched_at",
            params![
                snapshot.artist_id,
                generation,
                payload,
                snapshot.fetched_at,
                snapshot.expires_at,
                snapshot.validators.etag,
                snapshot.validators.last_modified,
            ],
        )
        .map_err(storage)?;
    Ok(changed == 1)
}

#[derive(Debug)]
struct LocalPopularTrackCandidate {
    song_id: i64,
    title_key: String,
    relaxed_title_key: String,
    recording_ids: std::collections::BTreeSet<String>,
}

/// Resolves an informational Last.fm ranking only against tracks that belong
/// to the already-confirmed local artist. Ambiguous matches deliberately stay
/// external: a false positive would make an unrelated file playable.
fn match_popular_tracks_to_library(
    conn: &Connection,
    artist_id: i64,
    items: &[ArtistPopularTrack],
) -> CoreResult<Vec<ArtistPopularTrack>> {
    let mut statement = conn
        .prepare(
            "SELECT DISTINCT s.song_id, s.title, t.payload
             FROM songs s
             JOIN song_artists sa ON sa.song_id = s.song_id
             LEFT JOIN song_musicbrainz_tags t ON t.song_id = s.song_id
             WHERE sa.artist_id = ?1
             ORDER BY s.song_id",
        )
        .map_err(storage)?;
    let candidates = statement
        .query_map([artist_id], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, Option<String>>(2)?,
            ))
        })
        .map_err(storage)?
        .map(|row| {
            let (song_id, title, payload) = row.map_err(storage)?;
            let recording_ids = payload
                .and_then(|payload| {
                    serde_json::from_str::<crate::metadata::MusicBrainzTags>(&payload).ok()
                })
                .map(|tags| {
                    tags.recordings
                        .into_iter()
                        .filter_map(|id| crate::enrichment::identity::normalize_mbid(&id))
                        .collect()
                })
                .unwrap_or_default();
            Ok(LocalPopularTrackCandidate {
                song_id,
                title_key: popular_track_title_key(&title, false),
                relaxed_title_key: popular_track_title_key(&title, true),
                recording_ids,
            })
        })
        .collect::<CoreResult<Vec<_>>>()?;

    items
        .iter()
        .map(|item| {
            let mut matched = item.clone();
            matched.local_track_id = unique_popular_track_match(item, &candidates);
            Ok(matched)
        })
        .collect()
}

fn unique_popular_track_match(
    item: &ArtistPopularTrack,
    candidates: &[LocalPopularTrackCandidate],
) -> Option<i64> {
    if let Some(recording_id) = item
        .musicbrainz_id
        .as_deref()
        .and_then(crate::enrichment::identity::normalize_mbid)
    {
        let recording_matches: Vec<_> = candidates
            .iter()
            .filter(|candidate| candidate.recording_ids.contains(&recording_id))
            .collect();
        match recording_matches.as_slice() {
            [candidate] => return Some(candidate.song_id),
            [] => {}
            matches => {
                let title_key = popular_track_title_key(&item.title, false);
                return unique_candidate_id(
                    matches
                        .iter()
                        .copied()
                        .filter(|candidate| candidate.title_key == title_key),
                );
            }
        }
    }

    let title_key = popular_track_title_key(&item.title, false);
    let exact: Vec<_> = candidates
        .iter()
        .filter(|candidate| candidate.title_key == title_key)
        .collect();
    match exact.as_slice() {
        [candidate] => return Some(candidate.song_id),
        [] => {}
        _ => return None,
    }

    let relaxed_title_key = popular_track_title_key(&item.title, true);
    if relaxed_title_key.is_empty() {
        return None;
    }
    unique_candidate_id(
        candidates
            .iter()
            .filter(|candidate| candidate.relaxed_title_key == relaxed_title_key),
    )
}

fn unique_candidate_id<'a>(
    candidates: impl Iterator<Item = &'a LocalPopularTrackCandidate>,
) -> Option<i64> {
    let mut candidates = candidates.map(|candidate| candidate.song_id);
    let candidate = candidates.next()?;
    candidates.next().is_none().then_some(candidate)
}

fn popular_track_title_key(title: &str, remove_punctuation: bool) -> String {
    let normalized = title
        .trim()
        .chars()
        .flat_map(char::to_lowercase)
        .filter(|character| {
            !remove_punctuation || character.is_alphanumeric() || character.is_whitespace()
        });
    normalized
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

pub fn touch_popular_tracks(
    conn: &Connection,
    artist_id: i64,
    identity_generation: u64,
    fetched_at: i64,
    expires_at: i64,
    validators: &CacheValidators,
) -> CoreResult<bool> {
    if artist_id < 0 || expires_at < fetched_at {
        return Err(invalid("Invalid popular tracks expiry"));
    }
    let generation = i64::try_from(identity_generation).map_err(storage)?;
    let changed = conn
        .execute(
            "UPDATE artist_popular_tracks
             SET fetched_at = ?3, expires_at = ?4, etag = ?5, last_modified = ?6
             WHERE artist_id = ?1 AND provider = 'last_fm' AND identity_generation = ?2
               AND EXISTS (
                 SELECT 1 FROM artist_enrichment_state
                 WHERE artist_id = ?1 AND generation = ?2 AND identity_status = 'resolved'
               )",
            params![
                artist_id,
                generation,
                fetched_at,
                expires_at,
                validators.etag,
                validators.last_modified,
            ],
        )
        .map_err(storage)?;
    Ok(changed == 1)
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
    use crate::enrichment::models::ReleaseGroupSnapshot;

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

    #[test]
    fn read_snapshots_do_not_compete_with_an_active_writer() {
        let unique = format!(
            "durvald-enrichment-locks-{}-{}.sqlite",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        );
        let path = std::env::temp_dir().join(unique);
        let mut writer = Connection::open(&path).unwrap();
        writer
            .execute_batch(
                "PRAGMA journal_mode = WAL; PRAGMA busy_timeout = 0; PRAGMA foreign_keys = ON;",
            )
            .unwrap();
        crate::database::operations::create_tables(&writer).unwrap();
        crate::database::migrations::migrate_enrichment(&mut writer).unwrap();
        writer
            .execute(
                "INSERT INTO artists (artist_id, name) VALUES (7, 'An artist')",
                [],
            )
            .unwrap();
        let catalog_generation = begin_discography_snapshot(&writer, 7, 0).unwrap().unwrap();
        store_discography_page(
            &writer,
            &discography_page(
                catalog_generation,
                0,
                vec![release_group(
                    "11111111-1111-4111-8111-111111111111",
                    "Album",
                    2001,
                )],
                None,
            ),
        )
        .unwrap();

        let reader = Connection::open(&path).unwrap();
        reader
            .execute_batch("PRAGMA busy_timeout = 0; PRAGMA foreign_keys = ON;")
            .unwrap();
        let write_tx = Transaction::new_unchecked(&writer, TransactionBehavior::Immediate).unwrap();
        write_tx
            .execute(
                "UPDATE enrichment_settings SET offline = offline WHERE id = 1",
                [],
            )
            .unwrap();

        let plan = external_artwork_refresh_plan(&reader, 7, 0, 150, false).unwrap();
        assert_eq!(plan.targets.len(), 1);
        let page = read_discography(&reader, 7, 10, 0, 150).unwrap();
        assert_eq!(page.items.len(), 1);

        write_tx.rollback().unwrap();
        drop(reader);
        drop(writer);
        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_file(path.with_extension("sqlite-wal"));
        let _ = std::fs::remove_file(path.with_extension("sqlite-shm"));
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

    fn release_group(id: &str, title: &str, year: i32) -> ReleaseGroupSnapshot {
        ReleaseGroupSnapshot {
            musicbrainz_id: id.into(),
            title: title.into(),
            primary_type: Some("Album".into()),
            secondary_types: vec!["Studio".into()],
            first_release_date: Some(ArtistPartialDate {
                year,
                month: None,
                day: None,
            }),
            genres: Vec::new(),
            composers: Vec::new(),
            producers: Vec::new(),
            attribution: EnrichmentAttribution {
                source_url: format!("https://musicbrainz.org/release-group/{id}"),
                author: Some("MusicBrainz contributors".into()),
                license_name: Some("CC BY-SA 3.0".into()),
                license_url: None,
                revision: None,
            },
        }
    }

    fn discography_page(
        generation: u64,
        offset: u64,
        groups: Vec<ReleaseGroupSnapshot>,
        next: Option<u64>,
    ) -> DiscographyPageSnapshot {
        let remote_total = next.map_or_else(
            || offset.saturating_add(groups.len() as u64),
            |next| next.saturating_add(1),
        );
        DiscographyPageSnapshot {
            artist_id: 7,
            identity_generation: 0,
            catalog_generation: generation,
            provider_offset: offset,
            groups,
            remote_total,
            remote_next_offset: next,
            remote_exhausted: next.is_none(),
            fetched_at: 100,
            expires_at: 200,
            validators: CacheValidators::default(),
        }
    }

    #[test]
    fn external_release_details_are_offline_readable_and_identity_scoped() {
        let conn = database();
        let group_id = "11111111-1111-4111-8111-111111111111";
        let generation = begin_discography_snapshot(&conn, 7, 0).unwrap().unwrap();
        conn.execute(
            "UPDATE artist_enrichment_state
             SET identity_status = 'resolved',
                 musicbrainz_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
             WHERE artist_id = 7",
            [],
        )
        .unwrap();
        store_discography_page(
            &conn,
            &discography_page(
                generation,
                0,
                vec![release_group(group_id, "Album", 2001)],
                None,
            ),
        )
        .unwrap();
        let details = ExternalReleaseDetails {
            release_group_mbid: group_id.into(),
            release_mbid: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb".into(),
            title: "Album".into(),
            artist: "An artist".into(),
            release_date: Some(ArtistPartialDate {
                year: 2001,
                month: None,
                day: None,
            }),
            genres: vec!["Electronic".into()],
            composers: vec![],
            producers: vec![],
            total_discs: 1,
            duration_seconds: 62,
            tracks: vec![ExternalReleaseTrack {
                disc_number: 1,
                track_number: 1,
                title: "Track".into(),
                artist: "An artist".into(),
                duration_seconds: Some(62),
            }],
            attribution: release_group(group_id, "Album", 2001).attribution,
        };
        let snapshot = ExternalReleaseDetailsSnapshot {
            artist_id: 7,
            identity_generation: 0,
            details: details.clone(),
            fetched_at: 100,
            expires_at: 200,
            validators: CacheValidators {
                etag: Some("\"details-v1\"".into()),
                last_modified: None,
            },
        };
        assert!(store_external_release_details(&conn, &snapshot).unwrap());
        let cached = external_release_details(&conn, 7, group_id)
            .unwrap()
            .unwrap();
        assert_eq!(cached.details, details);
        assert_eq!(cached.validators.etag.as_deref(), Some("\"details-v1\""));

        conn.execute(
            "UPDATE artist_enrichment_state SET generation = generation + 1 WHERE artist_id = 7",
            [],
        )
        .unwrap();
        assert!(
            external_release_details(&conn, 7, group_id)
                .unwrap()
                .is_none()
        );
        assert_eq!(
            conn.query_row("SELECT COUNT(*) FROM external_release_details", [], |row| {
                row.get::<_, i64>(0)
            })
            .unwrap(),
            0
        );
    }

    fn external_artwork(
        group_id: &str,
        exact_release_mbid: Option<&str>,
        scope: ExternalArtworkScope,
        path: &str,
        fetched_at: i64,
    ) -> ExternalArtworkSnapshot {
        ExternalArtworkSnapshot {
            artist_id: 7,
            identity_generation: 0,
            release_group_mbid: group_id.into(),
            exact_release_mbid: exact_release_mbid.map(str::to_owned),
            scope,
            provider_id: fetched_at.to_string(),
            source_url: "https://coverartarchive.org/release/source/1".into(),
            managed_path: path.into(),
            width: 500,
            height: 500,
            attribution: EnrichmentAttribution {
                source_url: "https://coverartarchive.org/release/source/1".into(),
                author: None,
                license_name: None,
                license_url: None,
                revision: None,
            },
            fetched_at,
            expires_at: fetched_at + 100,
        }
    }

    #[test]
    fn negative_artwork_results_expire_and_are_scoped_to_catalog_identity_and_mbid() {
        use crate::enrichment::models::{
            ExternalArtworkNegativeResult, ExternalArtworkNegativeSnapshot,
        };

        let conn = database();
        let group_id = "11111111-1111-4111-8111-111111111111";
        let first_release_id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
        let second_release_id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
        let first_catalog = begin_discography_snapshot(&conn, 7, 0).unwrap().unwrap();
        store_discography_page(
            &conn,
            &discography_page(
                first_catalog,
                0,
                vec![release_group(group_id, "Album", 2010)],
                None,
            ),
        )
        .unwrap();
        let mut negative = ExternalArtworkNegativeSnapshot {
            artist_id: 7,
            identity_generation: 0,
            catalog_generation: first_catalog,
            release_group_mbid: group_id.into(),
            exact_release_mbid: None,
            result: ExternalArtworkNegativeResult::NotFound,
            last_error: "http_404".into(),
            recorded_at: 100,
            expires_at: 1_000,
        };
        assert!(store_external_artwork_negative_result(&conn, &negative).unwrap());
        assert_eq!(
            conn.query_row(
                "SELECT result FROM external_artwork_negative_results",
                [],
                |row| row.get::<_, String>(0),
            )
            .unwrap(),
            "not_found"
        );
        assert!(
            external_artwork_refresh_plan(&conn, 7, 0, 999, false)
                .unwrap()
                .targets
                .is_empty()
        );
        assert_eq!(
            external_artwork_refresh_plan(&conn, 7, 0, 1_000, false)
                .unwrap()
                .targets
                .len(),
            1
        );

        let second_catalog = begin_discography_snapshot(&conn, 7, 0).unwrap().unwrap();
        store_discography_page(
            &conn,
            &discography_page(
                second_catalog,
                0,
                vec![release_group(group_id, "Album", 2010)],
                None,
            ),
        )
        .unwrap();
        let fresh_catalog_plan = external_artwork_refresh_plan(&conn, 7, 0, 200, false).unwrap();
        assert_eq!(fresh_catalog_plan.targets.len(), 1);
        assert_eq!(
            fresh_catalog_plan.targets[0].catalog_generation,
            second_catalog
        );

        conn.execute(
            "INSERT INTO releases
             (release_id, title, artist_id, artist_name, artwork)
             VALUES (70, 'Local edition', 7, 'An artist', '')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO local_release_external_ids
             (release_id, release_mbid, release_group_mbid, origin, updated_at)
             VALUES (70, ?1, ?2, 'tag', 200)",
            params![first_release_id, group_id],
        )
        .unwrap();
        negative.catalog_generation = second_catalog;
        negative.exact_release_mbid = Some(first_release_id.into());
        negative.result = ExternalArtworkNegativeResult::InvalidImage;
        negative.last_error = "invalid_image".into();
        negative.recorded_at = 200;
        negative.expires_at = 800;
        assert!(store_external_artwork_negative_result(&conn, &negative).unwrap());
        assert_eq!(
            conn.query_row(
                "SELECT result FROM external_artwork_negative_results
                 WHERE catalog_key = ?1",
                [format!("release:{first_release_id}")],
                |row| row.get::<_, String>(0),
            )
            .unwrap(),
            "invalid_image"
        );
        assert!(
            external_artwork_refresh_plan(&conn, 7, 0, 300, false)
                .unwrap()
                .targets
                .is_empty()
        );

        negative.result = ExternalArtworkNegativeResult::TemporaryFailure;
        negative.last_error = "timeout".into();
        negative.recorded_at = 300;
        negative.expires_at = 350;
        assert!(store_external_artwork_negative_result(&conn, &negative).unwrap());
        assert_eq!(
            conn.query_row(
                "SELECT result FROM external_artwork_negative_results
                 WHERE catalog_key = ?1",
                [format!("release:{first_release_id}")],
                |row| row.get::<_, String>(0),
            )
            .unwrap(),
            "temporary_failure"
        );

        conn.execute(
            "UPDATE local_release_external_ids
             SET release_mbid = ?1, updated_at = 301 WHERE release_id = 70",
            [second_release_id],
        )
        .unwrap();
        let changed_mbid_plan = external_artwork_refresh_plan(&conn, 7, 0, 301, false).unwrap();
        assert_eq!(changed_mbid_plan.targets.len(), 1);
        assert_eq!(
            changed_mbid_plan.targets[0].exact_release_mbid.as_deref(),
            Some(second_release_id)
        );

        conn.execute(
            "UPDATE artist_enrichment_state SET generation = 1 WHERE artist_id = 7",
            [],
        )
        .unwrap();
        negative.exact_release_mbid = Some(second_release_id.into());
        assert!(!store_external_artwork_negative_result(&conn, &negative).unwrap());
        assert!(
            external_artwork_refresh_plan(&conn, 7, 1, 301, false)
                .unwrap()
                .targets
                .is_empty()
        );
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
    fn lastfm_biography_does_not_replace_an_existing_wikipedia_snapshot() {
        let conn = database();
        let wikipedia = snapshot();
        assert!(store_profile(&conn, &wikipedia).unwrap());

        let mut lastfm = wikipedia.clone();
        lastfm.provider = EnrichmentProvider::LastFm;
        lastfm.fetched_at = 101;
        lastfm.profile.biography = Some("Last.fm biography".into());
        lastfm.profile.attribution.source_url = "https://www.last.fm/music/Artist".into();
        assert!(store_profile(&conn, &lastfm).unwrap());

        let details = read_artist_details(&conn, 7, "pt-br", 150).unwrap();
        assert_eq!(details.sources.len(), 2);
        assert_eq!(
            details
                .sources
                .iter()
                .find(|source| source.provider == EnrichmentProvider::Wikipedia)
                .and_then(|source| source.profile.biography.as_deref()),
            Some("A biography")
        );
        assert_eq!(
            details
                .sources
                .iter()
                .find(|source| source.provider == EnrichmentProvider::LastFm)
                .and_then(|source| source.profile.biography.as_deref()),
            Some("Last.fm biography")
        );
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

        let lastfm_asset = AssetSnapshot {
            provider: EnrichmentProvider::LastFm,
            provider_id: "lastfm-portrait".into(),
            source_url: "https://www.last.fm/music/Artist".into(),
            managed_path: "/managed/covers/lastfm.jpg".into(),
            attribution: EnrichmentAttribution {
                source_url: "https://www.last.fm/music/Artist".into(),
                author: Some("Last.fm community".into()),
                license_name: None,
                license_url: None,
                revision: None,
            },
            ..asset.clone()
        };
        assert!(store_asset(&conn, &lastfm_asset).unwrap());
        let preferred = read_artist_details(&conn, 7, "pt", 200)
            .unwrap()
            .portrait
            .unwrap();
        assert_eq!(preferred.provider, EnrichmentProvider::LastFm);
        assert_eq!(preferred.managed_path, "/managed/covers/lastfm.jpg");

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
            vec!["/managed/covers/hash.jpg", "/managed/covers/lastfm.jpg"]
        );
        assert_eq!(
            conn.query_row("SELECT COUNT(*) FROM enrichment_assets", [], |row| row
                .get::<_, i64>(0))
                .unwrap(),
            0
        );
    }

    #[test]
    fn popular_tracks_are_atomic_generation_scoped_snapshots() {
        let conn = database();
        crate::database::identity::read(&conn, 7).unwrap();
        conn.execute(
            "UPDATE artist_enrichment_state
             SET identity_status = 'resolved',
                 musicbrainz_id = '11111111-1111-4111-8111-111111111111'",
            [],
        )
        .unwrap();
        let snapshot = PopularTracksSnapshot {
            artist_id: 7,
            identity_generation: 0,
            items: vec![ArtistPopularTrack {
                rank: 1,
                title: "Clockwork Orange".into(),
                musicbrainz_id: None,
                play_count: 42,
                listeners: 21,
                lastfm_url: "https://www.last.fm/music/Wendy+Carlos/_/Clockwork+Orange".into(),
                local_track_id: None,
            }],
            fetched_at: 100,
            expires_at: 200,
            validators: CacheValidators {
                etag: Some("ranking-v1".into()),
                last_modified: None,
            },
        };
        assert!(store_popular_tracks(&conn, &snapshot).unwrap());
        assert_eq!(
            popular_tracks_snapshot(&conn, 7).unwrap().unwrap().items,
            snapshot.items
        );

        let mut stale_generation = snapshot.clone();
        stale_generation.identity_generation = 1;
        stale_generation.fetched_at = 101;
        assert!(!store_popular_tracks(&conn, &stale_generation).unwrap());
        assert_eq!(
            popular_tracks_snapshot(&conn, 7).unwrap().unwrap().items,
            snapshot.items
        );

        conn.execute("UPDATE artist_enrichment_state SET generation = 1", [])
            .unwrap();
        assert!(popular_tracks_snapshot(&conn, 7).unwrap().is_none());
        assert_eq!(
            conn.query_row("SELECT COUNT(*) FROM artist_popular_tracks", [], |row| row
                .get::<_, i64>(
                0
            ))
            .unwrap(),
            0
        );
    }

    #[test]
    fn popular_tracks_match_only_unique_local_tracks_for_the_confirmed_artist() {
        let conn = database();
        crate::database::identity::read(&conn, 7).unwrap();
        conn.execute(
            "UPDATE artist_enrichment_state
             SET identity_status = 'resolved',
                 musicbrainz_id = '11111111-1111-4111-8111-111111111111'",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO releases
             (release_id, title, artist_id, artist_name, duration)
             VALUES (10, 'Local album', 7, 'An artist', 600)",
            [],
        )
        .unwrap();
        for (song_id, title) in [
            (100, "Exact Title"),
            (101, "Don't Stop"),
            (102, "Ambiguous"),
            (103, "Ambiguous"),
            (104, "Recording Match"),
        ] {
            conn.execute(
                "INSERT INTO songs
                 (song_id, title, artwork, artist_id, artist_name, release_id,
                  release_title, track_number, disc_number, duration, file_path)
                 VALUES (?1, ?2, '', 7, 'An artist', 10, 'Local album', 1, 1, 120, ?3)",
                params![song_id, title, format!("/music/{song_id}.flac")],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO song_artists (song_id, artist_id, position) VALUES (?1, 7, 0)",
                [song_id],
            )
            .unwrap();
        }
        let recording_id = "22222222-2222-4222-8222-222222222222";
        let tags = crate::metadata::MusicBrainzTags {
            recordings: vec![recording_id.into()],
            ..Default::default()
        };
        conn.execute(
            "INSERT INTO song_musicbrainz_tags (song_id, payload) VALUES (104, ?1)",
            [serde_json::to_string(&tags).unwrap()],
        )
        .unwrap();
        let items = vec![
            popular_track(1, "exact title", None),
            popular_track(2, "Dont Stop", None),
            popular_track(3, "Ambiguous", None),
            popular_track(4, "Different provider title", Some(recording_id)),
            popular_track(5, "Exact Title (Radio Edit)", None),
        ];
        let snapshot = PopularTracksSnapshot {
            artist_id: 7,
            identity_generation: 0,
            items,
            fetched_at: 100,
            expires_at: 200,
            validators: CacheValidators::default(),
        };

        assert!(store_popular_tracks(&conn, &snapshot).unwrap());
        let stored = popular_tracks_snapshot(&conn, 7).unwrap().unwrap();
        assert_eq!(
            stored
                .items
                .iter()
                .map(|item| item.local_track_id)
                .collect::<Vec<_>>(),
            vec![Some(100), Some(101), None, Some(104), None]
        );
    }

    #[test]
    fn clearing_lastfm_data_preserves_other_providers_and_reports_only_orphans() {
        let conn = database();
        crate::database::identity::read(&conn, 7).unwrap();
        let attribution = serde_json::to_string(&EnrichmentAttribution {
            source_url: "https://example.test/source".into(),
            author: None,
            license_name: None,
            license_url: None,
            revision: None,
        })
        .unwrap();
        for (provider, path) in [
            ("last_fm", "/managed/lastfm.jpg"),
            ("commons", "/managed/commons.jpg"),
        ] {
            conn.execute(
                "INSERT INTO enrichment_assets
                 (artist_id, provider, catalog_key, provider_id, generation,
                  source_url, managed_path, attribution, fetched_at, expires_at)
                 VALUES (7, ?1, '', ?1, 0, 'https://example.test', ?2, ?3, 100, 200)",
                params![provider, path, attribution],
            )
            .unwrap();
        }
        conn.execute(
            "INSERT INTO artist_profile_sources
             (artist_id, provider, language, generation, payload_version, payload,
              fetched_at, expires_at)
             VALUES (7, 'last_fm', 'pt', 0, 1, '{}', 100, 200),
                    (7, 'wikipedia', 'pt', 0, 1, '{}', 100, 200)",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO artist_popular_tracks
             (artist_id, provider, identity_generation, payload_version, payload,
              fetched_at, expires_at)
             VALUES (7, 'last_fm', 0, 1, '[]', 100, 200)",
            [],
        )
        .unwrap();

        assert_eq!(
            clear_provider_data(&conn, EnrichmentProvider::LastFm).unwrap(),
            vec!["/managed/lastfm.jpg"]
        );
        assert_eq!(
            conn.query_row(
                "SELECT COUNT(*) FROM enrichment_assets WHERE provider = 'commons'",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
            1
        );
        assert_eq!(
            conn.query_row(
                "SELECT COUNT(*) FROM artist_profile_sources WHERE provider = 'wikipedia'",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
            1
        );
        assert_eq!(
            conn.query_row(
                "SELECT COUNT(*) FROM artist_popular_tracks WHERE provider = 'last_fm'",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
            0
        );
    }

    #[test]
    fn lastfm_retention_prunes_the_oldest_artist_snapshot() {
        let conn = database();
        for artist_id in [7, 8, 9] {
            if artist_id != 7 {
                conn.execute(
                    "INSERT INTO artists (artist_id, name) VALUES (?1, ?2)",
                    params![artist_id, format!("Artist {artist_id}")],
                )
                .unwrap();
            }
            crate::database::identity::read(&conn, artist_id).unwrap();
            conn.execute(
                "INSERT INTO artist_popular_tracks
                 (artist_id, provider, identity_generation, payload_version, payload,
                  fetched_at, expires_at)
                 VALUES (?1, 'last_fm', 0, 1, '[]', ?2, 999)",
                params![artist_id, artist_id * 10],
            )
            .unwrap();
        }

        assert!(
            prune_provider_snapshots(&conn, EnrichmentProvider::LastFm, 2)
                .unwrap()
                .is_empty()
        );
        let retained: Vec<i64> = conn
            .prepare(
                "SELECT artist_id FROM artist_popular_tracks
                 WHERE provider = 'last_fm' ORDER BY artist_id",
            )
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert_eq!(retained, vec![8, 9]);
    }

    fn popular_track(rank: u32, title: &str, musicbrainz_id: Option<&str>) -> ArtistPopularTrack {
        ArtistPopularTrack {
            rank,
            title: title.into(),
            musicbrainz_id: musicbrainz_id.map(str::to_owned),
            play_count: 42,
            listeners: 21,
            lastfm_url: "https://www.last.fm/music/artist/_/track".into(),
            local_track_id: None,
        }
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

    #[test]
    fn discography_pages_stay_hidden_until_atomically_published() {
        let conn = database();
        let first_id = "11111111-1111-4111-8111-111111111111";
        let second_id = "22222222-2222-4222-8222-222222222222";
        let generation = begin_discography_snapshot(&conn, 7, 0).unwrap().unwrap();
        assert_eq!(generation, 1);
        assert_eq!(
            discography_build_state(&conn, 7, 0).unwrap(),
            Some(DiscographyBuildState {
                catalog_generation: 1,
                next_offset: 0,
                remote_total: None,
                validators: CacheValidators::default(),
            })
        );
        assert!(
            store_discography_page(
                &conn,
                &discography_page(
                    generation,
                    0,
                    vec![release_group(first_id, "First", 1999)],
                    Some(1),
                ),
            )
            .unwrap()
        );
        let hidden = read_discography(&conn, 7, 10, 0, 150).unwrap();
        assert!(hidden.items.is_empty());
        assert!(!hidden.remote_exhausted);
        assert_eq!(
            discography_build_state(&conn, 7, 0).unwrap(),
            Some(DiscographyBuildState {
                catalog_generation: 1,
                next_offset: 1,
                remote_total: Some(2),
                validators: CacheValidators::default(),
            })
        );

        assert!(
            store_discography_page(
                &conn,
                &discography_page(
                    generation,
                    1,
                    vec![release_group(second_id, "Second", 2001)],
                    None,
                ),
            )
            .unwrap()
        );
        let first_page = read_discography(&conn, 7, 1, 0, 150).unwrap();
        assert_eq!(first_page.catalog_generation, generation);
        assert_eq!(first_page.items[0].title, "First");
        assert_eq!(first_page.next_offset, Some(1));
        assert!(first_page.remote_exhausted);
        assert_eq!(first_page.remote_total, Some(2));
        assert!(!first_page.stale);
        assert_eq!(discography_build_state(&conn, 7, 0).unwrap(), None);
        let second_page = read_discography(&conn, 7, 1, 1, 200).unwrap();
        assert_eq!(second_page.items[0].title, "Second");
        assert_eq!(second_page.next_offset, None);
        assert!(second_page.stale);

        let replacement = begin_discography_snapshot(&conn, 7, 0).unwrap().unwrap();
        assert_eq!(replacement, 2);
        let mut replacement_page = discography_page(
            replacement,
            0,
            vec![release_group(first_id, "Interrupted replacement", 2020)],
            Some(1),
        );
        replacement_page.fetched_at = 300;
        replacement_page.expires_at = 400;
        store_discography_page(&conn, &replacement_page).unwrap();
        let still_active = read_discography(&conn, 7, 10, 0, 250).unwrap();
        assert_eq!(
            still_active
                .items
                .iter()
                .map(|item| item.title.as_str())
                .collect::<Vec<_>>(),
            vec!["First", "Second"]
        );
        assert!(still_active.stale);
        assert_eq!(still_active.items[0].title, "First");
    }

    #[test]
    fn completed_discography_survives_database_reopening() {
        let path = std::env::temp_dir().join(format!(
            "durvald-discography-{}-{}.sqlite",
            std::process::id(),
            std::thread::current().name().unwrap_or("test")
        ));
        let _ = std::fs::remove_file(&path);
        {
            let mut conn = Connection::open(&path).unwrap();
            conn.execute_batch("PRAGMA foreign_keys = ON;").unwrap();
            crate::database::operations::create_tables(&conn).unwrap();
            crate::database::migrations::migrate_enrichment(&mut conn).unwrap();
            conn.execute(
                "INSERT INTO artists (artist_id, name) VALUES (7, 'An artist')",
                [],
            )
            .unwrap();
            let generation = begin_discography_snapshot(&conn, 7, 0).unwrap().unwrap();
            assert!(
                store_discography_page(
                    &conn,
                    &discography_page(
                        generation,
                        0,
                        vec![release_group(
                            "11111111-1111-4111-8111-111111111111",
                            "Persisted",
                            2005,
                        )],
                        None,
                    ),
                )
                .unwrap()
            );
        }
        {
            let mut conn = Connection::open(&path).unwrap();
            conn.execute_batch("PRAGMA foreign_keys = ON;").unwrap();
            crate::database::migrations::migrate_enrichment(&mut conn).unwrap();
            let page = read_discography(&conn, 7, 10, 0, 150).unwrap();
            assert_eq!(page.catalog_generation, 1);
            assert_eq!(page.items[0].title, "Persisted");
            assert!(page.remote_exhausted);
        }
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn discography_read_links_local_release_and_external_artwork_without_mutating_it() {
        let conn = database();
        let group_id = "11111111-1111-4111-8111-111111111111";
        let generation = begin_discography_snapshot(&conn, 7, 0).unwrap().unwrap();
        store_discography_page(
            &conn,
            &discography_page(
                generation,
                0,
                vec![release_group(group_id, "Linked", 2010)],
                None,
            ),
        )
        .unwrap();
        conn.execute(
            "INSERT INTO releases (release_id, title, artist_id, artist_name)
             VALUES (70, 'Local edition', 7, 'An artist')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO local_release_external_ids
             (release_id, release_mbid, release_group_mbid, origin, updated_at)
             VALUES (70, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', ?1, 'tag', 100)",
            [group_id],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO enrichment_assets
             (artist_id, provider, catalog_key, provider_id, generation,
              release_group_mbid, artwork_scope, source_url, managed_path,
              width, height, attribution, fetched_at, expires_at)
             VALUES (7, 'cover_art_archive', ?1, 'front-250.jpg', 0, ?2,
                     'release_group', 'https://coverartarchive.org/release-group/source',
                     '/managed/covers/front.jpg', 250, 250, ?3, 100, 200)",
            params![
                format!("release-group:{group_id}"),
                group_id,
                serde_json::to_string(&EnrichmentAttribution {
                    source_url: "https://coverartarchive.org/release-group/source".into(),
                    author: None,
                    license_name: None,
                    license_url: None,
                    revision: None,
                })
                .unwrap()
            ],
        )
        .unwrap();

        let page = read_discography(&conn, 7, 10, 0, 150).unwrap();
        assert_eq!(page.items[0].local_release_id, Some(70));
        let artwork = page.items[0].artwork.as_ref().unwrap();
        assert_eq!(artwork.scope, ExternalArtworkScope::ReleaseGroup);
        assert_eq!(artwork.image.provider, EnrichmentProvider::CoverArtArchive);
        assert_eq!(artwork.image.managed_path, "/managed/covers/front.jpg");
        assert_eq!(
            conn.query_row(
                "SELECT artwork FROM releases WHERE release_id = 70",
                [],
                |row| { row.get::<_, Option<String>>(0) }
            )
            .unwrap(),
            None
        );
    }

    #[test]
    fn local_artwork_wins_and_exact_external_artwork_requires_matching_identifiers() {
        let conn = database();
        let group_id = "11111111-1111-4111-8111-111111111111";
        let release_id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
        let generation = begin_discography_snapshot(&conn, 7, 0).unwrap().unwrap();
        store_discography_page(
            &conn,
            &discography_page(
                generation,
                0,
                vec![release_group(group_id, "Linked", 2010)],
                None,
            ),
        )
        .unwrap();
        conn.execute(
            "INSERT INTO releases
             (release_id, title, artist_id, artist_name, artwork)
             VALUES (70, 'Local edition', 7, 'An artist', '/managed/local.jpg')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO local_release_external_ids
             (release_id, release_mbid, release_group_mbid, origin, updated_at)
             VALUES (70, ?1, ?2, 'tag', 100)",
            params![release_id, group_id],
        )
        .unwrap();

        assert!(
            store_external_artwork(
                &conn,
                &external_artwork(
                    group_id,
                    None,
                    ExternalArtworkScope::ReleaseGroup,
                    "/managed/group-old.jpg",
                    100,
                ),
            )
            .unwrap()
            .stored
        );
        assert!(
            store_external_artwork(
                &conn,
                &external_artwork(
                    group_id,
                    Some(release_id),
                    ExternalArtworkScope::ExactRelease,
                    "/managed/exact.jpg",
                    100,
                ),
            )
            .unwrap()
            .stored
        );
        assert!(
            store_external_artwork(
                &conn,
                &external_artwork(
                    group_id,
                    Some("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"),
                    ExternalArtworkScope::ExactRelease,
                    "/managed/wrong.jpg",
                    100,
                ),
            )
            .is_err()
        );

        let local_wins = read_discography(&conn, 7, 10, 0, 150).unwrap();
        assert_eq!(local_wins.items[0].local_release_id, Some(70));
        assert_eq!(local_wins.items[0].artwork, None);
        assert_eq!(
            conn.query_row(
                "SELECT artwork FROM releases WHERE release_id = 70",
                [],
                |row| row.get::<_, String>(0),
            )
            .unwrap(),
            "/managed/local.jpg"
        );

        conn.execute("UPDATE releases SET artwork = '' WHERE release_id = 70", [])
            .unwrap();
        let exact_wins = read_discography(&conn, 7, 10, 0, 150).unwrap();
        let artwork = exact_wins.items[0].artwork.as_ref().unwrap();
        assert_eq!(artwork.scope, ExternalArtworkScope::ExactRelease);
        assert_eq!(artwork.image.managed_path, "/managed/exact.jpg");

        conn.execute(
            "DELETE FROM enrichment_assets
             WHERE artist_id = 7 AND catalog_key = ?1",
            [format!("release:{release_id}")],
        )
        .unwrap();
        let group_fallback = read_discography(&conn, 7, 10, 0, 150).unwrap();
        let artwork = group_fallback.items[0].artwork.as_ref().unwrap();
        assert_eq!(artwork.scope, ExternalArtworkScope::ReleaseGroup);
        assert_eq!(artwork.image.managed_path, "/managed/group-old.jpg");

        let replaced = store_external_artwork(
            &conn,
            &external_artwork(
                group_id,
                None,
                ExternalArtworkScope::ReleaseGroup,
                "/managed/group-new.jpg",
                200,
            ),
        )
        .unwrap();
        assert_eq!(
            replaced.orphaned_path.as_deref(),
            Some("/managed/group-old.jpg")
        );
        conn.execute(
            "UPDATE releases SET artwork = '/managed/group-new.jpg' WHERE release_id = 70",
            [],
        )
        .unwrap();
        let conservatively_replaced = store_external_artwork(
            &conn,
            &external_artwork(
                group_id,
                None,
                ExternalArtworkScope::ReleaseGroup,
                "/managed/group-newest.jpg",
                300,
            ),
        )
        .unwrap();
        assert_eq!(conservatively_replaced.orphaned_path, None);
        assert_eq!(
            conn.query_row(
                "SELECT artwork FROM releases WHERE release_id = 70",
                [],
                |row| row.get::<_, String>(0),
            )
            .unwrap(),
            "/managed/group-new.jpg"
        );
    }

    #[test]
    fn discography_never_links_a_local_release_by_title() {
        let conn = database();
        let group_id = "11111111-1111-4111-8111-111111111111";
        conn.execute(
            "INSERT INTO releases (release_id, title, artist_id, artist_name)
             VALUES (70, 'Same title', 7, 'An artist')",
            [],
        )
        .unwrap();
        let generation = begin_discography_snapshot(&conn, 7, 0).unwrap().unwrap();
        store_discography_page(
            &conn,
            &discography_page(
                generation,
                0,
                vec![release_group(group_id, "Same title", 2010)],
                None,
            ),
        )
        .unwrap();

        let page = read_discography(&conn, 7, 10, 0, 150).unwrap();
        assert_eq!(page.items[0].title, "Same title");
        assert_eq!(page.items[0].local_release_id, None);
    }

    #[test]
    fn discography_writes_are_generation_scoped_and_validate_pages() {
        let conn = database();
        let generation = begin_discography_snapshot(&conn, 7, 0).unwrap().unwrap();
        let duplicate = release_group("11111111-1111-4111-8111-111111111111", "One", 2000);
        let invalid = discography_page(generation, 0, vec![duplicate.clone(), duplicate], None);
        assert!(store_discography_page(&conn, &invalid).is_err());
        conn.execute("UPDATE artist_enrichment_state SET generation = 1", [])
            .unwrap();
        assert!(
            !store_discography_page(&conn, &discography_page(generation, 0, Vec::new(), None))
                .unwrap()
        );
        assert!(begin_discography_snapshot(&conn, 7, 0).unwrap().is_none());
        let page = read_discography(&conn, 7, 10, 0, 0).unwrap();
        assert!(page.items.is_empty());
        assert_eq!(page.identity_generation, 1);
    }

    #[test]
    fn discography_publication_requires_a_complete_stable_remote_total() {
        let conn = database();
        let generation = begin_discography_snapshot(&conn, 7, 0).unwrap().unwrap();
        assert!(
            store_discography_page(
                &conn,
                &discography_page(
                    generation,
                    0,
                    vec![release_group(
                        "11111111-1111-4111-8111-111111111111",
                        "First",
                        2000,
                    )],
                    Some(1),
                ),
            )
            .unwrap()
        );

        let mut changed_total = discography_page(
            generation,
            1,
            vec![release_group(
                "22222222-2222-4222-8222-222222222222",
                "Second",
                2001,
            )],
            None,
        );
        changed_total.remote_total = 3;
        assert!(store_discography_page(&conn, &changed_total).is_err());

        let mut incomplete = changed_total;
        incomplete.remote_total = 2;
        incomplete.groups[0].musicbrainz_id = "11111111-1111-4111-8111-111111111111".into();
        assert!(store_discography_page(&conn, &incomplete).is_err());
        let active = read_discography(&conn, 7, 10, 0, 150).unwrap();
        assert!(active.items.is_empty());
        assert_eq!(active.catalog_generation, 0);
        assert_eq!(
            discography_build_state(&conn, 7, 0)
                .unwrap()
                .unwrap()
                .next_offset,
            1
        );
        assert!(discard_discography_snapshot(&conn, 7, 0, generation).unwrap());
        assert_eq!(discography_build_state(&conn, 7, 0).unwrap(), None);
        assert!(!discard_discography_snapshot(&conn, 7, 0, generation).unwrap());
    }

    #[test]
    fn permanent_provider_failures_expire_and_follow_identity_and_resource() {
        let conn = database();
        conn.execute(
            "INSERT INTO artist_enrichment_state
             (artist_id, generation, identity_status, musicbrainz_id)
             VALUES (7, 2, 'resolved', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')",
            [],
        )
        .unwrap();
        let mut failure = ProviderFailureSnapshot {
            artist_id: 7,
            identity_generation: 2,
            provider: EnrichmentProvider::MusicBrainz,
            operation: "discography".into(),
            resource_key: "11111111111111111111111111111111".into(),
            error_code: "http_404".into(),
            retry_after_seconds: None,
            recorded_at: 100,
            expires_at: 200,
        };
        assert!(store_provider_failure(&conn, &failure).unwrap());
        assert!(
            active_provider_failure(
                &conn,
                7,
                2,
                EnrichmentProvider::MusicBrainz,
                "discography",
                &failure.resource_key,
                199,
            )
            .unwrap()
            .is_some()
        );
        assert!(
            active_provider_failure(
                &conn,
                7,
                2,
                EnrichmentProvider::MusicBrainz,
                "discography",
                &failure.resource_key,
                200,
            )
            .unwrap()
            .is_none()
        );
        assert!(
            active_provider_failure(
                &conn,
                7,
                2,
                EnrichmentProvider::MusicBrainz,
                "discography",
                "22222222222222222222222222222222",
                150,
            )
            .unwrap()
            .is_none()
        );

        conn.execute(
            "UPDATE artist_enrichment_state SET generation = 3 WHERE artist_id = 7",
            [],
        )
        .unwrap();
        assert!(
            active_provider_failure(
                &conn,
                7,
                3,
                EnrichmentProvider::MusicBrainz,
                "discography",
                &failure.resource_key,
                150,
            )
            .unwrap()
            .is_none()
        );
        failure.identity_generation = 3;
        assert!(store_provider_failure(&conn, &failure).unwrap());
        clear_provider_failure(&conn, 7, 3, EnrichmentProvider::MusicBrainz, "discography")
            .unwrap();
        assert!(
            active_provider_failure(
                &conn,
                7,
                3,
                EnrichmentProvider::MusicBrainz,
                "discography",
                &failure.resource_key,
                150,
            )
            .unwrap()
            .is_none()
        );
    }
}
