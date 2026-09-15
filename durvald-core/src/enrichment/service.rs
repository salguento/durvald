//! Explicit, bounded identity lookups; no permanent worker or audio state.

use crate::api::*;
use crate::database::enrichment;
use crate::enrichment::policy::{normalize_language, normalized_settings};
use md5::{Digest, Md5};
use std::future::Future;
use std::sync::Arc;

type LookupResult = CoreResult<ArtistIdentityCandidates>;
struct IdentityFlight {
    receiver: tokio::sync::watch::Receiver<Option<LookupResult>>,
    abort: tokio::task::AbortHandle,
}

type RefreshResult = CoreResult<ArtistRefreshResult>;
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct RefreshKey {
    artist_id: i64,
    language: String,
    sections: u8,
    force: bool,
}
struct RefreshFlight {
    receiver: tokio::sync::watch::Receiver<Option<RefreshResult>>,
    abort: tokio::task::AbortHandle,
}

fn format_partial_date(date: &ArtistPartialDate) -> String {
    match (date.month, date.day) {
        (Some(month), Some(day)) => format!("{:04}-{month:02}-{day:02}", date.year),
        (Some(month), None) => format!("{:04}-{month:02}", date.year),
        _ => format!("{:04}", date.year),
    }
}

fn release_group_metadata_snapshot(
    context: &super::models::LocalReleaseMatchContext,
    group: &super::models::ReleaseGroupSnapshot,
    identity_generation: u64,
    fetched_at: i64,
) -> super::models::MatchedReleaseMetadata {
    super::models::MatchedReleaseMetadata {
        release_id: context.release_id,
        artist_id: context.artist_id,
        identity_generation,
        release_group_mbid: group.musicbrainz_id.clone(),
        release_mbid: context.tagged_release_mbid.clone(),
        release_date: group.first_release_date.as_ref().map(format_partial_date),
        genres: group.genres.clone(),
        composers: group.composers.clone(),
        producers: group.producers.clone(),
        source_url: group.attribution.source_url.clone(),
        fetched_at,
    }
}

impl Drop for RefreshFlight {
    fn drop(&mut self) {
        self.abort.abort();
    }
}
impl Drop for IdentityFlight {
    fn drop(&mut self) {
        self.abort.abort();
    }
}

#[derive(Clone)]
pub struct EnrichmentService {
    flights: Arc<std::sync::Mutex<std::collections::HashMap<i64, std::sync::Weak<IdentityFlight>>>>,
    refresh_flights: Arc<
        std::sync::Mutex<std::collections::HashMap<RefreshKey, std::sync::Weak<RefreshFlight>>>,
    >,
    musicbrainz: Arc<
        std::sync::OnceLock<
            Result<super::providers::musicbrainz::MusicBrainz, super::transport::TransportError>,
        >,
    >,
    wikidata: Arc<
        std::sync::OnceLock<
            Result<super::providers::wikidata::Wikidata, super::transport::TransportError>,
        >,
    >,
    commons: Arc<
        std::sync::OnceLock<
            Result<super::providers::commons::Commons, super::transport::TransportError>,
        >,
    >,
    cover_art_archive: Arc<
        std::sync::OnceLock<
            Result<
                super::providers::cover_art_archive::CoverArtArchive,
                super::transport::TransportError,
            >,
        >,
    >,
    #[allow(dead_code)] // First consumed by the profile/portrait phase.
    lastfm: Arc<super::providers::lastfm::LastFm>,
    pool: Arc<r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>>,
    /// Enrichment snapshots are published in short, serialized database jobs.
    /// Network and filesystem work always happens before this gate is taken.
    write_coordinator: Arc<tokio::sync::Mutex<()>>,
    covers_dir: Arc<std::path::PathBuf>,
}

impl EnrichmentService {
    const SQLITE_WRITE_ATTEMPTS: u32 = 3;
    const SQLITE_RETRY_BASE: std::time::Duration = std::time::Duration::from_millis(25);

    pub fn new(
        pool: Arc<r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>>,
        covers_dir: String,
        lastfm: Arc<crate::lastfm::LastFmClient>,
    ) -> Self {
        Self {
            pool,
            covers_dir: Arc::new(covers_dir.into()),
            musicbrainz: Arc::new(std::sync::OnceLock::new()),
            wikidata: Arc::new(std::sync::OnceLock::new()),
            commons: Arc::new(std::sync::OnceLock::new()),
            cover_art_archive: Arc::new(std::sync::OnceLock::new()),
            lastfm: Arc::new(super::providers::lastfm::LastFm::new(lastfm)),
            flights: Arc::default(),
            refresh_flights: Arc::default(),
            write_coordinator: Arc::default(),
        }
    }

    async fn database<T, F>(&self, operation: F) -> CoreResult<T>
    where
        T: Send + 'static,
        F: FnOnce(&rusqlite::Connection) -> CoreResult<T> + Send + 'static,
    {
        let pool = self.pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = pool.get().map_err(|error| CoreError::Storage {
                message: error.to_string(),
            })?;
            operation(&conn)
        })
        .await
        .map_err(|error| CoreError::Storage {
            message: format!("Enrichment database task failed: {error}"),
        })?
    }

    /// Runs a single enrichment write while holding the service-wide
    /// publication gate. The closure must contain database work only.
    async fn write_database<T, F>(&self, operation: F) -> CoreResult<T>
    where
        T: Send + 'static,
        F: FnOnce(&rusqlite::Connection) -> CoreResult<T> + Send + 'static,
    {
        let _publication = self.write_coordinator.lock().await;
        self.database(operation).await
    }

    /// Retries an idempotent publication only when SQLite reports BUSY or
    /// LOCKED. Other storage and domain failures are returned immediately.
    async fn write_database_idempotent<T, F>(
        &self,
        operation_name: &'static str,
        operation: F,
    ) -> CoreResult<T>
    where
        T: Send + 'static,
        F: Fn(&rusqlite::Connection) -> CoreResult<T> + Send + 'static,
    {
        let _publication = self.write_coordinator.lock().await;
        let pool = self.pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = pool.get().map_err(|error| CoreError::Storage {
                message: error.to_string(),
            })?;
            let mut waited = std::time::Duration::ZERO;
            for attempt in 0..Self::SQLITE_WRITE_ATTEMPTS {
                match operation(&conn) {
                    Ok(value) => return Ok(value),
                    Err(error) => {
                        let Some(extended_code) =
                            crate::database::sqlite_busy_extended_code(&error)
                        else {
                            return Err(error);
                        };
                        if attempt + 1 == Self::SQLITE_WRITE_ATTEMPTS {
                            eprintln!(
                                "enrichment_sqlite_retry operation={operation_name} extended_code={extended_code} wait_ms={} exhausted=true",
                                waited.as_millis()
                            );
                            return Err(error);
                        }
                        let jitter_ms = u64::from(
                            std::time::SystemTime::now()
                                .duration_since(std::time::UNIX_EPOCH)
                                .unwrap_or_default()
                                .subsec_nanos()
                                % 26,
                        );
                        let delay = Self::SQLITE_RETRY_BASE * (1 << attempt)
                            + std::time::Duration::from_millis(jitter_ms);
                        waited += delay;
                        eprintln!(
                            "enrichment_sqlite_retry operation={operation_name} extended_code={extended_code} wait_ms={} exhausted=false",
                            waited.as_millis()
                        );
                        std::thread::sleep(delay);
                    }
                }
            }
            unreachable!()
        })
        .await
        .map_err(|error| CoreError::Storage {
            message: format!("Enrichment database task failed: {error}"),
        })?
    }

    #[allow(clippy::too_many_arguments)]
    async fn provider_request<T, F>(
        &self,
        artist_id: i64,
        identity_generation: u64,
        provider: EnrichmentProvider,
        operation: &'static str,
        resource_key: String,
        force: bool,
        request: F,
    ) -> Result<T, super::transport::TransportError>
    where
        F: Future<Output = Result<T, super::transport::TransportError>>,
    {
        use super::models::ProviderFailureSnapshot;
        let now = chrono::Utc::now().timestamp();
        if !force {
            let lookup_key = resource_key.clone();
            if let Some(failure) = self
                .database(move |conn| {
                    enrichment::active_provider_failure(
                        conn,
                        artist_id,
                        identity_generation,
                        provider,
                        operation,
                        &lookup_key,
                        now,
                    )
                })
                .await
                .map_err(storage_transport)?
            {
                return Err(cached_transport_error(&failure));
            }
        }

        match request.await {
            Ok(value) => {
                self.write_database_idempotent("provider_failure.clear", move |conn| {
                    enrichment::clear_provider_failure(
                        conn,
                        artist_id,
                        identity_generation,
                        provider,
                        operation,
                    )
                })
                .await
                .map_err(storage_transport)?;
                Ok(value)
            }
            Err(error) => {
                if let Some(ttl) = permanent_failure_ttl(&error) {
                    let snapshot = ProviderFailureSnapshot {
                        artist_id,
                        identity_generation,
                        provider,
                        operation: operation.into(),
                        resource_key,
                        error_code: provider_error_code(&error),
                        retry_after_seconds: error.retry_after_seconds(),
                        recorded_at: now,
                        expires_at: now.saturating_add(ttl.as_secs() as i64),
                    };
                    self.write_database_idempotent("provider_failure.store", move |conn| {
                        enrichment::store_provider_failure(conn, &snapshot)
                    })
                    .await
                    .map_err(storage_transport)?;
                }
                Err(error)
            }
        }
    }

    pub async fn artist_identity(&self, artist_id: i64) -> CoreResult<ArtistIdentity> {
        // Identity resolution currently repairs its materialized state, so it
        // participates in the same publication queue as snapshot writes.
        self.write_database_idempotent("identity.read", move |conn| {
            crate::database::identity::read(conn, artist_id)
        })
        .await
    }

    pub async fn confirm_artist_identity(
        &self,
        artist_id: i64,
        mbid: Option<String>,
    ) -> CoreResult<ArtistIdentity> {
        self.write_database(move |conn| crate::database::identity::confirm(conn, artist_id, mbid))
            .await
    }

    /// Subscribers share a bounded task. The last subscriber dropping aborts it.
    pub async fn resolve_artist_candidates(&self, artist_id: i64) -> LookupResult {
        let flight = {
            let mut flights = self.flights.lock().map_err(|_| CoreError::Storage {
                message: "Identity coordinator unavailable".into(),
            })?;
            flights.retain(|_, flight| flight.strong_count() > 0);
            if let Some(flight) = flights.get(&artist_id).and_then(std::sync::Weak::upgrade) {
                flight
            } else {
                let (sender, receiver) = tokio::sync::watch::channel(None);
                let service = self.clone();
                let task = tokio::spawn(async move {
                    let result = service.resolve_identity_once(artist_id).await;
                    let _ = sender.send(Some(result));
                });
                let flight = Arc::new(IdentityFlight {
                    receiver,
                    abort: task.abort_handle(),
                });
                flights.insert(artist_id, Arc::downgrade(&flight));
                flight
            }
        };
        let mut receiver = flight.receiver.clone();
        loop {
            if let Some(result) = receiver.borrow_and_update().clone() {
                return result;
            }
            receiver.changed().await.map_err(|_| CoreError::Network {
                message: "Identity lookup interrupted".into(),
            })?;
        }
    }

    async fn resolve_identity_once(&self, artist_id: i64) -> CoreResult<ArtistIdentityCandidates> {
        use super::transport::TransportError;
        use crate::database::identity;
        let mut result = self
            .write_database_idempotent("identity.candidates", move |conn| {
                identity::candidates(conn, artist_id)
            })
            .await?;
        let settings = self.settings().await?;
        if !settings.enabled || settings.offline {
            result.lookup_status = if settings.offline {
                ArtistIdentityLookupStatus::Offline
            } else {
                ArtistIdentityLookupStatus::Disabled
            };
            return Ok(result);
        }
        if result.identity.status == ArtistIdentityStatus::Resolved
            || result.identity.conflicting_tags
        {
            return Ok(result);
        }
        let generation = result.identity.generation;
        let (name, releases) = self
            .database(move |conn| identity::local_context(conn, artist_id))
            .await?;
        let provider = self
            .musicbrainz
            .get_or_init(super::providers::musicbrainz::MusicBrainz::new)
            .as_ref()
            .map_err(|e| CoreError::Network {
                message: e.to_string(),
            })?;
        let response = tokio::time::timeout(
            std::time::Duration::from_secs(30),
            provider.search(&name, &releases),
        )
        .await
        .unwrap_or(Err(TransportError::Timeout));
        match response {
            Ok((candidates, truncated)) => {
                let stored = self
                    .write_database_idempotent("identity.store_candidates", move |conn| {
                        identity::store_candidates(
                            conn,
                            artist_id,
                            generation,
                            &candidates,
                            truncated,
                        )
                    })
                    .await?;
                result = self
                    .write_database_idempotent("identity.candidates", move |conn| {
                        identity::candidates(conn, artist_id)
                    })
                    .await?;
                if !stored {
                    result.lookup_status = ArtistIdentityLookupStatus::Superseded;
                }
            }
            Err(error) => {
                result = self
                    .write_database_idempotent("identity.candidates", move |conn| {
                        identity::candidates(conn, artist_id)
                    })
                    .await?;
                result.lookup_status = ArtistIdentityLookupStatus::Unavailable;
                match error {
                    TransportError::RateLimited {
                        retry_after_seconds,
                    } => {
                        result.lookup_status = ArtistIdentityLookupStatus::RateLimited;
                        result.retry_after_seconds = Some(retry_after_seconds);
                    }
                    TransportError::HttpStatus {
                        retry_after_seconds,
                        ..
                    } => result.retry_after_seconds = retry_after_seconds,
                    _ => {}
                }
            }
        }
        Ok(result)
    }

    pub async fn settings(&self) -> CoreResult<EnrichmentSettings> {
        self.database(enrichment::read_settings).await
    }

    pub async fn configure(&self, settings: EnrichmentSettings) -> CoreResult<()> {
        let settings = normalized_settings(settings)?;
        self.write_database_idempotent("settings.write", move |conn| {
            enrichment::write_settings(conn, settings.clone())
        })
        .await
    }

    pub async fn artist_details(
        &self,
        artist_id: i64,
        language: String,
    ) -> CoreResult<ArtistDetails> {
        if artist_id < 0 {
            return Err(CoreError::InvalidInput {
                message: "Artist ID must be non-negative".into(),
            });
        }
        let language = normalize_language(&language)?;
        self.database(move |conn| {
            enrichment::read_artist_details(
                conn,
                artist_id,
                &language,
                chrono::Utc::now().timestamp(),
            )
        })
        .await
    }

    pub async fn artist_discography(
        &self,
        artist_id: i64,
        page_size: u64,
        offset: u64,
    ) -> CoreResult<ArtistDiscographyPage> {
        self.database(move |conn| {
            enrichment::read_discography(
                conn,
                artist_id,
                page_size,
                offset,
                chrono::Utc::now().timestamp(),
            )
        })
        .await
    }

    pub async fn external_release_details(
        &self,
        artist_id: i64,
        release_group_mbid: String,
    ) -> CoreResult<ExternalReleaseDetails> {
        use super::models::{CacheValidators, ExternalReleaseDetailsSnapshot, ProviderResponse};
        use super::policy::EXTERNAL_RELEASE_DETAILS_TTL;
        use crate::enrichment::identity::normalize_mbid;

        if artist_id < 0 {
            return Err(CoreError::InvalidInput {
                message: "Artist ID must be non-negative".into(),
            });
        }
        let release_group_mbid =
            normalize_mbid(&release_group_mbid).ok_or_else(|| CoreError::InvalidInput {
                message: "Invalid MusicBrainz release-group ID".into(),
            })?;
        let group = self
            .database({
                let release_group_mbid = release_group_mbid.clone();
                move |conn| enrichment::release_group_snapshot(conn, artist_id, &release_group_mbid)
            })
            .await?
            .ok_or_else(|| CoreError::NotFound {
                message: "Online release is not part of the current artist catalog".into(),
            })?;
        let identity = self.artist_identity(artist_id).await?;
        let cached = self
            .database({
                let release_group_mbid = release_group_mbid.clone();
                move |conn| {
                    enrichment::external_release_details(conn, artist_id, &release_group_mbid)
                }
            })
            .await?;
        let now = chrono::Utc::now().timestamp();
        if let Some(cached) = cached.as_ref().filter(|cached| now < cached.expires_at) {
            return Ok(cached.details.clone());
        }
        let settings = self.settings().await?;
        if !settings.enabled {
            if let Some(cached) = cached {
                return Ok(cached.details);
            }
            return Err(CoreError::Network {
                message: "Online metadata is disabled".into(),
            });
        }
        if settings.offline {
            if let Some(cached) = cached {
                return Ok(cached.details);
            }
            return Err(CoreError::Network {
                message: "Online metadata is in offline mode".into(),
            });
        }
        let musicbrainz = self
            .musicbrainz
            .get_or_init(super::providers::musicbrainz::MusicBrainz::new)
            .as_ref()
            .map_err(|error| CoreError::Network {
                message: error.to_string(),
            })?;
        let validators = cached
            .as_ref()
            .map(|cached| cached.validators.clone())
            .unwrap_or_else(CacheValidators::default);
        let resource_key = provider_resource_key(&[&release_group_mbid]);
        let response = self
            .provider_request(
                artist_id,
                identity.generation,
                EnrichmentProvider::MusicBrainz,
                "external_release_details",
                resource_key,
                false,
                musicbrainz.external_release_details(&group, &validators),
            )
            .await;
        let (details, validators) = match response {
            Ok(ProviderResponse::Modified { value, validators }) => (value, validators),
            Ok(ProviderResponse::NotModified { validators }) => {
                let Some(cached) = cached.as_ref() else {
                    return Err(CoreError::Network {
                        message: "MusicBrainz returned an invalid cache response".into(),
                    });
                };
                (cached.details.clone(), validators)
            }
            Err(error) => {
                if let Some(cached) = cached {
                    return Ok(cached.details);
                }
                return Err(CoreError::Network {
                    message: error.to_string(),
                });
            }
        };
        let snapshot = ExternalReleaseDetailsSnapshot {
            artist_id,
            identity_generation: identity.generation,
            details: details.clone(),
            fetched_at: now,
            expires_at: now.saturating_add(EXTERNAL_RELEASE_DETAILS_TTL.as_secs() as i64),
            validators,
        };
        let stored = self
            .write_database_idempotent("external_release_details.store", move |conn| {
                enrichment::store_external_release_details(conn, &snapshot)
            })
            .await?;
        if !stored {
            return Err(CoreError::NotFound {
                message: "Artist identity changed while loading online release".into(),
            });
        }
        Ok(details)
    }

    /// Applies unambiguous release-group metadata already present in the local
    /// MusicBrainz catalog. This operation is network-free and remains useful
    /// while enrichment is offline.
    pub async fn sync_local_release_metadata(&self, artist_id: i64) -> CoreResult<()> {
        if artist_id < 0 {
            return Err(CoreError::InvalidInput {
                message: "Artist ID must be non-negative".into(),
            });
        }
        let identity = self.artist_identity(artist_id).await?;
        if identity.status != ArtistIdentityStatus::Resolved || identity.conflicting_tags {
            return Ok(());
        }
        let identity_generation = identity.generation;
        let contexts = self
            .database(move |conn| {
                enrichment::local_release_match_contexts(conn, artist_id, identity_generation, true)
            })
            .await?;
        let now = chrono::Utc::now().timestamp();
        for context in contexts {
            let [group] = context.candidate_release_groups.as_slice() else {
                continue;
            };
            let snapshot =
                release_group_metadata_snapshot(&context, group, identity_generation, now);
            self.write_database_idempotent("release_metadata.store_cached_group", move |conn| {
                enrichment::store_matched_release_metadata(conn, &snapshot)
            })
            .await?;
        }
        Ok(())
    }

    pub async fn set_artist_override(
        &self,
        artist_id: i64,
        value: ArtistFieldOverride,
    ) -> CoreResult<()> {
        self.write_database_idempotent("override.set", move |conn| {
            enrichment::set_override(conn, artist_id, value.clone())
        })
        .await
    }

    pub async fn clear_artist_override(
        &self,
        artist_id: i64,
        field: ArtistProfileField,
        language: String,
    ) -> CoreResult<()> {
        self.write_database_idempotent("override.clear", move |conn| {
            enrichment::clear_override(conn, artist_id, field, &language)
        })
        .await
    }

    pub async fn refresh_artist(
        &self,
        artist_id: i64,
        mut request: ArtistRefreshRequest,
    ) -> CoreResult<ArtistRefreshResult> {
        if artist_id < 0 {
            return Err(CoreError::InvalidInput {
                message: "Artist ID must be non-negative".into(),
            });
        }
        let language = normalize_language(&request.language)?;
        if request.sections.is_empty() {
            return Err(CoreError::InvalidInput {
                message: "At least one refresh section is required".into(),
            });
        }
        request.language = language.clone();
        let sections = u8::from(request.sections.contains(&ArtistRefreshSection::Profile))
            | (u8::from(request.sections.contains(&ArtistRefreshSection::Portrait)) << 1)
            | (u8::from(
                request
                    .sections
                    .contains(&ArtistRefreshSection::Discography),
            ) << 2)
            | (u8::from(request.sections.contains(&ArtistRefreshSection::Covers)) << 3);
        request.sections = [
            ArtistRefreshSection::Profile,
            ArtistRefreshSection::Portrait,
            ArtistRefreshSection::Discography,
            ArtistRefreshSection::Covers,
        ]
        .into_iter()
        .filter(|section| request.sections.contains(section))
        .collect();
        let key = RefreshKey {
            artist_id,
            language,
            sections,
            force: request.force,
        };
        let flight = {
            let mut flights = self
                .refresh_flights
                .lock()
                .map_err(|_| CoreError::Storage {
                    message: "Profile refresh coordinator unavailable".into(),
                })?;
            flights.retain(|_, flight| flight.strong_count() > 0);
            if let Some(flight) = flights.get(&key).and_then(std::sync::Weak::upgrade) {
                flight
            } else {
                let (sender, receiver) = tokio::sync::watch::channel(None);
                let service = self.clone();
                let task = tokio::spawn(async move {
                    let result = service.refresh_artist_once(artist_id, request).await;
                    let _ = sender.send(Some(result));
                });
                let flight = Arc::new(RefreshFlight {
                    receiver,
                    abort: task.abort_handle(),
                });
                flights.insert(key, Arc::downgrade(&flight));
                flight
            }
        };
        let mut receiver = flight.receiver.clone();
        loop {
            if let Some(result) = receiver.borrow_and_update().clone() {
                return result;
            }
            receiver.changed().await.map_err(|_| CoreError::Network {
                message: "Profile refresh interrupted".into(),
            })?;
        }
    }

    async fn refresh_artist_once(
        &self,
        artist_id: i64,
        request: ArtistRefreshRequest,
    ) -> CoreResult<ArtistRefreshResult> {
        let language = request.language.clone();
        let identity = self.artist_identity(artist_id).await?;
        self.cleanup_stale_assets().await?;
        let settings = self.settings().await?;
        let common = if !settings.enabled {
            Some(ArtistRefreshStatus::Disabled)
        } else if settings.offline {
            Some(ArtistRefreshStatus::Offline)
        } else if identity.status != ArtistIdentityStatus::Resolved || identity.conflicting_tags {
            Some(ArtistRefreshStatus::NeedsIdentity)
        } else {
            None
        };
        if let Some(status) = common {
            return Ok(refresh_result(
                artist_id,
                identity.generation,
                request.sections,
                status,
                None,
            ));
        }
        let cached = self.artist_details(artist_id, language.clone()).await?;
        if !request.force
            && request.sections == [ArtistRefreshSection::Profile]
            && cached
                .sources
                .iter()
                .any(|source| source.provider == EnrichmentProvider::Wikidata && !source.stale)
        {
            return Ok(refresh_result(
                artist_id,
                identity.generation,
                request.sections,
                ArtistRefreshStatus::Unchanged,
                None,
            ));
        }
        let requested_profile = request.sections.contains(&ArtistRefreshSection::Profile);
        let requested_portrait = request.sections.contains(&ArtistRefreshSection::Portrait);
        let requested_discography = request
            .sections
            .contains(&ArtistRefreshSection::Discography);
        let requested_covers = request.sections.contains(&ArtistRefreshSection::Covers);
        let mut results = Vec::new();
        if requested_profile || requested_portrait {
            let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(30);
            let profile_result = tokio::time::timeout_at(
                deadline,
                self.refresh_profile_once(&identity, &language, request.force),
            )
            .await
            .unwrap_or(Err(super::transport::TransportError::Timeout));
            match profile_result {
                Ok(outcome) => {
                    if requested_profile {
                        results.push(refresh_section_result(
                            ArtistRefreshSection::Profile,
                            outcome.profile_status,
                            None,
                            None,
                            None,
                        ));
                    }
                    if requested_portrait {
                        let (status, retry_after_seconds, diagnostic) = match outcome.commons_file {
                            Some(filename) => {
                                let portrait = tokio::time::timeout_at(
                                    deadline,
                                    self.refresh_portrait_once(
                                        identity.artist_id,
                                        identity.generation,
                                        &filename,
                                        request.force,
                                    ),
                                )
                                .await
                                .unwrap_or(Err(super::transport::TransportError::Timeout));
                                match portrait {
                                    Ok(status) => (status, None, None),
                                    Err(error) => refresh_transport_error(&error),
                                }
                            }
                            None => (ArtistRefreshStatus::NotFound, None, None),
                        };
                        results.push(refresh_section_result(
                            ArtistRefreshSection::Portrait,
                            status,
                            retry_after_seconds,
                            None,
                            diagnostic,
                        ));
                    }
                }
                Err(error) => {
                    let (status, retry, diagnostic) = refresh_transport_error(&error);
                    for section in [
                        ArtistRefreshSection::Profile,
                        ArtistRefreshSection::Portrait,
                    ] {
                        if request.sections.contains(&section) {
                            results.push(refresh_section_result(
                                section, status, retry, None, diagnostic,
                            ));
                        }
                    }
                }
            }
        }
        if requested_discography {
            let (status, retry_after_seconds, diagnostic) = match self
                .refresh_discography_once(&identity, request.force)
                .await
            {
                Ok(status) => (status, None, None),
                Err(error) => refresh_transport_error(&error),
            };
            results.push(refresh_section_result(
                ArtistRefreshSection::Discography,
                status,
                retry_after_seconds,
                None,
                diagnostic,
            ));
        }
        if requested_covers {
            let (status, retry_after_seconds, cover_progress, diagnostic) =
                match self.refresh_covers_once(&identity, request.force).await {
                    Ok(outcome) => (outcome.status, None, Some(outcome.progress), None),
                    Err(error) => {
                        let (status, retry, diagnostic) = refresh_transport_error(&error);
                        let progress = self
                            .database({
                                let generation = identity.generation;
                                move |conn| {
                                    enrichment::external_artwork_queue_progress(
                                        conn, artist_id, generation,
                                    )
                                }
                            })
                            .await
                            .ok();
                        (status, retry, progress, diagnostic)
                    }
                };
            results.push(refresh_section_result(
                ArtistRefreshSection::Covers,
                status,
                retry_after_seconds,
                cover_progress,
                diagnostic,
            ));
        }
        Ok(ArtistRefreshResult {
            artist_id,
            identity_generation: identity.generation,
            sections: results,
        })
    }

    /// Writes only to a hidden generation while pagination is incomplete. The
    /// final provider page and generation swap commit in the same transaction.
    async fn refresh_discography_once(
        &self,
        identity: &ArtistIdentity,
        force: bool,
    ) -> Result<ArtistRefreshStatus, super::transport::TransportError> {
        use super::models::{CacheValidators, DiscographyPageSnapshot, ProviderResponse};
        use super::policy::DISCOGRAPHY_TTL;
        use super::transport::TransportError;

        let artist_id = identity.artist_id;
        let identity_generation = identity.generation;
        let mbid = identity
            .musicbrainz_id
            .as_deref()
            .ok_or(TransportError::InvalidRequest)?;
        let now = chrono::Utc::now().timestamp();
        let state = self
            .database(move |conn| {
                enrichment::discography_refresh_state(conn, artist_id, identity_generation)
            })
            .await
            .map_err(storage_transport)?
            .ok_or(TransportError::InvalidRequest)?;
        if state.building.is_none()
            && !force
            && state.active_generation > 0
            && state
                .active_expires_at
                .is_some_and(|expires_at| now < expires_at)
        {
            self.refresh_local_release_metadata(identity, false).await?;
            return Ok(ArtistRefreshStatus::Unchanged);
        }
        let start_offset = state.building.as_ref().map_or(0, |build| build.next_offset);
        let request_validators = if start_offset == 0 {
            state.active_validators.clone()
        } else {
            CacheValidators::default()
        };
        let musicbrainz = self
            .musicbrainz
            .get_or_init(super::providers::musicbrainz::MusicBrainz::new)
            .as_ref()
            .map_err(|_| TransportError::Configuration)?;
        let resource_key = provider_resource_key(&[mbid]);
        let response = self
            .provider_request(
                artist_id,
                identity_generation,
                EnrichmentProvider::MusicBrainz,
                "discography",
                resource_key,
                force,
                musicbrainz.discography(mbid, start_offset, &request_validators),
            )
            .await?;
        let (value, validators) = match response {
            ProviderResponse::NotModified { validators } => {
                if state.active_generation == 0 || start_offset != 0 {
                    return Err(TransportError::InvalidJson);
                }
                let expires_at = now.saturating_add(DISCOGRAPHY_TTL.as_secs() as i64);
                let stored = self
                    .write_database_idempotent("discography.revalidate", move |conn| {
                        enrichment::revalidate_discography(
                            conn,
                            artist_id,
                            identity_generation,
                            state.active_generation,
                            now,
                            expires_at,
                            &validators,
                        )
                    })
                    .await
                    .map_err(storage_transport)?;
                if stored {
                    self.refresh_local_release_metadata(identity, force).await?;
                }
                return Ok(if stored {
                    ArtistRefreshStatus::Unchanged
                } else {
                    ArtistRefreshStatus::Superseded
                });
            }
            ProviderResponse::Modified { value, validators } => (value, validators),
        };
        let catalog_generation = self
            .write_database_idempotent("discography.begin_snapshot", move |conn| {
                enrichment::begin_discography_snapshot(conn, artist_id, identity_generation)
            })
            .await
            .map_err(storage_transport)?;
        let Some(catalog_generation) = catalog_generation else {
            return Ok(ArtistRefreshStatus::Superseded);
        };
        let build = self
            .database(move |conn| {
                enrichment::discography_build_state(conn, artist_id, identity_generation)
            })
            .await
            .map_err(storage_transport)?
            .filter(|build| {
                build.catalog_generation == catalog_generation && build.next_offset == start_offset
            });
        let Some(build) = build else {
            return Ok(ArtistRefreshStatus::Superseded);
        };
        let snapshot_validators = if start_offset == 0 {
            validators
        } else {
            build.validators
        };
        let expires_at = now.saturating_add(DISCOGRAPHY_TTL.as_secs() as i64);
        let remote_exhausted = value.remote_exhausted;
        let mut stored_any = false;
        for page in value.pages {
            let snapshot = DiscographyPageSnapshot {
                artist_id,
                identity_generation,
                catalog_generation,
                provider_offset: page.provider_offset,
                groups: page.groups,
                remote_total: page.remote_total,
                remote_next_offset: page.remote_next_offset,
                remote_exhausted: page.remote_exhausted,
                fetched_at: now,
                expires_at,
                validators: snapshot_validators.clone(),
            };
            let store_result = self
                .write_database_idempotent("discography.store_page", move |conn| {
                    enrichment::store_discography_page(conn, &snapshot)
                })
                .await;
            let stored = match store_result {
                Ok(stored) => stored,
                Err(CoreError::InvalidInput { .. }) => {
                    self.write_database_idempotent("discography.discard_snapshot", move |conn| {
                        enrichment::discard_discography_snapshot(
                            conn,
                            artist_id,
                            identity_generation,
                            catalog_generation,
                        )
                    })
                    .await
                    .map_err(storage_transport)?;
                    return Err(TransportError::InvalidJson);
                }
                Err(_) => return Err(TransportError::Network),
            };
            if !stored {
                return Ok(ArtistRefreshStatus::Superseded);
            }
            stored_any = true;
        }
        if remote_exhausted {
            self.refresh_local_release_metadata(identity, force).await?;
        }
        Ok(if !remote_exhausted {
            ArtistRefreshStatus::Partial
        } else if stored_any {
            ArtistRefreshStatus::Updated
        } else {
            ArtistRefreshStatus::Unchanged
        })
    }

    async fn refresh_local_release_metadata(
        &self,
        identity: &ArtistIdentity,
        force: bool,
    ) -> Result<(), super::transport::TransportError> {
        use super::transport::TransportError;
        const MAX_LOCAL_RELEASES_PER_REFRESH: usize = 10;

        let artist_id = identity.artist_id;
        let identity_generation = identity.generation;
        if force {
            self.write_database_idempotent("release_metadata.reset_attempts", move |conn| {
                enrichment::reset_local_release_metadata_attempts(conn, artist_id)
            })
            .await
            .map_err(storage_transport)?;
        }
        let contexts = self
            .database(move |conn| {
                enrichment::local_release_match_contexts(
                    conn,
                    artist_id,
                    identity_generation,
                    false,
                )
            })
            .await
            .map_err(storage_transport)?;
        let musicbrainz = self
            .musicbrainz
            .get_or_init(super::providers::musicbrainz::MusicBrainz::new)
            .as_ref()
            .map_err(|_| TransportError::Configuration)?;
        let now = chrono::Utc::now().timestamp();
        for context in contexts.into_iter().take(MAX_LOCAL_RELEASES_PER_REFRESH) {
            if let [group] = context.candidate_release_groups.as_slice() {
                let snapshot =
                    release_group_metadata_snapshot(&context, group, identity_generation, now);
                self.write_database_idempotent("release_metadata.store_group", move |conn| {
                    enrichment::store_matched_release_metadata(conn, &snapshot)
                })
                .await
                .map_err(storage_transport)?;
            }
            let mut matches = Vec::new();
            let mut request_failed = false;
            for group in &context.candidate_release_groups {
                match musicbrainz
                    .match_local_release(&context, &group.musicbrainz_id, identity_generation, now)
                    .await
                {
                    Ok(Some(metadata)) => matches.push(metadata),
                    Ok(None) => {}
                    Err(
                        TransportError::RateLimited { .. }
                        | TransportError::HttpStatus { status: 503, .. }
                        | TransportError::Timeout
                        | TransportError::Network,
                    ) => {
                        request_failed = true;
                        break;
                    }
                    Err(_) => {}
                }
            }
            if request_failed {
                break;
            }
            if matches.len() == 1 {
                let snapshot = matches.pop().unwrap();
                self.write_database_idempotent("release_metadata.store", move |conn| {
                    enrichment::store_matched_release_metadata(conn, &snapshot)
                })
                .await
                .map_err(storage_transport)?;
            }
            let release_id = context.release_id;
            self.write_database_idempotent("release_metadata.mark_attempt", move |conn| {
                enrichment::mark_local_release_metadata_attempted(
                    conn,
                    release_id,
                    artist_id,
                    identity_generation,
                    now,
                )
            })
            .await
            .map_err(storage_transport)?;
        }
        Ok(())
    }

    /// Refreshes a bounded set of missing or expired covers from the active
    /// catalog. A hidden discography generation is never exposed to this pass.
    async fn refresh_covers_once(
        &self,
        identity: &ArtistIdentity,
        force: bool,
    ) -> Result<CoverRefreshOutcome, super::transport::TransportError> {
        use super::models::{ExternalArtworkNegativeResult, ExternalArtworkSnapshot};
        use super::policy::{DISCOGRAPHY_TTL, OPERATION_TIMEOUT};
        use super::transport::TransportError;

        let artist_id = identity.artist_id;
        let identity_generation = identity.generation;
        let now = chrono::Utc::now().timestamp();
        let plan = self
            .write_database_idempotent("artwork.dequeue_batch", move |conn| {
                enrichment::dequeue_external_artwork_batch(
                    conn,
                    artist_id,
                    identity_generation,
                    now,
                    force,
                )
            })
            .await
            .map_err(storage_transport)?;
        if plan.targets.is_empty() {
            let status = if plan.catalog_pending || plan.progress.pending > 0 {
                ArtistRefreshStatus::Partial
            } else {
                ArtistRefreshStatus::Unchanged
            };
            return Ok(CoverRefreshOutcome {
                status,
                progress: plan.progress,
            });
        }
        let has_more = plan.catalog_pending || plan.queue_has_more;
        let cover_art_archive = self
            .cover_art_archive
            .get_or_init(super::providers::cover_art_archive::CoverArtArchive::new)
            .as_ref()
            .map_err(|_| TransportError::Configuration)?;
        let deadline = tokio::time::Instant::now() + OPERATION_TIMEOUT;
        let mut updated = false;
        let mut found = false;
        let mut recorded_not_found = false;
        let mut recorded_invalid_image = false;
        let mut recorded_temporary_failure = false;
        for target in plan.targets {
            let candidate = match tokio::time::timeout_at(
                deadline,
                cover_art_archive.artwork(
                    target.exact_release_mbid.as_deref(),
                    &target.release_group_mbid,
                ),
            )
            .await
            {
                Ok(Ok(candidate)) => candidate,
                Ok(Err(error)) => {
                    if cover_cacheable_failure(&error) {
                        let transient = error.is_transient();
                        let retry_after = error.retry_after_seconds();
                        let stored = self
                            .record_external_artwork_negative_result(
                                identity,
                                &target,
                                ExternalArtworkNegativeResult::TemporaryFailure,
                                cover_error_code(&error),
                                retry_after,
                                transient,
                                now,
                            )
                            .await?;
                        if !stored {
                            return self
                                .cover_refresh_outcome(identity, ArtistRefreshStatus::Superseded)
                                .await;
                        }
                        recorded_temporary_failure = true;
                        continue;
                    }
                    return Err(error);
                }
                Err(_) => {
                    let stored = self
                        .record_external_artwork_negative_result(
                            identity,
                            &target,
                            ExternalArtworkNegativeResult::TemporaryFailure,
                            "timeout".into(),
                            None,
                            true,
                            now,
                        )
                        .await?;
                    if !stored {
                        return self
                            .cover_refresh_outcome(identity, ArtistRefreshStatus::Superseded)
                            .await;
                    }
                    recorded_temporary_failure = true;
                    break;
                }
            };
            let Some(candidate) = candidate else {
                let stored = self
                    .record_external_artwork_negative_result(
                        identity,
                        &target,
                        ExternalArtworkNegativeResult::NotFound,
                        "http_404".into(),
                        None,
                        false,
                        now,
                    )
                    .await?;
                if !stored {
                    return self
                        .cover_refresh_outcome(identity, ArtistRefreshStatus::Superseded)
                        .await;
                }
                recorded_not_found = true;
                continue;
            };
            found = true;
            let downloaded = match tokio::time::timeout_at(
                deadline,
                cover_art_archive.download(candidate),
            )
            .await
            {
                Ok(Ok(downloaded)) => downloaded,
                Ok(Err(error @ (TransportError::InvalidImage | TransportError::BodyTooLarge))) => {
                    let stored = self
                        .record_external_artwork_negative_result(
                            identity,
                            &target,
                            ExternalArtworkNegativeResult::InvalidImage,
                            cover_error_code(&error),
                            None,
                            false,
                            now,
                        )
                        .await?;
                    if !stored {
                        return self
                            .cover_refresh_outcome(identity, ArtistRefreshStatus::Superseded)
                            .await;
                    }
                    recorded_invalid_image = true;
                    continue;
                }
                Ok(Err(error)) => {
                    if cover_cacheable_failure(&error) {
                        let transient = error.is_transient();
                        let retry_after = error.retry_after_seconds();
                        let stored = self
                            .record_external_artwork_negative_result(
                                identity,
                                &target,
                                ExternalArtworkNegativeResult::TemporaryFailure,
                                cover_error_code(&error),
                                retry_after,
                                transient,
                                now,
                            )
                            .await?;
                        if !stored {
                            return self
                                .cover_refresh_outcome(identity, ArtistRefreshStatus::Superseded)
                                .await;
                        }
                        recorded_temporary_failure = true;
                        continue;
                    }
                    return Err(error);
                }
                Err(_) => {
                    let stored = self
                        .record_external_artwork_negative_result(
                            identity,
                            &target,
                            ExternalArtworkNegativeResult::TemporaryFailure,
                            "timeout".into(),
                            None,
                            true,
                            now,
                        )
                        .await?;
                    if !stored {
                        return self
                            .cover_refresh_outcome(identity, ArtistRefreshStatus::Superseded)
                            .await;
                    }
                    recorded_temporary_failure = true;
                    break;
                }
            };
            let covers_dir = self.covers_dir.clone();
            let bytes = downloaded.bytes;
            let managed_path = tokio::task::spawn_blocking(move || {
                crate::artwork::write_managed(&covers_dir, &bytes)
            })
            .await
            .map_err(|_| TransportError::Network)?
            .map_err(|_| TransportError::Network)?;
            let snapshot = ExternalArtworkSnapshot {
                artist_id,
                identity_generation,
                release_group_mbid: downloaded.candidate.release_group_mbid,
                exact_release_mbid: downloaded.candidate.exact_release_mbid,
                scope: downloaded.candidate.scope,
                provider_id: downloaded.candidate.provider_id,
                source_url: downloaded.candidate.source_url,
                managed_path: managed_path.to_string_lossy().into_owned(),
                width: downloaded.width,
                height: downloaded.height,
                attribution: downloaded.candidate.attribution,
                fetched_at: now,
                expires_at: now.saturating_add(DISCOGRAPHY_TTL.as_secs() as i64),
            };
            let outcome = self
                .write_database_idempotent("artwork.store", move |conn| {
                    enrichment::store_external_artwork(conn, &snapshot)
                })
                .await
                .map_err(storage_transport)?;
            if !outcome.stored {
                self.remove_unreferenced_managed_path(managed_path).await?;
                return self
                    .cover_refresh_outcome(identity, ArtistRefreshStatus::Superseded)
                    .await;
            }
            let catalog_key = target.catalog_key.clone();
            let catalog_generation = target.catalog_generation;
            let completed = self
                .write_database_idempotent("artwork.complete_queue_target", move |conn| {
                    enrichment::complete_external_artwork_queue_target(
                        conn,
                        artist_id,
                        identity_generation,
                        catalog_generation,
                        &catalog_key,
                        now,
                    )
                })
                .await
                .map_err(storage_transport)?;
            if !completed {
                return self
                    .cover_refresh_outcome(identity, ArtistRefreshStatus::Superseded)
                    .await;
            }
            updated = true;
            if let Some(path) = outcome.orphaned_path {
                self.remove_unreferenced_managed_path(path.into()).await?;
            }
        }
        let status = if has_more || recorded_temporary_failure {
            ArtistRefreshStatus::Partial
        } else if updated {
            ArtistRefreshStatus::Updated
        } else if recorded_invalid_image {
            ArtistRefreshStatus::Partial
        } else if recorded_not_found {
            ArtistRefreshStatus::NotFound
        } else if found {
            ArtistRefreshStatus::Unchanged
        } else {
            ArtistRefreshStatus::NotFound
        };
        self.cover_refresh_outcome(identity, status).await
    }

    async fn cover_refresh_outcome(
        &self,
        identity: &ArtistIdentity,
        status: ArtistRefreshStatus,
    ) -> Result<CoverRefreshOutcome, super::transport::TransportError> {
        let artist_id = identity.artist_id;
        let identity_generation = identity.generation;
        let progress = self
            .database(move |conn| {
                enrichment::external_artwork_queue_progress(conn, artist_id, identity_generation)
            })
            .await
            .map_err(storage_transport)?;
        Ok(CoverRefreshOutcome { status, progress })
    }

    #[allow(clippy::too_many_arguments)]
    async fn record_external_artwork_negative_result(
        &self,
        identity: &ArtistIdentity,
        target: &super::models::ExternalArtworkRefreshTarget,
        result: super::models::ExternalArtworkNegativeResult,
        last_error: String,
        retry_after_seconds: Option<u64>,
        transient: bool,
        now: i64,
    ) -> Result<bool, super::transport::TransportError> {
        use super::models::ExternalArtworkNegativeSnapshot;
        use super::policy::{
            COVER_INVALID_IMAGE_TTL, COVER_NOT_FOUND_TTL, COVER_TRANSIENT_FAILURE_TTL,
        };
        let ttl = match result {
            super::models::ExternalArtworkNegativeResult::NotFound => COVER_NOT_FOUND_TTL,
            super::models::ExternalArtworkNegativeResult::InvalidImage => COVER_INVALID_IMAGE_TTL,
            super::models::ExternalArtworkNegativeResult::TemporaryFailure if transient => {
                let exponent = target.attempt_count.saturating_sub(1).min(5);
                let jitter = std::time::Duration::from_secs(u64::from(
                    std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .unwrap_or_default()
                        .subsec_nanos()
                        % 61,
                ));
                let calculated = (COVER_TRANSIENT_FAILURE_TTL * (1 << exponent) + jitter)
                    .min(std::time::Duration::from_secs(6 * 60 * 60));
                calculated.max(std::time::Duration::from_secs(
                    retry_after_seconds.unwrap_or_default(),
                ))
            }
            super::models::ExternalArtworkNegativeResult::TemporaryFailure => {
                COVER_INVALID_IMAGE_TTL
            }
        };
        let snapshot = ExternalArtworkNegativeSnapshot {
            artist_id: identity.artist_id,
            identity_generation: identity.generation,
            catalog_generation: target.catalog_generation,
            release_group_mbid: target.release_group_mbid.clone(),
            exact_release_mbid: target.exact_release_mbid.clone(),
            result,
            last_error,
            recorded_at: now,
            expires_at: now.saturating_add(ttl.as_secs() as i64),
        };
        self.write_database_idempotent("artwork.store_negative", move |conn| {
            enrichment::store_external_artwork_negative_result(conn, &snapshot)
        })
        .await
        .map_err(storage_transport)
    }

    async fn remove_unreferenced_managed_path(
        &self,
        path: std::path::PathBuf,
    ) -> Result<(), super::transport::TransportError> {
        use super::transport::TransportError;
        let path_text = path.to_string_lossy().into_owned();
        let referenced = self
            .database(move |conn| enrichment::path_is_referenced(conn, &path_text))
            .await
            .map_err(storage_transport)?;
        if !referenced {
            let covers_dir = self.covers_dir.clone();
            tokio::task::spawn_blocking(move || {
                crate::artwork::remove_managed_if_safe(&covers_dir, &path)
            })
            .await
            .map_err(|_| TransportError::Network)?
            .map_err(|_| TransportError::Network)?;
        }
        Ok(())
    }

    async fn refresh_profile_once(
        &self,
        identity: &ArtistIdentity,
        language: &str,
        force: bool,
    ) -> Result<ProfileRefreshOutcome, super::transport::TransportError> {
        use super::models::{ProfileSnapshot, ProviderFailureSnapshot};
        use super::policy::{NOT_FOUND_TTL, PROFILE_TTL};
        use super::transport::TransportError;
        let artist_id = identity.artist_id;
        let generation = identity.generation;
        let mbid = identity
            .musicbrainz_id
            .as_deref()
            .ok_or(TransportError::InvalidRequest)?;
        let cached_qid = self
            .database(move |conn| {
                enrichment::external_id(conn, artist_id, generation, EnrichmentProvider::Wikidata)
            })
            .await
            .map_err(storage_transport)?;
        let qid = if let Some(qid) = cached_qid {
            qid
        } else {
            let musicbrainz = self
                .musicbrainz
                .get_or_init(super::providers::musicbrainz::MusicBrainz::new)
                .as_ref()
                .map_err(|_| TransportError::Configuration)?;
            let resource_key = provider_resource_key(&[mbid]);
            let Some(qid) = self
                .provider_request(
                    artist_id,
                    generation,
                    EnrichmentProvider::MusicBrainz,
                    "profile_relation",
                    resource_key.clone(),
                    force,
                    musicbrainz.wikidata_id(mbid),
                )
                .await?
            else {
                let now = chrono::Utc::now().timestamp();
                let failure = ProviderFailureSnapshot {
                    artist_id,
                    identity_generation: generation,
                    provider: EnrichmentProvider::MusicBrainz,
                    operation: "profile_relation".into(),
                    resource_key,
                    error_code: "http_404".into(),
                    retry_after_seconds: None,
                    recorded_at: now,
                    expires_at: now.saturating_add(NOT_FOUND_TTL.as_secs() as i64),
                };
                self.write_database_idempotent("provider_failure.store", move |conn| {
                    enrichment::store_provider_failure(conn, &failure)
                })
                .await
                .map_err(storage_transport)?;
                return Ok(ProfileRefreshOutcome {
                    profile_status: ArtistRefreshStatus::NotFound,
                    commons_file: None,
                });
            };
            let stored_qid = qid.clone();
            let stored = self
                .write_database_idempotent("external_id.store", move |conn| {
                    enrichment::store_external_id(
                        conn,
                        artist_id,
                        generation,
                        EnrichmentProvider::Wikidata,
                        &stored_qid,
                        "musicbrainz_relation",
                        chrono::Utc::now().timestamp(),
                    )
                })
                .await
                .map_err(storage_transport)?;
            if !stored {
                return Ok(ProfileRefreshOutcome {
                    profile_status: ArtistRefreshStatus::Superseded,
                    commons_file: None,
                });
            }
            qid
        };
        let wikidata = self
            .wikidata
            .get_or_init(super::providers::wikidata::Wikidata::new)
            .as_ref()
            .map_err(|_| TransportError::Configuration)?;
        let cached_validators = self
            .database(move |conn| {
                enrichment::profile_validators(conn, artist_id, EnrichmentProvider::Wikidata, "und")
            })
            .await
            .map_err(storage_transport)?
            .unwrap_or_default();
        let resource_key = provider_resource_key(&[&qid, language]);
        let response = self
            .provider_request(
                artist_id,
                generation,
                EnrichmentProvider::Wikidata,
                "profile",
                resource_key,
                force,
                wikidata.profile(&qid, language, &cached_validators),
            )
            .await?;
        let now = chrono::Utc::now().timestamp();
        let expires_at = now.saturating_add(PROFILE_TTL.as_secs() as i64);
        if let super::models::ProviderResponse::NotModified { validators } = response {
            let touched = self
                .write_database_idempotent("profile.touch", move |conn| {
                    enrichment::touch_profile(
                        conn,
                        artist_id,
                        generation,
                        EnrichmentProvider::Wikidata,
                        "und",
                        now,
                        expires_at,
                        &validators,
                    )
                })
                .await
                .map_err(storage_transport)?;
            if !touched {
                return Ok(ProfileRefreshOutcome {
                    profile_status: ArtistRefreshStatus::Superseded,
                    commons_file: None,
                });
            }
            let commons_file = self
                .database(move |conn| {
                    enrichment::external_id(
                        conn,
                        artist_id,
                        generation,
                        EnrichmentProvider::Commons,
                    )
                })
                .await
                .map_err(storage_transport)?;
            let article = self
                .database(move |conn| {
                    enrichment::external_id(
                        conn,
                        artist_id,
                        generation,
                        EnrichmentProvider::Wikipedia,
                    )
                })
                .await
                .map_err(storage_transport)?
                .and_then(|value| serde_json::from_str::<(String, String)>(&value).ok());
            let mut status = ArtistRefreshStatus::Unchanged;
            if let Some((article_language, article_title)) = article {
                match self
                    .refresh_wikipedia_once(
                        artist_id,
                        generation,
                        article_language,
                        article_title,
                        now,
                        expires_at,
                        force,
                    )
                    .await
                {
                    Ok(ArtistRefreshStatus::Updated) => status = ArtistRefreshStatus::Updated,
                    Ok(ArtistRefreshStatus::Superseded) => status = ArtistRefreshStatus::Superseded,
                    _ => {}
                }
            }
            return Ok(ProfileRefreshOutcome {
                profile_status: status,
                commons_file,
            });
        }
        let super::models::ProviderResponse::Modified {
            value: remote,
            validators,
        } = response
        else {
            unreachable!()
        };
        let article = remote
            .article_language
            .clone()
            .zip(remote.article_title.clone());
        let commons_file = remote.commons_file.clone();
        let snapshot = ProfileSnapshot {
            artist_id,
            identity_generation: generation,
            provider: EnrichmentProvider::Wikidata,
            language: "und".into(),
            profile: remote.profile,
            fetched_at: now,
            expires_at,
            validators,
        };
        let stored = self
            .write_database_idempotent("profile.store", move |conn| {
                enrichment::store_profile(conn, &snapshot)
            })
            .await
            .map_err(storage_transport)?;
        if !stored {
            return Ok(ProfileRefreshOutcome {
                profile_status: ArtistRefreshStatus::Superseded,
                commons_file,
            });
        }
        let article_json = article
            .as_ref()
            .and_then(|value| serde_json::to_string(value).ok());
        let stored_article = self
            .write_database_idempotent("external_id.replace_wikipedia", move |conn| {
                enrichment::replace_external_id(
                    conn,
                    artist_id,
                    generation,
                    EnrichmentProvider::Wikipedia,
                    article_json.as_deref(),
                    "wikidata_sitelink",
                    now,
                )
            })
            .await
            .map_err(storage_transport)?;
        let stored_commons = commons_file.clone();
        let targets_current = self
            .write_database_idempotent("external_id.replace_commons", move |conn| {
                enrichment::replace_external_id(
                    conn,
                    artist_id,
                    generation,
                    EnrichmentProvider::Commons,
                    stored_commons.as_deref(),
                    "wikidata_p18",
                    now,
                )
            })
            .await
            .map_err(storage_transport)?;
        if !stored_article || !targets_current {
            return Ok(ProfileRefreshOutcome {
                profile_status: ArtistRefreshStatus::Superseded,
                commons_file,
            });
        }
        let mut status = ArtistRefreshStatus::Updated;
        if let Some((article_language, article_title)) = article {
            if matches!(
                self.refresh_wikipedia_once(
                    artist_id,
                    generation,
                    article_language,
                    article_title,
                    now,
                    expires_at,
                    force,
                )
                .await,
                Ok(ArtistRefreshStatus::Superseded)
            ) {
                status = ArtistRefreshStatus::Superseded;
            }
        }
        Ok(ProfileRefreshOutcome {
            profile_status: status,
            commons_file,
        })
    }

    #[allow(clippy::too_many_arguments)]
    async fn refresh_wikipedia_once(
        &self,
        artist_id: i64,
        generation: u64,
        language: String,
        title: String,
        fetched_at: i64,
        expires_at: i64,
        force: bool,
    ) -> Result<ArtistRefreshStatus, super::transport::TransportError> {
        use super::models::{ProfileSnapshot, ProviderResponse};
        let lookup_language = language.clone();
        let validators = self
            .database(move |conn| {
                enrichment::profile_validators(
                    conn,
                    artist_id,
                    EnrichmentProvider::Wikipedia,
                    &lookup_language,
                )
            })
            .await
            .map_err(storage_transport)?
            .unwrap_or_default();
        let wikipedia = super::providers::wikipedia::Wikipedia::new(&language)?;
        let resource_key = provider_resource_key(&[&language, &title]);
        let response = self
            .provider_request(
                artist_id,
                generation,
                EnrichmentProvider::Wikipedia,
                "profile",
                resource_key,
                force,
                wikipedia.introduction(&title, &language, &validators),
            )
            .await?;
        match response {
            ProviderResponse::Modified { value, validators } => {
                let snapshot = ProfileSnapshot {
                    artist_id,
                    identity_generation: generation,
                    provider: EnrichmentProvider::Wikipedia,
                    language,
                    profile: value,
                    fetched_at,
                    expires_at,
                    validators,
                };
                Ok(
                    if self
                        .write_database_idempotent("profile.store", move |conn| {
                            enrichment::store_profile(conn, &snapshot)
                        })
                        .await
                        .map_err(storage_transport)?
                    {
                        ArtistRefreshStatus::Updated
                    } else {
                        ArtistRefreshStatus::Superseded
                    },
                )
            }
            ProviderResponse::NotModified { validators } => Ok(
                if self
                    .write_database_idempotent("profile.touch", move |conn| {
                        enrichment::touch_profile(
                            conn,
                            artist_id,
                            generation,
                            EnrichmentProvider::Wikipedia,
                            &language,
                            fetched_at,
                            expires_at,
                            &validators,
                        )
                    })
                    .await
                    .map_err(storage_transport)?
                {
                    ArtistRefreshStatus::Unchanged
                } else {
                    ArtistRefreshStatus::Superseded
                },
            ),
        }
    }

    async fn refresh_portrait_once(
        &self,
        artist_id: i64,
        generation: u64,
        filename: &str,
        force: bool,
    ) -> Result<ArtistRefreshStatus, super::transport::TransportError> {
        use super::models::AssetSnapshot;
        use super::policy::PROFILE_TTL;
        use super::transport::TransportError;
        let commons = self
            .commons
            .get_or_init(super::providers::commons::Commons::new)
            .as_ref()
            .map_err(|_| TransportError::Configuration)?;
        let resource_key = provider_resource_key(&[filename]);
        let metadata = self
            .provider_request(
                artist_id,
                generation,
                EnrichmentProvider::Commons,
                "portrait_metadata",
                resource_key.clone(),
                force,
                commons.metadata(filename),
            )
            .await?;
        let bytes = self
            .provider_request(
                artist_id,
                generation,
                EnrichmentProvider::Commons,
                "portrait_image",
                resource_key,
                force,
                commons.download(&metadata.download_url),
            )
            .await?;
        let covers_dir = self.covers_dir.clone();
        let managed_path =
            tokio::task::spawn_blocking(move || crate::artwork::write_managed(&covers_dir, &bytes))
                .await
                .map_err(|_| TransportError::Network)?
                .map_err(|_| TransportError::InvalidJson)?;
        let previous_path = self
            .database(move |conn| {
                enrichment::asset_path(conn, artist_id, EnrichmentProvider::Commons)
            })
            .await
            .map_err(storage_transport)?;
        let now = chrono::Utc::now().timestamp();
        let snapshot = AssetSnapshot {
            artist_id,
            identity_generation: generation,
            provider: EnrichmentProvider::Commons,
            provider_id: metadata.provider_id,
            source_url: metadata.source_url,
            managed_path: managed_path.to_string_lossy().into_owned(),
            width: metadata.width,
            height: metadata.height,
            attribution: metadata.attribution,
            fetched_at: now,
            expires_at: now.saturating_add(PROFILE_TTL.as_secs() as i64),
        };
        if self
            .write_database_idempotent("portrait.store", move |conn| {
                enrichment::store_asset(conn, &snapshot)
            })
            .await
            .map_err(storage_transport)?
        {
            if let Some(previous_path) =
                previous_path.filter(|path| path != managed_path.to_string_lossy().as_ref())
            {
                let check_path = previous_path.clone();
                let referenced = self
                    .database(move |conn| enrichment::path_is_referenced(conn, &check_path))
                    .await
                    .map_err(storage_transport)?;
                if !referenced {
                    let covers_dir = self.covers_dir.clone();
                    tokio::task::spawn_blocking(move || {
                        crate::artwork::remove_managed_if_safe(
                            &covers_dir,
                            std::path::Path::new(&previous_path),
                        )
                    })
                    .await
                    .map_err(|_| TransportError::Network)?
                    .map_err(|_| TransportError::Network)?;
                }
            }
            Ok(ArtistRefreshStatus::Updated)
        } else {
            let check_path = managed_path.to_string_lossy().into_owned();
            let referenced = self
                .database(move |conn| enrichment::path_is_referenced(conn, &check_path))
                .await
                .map_err(storage_transport)?;
            if !referenced {
                let covers_dir = self.covers_dir.clone();
                tokio::task::spawn_blocking(move || {
                    crate::artwork::remove_managed_if_safe(&covers_dir, &managed_path)
                })
                .await
                .map_err(|_| TransportError::Network)?
                .map_err(|_| TransportError::Network)?;
            }
            Ok(ArtistRefreshStatus::Superseded)
        }
    }

    async fn cleanup_stale_assets(&self) -> CoreResult<()> {
        let paths = self
            .write_database_idempotent(
                "artwork.cleanup_stale",
                enrichment::collect_stale_asset_paths,
            )
            .await?;
        if paths.is_empty() {
            return Ok(());
        }
        let covers_dir = self.covers_dir.clone();
        tokio::task::spawn_blocking(move || {
            for path in paths {
                crate::artwork::remove_managed_if_safe(&covers_dir, std::path::Path::new(&path))?;
            }
            Ok::<_, CoreError>(())
        })
        .await
        .map_err(|error| CoreError::Storage {
            message: format!("Artwork cleanup task failed: {error}"),
        })?
    }
}

struct ProfileRefreshOutcome {
    profile_status: ArtistRefreshStatus,
    commons_file: Option<String>,
}

struct CoverRefreshOutcome {
    status: ArtistRefreshStatus,
    progress: CoverRefreshProgress,
}

fn refresh_result(
    artist_id: i64,
    generation: u64,
    sections: Vec<ArtistRefreshSection>,
    status: ArtistRefreshStatus,
    retry_after_seconds: Option<u64>,
) -> ArtistRefreshResult {
    ArtistRefreshResult {
        artist_id,
        identity_generation: generation,
        sections: sections
            .into_iter()
            .map(|section| refresh_section_result(section, status, retry_after_seconds, None, None))
            .collect(),
    }
}

fn refresh_section_result(
    section: ArtistRefreshSection,
    status: ArtistRefreshStatus,
    retry_after_seconds: Option<u64>,
    cover_progress: Option<CoverRefreshProgress>,
    diagnostic: Option<ArtistRefreshDiagnosticCode>,
) -> ArtistRefreshSectionResult {
    ArtistRefreshSectionResult {
        section,
        status,
        retry_after_seconds,
        cover_progress,
        diagnostic,
        provider: Some(match section {
            ArtistRefreshSection::Profile => EnrichmentProvider::Wikidata,
            ArtistRefreshSection::Portrait => EnrichmentProvider::Commons,
            ArtistRefreshSection::Discography => EnrichmentProvider::MusicBrainz,
            ArtistRefreshSection::Covers => EnrichmentProvider::CoverArtArchive,
        }),
    }
}

fn refresh_transport_error(
    error: &super::transport::TransportError,
) -> (
    ArtistRefreshStatus,
    Option<u64>,
    Option<ArtistRefreshDiagnosticCode>,
) {
    use super::transport::TransportError;
    use ArtistRefreshDiagnosticCode as Diagnostic;
    match error {
        TransportError::RateLimited {
            retry_after_seconds,
        } => (
            ArtistRefreshStatus::RateLimited,
            Some(*retry_after_seconds),
            None,
        ),
        TransportError::HttpStatus { status: 404, .. } => {
            (ArtistRefreshStatus::NotFound, None, None)
        }
        TransportError::Timeout => (
            ArtistRefreshStatus::Unavailable,
            None,
            Some(Diagnostic::Timeout),
        ),
        TransportError::Connection | TransportError::Network => (
            ArtistRefreshStatus::Unavailable,
            None,
            Some(Diagnostic::ConnectionFailed),
        ),
        TransportError::InvalidJson | TransportError::BodyTooLarge => (
            ArtistRefreshStatus::Unavailable,
            None,
            Some(Diagnostic::InvalidResponse),
        ),
        TransportError::InvalidImage => (
            ArtistRefreshStatus::Unavailable,
            None,
            Some(Diagnostic::InvalidImage),
        ),
        TransportError::Storage { extended_code } => {
            let busy = extended_code.is_some_and(|code| matches!(code & 0xff, 5 | 6));
            (
                ArtistRefreshStatus::Unavailable,
                None,
                Some(if busy {
                    Diagnostic::DatabaseBusy
                } else {
                    Diagnostic::ProviderUnavailable
                }),
            )
        }
        TransportError::HttpStatus {
            retry_after_seconds,
            ..
        } => (
            ArtistRefreshStatus::Unavailable,
            *retry_after_seconds,
            Some(Diagnostic::ProviderUnavailable),
        ),
        TransportError::Configuration | TransportError::InvalidRequest => (
            ArtistRefreshStatus::Unavailable,
            None,
            Some(Diagnostic::ProviderUnavailable),
        ),
    }
}

fn storage_transport(error: CoreError) -> super::transport::TransportError {
    super::transport::TransportError::Storage {
        extended_code: crate::database::sqlite_busy_extended_code(&error),
    }
}

fn provider_resource_key(parts: &[&str]) -> String {
    let mut digest = Md5::new();
    for part in parts {
        digest.update((part.len() as u64).to_be_bytes());
        digest.update(part.as_bytes());
    }
    format!("{:x}", digest.finalize())
}

fn permanent_failure_ttl(error: &super::transport::TransportError) -> Option<std::time::Duration> {
    use super::policy::{NOT_FOUND_TTL, PERMANENT_FAILURE_TTL};
    use super::transport::TransportError;
    match error {
        TransportError::HttpStatus { status: 404, .. } => Some(NOT_FOUND_TTL),
        TransportError::HttpStatus { status, .. }
            if (400..500).contains(status) && *status != 408 && *status != 429 =>
        {
            Some(PERMANENT_FAILURE_TTL)
        }
        TransportError::InvalidJson
        | TransportError::InvalidImage
        | TransportError::BodyTooLarge => Some(PERMANENT_FAILURE_TTL),
        _ => None,
    }
}

fn provider_error_code(error: &super::transport::TransportError) -> String {
    use super::transport::TransportError;
    match error {
        TransportError::BodyTooLarge => "body_too_large".into(),
        TransportError::InvalidJson => "invalid_json".into(),
        TransportError::InvalidImage => "invalid_image".into(),
        TransportError::HttpStatus { status, .. } => format!("http_{status}"),
        _ => "permanent_provider_error".into(),
    }
}

fn cached_transport_error(
    failure: &super::models::CachedProviderFailure,
) -> super::transport::TransportError {
    use super::transport::TransportError;
    match failure.error_code.as_str() {
        "body_too_large" => TransportError::BodyTooLarge,
        "invalid_json" => TransportError::InvalidJson,
        "invalid_image" => TransportError::InvalidImage,
        code if code.starts_with("http_") => code[5..]
            .parse::<u16>()
            .map(|status| TransportError::HttpStatus {
                status,
                retry_after_seconds: failure.retry_after_seconds,
            })
            .unwrap_or(TransportError::Network),
        _ => TransportError::Network,
    }
}

fn cover_cacheable_failure(error: &super::transport::TransportError) -> bool {
    use super::transport::TransportError;
    !matches!(
        error,
        TransportError::Configuration
            | TransportError::InvalidRequest
            | TransportError::Storage { .. }
            | TransportError::InvalidImage
    )
}

fn cover_error_code(error: &super::transport::TransportError) -> String {
    use super::transport::TransportError;
    match error {
        TransportError::Configuration => "configuration".into(),
        TransportError::InvalidRequest => "invalid_request".into(),
        TransportError::Timeout => "timeout".into(),
        TransportError::Connection => "connection".into(),
        TransportError::Network => "network".into(),
        TransportError::BodyTooLarge => "image_too_large".into(),
        TransportError::InvalidJson => "invalid_json".into(),
        TransportError::InvalidImage => "invalid_image".into(),
        TransportError::HttpStatus { status, .. } => format!("http_{status}"),
        TransportError::RateLimited { .. } => "http_429".into(),
        TransportError::Storage {
            extended_code: Some(code),
        } => format!("sqlite_{code}"),
        TransportError::Storage {
            extended_code: None,
        } => "sqlite".into(),
    }
}

#[cfg(test)]
mod tests {
    use super::super::{
        providers::{
            commons::Commons, cover_art_archive::CoverArtArchive, musicbrainz::MusicBrainz,
            wikidata::Wikidata,
        },
        transport::{
            EnrichmentHttpClient, tests::client, tests::client_for, tests::response,
            tests::response_bytes,
        },
    };
    use super::*;
    use std::io::Cursor;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    fn test_lastfm_client() -> Arc<crate::lastfm::LastFmClient> {
        let directory = std::env::temp_dir().join(format!(
            "durvald-enrichment-lastfm-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let store =
            crate::secure_store::SecureStore::new(directory, "durvald-enrichment-test".to_string())
                .unwrap();
        Arc::new(
            crate::lastfm::LastFmClient::new(Arc::new(tokio::sync::Mutex::new(store))).unwrap(),
        )
    }

    fn service() -> EnrichmentService {
        let manager = r2d2_sqlite::SqliteConnectionManager::memory().with_init(|conn| {
            conn.execute_batch("PRAGMA foreign_keys = ON")?;
            crate::database::operations::create_tables(conn)
                .map_err(|_| rusqlite::Error::InvalidQuery)?;
            crate::database::migrations::migrate_enrichment(conn)?;
            conn.execute(
                "INSERT INTO artists(artist_id, name) VALUES (1, 'Same Name')",
                [],
            )?;
            Ok(())
        });
        EnrichmentService::new(
            Arc::new(r2d2::Pool::builder().max_size(1).build(manager).unwrap()),
            std::env::temp_dir()
                .join("durvald-enrichment-service-tests")
                .to_string_lossy()
                .into_owned(),
            test_lastfm_client(),
        )
    }

    #[test]
    fn refresh_transport_errors_keep_actionable_diagnostics() {
        use super::super::transport::TransportError;

        let (status, retry, diagnostic) = refresh_transport_error(&TransportError::Storage {
            extended_code: Some(5),
        });
        assert_eq!(status, ArtistRefreshStatus::Unavailable);
        assert_eq!(retry, None);
        assert_eq!(diagnostic, Some(ArtistRefreshDiagnosticCode::DatabaseBusy));

        let (_, _, diagnostic) = refresh_transport_error(&TransportError::Timeout);
        assert_eq!(diagnostic, Some(ArtistRefreshDiagnosticCode::Timeout));

        let (_, _, diagnostic) = refresh_transport_error(&TransportError::InvalidJson);
        assert_eq!(
            diagnostic,
            Some(ArtistRefreshDiagnosticCode::InvalidResponse)
        );

        let (_, _, diagnostic) = refresh_transport_error(&TransportError::Network);
        assert_eq!(
            diagnostic,
            Some(ArtistRefreshDiagnosticCode::ConnectionFailed)
        );
    }

    #[tokio::test]
    async fn enrichment_writes_hold_one_publication_gate() {
        let service = service();
        let worker = service.clone();
        let (entered_tx, entered_rx) = tokio::sync::oneshot::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let write = tokio::spawn(async move {
            worker
                .write_database(move |_| {
                    entered_tx.send(()).unwrap();
                    release_rx.recv().unwrap();
                    Ok(())
                })
                .await
        });

        entered_rx.await.unwrap();
        assert!(service.write_coordinator.try_lock().is_err());
        release_tx.send(()).unwrap();
        write.await.unwrap().unwrap();
        assert!(service.write_coordinator.try_lock().is_ok());
    }

    #[tokio::test(flavor = "current_thread")]
    async fn idempotent_writes_retry_only_sqlite_lock_errors_with_a_limit() {
        use std::sync::atomic::{AtomicUsize, Ordering};

        let unique = format!(
            "durvald-enrichment-retry-{}-{}.sqlite",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        );
        let path = std::env::temp_dir().join(unique);
        let mut writer = rusqlite::Connection::open(&path).unwrap();
        writer
            .execute_batch(
                "PRAGMA journal_mode = WAL; PRAGMA busy_timeout = 0; PRAGMA foreign_keys = ON;",
            )
            .unwrap();
        crate::database::operations::create_tables(&writer).unwrap();
        crate::database::migrations::migrate_enrichment(&mut writer).unwrap();
        let manager = r2d2_sqlite::SqliteConnectionManager::file(&path).with_init(|conn| {
            conn.execute_batch("PRAGMA busy_timeout = 0; PRAGMA foreign_keys = ON;")
        });
        let service = EnrichmentService::new(
            Arc::new(r2d2::Pool::builder().max_size(1).build(manager).unwrap()),
            std::env::temp_dir().to_string_lossy().into_owned(),
            test_lastfm_client(),
        );
        let write_tx =
            rusqlite::Transaction::new_unchecked(&writer, rusqlite::TransactionBehavior::Immediate)
                .unwrap();
        let attempts = Arc::new(AtomicUsize::new(0));
        let counted = attempts.clone();
        let started = std::time::Instant::now();
        let error = service
            .write_database_idempotent("test.locked_write", move |conn| {
                counted.fetch_add(1, Ordering::SeqCst);
                conn.execute(
                    "UPDATE enrichment_settings SET offline = offline WHERE id = 1",
                    [],
                )
                .map(|_| ())
                .map_err(|error| crate::database::storage_error("Test storage", error))
            })
            .await
            .unwrap_err();
        assert_eq!(
            attempts.load(Ordering::SeqCst),
            EnrichmentService::SQLITE_WRITE_ATTEMPTS as usize
        );
        assert!(started.elapsed() >= EnrichmentService::SQLITE_RETRY_BASE * 3);
        assert!(crate::database::sqlite_busy_extended_code(&error).is_some());
        write_tx.rollback().unwrap();

        let transient_tx =
            rusqlite::Transaction::new_unchecked(&writer, rusqlite::TransactionBehavior::Immediate)
                .unwrap();
        let transient_service = service.clone();
        let transient_attempts = Arc::new(AtomicUsize::new(0));
        let transient_failures = Arc::new(AtomicUsize::new(0));
        let counted = transient_attempts.clone();
        let failed = transient_failures.clone();
        let transient = tokio::spawn(async move {
            transient_service
                .write_database_idempotent("test.transient_lock", move |conn| {
                    counted.fetch_add(1, Ordering::SeqCst);
                    conn.execute(
                        "UPDATE enrichment_settings SET offline = offline WHERE id = 1",
                        [],
                    )
                    .map(|_| ())
                    .map_err(|error| {
                        failed.fetch_add(1, Ordering::SeqCst);
                        crate::database::storage_error("Test storage", error)
                    })
                })
                .await
        });
        tokio::time::timeout(std::time::Duration::from_secs(1), async {
            while transient_failures.load(Ordering::SeqCst) == 0 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        transient_tx.rollback().unwrap();
        transient.await.unwrap().unwrap();
        assert!(transient_attempts.load(Ordering::SeqCst) >= 2);

        let attempts = Arc::new(AtomicUsize::new(0));
        let counted = attempts.clone();
        let error = service
            .write_database_idempotent("test.permanent_error", move |_| {
                counted.fetch_add(1, Ordering::SeqCst);
                Err::<(), _>(CoreError::InvalidInput {
                    message: "permanent".into(),
                })
            })
            .await
            .unwrap_err();
        assert!(matches!(error, CoreError::InvalidInput { .. }));
        assert_eq!(attempts.load(Ordering::SeqCst), 1);

        drop(service);
        drop(writer);
        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_file(path.with_extension("sqlite-wal"));
        let _ = std::fs::remove_file(path.with_extension("sqlite-shm"));
    }

    /// Real loopback HTTP plus SQLite: gates hold no database connection, and
    /// subscribers can cancel independently while a manual correction wins.
    #[tokio::test]
    async fn shared_http_releases_database_and_discards_response_after_confirmation() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}/", listener.local_addr().unwrap());
        let (started_tx, started_rx) = tokio::sync::oneshot::channel();
        let (release_tx, release_rx) = tokio::sync::oneshot::channel();
        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = vec![0; 8192];
            let count = socket.read(&mut request).await.unwrap();
            let request = String::from_utf8_lossy(&request[..count]);
            assert!(request.starts_with("GET /ws/2/artist/"));
            assert!(request.contains("query=artist%3A%22Same+Name%22"));
            started_tx.send(()).unwrap();
            release_rx.await.unwrap();
            let body = include_str!("../../tests/fixtures/musicbrainz-homonyms.json");
            socket.write_all(format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).as_bytes()).await.unwrap();
        });
        let service = service();
        assert!(
            service
                .musicbrainz
                .set(Ok(MusicBrainz {
                    http: EnrichmentHttpClient::local_test_client(&base)
                }))
                .is_ok()
        );
        service
            .configure(EnrichmentSettings {
                enabled: true,
                offline: false,
                preferred_language: "pt".into(),
            })
            .await
            .unwrap();
        let first_service = service.clone();
        let first = tokio::spawn(async move { first_service.resolve_artist_candidates(1).await });
        started_rx.await.unwrap();
        let second_service = service.clone();
        let second = tokio::spawn(async move { second_service.resolve_artist_candidates(1).await });
        // Wait until the second subscriber has joined the same flight.
        tokio::time::timeout(std::time::Duration::from_secs(2), async {
            loop {
                if service
                    .flights
                    .lock()
                    .unwrap()
                    .get(&1)
                    .unwrap()
                    .strong_count()
                    == 2
                {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        first.abort();
        let confirmed = tokio::time::timeout(
            std::time::Duration::from_secs(2),
            service.confirm_artist_identity(1, Some("33333333-3333-4333-8333-333333333333".into())),
        )
        .await
        .unwrap()
        .unwrap();
        release_tx.send(()).unwrap();
        let result = second.await.unwrap().unwrap();
        assert_eq!(result.identity, confirmed);
        assert_eq!(result.lookup_status, ArtistIdentityLookupStatus::Superseded);
        assert!(result.candidates.is_empty());
        server.await.unwrap();
    }

    #[tokio::test]
    async fn disabled_and_offline_do_not_construct_http_clients() {
        let service = service();
        assert_eq!(
            service
                .resolve_artist_candidates(1)
                .await
                .unwrap()
                .lookup_status,
            ArtistIdentityLookupStatus::Disabled
        );
        service
            .configure(EnrichmentSettings {
                enabled: true,
                offline: true,
                preferred_language: "pt".into(),
            })
            .await
            .unwrap();
        assert_eq!(
            service
                .resolve_artist_candidates(1)
                .await
                .unwrap()
                .lookup_status,
            ArtistIdentityLookupStatus::Offline
        );
        assert!(service.musicbrainz.get().is_none());
    }

    #[tokio::test(start_paused = true)]
    async fn external_release_details_are_reused_from_disk_while_offline() {
        let service = service();
        service
            .configure(EnrichmentSettings {
                enabled: true,
                offline: false,
                preferred_language: "pt".into(),
            })
            .await
            .unwrap();
        service
            .confirm_artist_identity(1, Some("11111111-1111-4111-8111-111111111111".into()))
            .await
            .unwrap();
        let group_id = "22222222-2222-4222-8222-222222222222";
        let (http, mock) = client(vec![
            response(
                200,
                &[],
                &[&format!(
                    r#"{{"release-group-count":1,"release-group-offset":0,"release-groups":[{{"id":"{group_id}","title":"Album","primary-type":"Album","secondary-types":[],"first-release-date":"2001"}}]}}"#
                )],
                None,
            ),
            response(
                200,
                &[("etag", "\"details-v1\"")],
                &[
                    r#"{"release-count":1,"release-offset":0,"releases":[{"id":"33333333-3333-4333-8333-333333333333","title":"Album","date":"2001","artist-credit":[{"name":"Same Name","artist":{"id":"11111111-1111-4111-8111-111111111111","name":"Same Name"}}],"media":[{"position":1,"tracks":[{"position":1,"title":"Track","length":60000,"recording":{"title":"Track","length":60000,"relations":[]}}]}]}]}"#,
                ],
                None,
            ),
        ]);
        service
            .musicbrainz
            .set(Ok(MusicBrainz { http }))
            .ok()
            .unwrap();
        service
            .refresh_artist(
                1,
                ArtistRefreshRequest {
                    sections: vec![ArtistRefreshSection::Discography],
                    language: "pt".into(),
                    force: true,
                },
            )
            .await
            .unwrap();
        let online = service
            .external_release_details(1, group_id.into())
            .await
            .unwrap();
        assert_eq!(online.tracks.len(), 1);
        service
            .database(|conn| {
                conn.execute(
                    "UPDATE external_release_details SET expires_at = fetched_at",
                    [],
                )
                .map(|_| ())
                .map_err(|error| CoreError::Storage {
                    message: error.to_string(),
                })
            })
            .await
            .unwrap();
        service
            .configure(EnrichmentSettings {
                enabled: true,
                offline: true,
                preferred_language: "pt".into(),
            })
            .await
            .unwrap();
        let offline = service
            .external_release_details(1, group_id.into())
            .await
            .unwrap();
        assert_eq!(offline, online);
        assert_eq!(mock.calls(), 2);
    }

    #[tokio::test(start_paused = true)]
    async fn profile_and_portrait_flow_persists_an_offline_generation_scoped_view() {
        let service = service();
        service
            .configure(EnrichmentSettings {
                enabled: true,
                offline: false,
                preferred_language: "pt".into(),
            })
            .await
            .unwrap();
        service
            .confirm_artist_identity(1, Some("11111111-1111-4111-8111-111111111111".into()))
            .await
            .unwrap();
        let (musicbrainz, _) = client(vec![response(
            200,
            &[],
            &[
                r#"{"relations":[{"type":"wikidata","url":{"resource":"https://www.wikidata.org/wiki/Q1"}}]}"#,
            ],
            None,
        )]);
        service
            .musicbrainz
            .set(Ok(MusicBrainz { http: musicbrainz }))
            .ok()
            .unwrap();
        let (wikidata, _) = client(vec![response(
            200,
            &[],
            &[
                r#"{"entities":{"Q1":{"lastrevid":7,"labels":{},"claims":{"P31":[{"rank":"normal","mainsnak":{"datavalue":{"value":{"id":"Q5"}}}}],"P569":[{"rank":"normal","mainsnak":{"datavalue":{"value":{"time":"+1965-00-00T00:00:00Z","precision":9}}}}],"P18":[{"rank":"normal","mainsnak":{"datavalue":{"value":"Portrait.png"}}}]},"sitelinks":{}}}}"#,
            ],
            None,
        )]);
        service
            .wikidata
            .set(Ok(Wikidata { http: wikidata }))
            .ok()
            .unwrap();
        let mut png = Vec::new();
        image::DynamicImage::new_rgb8(2, 2)
            .write_to(&mut Cursor::new(&mut png), image::ImageFormat::Png)
            .unwrap();
        let commons_json = r#"{"query":{"pages":[{"title":"File:Portrait.png","imageinfo":[{"url":"https://upload.wikimedia.org/portrait.png","descriptionurl":"https://commons.wikimedia.org/wiki/File:Portrait.png","width":2,"height":2,"mime":"image/png","extmetadata":{"Artist":{"value":"Photographer"},"LicenseShortName":{"value":"CC0"}}}]}]}}"#;
        let (commons, _) = client(vec![
            response(200, &[], &[commons_json], None),
            response_bytes(200, &[], &[&png], Some(png.len() as u64)),
        ]);
        service
            .commons
            .set(Ok(Commons { http: commons }))
            .ok()
            .unwrap();
        let result = service
            .refresh_artist(
                1,
                ArtistRefreshRequest {
                    sections: vec![
                        ArtistRefreshSection::Profile,
                        ArtistRefreshSection::Portrait,
                    ],
                    language: "pt".into(),
                    force: true,
                },
            )
            .await
            .unwrap();
        assert!(
            result
                .sections
                .iter()
                .all(|section| section.status == ArtistRefreshStatus::Updated)
        );
        let details = service.artist_details(1, "pt".into()).await.unwrap();
        assert_eq!(details.sources.len(), 1);
        assert_eq!(
            details.sources[0].profile.birth_date,
            Some(ArtistPartialDate {
                year: 1965,
                month: None,
                day: None,
            })
        );
        let portrait = details.portrait.unwrap();
        assert_eq!(portrait.provider_id, "Portrait.png");
        assert!(std::path::Path::new(&portrait.managed_path).is_file());
        assert_eq!(portrait.attribution.author.as_deref(), Some("Photographer"));
    }

    #[tokio::test(start_paused = true)]
    async fn discography_refresh_resumes_hidden_generation_and_publishes_only_at_end() {
        let service = service();
        service
            .configure(EnrichmentSettings {
                enabled: true,
                offline: false,
                preferred_language: "pt".into(),
            })
            .await
            .unwrap();
        service
            .confirm_artist_identity(1, Some("11111111-1111-4111-8111-111111111111".into()))
            .await
            .unwrap();

        let mut steps = Vec::new();
        for offset in 0..11 {
            let id = format!("00000000-0000-4000-8000-{offset:012}");
            let body = serde_json::json!({
                "release-group-count": 11,
                "release-group-offset": offset,
                "release-groups": [{
                    "id": id,
                    "title": format!("Release {offset}"),
                    "primary-type": "Album",
                    "secondary-types": [],
                    "first-release-date": format!("20{:02}", offset)
                }]
            })
            .to_string();
            steps.push(response(200, &[], &[body.as_str()], None));
        }
        let (musicbrainz, mock) = client(steps);
        service
            .musicbrainz
            .set(Ok(MusicBrainz { http: musicbrainz }))
            .ok()
            .unwrap();
        let request = ArtistRefreshRequest {
            sections: vec![ArtistRefreshSection::Discography],
            language: "pt".into(),
            force: true,
        };

        let first = service.refresh_artist(1, request.clone()).await.unwrap();
        assert_eq!(first.sections[0].status, ArtistRefreshStatus::Partial);
        assert_eq!(mock.calls(), 10);
        let hidden = service.artist_discography(1, 50, 0).await.unwrap();
        assert!(hidden.items.is_empty());
        assert_eq!(hidden.catalog_generation, 0);

        let second = service.refresh_artist(1, request).await.unwrap();
        assert_eq!(second.sections[0].status, ArtistRefreshStatus::Updated);
        assert_eq!(mock.calls(), 11);
        let published = service.artist_discography(1, 50, 0).await.unwrap();
        assert_eq!(published.catalog_generation, 1);
        assert_eq!(published.items.len(), 11);
        assert_eq!(published.remote_total, Some(11));
        assert!(published.remote_exhausted);
    }

    #[tokio::test(start_paused = true)]
    async fn discography_and_covers_refresh_then_reuse_the_seven_day_cache() {
        let service = service();
        service
            .configure(EnrichmentSettings {
                enabled: true,
                offline: false,
                preferred_language: "pt".into(),
            })
            .await
            .unwrap();
        service
            .confirm_artist_identity(1, Some("11111111-1111-4111-8111-111111111111".into()))
            .await
            .unwrap();
        let group_without_cover = "22222222-2222-4222-8222-222222222222";
        let group_with_cover = "44444444-4444-4444-8444-444444444444";
        let source_release = "33333333-3333-4333-8333-333333333333";
        let discography = serde_json::json!({
            "release-group-count": 2,
            "release-group-offset": 0,
            "release-groups": [
                {
                    "id": group_without_cover,
                    "title": "Remote album without cover",
                    "primary-type": "Album",
                    "secondary-types": [],
                    "first-release-date": "2023"
                },
                {
                    "id": group_with_cover,
                    "title": "Remote album with cover",
                    "primary-type": "Album",
                    "secondary-types": [],
                    "first-release-date": "2024"
                }
            ]
        })
        .to_string();
        let (musicbrainz, musicbrainz_mock) = client(vec![response(
            200,
            &[("etag", "\"discography-v1\"")],
            &[discography.as_str()],
            None,
        )]);
        service
            .musicbrainz
            .set(Ok(MusicBrainz { http: musicbrainz }))
            .ok()
            .unwrap();
        let mut png = Vec::new();
        image::DynamicImage::new_rgb8(2, 2)
            .write_to(&mut Cursor::new(&mut png), image::ImageFormat::Png)
            .unwrap();
        let metadata = serde_json::json!({
            "release": format!("https://musicbrainz.org/release/{source_release}"),
            "images": [{
                "id": "10",
                "image": format!("https://coverartarchive.org/release/{source_release}/10.png"),
                "front": true,
                "edit": 7
            }]
        })
        .to_string();
        let (cover_art, cover_art_mock) = client_for(
            "https://coverartarchive.org/",
            vec![
                response(404, &[], &[""], None),
                response(200, &[], &[metadata.as_str()], None),
                response_bytes(200, &[], &[&png], Some(png.len() as u64)),
            ],
        );
        service
            .cover_art_archive
            .set(Ok(CoverArtArchive { http: cover_art }))
            .ok()
            .unwrap();
        let request = ArtistRefreshRequest {
            sections: vec![
                ArtistRefreshSection::Discography,
                ArtistRefreshSection::Covers,
            ],
            language: "pt".into(),
            force: false,
        };
        let first = service.refresh_artist(1, request.clone()).await.unwrap();
        assert_eq!(
            first
                .sections
                .iter()
                .map(|result| result.status)
                .collect::<Vec<_>>(),
            vec![ArtistRefreshStatus::Updated, ArtistRefreshStatus::Updated]
        );
        let stored = service.artist_discography(1, 10, 0).await.unwrap();
        assert!(stored.items[0].artwork.is_none());
        let artwork = stored.items[1].artwork.as_ref().unwrap();
        assert_eq!(artwork.scope, ExternalArtworkScope::ReleaseGroup);
        assert!(std::path::Path::new(&artwork.image.managed_path).is_file());

        let second = service.refresh_artist(1, request).await.unwrap();
        assert!(
            second
                .sections
                .iter()
                .all(|result| result.status == ArtistRefreshStatus::Unchanged)
        );
        assert_eq!(musicbrainz_mock.calls(), 1);
        assert_eq!(cover_art_mock.calls(), 3);
        let negative_result = service
            .database(move |conn| {
                conn.query_row(
                    "SELECT result FROM external_artwork_negative_results
                     WHERE artist_id = 1 AND release_group_mbid = ?1",
                    [group_without_cover],
                    |row| row.get::<_, String>(0),
                )
                .map_err(|error| crate::database::storage_error("test", error))
            })
            .await
            .unwrap();
        assert_eq!(negative_result, "not_found");
    }

    #[tokio::test(start_paused = true)]
    async fn forced_discography_refresh_revalidates_and_preserves_the_cached_generation() {
        let service = service();
        service
            .configure(EnrichmentSettings {
                enabled: true,
                offline: false,
                preferred_language: "pt".into(),
            })
            .await
            .unwrap();
        service
            .confirm_artist_identity(1, Some("11111111-1111-4111-8111-111111111111".into()))
            .await
            .unwrap();
        let group_id = "22222222-2222-4222-8222-222222222222";
        let discography = serde_json::json!({
            "release-group-count": 1,
            "release-group-offset": 0,
            "release-groups": [{
                "id": group_id,
                "title": "Cached album",
                "primary-type": "Album",
                "secondary-types": [],
                "first-release-date": "2020"
            }]
        })
        .to_string();
        let (musicbrainz, mock) = client(vec![
            response(
                200,
                &[("etag", "\"discography-v1\"")],
                &[discography.as_str()],
                None,
            ),
            response(304, &[("etag", "\"discography-v1\"")], &[], None),
        ]);
        service
            .musicbrainz
            .set(Ok(MusicBrainz { http: musicbrainz }))
            .ok()
            .unwrap();
        let request = ArtistRefreshRequest {
            sections: vec![ArtistRefreshSection::Discography],
            language: "pt".into(),
            force: true,
        };
        service.refresh_artist(1, request.clone()).await.unwrap();
        let before = service.artist_discography(1, 10, 0).await.unwrap();
        let result = service.refresh_artist(1, request).await.unwrap();
        assert_eq!(result.sections[0].status, ArtistRefreshStatus::Unchanged);
        let after = service.artist_discography(1, 10, 0).await.unwrap();
        assert_eq!(after.catalog_generation, before.catalog_generation);
        assert_eq!(after.items, before.items);
        assert!(!after.stale);
        assert_eq!(mock.calls(), 2);
    }

    #[tokio::test(start_paused = true)]
    async fn identity_change_during_discography_fetch_returns_superseded_without_publishing() {
        let service = service();
        service
            .configure(EnrichmentSettings {
                enabled: true,
                offline: false,
                preferred_language: "pt".into(),
            })
            .await
            .unwrap();
        service
            .confirm_artist_identity(1, Some("11111111-1111-4111-8111-111111111111".into()))
            .await
            .unwrap();
        let body = serde_json::json!({
            "release-group-count": 1,
            "release-group-offset": 0,
            "release-groups": [{
                "id": "22222222-2222-4222-8222-222222222222",
                "title": "Superseded album",
                "primary-type": "Album",
                "secondary-types": [],
                "first-release-date": "2025"
            }]
        })
        .to_string();
        let mut delayed = response(200, &[], &[body.as_str()], None);
        delayed.delay = std::time::Duration::from_secs(5);
        let (musicbrainz, mock) = client(vec![delayed]);
        service
            .musicbrainz
            .set(Ok(MusicBrainz { http: musicbrainz }))
            .ok()
            .unwrap();
        let refresh_service = service.clone();
        let refresh = tokio::spawn(async move {
            refresh_service
                .refresh_artist(
                    1,
                    ArtistRefreshRequest {
                        sections: vec![ArtistRefreshSection::Discography],
                        language: "pt".into(),
                        force: true,
                    },
                )
                .await
                .unwrap()
        });
        while mock.calls() == 0 {
            tokio::task::yield_now().await;
        }
        let replacement = service
            .confirm_artist_identity(1, Some("44444444-4444-4444-8444-444444444444".into()))
            .await
            .unwrap();
        tokio::time::advance(std::time::Duration::from_secs(5)).await;
        let result = refresh.await.unwrap();
        assert_eq!(result.sections[0].status, ArtistRefreshStatus::Superseded);
        let page = service.artist_discography(1, 10, 0).await.unwrap();
        assert_eq!(page.identity_generation, replacement.generation);
        assert_eq!(page.catalog_generation, 0);
        assert!(page.items.is_empty());
    }

    #[tokio::test(start_paused = true)]
    async fn offline_refresh_keeps_published_discography_available_without_network() {
        let service = service();
        service
            .configure(EnrichmentSettings {
                enabled: true,
                offline: false,
                preferred_language: "pt".into(),
            })
            .await
            .unwrap();
        service
            .confirm_artist_identity(1, Some("11111111-1111-4111-8111-111111111111".into()))
            .await
            .unwrap();
        let body = serde_json::json!({
            "release-group-count": 1,
            "release-group-offset": 0,
            "release-groups": [{
                "id": "22222222-2222-4222-8222-222222222222",
                "title": "Offline album",
                "primary-type": "Album",
                "secondary-types": [],
                "first-release-date": "2019"
            }]
        })
        .to_string();
        let (musicbrainz, mock) = client(vec![response(200, &[], &[body.as_str()], None)]);
        service
            .musicbrainz
            .set(Ok(MusicBrainz { http: musicbrainz }))
            .ok()
            .unwrap();
        service
            .refresh_artist(
                1,
                ArtistRefreshRequest {
                    sections: vec![ArtistRefreshSection::Discography],
                    language: "pt".into(),
                    force: true,
                },
            )
            .await
            .unwrap();
        let before = service.artist_discography(1, 10, 0).await.unwrap();
        service
            .configure(EnrichmentSettings {
                enabled: true,
                offline: true,
                preferred_language: "pt".into(),
            })
            .await
            .unwrap();
        let result = service
            .refresh_artist(
                1,
                ArtistRefreshRequest {
                    sections: vec![
                        ArtistRefreshSection::Discography,
                        ArtistRefreshSection::Covers,
                    ],
                    language: "pt".into(),
                    force: true,
                },
            )
            .await
            .unwrap();
        assert!(
            result
                .sections
                .iter()
                .all(|section| section.status == ArtistRefreshStatus::Offline)
        );
        assert_eq!(mock.calls(), 1);
        assert_eq!(service.artist_discography(1, 10, 0).await.unwrap(), before);
    }

    #[tokio::test(start_paused = true)]
    async fn discography_intermediate_failure_preserves_the_active_snapshot() {
        let service = service();
        service
            .configure(EnrichmentSettings {
                enabled: true,
                offline: false,
                preferred_language: "pt".into(),
            })
            .await
            .unwrap();
        service
            .confirm_artist_identity(1, Some("11111111-1111-4111-8111-111111111111".into()))
            .await
            .unwrap();
        let group_id = "22222222-2222-4222-8222-222222222222";
        let stable = serde_json::json!({
            "release-group-count": 1,
            "release-group-offset": 0,
            "release-groups": [{
                "id": group_id,
                "title": "Stable title",
                "primary-type": "Album",
                "secondary-types": [],
                "first-release-date": "2000"
            }]
        })
        .to_string();
        let replacement_first_page = serde_json::json!({
            "release-group-count": 2,
            "release-group-offset": 0,
            "release-groups": [{
                "id": group_id,
                "title": "Unpublished title",
                "primary-type": "Album",
                "secondary-types": [],
                "first-release-date": "2020"
            }]
        })
        .to_string();
        let (musicbrainz, _) = client(vec![
            response(200, &[], &[stable.as_str()], None),
            response(200, &[], &[replacement_first_page.as_str()], None),
            response(500, &[], &[], None),
            response(500, &[], &[], None),
            response(500, &[], &[], None),
        ]);
        service
            .musicbrainz
            .set(Ok(MusicBrainz { http: musicbrainz }))
            .ok()
            .unwrap();
        let request = ArtistRefreshRequest {
            sections: vec![ArtistRefreshSection::Discography],
            language: "pt".into(),
            force: true,
        };

        service.refresh_artist(1, request.clone()).await.unwrap();
        let before = service.artist_discography(1, 10, 0).await.unwrap();
        assert_eq!(before.items[0].title, "Stable title");
        let failed = service.refresh_artist(1, request).await.unwrap();
        assert_eq!(failed.sections[0].status, ArtistRefreshStatus::Unavailable);
        let after = service.artist_discography(1, 10, 0).await.unwrap();
        assert_eq!(after.catalog_generation, before.catalog_generation);
        assert_eq!(after.items, before.items);
        assert_eq!(after.remote_total, before.remote_total);
    }

    #[tokio::test]
    async fn cancelling_discography_refresh_keeps_the_active_snapshot() {
        let service = service();
        service
            .configure(EnrichmentSettings {
                enabled: true,
                offline: false,
                preferred_language: "pt".into(),
            })
            .await
            .unwrap();
        service
            .confirm_artist_identity(1, Some("11111111-1111-4111-8111-111111111111".into()))
            .await
            .unwrap();
        let group_id = "22222222-2222-4222-8222-222222222222";
        let page = |title: &str| {
            serde_json::json!({
                "release-group-count": 1,
                "release-group-offset": 0,
                "release-groups": [{
                    "id": group_id,
                    "title": title,
                    "primary-type": "Album",
                    "secondary-types": [],
                    "first-release-date": "2000"
                }]
            })
            .to_string()
        };
        let stable = page("Stable title");
        let replacement = page("Cancelled title");
        let mut delayed = response(200, &[], &[replacement.as_str()], None);
        delayed.delay = std::time::Duration::from_secs(5);
        let (musicbrainz, mock) =
            client(vec![response(200, &[], &[stable.as_str()], None), delayed]);
        service
            .musicbrainz
            .set(Ok(MusicBrainz { http: musicbrainz }))
            .ok()
            .unwrap();
        let request = ArtistRefreshRequest {
            sections: vec![ArtistRefreshSection::Discography],
            language: "pt".into(),
            force: true,
        };
        service.refresh_artist(1, request.clone()).await.unwrap();
        let before = service.artist_discography(1, 10, 0).await.unwrap();

        let refresh_service = service.clone();
        let refresh = tokio::spawn(async move { refresh_service.refresh_artist(1, request).await });
        tokio::time::timeout(std::time::Duration::from_secs(1), async {
            while mock.calls() < 2 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        refresh.abort();
        let _ = refresh.await;
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;

        let after = service.artist_discography(1, 10, 0).await.unwrap();
        assert_eq!(after.catalog_generation, before.catalog_generation);
        assert_eq!(after.items, before.items);
    }
}
