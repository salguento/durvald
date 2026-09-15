//! Last.fm enrichment adapter.
//!
//! Provider-specific payload normalization is added by the next enrichment
//! phases. This adapter deliberately owns no credentials or HTTP client: it
//! shares the application's existing `LastFmClient`.

use crate::enrichment::models::CacheValidators;
use crate::lastfm::{LastFmClient, LastFmMetadataResponse, LastFmResult};
use std::sync::Arc;

#[derive(Clone)]
#[allow(dead_code)] // Consumed when artist.getInfo lands in the next phase.
pub struct LastFm {
    client: Arc<LastFmClient>,
}

impl LastFm {
    pub fn new(client: Arc<LastFmClient>) -> Self {
        Self { client }
    }

    #[allow(dead_code)] // Provider payload normalization is intentionally deferred.
    pub(crate) async fn metadata_json(
        &self,
        method: &str,
        parameters: &[(&str, &str)],
        validators: &CacheValidators,
    ) -> LastFmResult<LastFmMetadataResponse> {
        self.client
            .get_metadata_json(method, parameters, validators)
            .await
    }

    #[cfg(test)]
    pub(crate) fn shares_client(&self, client: &Arc<LastFmClient>) -> bool {
        Arc::ptr_eq(&self.client, client)
    }
}
