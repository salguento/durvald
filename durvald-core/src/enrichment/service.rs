//! Explicit, bounded identity lookups; no permanent worker or audio state.

use crate::api::*;
use crate::database::enrichment;
use crate::enrichment::policy::{normalize_language, normalized_settings};
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
    pool: Arc<r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>>,
    covers_dir: Arc<std::path::PathBuf>,
}

impl EnrichmentService {
    pub fn new(
        pool: Arc<r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>>,
        covers_dir: String,
    ) -> Self {
        Self {
            pool,
            covers_dir: Arc::new(covers_dir.into()),
            musicbrainz: Arc::new(std::sync::OnceLock::new()),
            wikidata: Arc::new(std::sync::OnceLock::new()),
            commons: Arc::new(std::sync::OnceLock::new()),
            flights: Arc::default(),
            refresh_flights: Arc::default(),
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

    pub async fn artist_identity(&self, artist_id: i64) -> CoreResult<ArtistIdentity> {
        self.database(move |conn| crate::database::identity::read(conn, artist_id))
            .await
    }

    pub async fn confirm_artist_identity(
        &self,
        artist_id: i64,
        mbid: Option<String>,
    ) -> CoreResult<ArtistIdentity> {
        self.database(move |conn| crate::database::identity::confirm(conn, artist_id, mbid))
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
            .database(move |conn| identity::candidates(conn, artist_id))
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
                    .database(move |conn| {
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
                    .database(move |conn| identity::candidates(conn, artist_id))
                    .await?;
                if !stored {
                    result.lookup_status = ArtistIdentityLookupStatus::Superseded;
                }
            }
            Err(error) => {
                result = self
                    .database(move |conn| identity::candidates(conn, artist_id))
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
        self.database(move |conn| enrichment::write_settings(conn, settings))
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

    pub async fn set_artist_override(
        &self,
        artist_id: i64,
        value: ArtistFieldOverride,
    ) -> CoreResult<()> {
        self.database(move |conn| enrichment::set_override(conn, artist_id, value))
            .await
    }

    pub async fn clear_artist_override(
        &self,
        artist_id: i64,
        field: ArtistProfileField,
        language: String,
    ) -> CoreResult<()> {
        self.database(move |conn| enrichment::clear_override(conn, artist_id, field, &language))
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
            | (u8::from(request.sections.contains(&ArtistRefreshSection::Portrait)) << 1);
        request.sections = [
            ArtistRefreshSection::Profile,
            ArtistRefreshSection::Portrait,
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
            && !request.sections.contains(&ArtistRefreshSection::Portrait)
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
        let mut results = Vec::new();
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(30);
        let profile_result = if requested_profile || requested_portrait {
            tokio::time::timeout_at(deadline, self.refresh_profile_once(&identity, &language))
                .await
                .unwrap_or(Err(super::transport::TransportError::Timeout))
        } else {
            unreachable!()
        };
        match profile_result {
            Ok(outcome) => {
                if requested_profile {
                    results.push(ArtistRefreshSectionResult {
                        section: ArtistRefreshSection::Profile,
                        status: outcome.profile_status,
                        retry_after_seconds: None,
                    });
                }
                if requested_portrait {
                    let (status, retry_after_seconds) = match outcome.commons_file {
                        Some(filename) => {
                            let portrait = tokio::time::timeout_at(
                                deadline,
                                self.refresh_portrait_once(
                                    identity.artist_id,
                                    identity.generation,
                                    &filename,
                                ),
                            )
                            .await
                            .unwrap_or(Err(super::transport::TransportError::Timeout));
                            match portrait {
                                Ok(status) => (status, None),
                                Err(error) => refresh_transport_error(&error),
                            }
                        }
                        None => (ArtistRefreshStatus::NotFound, None),
                    };
                    results.push(ArtistRefreshSectionResult {
                        section: ArtistRefreshSection::Portrait,
                        status,
                        retry_after_seconds,
                    });
                }
            }
            Err(error) => {
                let (status, retry) = refresh_transport_error(&error);
                for section in request.sections {
                    results.push(ArtistRefreshSectionResult {
                        section,
                        status,
                        retry_after_seconds: retry,
                    });
                }
            }
        }
        Ok(ArtistRefreshResult {
            artist_id,
            identity_generation: identity.generation,
            sections: results,
        })
    }

    async fn refresh_profile_once(
        &self,
        identity: &ArtistIdentity,
        language: &str,
    ) -> Result<ProfileRefreshOutcome, super::transport::TransportError> {
        use super::models::ProfileSnapshot;
        use super::policy::PROFILE_TTL;
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
            .map_err(|_| TransportError::Network)?;
        let qid = if let Some(qid) = cached_qid {
            qid
        } else {
            let musicbrainz = self
                .musicbrainz
                .get_or_init(super::providers::musicbrainz::MusicBrainz::new)
                .as_ref()
                .map_err(|_| TransportError::Configuration)?;
            let Some(qid) = musicbrainz.wikidata_id(mbid).await? else {
                return Ok(ProfileRefreshOutcome {
                    profile_status: ArtistRefreshStatus::NotFound,
                    commons_file: None,
                });
            };
            let stored_qid = qid.clone();
            let stored = self
                .database(move |conn| {
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
                .map_err(|_| TransportError::Network)?;
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
            .map_err(|_| TransportError::Network)?
            .unwrap_or_default();
        let response = wikidata.profile(&qid, language, &cached_validators).await?;
        let now = chrono::Utc::now().timestamp();
        let expires_at = now.saturating_add(PROFILE_TTL.as_secs() as i64);
        if let super::models::ProviderResponse::NotModified { validators } = response {
            let touched = self
                .database(move |conn| {
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
                .map_err(|_| TransportError::Network)?;
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
                .map_err(|_| TransportError::Network)?;
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
                .map_err(|_| TransportError::Network)?
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
            .database(move |conn| enrichment::store_profile(conn, &snapshot))
            .await
            .map_err(|_| TransportError::Network)?;
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
            .database(move |conn| {
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
            .map_err(|_| TransportError::Network)?;
        let stored_commons = commons_file.clone();
        let targets_current = self
            .database(move |conn| {
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
            .map_err(|_| TransportError::Network)?;
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

    async fn refresh_wikipedia_once(
        &self,
        artist_id: i64,
        generation: u64,
        language: String,
        title: String,
        fetched_at: i64,
        expires_at: i64,
    ) -> Result<ArtistRefreshStatus, super::transport::TransportError> {
        use super::models::{ProfileSnapshot, ProviderResponse};
        use super::transport::TransportError;
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
            .map_err(|_| TransportError::Network)?
            .unwrap_or_default();
        let wikipedia = super::providers::wikipedia::Wikipedia::new(&language)?;
        match wikipedia
            .introduction(&title, &language, &validators)
            .await?
        {
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
                        .database(move |conn| enrichment::store_profile(conn, &snapshot))
                        .await
                        .map_err(|_| TransportError::Network)?
                    {
                        ArtistRefreshStatus::Updated
                    } else {
                        ArtistRefreshStatus::Superseded
                    },
                )
            }
            ProviderResponse::NotModified { validators } => Ok(
                if self
                    .database(move |conn| {
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
                    .map_err(|_| TransportError::Network)?
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
    ) -> Result<ArtistRefreshStatus, super::transport::TransportError> {
        use super::models::AssetSnapshot;
        use super::policy::PROFILE_TTL;
        use super::transport::TransportError;
        let commons = self
            .commons
            .get_or_init(super::providers::commons::Commons::new)
            .as_ref()
            .map_err(|_| TransportError::Configuration)?;
        let metadata = commons.metadata(filename).await?;
        let bytes = commons.download(&metadata.download_url).await?;
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
            .map_err(|_| TransportError::Network)?;
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
            .database(move |conn| enrichment::store_asset(conn, &snapshot))
            .await
            .map_err(|_| TransportError::Network)?
        {
            if let Some(previous_path) =
                previous_path.filter(|path| path != managed_path.to_string_lossy().as_ref())
            {
                let check_path = previous_path.clone();
                let referenced = self
                    .database(move |conn| enrichment::path_is_referenced(conn, &check_path))
                    .await
                    .map_err(|_| TransportError::Network)?;
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
                .map_err(|_| TransportError::Network)?;
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
        let paths = self.database(enrichment::collect_stale_asset_paths).await?;
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
            .map(|section| ArtistRefreshSectionResult {
                section,
                status,
                retry_after_seconds,
            })
            .collect(),
    }
}

fn refresh_transport_error(
    error: &super::transport::TransportError,
) -> (ArtistRefreshStatus, Option<u64>) {
    use super::transport::TransportError;
    match error {
        TransportError::RateLimited {
            retry_after_seconds,
        } => (ArtistRefreshStatus::RateLimited, Some(*retry_after_seconds)),
        TransportError::HttpStatus { status: 404, .. } => (ArtistRefreshStatus::NotFound, None),
        TransportError::HttpStatus {
            retry_after_seconds,
            ..
        } => (ArtistRefreshStatus::Unavailable, *retry_after_seconds),
        _ => (ArtistRefreshStatus::Unavailable, None),
    }
}

#[cfg(test)]
mod tests {
    use super::super::{
        providers::{commons::Commons, musicbrainz::MusicBrainz, wikidata::Wikidata},
        transport::{EnrichmentHttpClient, tests::client, tests::response, tests::response_bytes},
    };
    use super::*;
    use std::io::Cursor;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

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
        )
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
}
