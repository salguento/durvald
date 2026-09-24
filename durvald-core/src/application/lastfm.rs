//! Last.fm use-case coordination.

use std::sync::Arc;

use crate::api::{AuthTokenResponse, CoreError, CoreResult, LastFmStatus};
use crate::lastfm::{LastFmClient, LastFmError};

pub(crate) struct LastFmApplication {
    client: Arc<LastFmClient>,
}

impl LastFmApplication {
    pub(crate) fn new(client: Arc<LastFmClient>) -> Self {
        Self { client }
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
}

pub(crate) fn lastfm_error(error: LastFmError) -> CoreError {
    let message = error.to_string();
    match error {
        LastFmError::Network(_) | LastFmError::RateLimit(_) => CoreError::Network { message },
        LastFmError::NotConnected | LastFmError::Api { .. } => {
            CoreError::Authentication { message }
        }
        LastFmError::SecureStore(_) => CoreError::Storage { message },
        _ => CoreError::Network { message },
    }
}
