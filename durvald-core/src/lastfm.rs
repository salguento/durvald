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
}

impl LastFmClient {
    pub fn new(secure_store: Arc<Mutex<SecureStore>>) -> Self {
        Self {
            secure_store,
            client: Client::new(),
        }
    }

    fn get_api_secret(&self) -> LastFmResult<String> {
        let store = self.secure_store.blocking_lock();
        store
            .get_secret("api_secret")
            .map_err(|e| LastFmError::SecureStore(e))
    }

    fn get_api_key(&self) -> LastFmResult<String> {
        let store = self.secure_store.blocking_lock();
        store
            .get("api_key")
            .and_then(|v| v.as_str().map(String::from))
            .ok_or_else(|| LastFmError::SecureStore(SecureStoreError::Custom("API key not configured".to_string())))
    }

    fn get_session_key(&self) -> LastFmResult<String> {
        let store = self.secure_store.blocking_lock();
        store
            .get_secret("session_key")
            .map_err(|e| LastFmError::SecureStore(e))
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

    pub async fn initialize_lastfm(
        &self,
        api_key: String,
        api_secret: String,
    ) -> LastFmResult<()> {
        let mut store = self.secure_store.lock().await;
        store.set("api_key".into(), api_key.into());
        store.save_data().map_err(LastFmError::SecureStore)?;
        store
            .set_secret("api_secret", &api_secret)
            .map_err(LastFmError::SecureStore)?;
        Ok(())
    }

    pub async fn verify_credentials(&self) -> LastFmResult<String> {
        let store = self.secure_store.lock().await;
        let api_key = store
            .get("api_key")
            .and_then(|v| v.as_str().map(String::from))
            .ok_or_else(|| LastFmError::SecureStore(SecureStoreError::Custom("API key not found".to_string())))?;

        let secret = store
            .get_secret("api_secret")
            .map_err(LastFmError::SecureStore)?;

        Ok(format!(
            "✅ Verified! Key: {}... Secret: {} chars",
            &api_key[..8.min(api_key.len())],
            secret.len()
        ))
    }

    pub async fn get_auth_token(&self) -> LastFmResult<AuthTokenResponse> {
        enforce_rate_limit().await?;

        let api_key = self.get_api_key()?;
        let secret = self.get_api_secret()?;

        let params = vec![("method", "auth.getToken"), ("api_key", &api_key)];
        let sig = Self::generate_signature(&params, &secret);

        let res = self
            .client
            .post("https://ws.audioscrobbler.com/2.0/")
            .form(&[
                ("method", "auth.getToken"),
                ("api_key", &api_key),
                ("api_sig", &sig),
                ("format", "json"),
            ])
            .send()
            .await?;

        let json: Value = res.json().await?;

        if let Some(token) = json["token"].as_str() {
            Ok(AuthTokenResponse {
                token: token.to_string(),
                auth_url: format!(
                    "https://www.last.fm/api/auth/?api_key={}&token={}",
                    api_key, token
                ),
            })
        } else {
            Err(LastFmError::Api {
                code: json["error"].as_i64().unwrap_or(0),
                message: json["message"].as_str().unwrap_or("Unknown error").to_string(),
            })
        }
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

        let res = self
            .client
            .post("https://ws.audioscrobbler.com/2.0/")
            .form(&[
                ("method", "auth.getSession"),
                ("api_key", &api_key),
                ("token", &token),
                ("api_sig", &sig),
                ("format", "json"),
            ])
            .send()
            .await?;

        let text = res.text().await?;
        let json: Value = serde_json::from_str(&text)?;

        if let Some(code) = json["error"].as_i64() {
            let msg = json["message"].as_str().unwrap_or("Unknown error");
            return Err(LastFmError::Api {
                code,
                message: msg.to_string(),
            });
        }

        let session = json["session"].as_object().ok_or_else(|| {
            LastFmError::Custom("No session object".to_string())
        })?;
        let username = session["name"].as_str().ok_or_else(|| {
            LastFmError::Custom("No username".to_string())
        })?.to_string();
        let session_key = session["key"].as_str().ok_or_else(|| {
            LastFmError::Custom("No session key".to_string())
        })?.to_string();

        let mut store = self.secure_store.lock().await;
        store
            .set_secret("session_key", &session_key)
            .map_err(|e| LastFmError::SecureStore(e))?;

        Ok(SessionResponse { username })
    }

    pub async fn update_now_playing(
        &self,
        artist: String,
        track: String,
        album: Option<String>,
    ) -> LastFmResult<()> {
        enforce_rate_limit().await?;

        // ✅ Trim inputs (signature is whitespace-sensitive)
        let artist = artist.trim().to_string();
        let track = track.trim().to_string();
        let album = album.and_then(|a| {
            let trimmed = a.trim().to_string();
            if trimmed.is_empty() {
                None
            } else {
                Some(trimmed)
            }
        });

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

        let res = self
            .client
            .post("https://ws.audioscrobbler.com/2.0/")
            .form(&form)
            .send()
            .await?;

        let text = res.text().await?;
        let json: Value = serde_json::from_str(&text)?;

        if let Some(code) = json["error"].as_i64() {
            let msg = json["message"].as_str().unwrap_or("Unknown error");
            return Err(LastFmError::Api {
                code,
                message: msg.to_string(),
            });
        }

        Ok(())
    }

    pub async fn scrobble_track(
        &self,
        artist: String,
        track: String,
        album: Option<String>,
        timestamp: u64,
    ) -> LastFmResult<()> {
        enforce_rate_limit().await?;

        let artist = artist.trim().to_string();
        let track = track.trim().to_string();
        let album = album.and_then(|a| {
            let trimmed = a.trim().to_string();
            if trimmed.is_empty() {
                None
            } else {
                Some(trimmed)
            }
        });
        let timestamp_str = timestamp.to_string();

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

        let res = self
            .client
            .post("https://ws.audioscrobbler.com/2.0/")
            .form(&form)
            .send()
            .await?;

        let text = res.text().await?;
        let json: Value = serde_json::from_str(&text)?;

        if let Some(code) = json["error"].as_i64() {
            let msg = json["message"].as_str().unwrap_or("Unknown error");
            return Err(LastFmError::Api {
                code,
                message: msg.to_string(),
            });
        }

        Ok(())
    }

    pub async fn is_connected(&self) -> bool {
        let store = self.secure_store.lock().await;
        store.get_secret("session_key").is_ok()
    }

    pub async fn disconnect_lastfm(&self) -> LastFmResult<()> {
        let mut store = self.secure_store.lock().await;
        let _ = store.delete_secret("session_key");
        store.delete("username");
        store.save_data().map_err(LastFmError::SecureStore)?;
        Ok(())
    }

    pub async fn debug_store(&self) -> LastFmResult<String> {
        let store = self.secure_store.lock().await;
        store
            .get("api_key")
            .and_then(|v| v.as_str().map(String::from))
            .map(|key| format!("Store OK. Key prefix: {}", &key[..8.min(key.len())]))
            .ok_or_else(|| LastFmError::SecureStore(SecureStoreError::Custom("API key not found".to_string())))
    }

    pub async fn debug_session(&self) -> LastFmResult<String> {
        let store = self.secure_store.lock().await;
        match store.get_secret("session_key") {
            Ok(key) => Ok(format!("Session key found ({} chars)", key.len())),
            Err(e) => Ok(format!("Session key not found: {}", e)),
        }
    }

    pub async fn debug_credentials(&self) -> LastFmResult<String> {
        let api_key = self.get_api_key()?;
        let secret = self.get_api_secret()?;

        Ok(format!(
            "API Key: {}... ({} chars)\nAPI Secret: {} chars",
            &api_key[..8.min(api_key.len())],
            api_key.len(),
            secret.len()
        ))
    }
}

use std::sync::Arc;