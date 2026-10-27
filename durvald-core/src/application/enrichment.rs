//! Enrichment use-case coordination.

use std::sync::Arc;

use crate::api::{
    ArtistDetails, ArtistDiscographyPage, ArtistFieldOverride, ArtistIdentity,
    ArtistIdentityCandidates, ArtistPopularTracks, ArtistProfileField, ArtistRefreshRequest,
    ArtistRefreshResult, CoreError, CoreResult, EnrichmentProvider, EnrichmentSettings,
    ExternalReleaseDetails, Release, RemoteArtistSelection,
};
use crate::application::library::LibraryApplication;
use crate::domain::ids::ArtistId;
use crate::enrichment::service::EnrichmentService;

const MAX_PAGE_SIZE: u64 = 200;

pub(crate) struct EnrichmentApplication {
    service: EnrichmentService,
    library: Arc<LibraryApplication>,
}

impl EnrichmentApplication {
    pub(crate) fn new(service: EnrichmentService, library: Arc<LibraryApplication>) -> Self {
        Self { service, library }
    }

    pub(crate) async fn artist_details(
        &self,
        artist_id: ArtistId,
        language: String,
    ) -> CoreResult<ArtistDetails> {
        self.service
            .artist_details(artist_id.get() as i64, language)
            .await
    }

    pub(crate) async fn artist_discography(
        &self,
        artist_id: ArtistId,
        page_size: u64,
        offset: u64,
    ) -> CoreResult<ArtistDiscographyPage> {
        let page_size = bounded_page_size(page_size, offset)?;
        self.service
            .artist_discography(artist_id.get() as i64, page_size, offset)
            .await
    }

    pub(crate) async fn artist_popular_tracks(
        &self,
        artist_id: ArtistId,
    ) -> CoreResult<Option<ArtistPopularTracks>> {
        self.service
            .artist_popular_tracks(artist_id.get() as i64)
            .await
    }

    pub(crate) async fn external_release_details(
        &self,
        artist_id: ArtistId,
        release_group_mbid: String,
    ) -> CoreResult<ExternalReleaseDetails> {
        self.service
            .external_release_details(artist_id.get() as i64, release_group_mbid)
            .await
    }

    pub(crate) async fn artist_identity(&self, artist_id: ArtistId) -> CoreResult<ArtistIdentity> {
        self.service.artist_identity(artist_id.get() as i64).await
    }

    pub(crate) async fn materialize_remote_artist(
        &self,
        selection: RemoteArtistSelection,
    ) -> CoreResult<crate::api::Artist> {
        let artist_id = self.service.materialize_remote_artist(selection).await?;
        let artist_id = ArtistId::try_from(artist_id).map_err(|_| CoreError::Storage {
            message: "Materialized artist has an invalid ID".into(),
        })?;
        self.library.artist(artist_id).await
    }

    pub(crate) async fn resolve_artist_candidates(
        &self,
        artist_id: ArtistId,
    ) -> CoreResult<ArtistIdentityCandidates> {
        self.service
            .resolve_artist_candidates(artist_id.get() as i64)
            .await
    }

    pub(crate) async fn confirm_artist_identity(
        &self,
        artist_id: ArtistId,
        musicbrainz_id: String,
    ) -> CoreResult<ArtistIdentity> {
        self.service
            .confirm_artist_identity(artist_id.get() as i64, Some(musicbrainz_id))
            .await
    }

    pub(crate) async fn clear_artist_identity(&self, artist_id: ArtistId) -> CoreResult<()> {
        self.service
            .confirm_artist_identity(artist_id.get() as i64, None)
            .await
            .map(|_| ())
    }

    pub(crate) async fn set_artist_override(
        &self,
        artist_id: ArtistId,
        value: ArtistFieldOverride,
    ) -> CoreResult<()> {
        self.service
            .set_artist_override(artist_id.get() as i64, value)
            .await
    }

    pub(crate) async fn clear_artist_override(
        &self,
        artist_id: ArtistId,
        field: ArtistProfileField,
        language: String,
    ) -> CoreResult<()> {
        self.service
            .clear_artist_override(artist_id.get() as i64, field, language)
            .await
    }

    pub(crate) async fn settings(&self) -> CoreResult<EnrichmentSettings> {
        self.service.settings().await
    }

    pub(crate) async fn configure(&self, settings: EnrichmentSettings) -> CoreResult<()> {
        self.service.configure(settings).await
    }

    pub(crate) async fn clear_provider_data(&self, provider: EnrichmentProvider) -> CoreResult<()> {
        self.service.clear_provider_data(provider).await?;
        if provider == EnrichmentProvider::MusicBrainz {
            self.library.clear_artist_news_provider().await?;
        }
        Ok(())
    }

    pub(crate) async fn refresh_artist_news(
        &self,
        artist_id: ArtistId,
        force: bool,
    ) -> CoreResult<ArtistRefreshResult> {
        use crate::api::{ArtistRefreshSection, ArtistRefreshStatus};
        let id = artist_id.get() as i64;
        let identity = self.service.artist_identity(id).await?;
        let followed = self
            .library
            .followed_artists()
            .await?
            .into_iter()
            .find(|f| f.artist.id == id)
            .ok_or_else(|| CoreError::InvalidInput {
                message: "Artist is not followed".into(),
            })?;
        let now = chrono::Utc::now().timestamp();
        if !force && followed.next_refresh_at.is_some_and(|t| now < t) {
            return Ok(ArtistRefreshResult {
                artist_id: id,
                identity_generation: identity.generation,
                sections: vec![crate::api::ArtistRefreshSectionResult {
                    section: ArtistRefreshSection::Discography,
                    status: followed.status.unwrap_or(ArtistRefreshStatus::Unchanged),
                    retry_after_seconds: None,
                    cover_progress: None,
                    diagnostic: None,
                    provider: Some(EnrichmentProvider::MusicBrainz),
                }],
            });
        }
        let generation = followed.generation;
        let identity_generation = identity.generation;
        // News checks revalidate at most daily, while ordinary discography
        // browsing can retain its longer TTL. The shared transport still owns
        // validators, per-provider gates, cooldowns and bounded cursors.
        let revalidate = force || followed.last_success_at.is_some_and(|t| now - t >= 86_400);
        let request = ArtistRefreshRequest {
            sections: vec![ArtistRefreshSection::Discography],
            language: "pt".into(),
            force: revalidate,
        };
        let refresh = self.service.refresh_artist(id, request);
        tokio::pin!(refresh);
        let result = loop {
            tokio::select! {
                result=&mut refresh=>break result,
                _=tokio::time::sleep(std::time::Duration::from_millis(250))=> {
                    let valid=self.library.artist_news_refresh_current(id,generation,identity_generation).await?;
                    if !valid {return Ok(ArtistRefreshResult{artist_id:id,identity_generation,sections:vec![crate::api::ArtistRefreshSectionResult{
                        section:ArtistRefreshSection::Discography,status:ArtistRefreshStatus::Superseded,retry_after_seconds:None,cover_progress:None,diagnostic:None,provider:Some(EnrichmentProvider::MusicBrainz)}]});}
                }
            }
        };
        let (status, retry) = result
            .as_ref()
            .ok()
            .and_then(|r| r.sections.first())
            .map(|r| (r.status, r.retry_after_seconds))
            .unwrap_or((ArtistRefreshStatus::Unavailable, None));
        let accepted = self
            .library
            .finish_artist_news_refresh(id, generation, identity_generation, status, retry)
            .await?;
        if !accepted {
            return Ok(ArtistRefreshResult {
                artist_id: id,
                identity_generation,
                sections: vec![crate::api::ArtistRefreshSectionResult {
                    section: ArtistRefreshSection::Discography,
                    status: ArtistRefreshStatus::Superseded,
                    retry_after_seconds: None,
                    cover_progress: None,
                    diagnostic: None,
                    provider: Some(EnrichmentProvider::MusicBrainz),
                }],
            });
        }
        result
    }

    pub(crate) async fn refresh_artist(
        &self,
        artist_id: ArtistId,
        request: ArtistRefreshRequest,
    ) -> CoreResult<ArtistRefreshResult> {
        self.service
            .refresh_artist(artist_id.get() as i64, request)
            .await
    }

    pub(crate) async fn sync_artist_release_metadata(
        &self,
        artist_id: ArtistId,
    ) -> CoreResult<Vec<Release>> {
        self.service
            .sync_local_release_metadata(artist_id.get() as i64)
            .await?;
        self.library.artist_releases(artist_id).await
    }
}

fn bounded_page_size(page_size: u64, offset: u64) -> CoreResult<u64> {
    if page_size == 0 {
        return Err(CoreError::InvalidInput {
            message: "Page size must be greater than zero".to_string(),
        });
    }
    if offset > i64::MAX as u64 {
        return Err(CoreError::InvalidInput {
            message: "Page offset is too large".to_string(),
        });
    }
    Ok(page_size.min(MAX_PAGE_SIZE))
}
