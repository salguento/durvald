//! Last.fm integration module

use crate::secure_store::{SecureStore, SecureStoreError};
use md5::{Digest, Md5};
use reqwest::Client;
use serde::Serialize;
use serde_json::Value;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use thiserror::Error;
use tokio::sync::Mutex;

#[derive(Error, Debug)]
pub enum LastFmError {
    #[error("Network error: {0}")]
    Network(#[from] reqwest::Error),
    #[error("JSON parse error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("Secure store error: {0}")]
    SecureStore(#[from] SecureStoreError),
    #[error("Rate limit error: {0}")]
    RateLimit(String),
    #[error("Last.fm API error {code}: {message}")]
    Api { code: i64, message: String },
    #[error("Time error: {0}")]
    Time(String),
    #[error("Not connected")]
    NotConnected,
    #[error("{0}")]
    Custom(String),
}

pub type LastFmResult<T> = Result<T, LastFmError>;

const LASTFM_API_ENDPOINT: &str = "https://ws.audioscrobbler.com/2.0/";

#[cfg(any(test, debug_assertions))]
fn api_key_diagnostic(api_key: &str) -> String {
    if api_key.trim().is_empty() {
        "Store is missing an API key".to_string()
    } else {
        "Store OK. API key configured".to_string()
    }
}

#[cfg(any(test, debug_assertions))]
fn credentials_diagnostic(api_key: &str, api_secret: &str) -> String {
    if api_key.trim().is_empty() || api_secret.trim().is_empty() {
        "Last.fm credentials are incomplete".to_string()
    } else {
        "Last.fm credentials are configured".to_string()
    }
}

fn api_error_from_response(response: &Value) -> Option<LastFmError> {
    response["error"].as_i64().map(|code| LastFmError::Api {
        code,
        message: response["message"]
            .as_str()
            .unwrap_or("Unknown error")
            .to_string(),
    })
}

fn require_api_success(response: &Value) -> LastFmResult<()> {
    match api_error_from_response(response) {
        Some(error) => Err(error),
        None => Ok(()),
    }
}

// ✅ Lock-free rate limiter: enforces Last.fm's 1 request/second limit
static LAST_REQUEST_MS: AtomicU64 = AtomicU64::new(0);

async fn enforce_rate_limit() -> LastFmResult<()> {
    loop {
        let now_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|e| LastFmError::Time(format!("Time error: {}", e)))?
            .as_millis() as u64;

        let last_ms = LAST_REQUEST_MS.load(Ordering::SeqCst);
        let elapsed_ms = now_ms.saturating_sub(last_ms);

        if elapsed_ms >= 1000 {
            if LAST_REQUEST_MS
                .compare_exchange(last_ms, now_ms, Ordering::SeqCst, Ordering::SeqCst)
                .is_ok()
            {
                return Ok(());
            }
        } else {
            let wait_ms = 1000 - elapsed_ms;
            tokio::time::sleep(Duration::from_millis(wait_ms)).await;
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AuthTokenResponse {
    pub token: String,
    pub auth_url: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionResponse {
    pub username: String,
}

pub struct LastFmClient {
    secure_store: Arc<Mutex<SecureStore>>,
    client: Client,
    #[cfg(test)]
    test_credentials: Option<TestCredentials>,
    #[cfg(test)]
    test_transport: Option<Arc<TestTransport>>,
}

#[cfg(test)]
struct TestCredentials {
    api_key: String,
    api_secret: String,
    session_key: String,
}

#[cfg(test)]
struct TestTransport {
    response: Value,
    forms: std::sync::Mutex<Vec<Vec<(String, String)>>>,
}

impl LastFmClient {
    pub fn new(secure_store: Arc<Mutex<SecureStore>>) -> Self {
        Self {
            secure_store,
            client: Client::new(),
            #[cfg(test)]
            test_credentials: None,
            #[cfg(test)]
            test_transport: None,
        }
    }

    #[cfg(test)]
    fn with_test_transport(
        secure_store: Arc<Mutex<SecureStore>>,
        response: Value,
    ) -> (Self, Arc<TestTransport>) {
        let transport = Arc::new(TestTransport {
            response,
            forms: std::sync::Mutex::new(Vec::new()),
        });
        let client = Self {
            secure_store,
            client: Client::new(),
            test_credentials: Some(TestCredentials {
                api_key: "test-api-key".to_string(),
                api_secret: "test-api-secret".to_string(),
                session_key: "test-session-key".to_string(),
            }),
            test_transport: Some(transport.clone()),
        };
        (client, transport)
    }

    async fn post_form(&self, form: &[(&str, &str)]) -> LastFmResult<Value> {
        #[cfg(test)]
        if let Some(transport) = &self.test_transport {
            transport.forms.lock().unwrap().push(
                form.iter()
                    .map(|(key, value)| ((*key).to_string(), (*value).to_string()))
                    .collect(),
            );
            return Ok(transport.response.clone());
        }

        let response = self
            .client
            .post(LASTFM_API_ENDPOINT)
            .form(form)
            .send()
            .await?;
        let text = response.text().await?;
        Ok(serde_json::from_str(&text)?)
    }

    fn get_api_secret(&self) -> LastFmResult<String> {
        #[cfg(test)]
        if let Some(credentials) = &self.test_credentials {
            return Ok(credentials.api_secret.clone());
        }
        let store = self.secure_store.blocking_lock();
        store
            .get_secret("api_secret")
            .map_err(LastFmError::SecureStore)
    }

    fn get_api_key(&self) -> LastFmResult<String> {
        #[cfg(test)]
        if let Some(credentials) = &self.test_credentials {
            return Ok(credentials.api_key.clone());
        }
        let store = self.secure_store.blocking_lock();
        store
            .get("api_key")
            .and_then(|v| v.as_str().map(String::from))
            .ok_or_else(|| {
                LastFmError::SecureStore(SecureStoreError::Custom(
                    "API key not configured".to_string(),
                ))
            })
    }

    fn get_session_key(&self) -> LastFmResult<String> {
        #[cfg(test)]
        if let Some(credentials) = &self.test_credentials {
            return Ok(credentials.session_key.clone());
        }
        let store = self.secure_store.blocking_lock();
        store
            .get_secret("session_key")
            .map_err(LastFmError::SecureStore)
    }

    fn generate_signature(params: &[(&str, &str)], secret: &str) -> String {
        let mut sorted_params: Vec<(&str, &str)> = params.to_vec();
        sorted_params.sort_by(|a, b| a.0.cmp(b.0));

        let mut sig_string = String::new();
        for (key, value) in sorted_params {
            sig_string.push_str(key);
            sig_string.push_str(value);
        }
        sig_string.push_str(secret);

        let digest = Md5::new().chain_update(sig_string.as_bytes()).finalize();
        format!("{:x}", digest)
    }

    pub async fn initialize_lastfm(&self, api_key: String, api_secret: String) -> LastFmResult<()> {
        let store = self.secure_store.lock().await;
        let credentials_changed = store
            .get("api_key")
            .and_then(|value| value.as_str().map(str::to_owned))
            .as_deref()
            != Some(api_key.as_str())
            || store
                .get_secret("api_secret")
                .map(|stored_secret| stored_secret != api_secret.as_str())
                .unwrap_or(true);

        if credentials_changed {
            if store.get_secret("session_key").is_ok() {
                store
                    .delete_secret("session_key")
                    .map_err(LastFmError::SecureStore)?;
            }
            store.delete("username");
        }
        store.set("api_key".into(), api_key.into());
        store
            .set_secret("api_secret", &api_secret)
            .map_err(LastFmError::SecureStore)?;
        store.save_data().map_err(LastFmError::SecureStore)?;
        Ok(())
    }

    pub async fn verify_credentials(&self) -> LastFmResult<String> {
        let store = self.secure_store.lock().await;
        let api_key = store
            .get("api_key")
            .and_then(|v| v.as_str().map(String::from))
            .ok_or_else(|| {
                LastFmError::SecureStore(SecureStoreError::Custom("API key not found".to_string()))
            })?;

        let secret = store
            .get_secret("api_secret")
            .map_err(LastFmError::SecureStore)?;

        if api_key.trim().is_empty() || secret.trim().is_empty() {
            return Err(LastFmError::Custom(
                "Last.fm credentials are empty".to_string(),
            ));
        }
        Ok("Last.fm credentials are configured".to_string())
    }

    pub async fn get_auth_token(&self) -> LastFmResult<AuthTokenResponse> {
        enforce_rate_limit().await?;

        let api_key = self.get_api_key()?;
        let secret = self.get_api_secret()?;

        let params = vec![("method", "auth.getToken"), ("api_key", &api_key)];
        let sig = Self::generate_signature(&params, &secret);

        let json = self
            .post_form(&[
                ("method", "auth.getToken"),
                ("api_key", &api_key),
                ("api_sig", &sig),
                ("format", "json"),
            ])
            .await?;

        require_api_success(&json)?;
        let token = json["token"].as_str().ok_or_else(|| {
            LastFmError::Custom("Last.fm response did not include a token".into())
        })?;
        Ok(AuthTokenResponse {
            token: token.to_string(),
            auth_url: format!(
                "https://www.last.fm/api/auth/?api_key={}&token={}",
                api_key, token
            ),
        })
    }

    pub async fn poll_session(&self, token: String) -> LastFmResult<SessionResponse> {
        enforce_rate_limit().await?;

        let api_key = self.get_api_key()?;
        let secret = self.get_api_secret()?;

        let mut params = vec![
            ("api_key", api_key.as_str()),
            ("method", "auth.getSession"),
            ("token", token.as_str()),
        ];
        params.sort_by(|a, b| a.0.cmp(b.0));
        let sig = Self::generate_signature(&params, &secret);

        let json = self
            .post_form(&[
                ("method", "auth.getSession"),
                ("api_key", &api_key),
                ("token", &token),
                ("api_sig", &sig),
                ("format", "json"),
            ])
            .await?;

        require_api_success(&json)?;

        let session = json["session"]
            .as_object()
            .ok_or_else(|| LastFmError::Custom("No session object".to_string()))?;
        let username = session["name"]
            .as_str()
            .ok_or_else(|| LastFmError::Custom("No username".to_string()))?
            .to_string();
        let session_key = session["key"]
            .as_str()
            .ok_or_else(|| LastFmError::Custom("No session key".to_string()))?
            .to_string();

        #[cfg(test)]
        if self.test_credentials.is_some() {
            return Ok(SessionResponse { username });
        }

        let store = self.secure_store.lock().await;
        store
            .set_secret("session_key", &session_key)
            .map_err(LastFmError::SecureStore)?;
        store.set("username".into(), username.clone().into());
        store.save_data().map_err(LastFmError::SecureStore)?;

        Ok(SessionResponse { username })
    }

    pub async fn update_now_playing(
        &self,
        artist: String,
        track: String,
        album: Option<String>,
    ) -> LastFmResult<()> {
        // ✅ Trim inputs (signature is whitespace-sensitive)
        let artist = artist.trim().to_string();
        let track = track.trim().to_string();
        if artist.is_empty() || track.is_empty() {
            return Err(LastFmError::Custom(
                "Last.fm artist and track cannot be empty".to_string(),
            ));
        }
        let album = album.and_then(|a| {
            let trimmed = a.trim().to_string();
            if trimmed.is_empty() {
                None
            } else {
                Some(trimmed)
            }
        });

        enforce_rate_limit().await?;

        let session_key = self.get_session_key()?;
        let api_key = self.get_api_key()?;
        let secret = self.get_api_secret()?;

        // ✅ CRITICAL FIX: Signature params EXCLUDE 'format' (Last.fm auth spec requirement)
        let mut params = vec![
            ("api_key", api_key.as_str()),
            ("artist", &artist),
            ("method", "track.updateNowPlaying"),
            ("sk", session_key.as_str()),
            ("track", &track),
        ];

        if let Some(ref a) = album {
            params.push(("album", a.as_str()));
        }

        // Sort alphabetically (Last.fm requirement)
        params.sort_by(|a, b| a.0.cmp(b.0));
        let sig = Self::generate_signature(&params, &secret);

        // ✅ 'format' ONLY in POST body (NOT in signature params)
        let mut form = vec![
            ("method", "track.updateNowPlaying"),
            ("api_key", &api_key),
            ("api_sig", &sig),
            ("sk", &session_key),
            ("artist", &artist),
            ("track", &track),
            ("format", "json"), // ← ONLY in POST body to get JSON response
        ];

        if let Some(ref a) = album {
            form.push(("album", a));
        }

        let json = self.post_form(&form).await?;

        require_api_success(&json)?;

        Ok(())
    }

    pub async fn scrobble_track(
        &self,
        artist: String,
        track: String,
        album: Option<String>,
        timestamp: u64,
    ) -> LastFmResult<()> {
        let artist = artist.trim().to_string();
        let track = track.trim().to_string();
        if artist.is_empty() || track.is_empty() {
            return Err(LastFmError::Custom(
                "Last.fm artist and track cannot be empty".to_string(),
            ));
        }
        let album = album.and_then(|a| {
            let trimmed = a.trim().to_string();
            if trimmed.is_empty() {
                None
            } else {
                Some(trimmed)
            }
        });
        let timestamp_str = timestamp.to_string();

        enforce_rate_limit().await?;

        let session_key = self.get_session_key()?;
        let api_key = self.get_api_key()?;
        let secret = self.get_api_secret()?;

        // ✅ CRITICAL FIX: Signature params EXCLUDE 'format'
        let mut params = vec![
            ("api_key", api_key.as_str()),
            ("artist", &artist),
            ("method", "track.scrobble"),
            ("sk", session_key.as_str()),
            ("timestamp", &timestamp_str),
            ("track", &track),
        ];

        if let Some(ref a) = album {
            params.push(("album", a.as_str()));
        }

        params.sort_by(|a, b| a.0.cmp(b.0));
        let sig = Self::generate_signature(&params, &secret);

        // ✅ 'format' ONLY in POST body
        let mut form = vec![
            ("method", "track.scrobble"),
            ("api_key", &api_key),
            ("api_sig", &sig),
            ("sk", &session_key),
            ("artist", &artist),
            ("track", &track),
            ("timestamp", &timestamp_str),
            ("format", "json"), // ← ONLY in POST body
        ];

        if let Some(ref a) = album {
            form.push(("album", a));
        }

        let json = self.post_form(&form).await?;

        require_api_success(&json)?;

        Ok(())
    }

    pub async fn is_connected(&self) -> bool {
        let store = self.secure_store.lock().await;
        store.get_secret("session_key").is_ok()
    }

    /// Returns the locally persisted Last.fm username, if the account has
    /// completed the authorization flow.
    pub async fn username(&self) -> Option<String> {
        let store = self.secure_store.lock().await;
        store
            .get("username")
            .and_then(|value| value.as_str().map(str::to_owned))
    }

    pub async fn disconnect_lastfm(&self) -> LastFmResult<()> {
        let store = self.secure_store.lock().await;
        let _ = store.delete_secret("session_key");
        store.delete("username");
        store.save_data().map_err(LastFmError::SecureStore)?;
        Ok(())
    }

    #[cfg(debug_assertions)]
    pub async fn debug_store(&self) -> LastFmResult<String> {
        let store = self.secure_store.lock().await;
        store
            .get("api_key")
            .and_then(|v| v.as_str().map(String::from))
            .map(|key| api_key_diagnostic(&key))
            .ok_or_else(|| {
                LastFmError::SecureStore(SecureStoreError::Custom("API key not found".to_string()))
            })
    }

    #[cfg(debug_assertions)]
    pub async fn debug_session(&self) -> LastFmResult<String> {
        let store = self.secure_store.lock().await;
        match store.get_secret("session_key") {
            Ok(key) => Ok(format!("Session key found ({} chars)", key.len())),
            Err(e) => Ok(format!("Session key not found: {}", e)),
        }
    }

    #[cfg(debug_assertions)]
    pub async fn debug_credentials(&self) -> LastFmResult<String> {
        let api_key = self.get_api_key()?;
        let secret = self.get_api_secret()?;
        Ok(credentials_diagnostic(&api_key, &secret))
    }
}

use std::sync::Arc;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn credential_diagnostics_never_reveal_credential_contents() {
        let api_key = "public-api-key-123";
        let secret = "private-secret-456";
        let store_message = api_key_diagnostic(api_key);
        let credentials_message = credentials_diagnostic(api_key, secret);

        assert_eq!(store_message, "Store OK. API key configured");
        assert_eq!(credentials_message, "Last.fm credentials are configured");
        assert!(!store_message.contains(api_key));
        assert!(!credentials_message.contains(api_key));
        assert!(!credentials_message.contains(secret));
    }

    #[test]
    fn api_errors_are_preserved_consistently_across_response_types() {
        let response = serde_json::json!({
            "error": 9,
            "message": "Invalid session key"
        });
        assert!(matches!(
            require_api_success(&response),
            Err(LastFmError::Api { code: 9, ref message }) if message == "Invalid session key"
        ));

        assert!(require_api_success(&serde_json::json!({"token": "token"})).is_ok());
        assert!(api_error_from_response(&serde_json::json!({"error": 6})).is_some());
    }

    #[tokio::test]
    async fn auth_token_request_uses_an_in_process_transport_mock() {
        LAST_REQUEST_MS.store(0, Ordering::SeqCst);
        let directory = std::env::temp_dir().join(format!(
            "durvald-lastfm-http-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let store = SecureStore::new(directory.clone(), "durvald-test".to_string()).unwrap();
        let (client, transport) = LastFmClient::with_test_transport(
            Arc::new(Mutex::new(store)),
            serde_json::json!({"token": "mock-token"}),
        );
        let response = client.get_auth_token().await.expect("get mock token");

        assert_eq!(response.token, "mock-token");
        assert!(response.auth_url.contains("api_key=test-api-key"));
        let forms = transport.forms.lock().unwrap();
        assert_eq!(forms.len(), 1);
        assert!(forms[0].contains(&("method".to_string(), "auth.getToken".to_string())));
        assert!(forms[0].contains(&("api_key".to_string(), "test-api-key".to_string())));
        assert!(forms[0].iter().any(|(key, _)| key == "api_sig"));
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[tokio::test]
    async fn now_playing_request_is_normalized_and_signed_before_dispatch() {
        LAST_REQUEST_MS.store(0, Ordering::SeqCst);
        let directory = std::env::temp_dir().join(format!(
            "durvald-lastfm-now-playing-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let store = SecureStore::new(directory.clone(), "durvald-test".to_string()).unwrap();
        let (client, transport) =
            LastFmClient::with_test_transport(Arc::new(Mutex::new(store)), serde_json::json!({}));

        client
            .update_now_playing(
                " Artist ".to_string(),
                " Track ".to_string(),
                Some(" Album ".to_string()),
            )
            .await
            .expect("send now-playing request");

        let forms = transport.forms.lock().unwrap();
        assert_eq!(forms.len(), 1);
        let form = &forms[0];
        assert!(form.contains(&("method".to_string(), "track.updateNowPlaying".to_string())));
        assert!(form.contains(&("artist".to_string(), "Artist".to_string())));
        assert!(form.contains(&("track".to_string(), "Track".to_string())));
        assert!(form.contains(&("album".to_string(), "Album".to_string())));
        assert!(form.contains(&("sk".to_string(), "test-session-key".to_string())));
        assert!(form.iter().any(|(key, _)| key == "api_sig"));
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[tokio::test]
    async fn scrobble_request_includes_timestamp_and_omits_blank_album() {
        LAST_REQUEST_MS.store(0, Ordering::SeqCst);
        let directory = std::env::temp_dir().join(format!(
            "durvald-lastfm-scrobble-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let store = SecureStore::new(directory.clone(), "durvald-test".to_string()).unwrap();
        let (client, transport) =
            LastFmClient::with_test_transport(Arc::new(Mutex::new(store)), serde_json::json!({}));

        client
            .scrobble_track(
                " Artist ".to_string(),
                " Track ".to_string(),
                Some(" ".to_string()),
                1_700_000_000,
            )
            .await
            .expect("send scrobble request");

        let forms = transport.forms.lock().unwrap();
        assert_eq!(forms.len(), 1);
        let form = &forms[0];
        assert!(form.contains(&("method".to_string(), "track.scrobble".to_string())));
        assert!(form.contains(&("artist".to_string(), "Artist".to_string())));
        assert!(form.contains(&("track".to_string(), "Track".to_string())));
        assert!(form.contains(&("timestamp".to_string(), "1700000000".to_string())));
        assert!(!form.iter().any(|(key, _)| key == "album"));
        assert!(form.iter().any(|(key, _)| key == "api_sig"));
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[tokio::test]
    async fn session_poll_request_is_signed_and_parses_the_authorized_user() {
        LAST_REQUEST_MS.store(0, Ordering::SeqCst);
        let directory = std::env::temp_dir().join(format!(
            "durvald-lastfm-session-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let store = SecureStore::new(directory.clone(), "durvald-test".to_string()).unwrap();
        let (client, transport) = LastFmClient::with_test_transport(
            Arc::new(Mutex::new(store)),
            serde_json::json!({"session": {"name": "mock-user", "key": "new-session-key"}}),
        );

        let session = client
            .poll_session("auth-token".to_string())
            .await
            .expect("poll mock session");

        assert_eq!(session.username, "mock-user");
        let forms = transport.forms.lock().unwrap();
        assert_eq!(forms.len(), 1);
        let form = &forms[0];
        assert!(form.contains(&("method".to_string(), "auth.getSession".to_string())));
        assert!(form.contains(&("token".to_string(), "auth-token".to_string())));
        assert!(form.iter().any(|(key, _)| key == "api_sig"));
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[tokio::test]
    async fn empty_track_payloads_fail_before_network_or_credentials() {
        let directory = std::env::temp_dir().join(format!(
            "durvald-lastfm-validation-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let store = SecureStore::new(directory.clone(), "durvald-test".to_string()).unwrap();
        let client = LastFmClient::new(Arc::new(Mutex::new(store)));

        assert!(matches!(
            client
                .update_now_playing(" ".to_string(), "Track".to_string(), None)
                .await,
            Err(LastFmError::Custom(_))
        ));
        assert!(matches!(
            client
                .scrobble_track("Artist".to_string(), " ".to_string(), None, 0)
                .await,
            Err(LastFmError::Custom(_))
        ));

        std::fs::remove_dir_all(directory).unwrap();
    }
}
