//! Last.fm use-case coordination.

use std::sync::Arc;

use crate::api::{
    AuthTokenResponse, CoreError, CoreResult, EnrichmentProvider, LastFmStatus, SessionResponse,
};
use crate::application::playback::PlaybackApplication;
use crate::enrichment::service::EnrichmentService;
use crate::lastfm::{LastFmClient, LastFmError};

pub(crate) struct LastFmApplication {
    client: Arc<LastFmClient>,
    enrichment: EnrichmentService,
    playback: Arc<PlaybackApplication>,
}

impl LastFmApplication {
    pub(crate) fn new(
        client: Arc<LastFmClient>,
        enrichment: EnrichmentService,
        playback: Arc<PlaybackApplication>,
    ) -> Self {
        Self {
            client,
            enrichment,
            playback,
        }
    }

    pub(crate) async fn status(&self) -> CoreResult<LastFmStatus> {
        let connected = self.client.is_connected().await;
        let username = if connected {
            self.client.username().await.map_err(lastfm_error)?
        } else {
            None
        };
        Ok(LastFmStatus {
            connected,
            username,
        })
    }

    pub(crate) async fn auth_token(&self) -> CoreResult<AuthTokenResponse> {
        self.client
            .get_auth_token()
            .await
            .map(|response| AuthTokenResponse {
                token: response.token,
                auth_url: response.auth_url,
            })
            .map_err(lastfm_error)
    }

    pub(crate) async fn configure(&self, api_key: String, api_secret: String) -> CoreResult<()> {
        if api_key.trim().is_empty() || api_secret.trim().is_empty() {
            return Err(CoreError::InvalidInput {
                message: "Last.fm API key and secret cannot be empty".to_string(),
            });
        }
        self.client
            .initialize_lastfm(api_key, api_secret)
            .await
            .map_err(lastfm_error)?;
        self.enrichment
            .clear_provider_failures(EnrichmentProvider::LastFm)
            .await
    }

    pub(crate) async fn complete_auth(&self, token: String) -> CoreResult<SessionResponse> {
        if token.trim().is_empty() {
            return Err(CoreError::InvalidInput {
                message: "Last.fm authorization token cannot be empty".to_string(),
            });
        }
        self.client
            .poll_session(token)
            .await
            .map(|response| SessionResponse {
                username: response.username,
            })
            .map_err(lastfm_error)
    }

    pub(crate) async fn disconnect(&self) -> CoreResult<()> {
        self.client
            .disconnect_lastfm()
            .await
            .map_err(lastfm_error)?;
        self.playback.clear_lastfm_tracking().await;
        self.enrichment
            .clear_provider_data(EnrichmentProvider::LastFm)
            .await
    }
}

pub(crate) fn lastfm_error(error: LastFmError) -> CoreError {
    let message = error.to_string();
    match error {
        LastFmError::Network(_) => CoreError::Network { message },
        LastFmError::Api { .. } => CoreError::Authentication { message },
        LastFmError::SecureStore(_) => CoreError::Storage { message },
        _ => CoreError::Network { message },
    }
}
