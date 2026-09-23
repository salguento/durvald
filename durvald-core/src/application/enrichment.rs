//! Enrichment use-case coordination.

use crate::api::{
    ArtistDetails, ArtistDiscographyPage, ArtistIdentity, ArtistIdentityCandidates,
    ArtistPopularTracks, CoreError, CoreResult, EnrichmentSettings, ExternalReleaseDetails,
};
use crate::enrichment::service::EnrichmentService;

const MAX_PAGE_SIZE: u64 = 200;

pub(crate) struct EnrichmentApplication {
    service: EnrichmentService,
}

impl EnrichmentApplication {
    pub(crate) fn new(service: EnrichmentService) -> Self {
        Self { service }
    }

    pub(crate) async fn artist_details(
        &self,
        artist_id: i64,
        language: String,
    ) -> CoreResult<ArtistDetails> {
        self.service.artist_details(artist_id, language).await
    }

    pub(crate) async fn artist_discography(
        &self,
        artist_id: i64,
        page_size: u64,
        offset: u64,
    ) -> CoreResult<ArtistDiscographyPage> {
        non_negative_id(artist_id, "Artist ID")?;
        let page_size = bounded_page_size(page_size, offset)?;
        self.service
            .artist_discography(artist_id, page_size, offset)
            .await
    }

    pub(crate) async fn artist_popular_tracks(
        &self,
        artist_id: i64,
    ) -> CoreResult<Option<ArtistPopularTracks>> {
        non_negative_id(artist_id, "Artist ID")?;
        self.service.artist_popular_tracks(artist_id).await
    }

    pub(crate) async fn external_release_details(
        &self,
        artist_id: i64,
        release_group_mbid: String,
    ) -> CoreResult<ExternalReleaseDetails> {
        non_negative_id(artist_id, "Artist ID")?;
        self.service
            .external_release_details(artist_id, release_group_mbid)
            .await
    }

    pub(crate) async fn artist_identity(&self, artist_id: i64) -> CoreResult<ArtistIdentity> {
        self.service.artist_identity(artist_id).await
    }

    pub(crate) async fn resolve_artist_candidates(
        &self,
        artist_id: i64,
    ) -> CoreResult<ArtistIdentityCandidates> {
        self.service.resolve_artist_candidates(artist_id).await
    }

    pub(crate) async fn settings(&self) -> CoreResult<EnrichmentSettings> {
        self.service.settings().await
    }
}

fn non_negative_id(value: i64, label: &str) -> CoreResult<u64> {
    u64::try_from(value).map_err(|_| CoreError::InvalidInput {
        message: format!("{label} must not be negative"),
    })
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
