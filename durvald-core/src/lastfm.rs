//! Last.fm integration module

use crate::enrichment::models::CacheValidators;
use crate::secure_store::{SecureStore, SecureStoreError};
use md5::{Digest, Md5};
use reqwest::{Client, StatusCode, header};
use serde::Serialize;
use serde_json::Value;
use std::sync::{
    Arc,
    atomic::{AtomicU64, Ordering},
};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use thiserror::Error;
use tokio::sync::Mutex;
use zeroize::Zeroizing;

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
    #[error("Last.fm response exceeds the {limit_bytes}-byte limit")]
    ResponseTooLarge { limit_bytes: usize },
    #[error("Last.fm API error {code}: {message}")]
    Api { code: i64, message: String },
    #[error("Last.fm metadata network request failed")]
    MetadataNetwork,
    #[error("Last.fm response cache storage failed")]
    MetadataStorage { extended_code: Option<i32> },
    #[error("Last.fm metadata request returned HTTP {status}")]
    HttpStatus {
        status: u16,
        retry_after: Option<String>,
    },
    #[error("Time error: {0}")]
    Time(String),
    #[error("Not connected")]
    NotConnected,
    #[error("{0}")]
    Custom(String),
}

pub type LastFmResult<T> = Result<T, LastFmError>;

const LASTFM_API_ENDPOINT: &str = "https://ws.audioscrobbler.com/2.0/";
const LASTFM_CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const LASTFM_READ_TIMEOUT: Duration = Duration::from_secs(10);
const LASTFM_REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
const MAX_LASTFM_RESPONSE_BYTES: usize = 1024 * 1024;
const LASTFM_USER_AGENT: &str = concat!(
    "Durvald/",
    env!("CARGO_PKG_VERSION"),
    " (desktop music player; Last.fm integration)"
);
#[allow(dead_code)] // Metadata consumers are introduced in the next phase.
const MAX_LASTFM_HEADER_BYTES: usize = 1024;

type ProtectedSecret = Arc<Zeroizing<String>>;

fn protected_secret(secret: String) -> ProtectedSecret {
    Arc::new(Zeroizing::new(secret))
}

fn configured_http_client() -> LastFmResult<Client> {
    Client::builder()
        .user_agent(LASTFM_USER_AGENT)
        .connect_timeout(LASTFM_CONNECT_TIMEOUT)
        .read_timeout(LASTFM_READ_TIMEOUT)
        .timeout(LASTFM_REQUEST_TIMEOUT)
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(LastFmError::Network)
}

#[derive(Debug, Clone, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[allow(dead_code)] // Staged transport contract for enrichment providers.
pub(crate) struct LastFmResponseHeaders {
    pub validators: CacheValidators,
    pub cache_control: Option<String>,
    pub expires: Option<String>,
    pub retry_after: Option<String>,
}

#[derive(Debug)]
#[allow(dead_code)] // Staged transport contract for enrichment providers.
pub(crate) enum LastFmMetadataResponse {
    Modified {
        body: Value,
        headers: LastFmResponseHeaders,
    },
    NotModified {
        headers: LastFmResponseHeaders,
    },
}

const LASTFM_IMAGE_HOSTS: &[&str] = &[
    "lastfm.freetls.fastly.net",
    "lastfm-img.freetls.fastly.net",
    "userserve-ak.last.fm",
    "lastfm-img2.akamaized.net",
];

pub(crate) fn valid_lastfm_image_url(url: &reqwest::Url) -> bool {
    url.scheme() == "https"
        && url.username().is_empty()
        && url.password().is_none()
        && url.port().is_none()
        && url
            .host_str()
            .is_some_and(|host| LASTFM_IMAGE_HOSTS.contains(&host))
}

fn cache_error(error: crate::enrichment::transport::TransportError) -> LastFmError {
    LastFmError::MetadataStorage {
        extended_code: match error {
            crate::enrichment::transport::TransportError::Storage { extended_code } => {
                extended_code
            }
            _ => None,
        },
    }
}

pub(crate) fn page_image(html: &str) -> Option<String> {
    let document = scraper::Html::parse_document(html);
    let metadata =
        scraper::Selector::parse("meta[property='og:image'], meta[name='twitter:image']").ok()?;
    let gallery = scraper::Selector::parse(
        "a[href*='/+images/'] img, a[href$='/+images'] img, img.image-list-image",
    )
    .ok()?;
    document
        .select(&metadata)
        .filter_map(|element| element.value().attr("content"))
        .chain(document.select(&gallery).filter_map(|element| {
            element
                .value()
                .attr("data-src")
                .or_else(|| element.value().attr("src"))
                .or_else(|| element.value().attr("data-background-image-url"))
                .or_else(|| element.value().attr("srcset").and_then(largest_srcset_url))
        }))
        .find_map(normalize_page_image_url)
}

fn largest_srcset_url(value: &str) -> Option<&str> {
    value
        .split(',')
        .filter_map(|candidate| candidate.split_ascii_whitespace().next())
        .next_back()
}

fn normalize_page_image_url(source: &str) -> Option<String> {
    if source.contains("2a96cbd8b46e442fc41c2b86b821562f") {
        return None;
    }
    let absolute;
    let source = if source.starts_with("//") {
        absolute = format!("https:{source}");
        absolute.as_str()
    } else {
        source
    };
    let mut url = reqwest::Url::parse(source).ok()?;
    if !valid_lastfm_image_url(&url) {
        return None;
    }
    url.set_fragment(None);
    Some(url.to_string())
}

fn valid_lastfm_image_mime(value: Option<&str>) -> bool {
    value
        .map(|value| value.split(';').next().unwrap_or_default().trim())
        .is_none_or(|mime| {
            matches!(
                mime.to_ascii_lowercase().as_str(),
                "image/jpeg"
                    | "image/png"
                    | "image/webp"
                    | "image/gif"
                    | "application/octet-stream"
            )
        })
}

#[allow(dead_code)] // Used by the staged metadata transport.
fn bounded_header(headers: &header::HeaderMap, name: header::HeaderName) -> Option<String> {
    headers
        .get(name)
        .and_then(|value| value.to_str().ok())
        .filter(|value| value.len() <= MAX_LASTFM_HEADER_BYTES)
        .map(str::to_owned)
}

#[allow(dead_code)] // Used by the staged metadata transport.
fn metadata_response_headers(headers: &header::HeaderMap) -> LastFmResponseHeaders {
    LastFmResponseHeaders {
        validators: CacheValidators {
            etag: bounded_header(headers, header::ETAG),
            last_modified: bounded_header(headers, header::LAST_MODIFIED),
        },
        cache_control: bounded_header(headers, header::CACHE_CONTROL),
        expires: bounded_header(headers, header::EXPIRES),
        retry_after: bounded_header(headers, header::RETRY_AFTER),
    }
}

#[allow(dead_code)] // Used by the staged metadata transport.
fn valid_metadata_component(value: &str, allow_dot: bool) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || (allow_dot && byte == b'.'))
}

fn append_response_chunk(body: &mut Vec<u8>, chunk: &[u8]) -> LastFmResult<()> {
    if body.len().saturating_add(chunk.len()) > MAX_LASTFM_RESPONSE_BYTES {
        return Err(LastFmError::ResponseTooLarge {
            limit_bytes: MAX_LASTFM_RESPONSE_BYTES,
        });
    }
    body.extend_from_slice(chunk);
    Ok(())
}

async fn bounded_json_response(mut response: reqwest::Response) -> LastFmResult<Value> {
    if response
        .content_length()
        .is_some_and(|length| length > MAX_LASTFM_RESPONSE_BYTES as u64)
    {
        return Err(LastFmError::ResponseTooLarge {
            limit_bytes: MAX_LASTFM_RESPONSE_BYTES,
        });
    }

    let capacity = response
        .content_length()
        .and_then(|length| usize::try_from(length).ok())
        .unwrap_or(0)
        .min(MAX_LASTFM_RESPONSE_BYTES);
    // Authorization responses can contain a session key. Clear the raw JSON
    // buffer as soon as parsing completes instead of leaving it in freed heap
    // memory.
    let mut body = Zeroizing::new(Vec::with_capacity(capacity));
    while let Some(chunk) = response.chunk().await? {
        append_response_chunk(&mut body, &chunk)?;
    }
    Ok(serde_json::from_slice(&body)?)
}

/// Metadata requests carry the API key in their URL, so reqwest errors from
/// body streaming must be redacted rather than retaining the request URL.
async fn bounded_metadata_json_response(mut response: reqwest::Response) -> LastFmResult<Value> {
    if response
        .content_length()
        .is_some_and(|length| length > MAX_LASTFM_RESPONSE_BYTES as u64)
    {
        return Err(LastFmError::ResponseTooLarge {
            limit_bytes: MAX_LASTFM_RESPONSE_BYTES,
        });
    }

    let capacity = response
        .content_length()
        .and_then(|length| usize::try_from(length).ok())
        .unwrap_or(0)
        .min(MAX_LASTFM_RESPONSE_BYTES);
    let mut body = Zeroizing::new(Vec::with_capacity(capacity));
    loop {
        let chunk = response
            .chunk()
            .await
            .map_err(|_| LastFmError::MetadataNetwork)?;
        let Some(chunk) = chunk else { break };
        append_response_chunk(&mut body, &chunk)?;
    }
    Ok(serde_json::from_slice(&body)?)
}

async fn bounded_metadata_image_response(mut response: reqwest::Response) -> LastFmResult<Vec<u8>> {
    let limit = crate::metadata::MAX_ARTWORK_BYTES;
    if response
        .content_length()
        .is_some_and(|length| length > limit as u64)
    {
        return Err(LastFmError::ResponseTooLarge { limit_bytes: limit });
    }
    let mut body = Vec::with_capacity(
        response
            .content_length()
            .and_then(|length| usize::try_from(length).ok())
            .unwrap_or_default()
            .min(limit),
    );
    loop {
        let chunk = response
            .chunk()
            .await
            .map_err(|_| LastFmError::MetadataNetwork)?;
        let Some(chunk) = chunk else { break };
        if body.len().saturating_add(chunk.len()) > limit {
            return Err(LastFmError::ResponseTooLarge { limit_bytes: limit });
        }
        body.extend_from_slice(&chunk);
    }
    crate::metadata::normalize_remote_artwork(&body)
        .map_err(|_| LastFmError::Custom("Invalid Last.fm image decode".into()))
}

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

async fn renew_metadata_representation(
    key: &str,
    entry: &crate::enrichment::cache::Entry,
    mut received: LastFmResponseHeaders,
) -> LastFmResult<LastFmMetadataResponse> {
    let (body, old_headers): (Value, LastFmResponseHeaders) = serde_json::from_slice(&entry.body)?;
    received.validators.etag = received.validators.etag.or(old_headers.validators.etag);
    received.validators.last_modified = received
        .validators
        .last_modified
        .or(old_headers.validators.last_modified);
    received.cache_control = received.cache_control.or(old_headers.cache_control);
    received.expires = received.expires.or(old_headers.expires);
    let renewed = crate::enrichment::cache::entry(
        serde_json::to_vec(&(body.clone(), received.clone()))?,
        received.validators.clone(),
        crate::enrichment::policy::TRANSIENT_PROVIDER_FAILURE_TTL,
    );
    crate::enrichment::cache::store(key, &renewed)
        .await
        .map_err(cache_error)?;
    require_api_success(&body)?;
    Ok(LastFmMetadataResponse::Modified {
        body,
        headers: received,
    })
}

static LASTFM_METADATA_COOLDOWN_UNTIL: AtomicU64 = AtomicU64::new(0);

async fn remember_metadata_cooldown(status: u16, retry_after: Option<&str>) -> LastFmResult<()> {
    if status == 429 || (status == 503 && retry_after.is_some()) {
        let seconds = retry_after
            .and_then(|value| {
                crate::enrichment::transport::retry_after_seconds(
                    value,
                    chrono::Utc::now().timestamp(),
                )
            })
            .unwrap_or(60);
        let until =
            (chrono::Utc::now().timestamp().max(0) as u64).saturating_add(seconds.min(86400));
        LASTFM_METADATA_COOLDOWN_UNTIL.fetch_max(until, Ordering::SeqCst);
        crate::enrichment::cache::defer("lastfm", seconds)
            .await
            .map_err(cache_error)?;
    }
    Ok(())
}
async fn metadata_cooldown() -> LastFmResult<()> {
    let now = chrono::Utc::now().timestamp().max(0) as u64;
    let until = LASTFM_METADATA_COOLDOWN_UNTIL.load(Ordering::SeqCst);
    if until > now {
        return Err(LastFmError::HttpStatus {
            status: 429,
            retry_after: Some((until - now).to_string()),
        });
    }
    crate::enrichment::cache::cooldown("lastfm")
        .await
        .map_err(|error| match error {
            crate::enrichment::transport::TransportError::RateLimited {
                retry_after_seconds,
            } => LastFmError::HttpStatus {
                status: 429,
                retry_after: Some(retry_after_seconds.to_string()),
            },
            _ => cache_error(error),
        })
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
    secret_cache: Mutex<LastFmSecretCache>,
    client: Client,
    #[cfg(test)]
    test_credentials: Option<TestCredentials>,
    #[cfg(test)]
    test_transport: Option<Arc<TestTransport>>,
}

#[derive(Default)]
struct LastFmSecretCache {
    api_secret: Option<ProtectedSecret>,
    session_key: Option<ProtectedSecret>,
}

#[cfg(test)]
struct TestCredentials {
    api_key: String,
    api_secret: ProtectedSecret,
    session_key: ProtectedSecret,
}

#[cfg(test)]
struct TestTransport {
    response: Value,
    forms: std::sync::Mutex<Vec<Vec<(String, String)>>>,
    metadata_queries: std::sync::Mutex<Vec<Vec<(String, String)>>>,
    metadata_validators: std::sync::Mutex<Vec<CacheValidators>>,
    metadata_headers: LastFmResponseHeaders,
    metadata_not_modified_after_first: bool,
    metadata_delay: std::time::Duration,
    image_bytes: Option<Vec<u8>>,
}

impl LastFmClient {
    pub fn open(data_dir: std::path::PathBuf, keychain_service: String) -> LastFmResult<Self> {
        let secure_store = SecureStore::new(data_dir, keychain_service)?;
        Self::new(Arc::new(Mutex::new(secure_store)))
    }

    pub fn new(secure_store: Arc<Mutex<SecureStore>>) -> LastFmResult<Self> {
        Ok(Self {
            secure_store,
            secret_cache: Mutex::new(LastFmSecretCache::default()),
            client: configured_http_client()?,
            #[cfg(test)]
            test_credentials: None,
            #[cfg(test)]
            test_transport: None,
        })
    }

    #[cfg(test)]
    fn with_test_transport(
        secure_store: Arc<Mutex<SecureStore>>,
        response: Value,
    ) -> LastFmResult<(Self, Arc<TestTransport>)> {
        let transport = Arc::new(TestTransport {
            response,
            forms: std::sync::Mutex::new(Vec::new()),
            metadata_queries: std::sync::Mutex::new(Vec::new()),
            metadata_validators: std::sync::Mutex::new(Vec::new()),
            metadata_headers: LastFmResponseHeaders::default(),
            metadata_not_modified_after_first: false,
            metadata_delay: std::time::Duration::ZERO,
            image_bytes: None,
        });
        let client = Self {
            secure_store,
            secret_cache: Mutex::new(LastFmSecretCache::default()),
            client: configured_http_client()?,
            test_credentials: Some(TestCredentials {
                api_key: "test-api-key".to_string(),
                api_secret: protected_secret("test-api-secret".to_string()),
                session_key: protected_secret("test-session-key".to_string()),
            }),
            test_transport: Some(transport.clone()),
        };
        Ok((client, transport))
    }

    #[cfg(test)]
    pub(crate) fn with_test_metadata_transport_options(
        secure_store: Arc<Mutex<SecureStore>>,
        response: Value,
        image_bytes: Option<Vec<u8>>,
        metadata_headers: LastFmResponseHeaders,
        metadata_not_modified_after_first: bool,
        metadata_delay: std::time::Duration,
    ) -> LastFmResult<Self> {
        let (mut client, _) = Self::with_test_transport(secure_store, response)?;
        client.test_transport = client.test_transport.take().map(|transport| {
            Arc::new(TestTransport {
                response: transport.response.clone(),
                forms: std::sync::Mutex::new(Vec::new()),
                metadata_queries: std::sync::Mutex::new(Vec::new()),
                metadata_validators: std::sync::Mutex::new(Vec::new()),
                metadata_headers,
                metadata_not_modified_after_first,
                metadata_delay,
                image_bytes,
            })
        });
        Ok(client)
    }

    #[cfg(test)]
    pub(crate) fn metadata_query_count(&self) -> usize {
        self.test_transport
            .as_ref()
            .map(|transport| transport.metadata_queries.lock().unwrap().len())
            .unwrap_or_default()
    }

    #[cfg(test)]
    pub(crate) fn metadata_validators(&self) -> Vec<CacheValidators> {
        self.test_transport
            .as_ref()
            .map(|transport| transport.metadata_validators.lock().unwrap().clone())
            .unwrap_or_default()
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
        bounded_json_response(response).await
    }

    /// Performs a public Last.fm metadata request using only the API key.
    /// Session keys and the API secret never enter the query string.
    async fn wait_metadata_budget(&self) -> LastFmResult<()> {
        metadata_cooldown().await?;
        #[cfg(test)]
        if self.test_transport.is_some() {
            return Ok(());
        }
        enforce_rate_limit().await
    }

    #[allow(dead_code)] // Called by artist metadata adapters in the next phase.
    pub(crate) async fn get_metadata_json(
        &self,
        method: &str,
        parameters: &[(&str, &str)],
        validators: &CacheValidators,
    ) -> LastFmResult<LastFmMetadataResponse> {
        if !valid_metadata_component(method, true)
            || parameters.iter().any(|(key, value)| {
                !valid_metadata_component(key, false)
                    || matches!(*key, "method" | "api_key" | "format")
                    || value.len() > 4096
            })
        {
            return Err(LastFmError::Custom(
                "Invalid Last.fm metadata request".to_string(),
            ));
        }

        use crate::enrichment::cache;
        let key = cache::key(
            "lastfm-json",
            &serde_json::to_string(&(method, parameters))?,
        );
        let _cache_lock = cache::request_lock(&key).await.map_err(cache_error)?;
        let cached = cache::load(&key).await.map_err(cache_error)?;
        if !cache::forced() {
            if let Some(entry) = cached.as_ref().filter(|entry| entry.fresh()) {
                let (body, headers) = serde_json::from_slice(&entry.body)?;
                require_api_success(&body)?;
                return Ok(LastFmMetadataResponse::Modified { body, headers });
            }
        }
        let caller_has_validators = validators.etag.is_some() || validators.last_modified.is_some();
        let validators = if caller_has_validators {
            validators.clone()
        } else {
            cached
                .as_ref()
                .map(|entry| entry.validators.clone())
                .unwrap_or_default()
        };
        self.wait_metadata_budget().await?;
        let api_key = self.get_api_key().await?;
        let mut query = Vec::with_capacity(parameters.len() + 3);
        query.push(("method".to_string(), method.to_string()));
        query.push(("api_key".to_string(), api_key));
        query.push(("format".to_string(), "json".to_string()));
        query.extend(
            parameters
                .iter()
                .map(|(key, value)| ((*key).to_string(), (*value).to_string())),
        );

        #[cfg(test)]
        if let Some(transport) = &self.test_transport {
            let request_number = {
                let mut queries = transport.metadata_queries.lock().unwrap();
                queries.push(query);
                queries.len()
            };
            transport
                .metadata_validators
                .lock()
                .unwrap()
                .push(validators.clone());
            if !transport.metadata_delay.is_zero() {
                tokio::time::sleep(transport.metadata_delay).await;
            }
            if transport.metadata_not_modified_after_first
                && request_number > 1
                && (validators.etag.is_some() || validators.last_modified.is_some())
            {
                if let Some(entry) = cached.as_ref() {
                    return renew_metadata_representation(
                        &key,
                        entry,
                        transport.metadata_headers.clone(),
                    )
                    .await;
                }
                return Ok(LastFmMetadataResponse::NotModified {
                    headers: transport.metadata_headers.clone(),
                });
            }
            if transport.response["error"]
                .as_i64()
                .is_none_or(|code| code == 7)
            {
                cache::store(
                    &key,
                    &cache::entry(
                        serde_json::to_vec(&(
                            transport.response.clone(),
                            transport.metadata_headers.clone(),
                        ))?,
                        transport.metadata_headers.validators.clone(),
                        crate::enrichment::policy::TRANSIENT_PROVIDER_FAILURE_TTL,
                    ),
                )
                .await
                .map_err(cache_error)?;
            }
            require_api_success(&transport.response)?;
            return Ok(LastFmMetadataResponse::Modified {
                body: transport.response.clone(),
                headers: transport.metadata_headers.clone(),
            });
        }

        let mut request = self.client.get(LASTFM_API_ENDPOINT).query(&query);
        if let Some(etag) = &validators.etag {
            request = request.header(header::IF_NONE_MATCH, etag);
        }
        if let Some(last_modified) = &validators.last_modified {
            request = request.header(header::IF_MODIFIED_SINCE, last_modified);
        }
        let response = request
            .send()
            .await
            .map_err(|_| LastFmError::MetadataNetwork)?;
        let status = response.status();
        let mut received = metadata_response_headers(response.headers());
        remember_metadata_cooldown(status.as_u16(), received.retry_after.as_deref()).await?;
        if status == StatusCode::NOT_MODIFIED
            && (validators.etag.is_some() || validators.last_modified.is_some())
        {
            received.validators.etag = received.validators.etag.or_else(|| validators.etag.clone());
            received.validators.last_modified = received
                .validators
                .last_modified
                .or_else(|| validators.last_modified.clone());
            if let Some(entry) = cached.as_ref() {
                return renew_metadata_representation(&key, entry, received).await;
            }
            return Ok(LastFmMetadataResponse::NotModified { headers: received });
        }
        if !status.is_success() {
            return Err(LastFmError::HttpStatus {
                status: status.as_u16(),
                retry_after: received.retry_after,
            });
        }
        let body = bounded_metadata_json_response(response).await?;
        if body["error"].as_i64() == Some(29) {
            remember_metadata_cooldown(429, received.retry_after.as_deref()).await?;
        }
        // Preserve an unknown-MBID response too: name fallback must not repeat
        // the same failed identity lookup on every refresh. Credential/rate
        // errors are deliberately not cached as metadata representations.
        if api_error_from_response(&body).is_some() && body["error"].as_i64() != Some(7) {
            require_api_success(&body)?;
        }
        cache::store(
            &key,
            &cache::entry(
                serde_json::to_vec(&(body.clone(), received.clone()))?,
                received.validators.clone(),
                crate::enrichment::policy::TRANSIENT_PROVIDER_FAILURE_TTL,
            ),
        )
        .await
        .map_err(cache_error)?;
        require_api_success(&body)?;
        Ok(LastFmMetadataResponse::Modified {
            body,
            headers: received,
        })
    }

    /// Downloads public Last.fm artwork without forwarding credentials.
    pub(crate) async fn download_metadata_image(&self, url: &str) -> LastFmResult<Vec<u8>> {
        let mut url = reqwest::Url::parse(url)
            .map_err(|_| LastFmError::Custom("Invalid Last.fm image URL".into()))?;
        if !valid_lastfm_image_url(&url) {
            return Err(LastFmError::Custom("Invalid Last.fm image URL".into()));
        }

        use crate::enrichment::cache;
        let key = cache::key("lastfm-image", url.as_str());
        let _cache_lock = cache::request_lock(&key).await.map_err(cache_error)?;
        if !cache::forced() {
            if let Some(entry) = cache::load(&key)
                .await
                .map_err(cache_error)?
                .filter(|entry| entry.fresh())
            {
                return crate::metadata::normalize_remote_artwork(&entry.body)
                    .map_err(|_| LastFmError::Custom("Invalid cached Last.fm image".into()));
            }
        }
        self.wait_metadata_budget().await?;
        #[cfg(test)]
        if let Some(transport) = &self.test_transport {
            return transport.image_bytes.clone().ok_or_else(|| {
                LastFmError::Custom("Last.fm image unavailable in test transport".into())
            });
        }

        for redirect in 0..=3 {
            let response = self
                .client
                .get(url.clone())
                .header(header::ACCEPT, "image/jpeg,image/png,image/webp,image/gif")
                .send()
                .await
                .map_err(|_| LastFmError::MetadataNetwork)?;
            if response.status().is_redirection() {
                if redirect == 3 {
                    return Err(LastFmError::HttpStatus {
                        status: response.status().as_u16(),
                        retry_after: None,
                    });
                }
                let location = response
                    .headers()
                    .get(header::LOCATION)
                    .and_then(|value| value.to_str().ok())
                    .ok_or_else(|| LastFmError::Custom("Invalid Last.fm image redirect".into()))?;
                url = url
                    .join(location)
                    .map_err(|_| LastFmError::Custom("Invalid Last.fm image redirect".into()))?;
                if !valid_lastfm_image_url(&url) {
                    return Err(LastFmError::Custom(
                        "Untrusted Last.fm image redirect".into(),
                    ));
                }
                continue;
            }
            let status = response.status();
            let retry_after = bounded_header(response.headers(), header::RETRY_AFTER);
            remember_metadata_cooldown(status.as_u16(), retry_after.as_deref()).await?;
            if !status.is_success() {
                return Err(LastFmError::HttpStatus {
                    status: status.as_u16(),
                    retry_after,
                });
            }
            if !valid_lastfm_image_mime(
                response
                    .headers()
                    .get(header::CONTENT_TYPE)
                    .and_then(|value| value.to_str().ok()),
            ) {
                return Err(LastFmError::Custom(
                    "Invalid Last.fm image MIME type".into(),
                ));
            }
            let bytes = bounded_metadata_image_response(response).await?;
            cache::store(
                &key,
                &cache::entry(
                    bytes.clone(),
                    CacheValidators::default(),
                    crate::enrichment::policy::PROFILE_TTL,
                ),
            )
            .await
            .map_err(cache_error)?;
            return Ok(bytes);
        }
        unreachable!()
    }

    /// Public artist page used when the API returns its shared placeholder.
    /// Never forwards API/session credentials, and never fetches arbitrary hosts.
    pub(crate) async fn artist_page_image(&self, source: &str) -> LastFmResult<Option<String>> {
        use crate::enrichment::cache;
        #[cfg(test)]
        if self.test_transport.is_some() {
            return Ok(None);
        }
        let mut url = reqwest::Url::parse(source)
            .map_err(|_| LastFmError::Custom("Invalid artist page".into()))?;
        let key = cache::key("lastfm-page", source);
        let _cache_lock = cache::request_lock(&key).await.map_err(cache_error)?;
        let cached = cache::load(&key).await.map_err(cache_error)?;
        if !cache::forced() {
            if let Some(entry) = cached.as_ref().filter(|entry| entry.fresh()) {
                let html = String::from_utf8_lossy(&entry.body);
                return Ok(page_image(&html));
            }
        }
        for redirect in 0..=3 {
            if url.scheme() != "https"
                || !matches!(url.host_str(), Some("www.last.fm" | "last.fm"))
                || !url.username().is_empty()
                || url.password().is_some()
                || url.port().is_some()
            {
                return Err(LastFmError::Custom("Invalid artist page redirect".into()));
            }
            self.wait_metadata_budget().await?;
            let response = self
                .client
                .get(url.clone())
                .header(header::ACCEPT, "text/html")
                .send()
                .await
                .map_err(|_| LastFmError::MetadataNetwork)?;
            let status = response.status();
            if status.is_redirection() && redirect < 3 {
                let location = response
                    .headers()
                    .get(header::LOCATION)
                    .and_then(|value| value.to_str().ok())
                    .ok_or_else(|| LastFmError::Custom("Invalid artist page redirect".into()))?;
                url = url
                    .join(location)
                    .map_err(|_| LastFmError::Custom("Invalid artist page redirect".into()))?;
                continue;
            }
            if !status.is_success() {
                let retry_after = bounded_header(response.headers(), header::RETRY_AFTER);
                remember_metadata_cooldown(status.as_u16(), retry_after.as_deref()).await?;
                let ttl = retry_after
                    .as_deref()
                    .and_then(|value| value.parse::<u64>().ok())
                    .unwrap_or(900)
                    .clamp(60, 86400);
                cache::store(
                    &key,
                    &cache::entry(
                        Vec::new(),
                        CacheValidators::default(),
                        Duration::from_secs(ttl),
                    ),
                )
                .await
                .map_err(cache_error)?;
                return Err(LastFmError::HttpStatus {
                    status: status.as_u16(),
                    retry_after,
                });
            }
            let mut response = response;
            let mut bytes = Vec::new();
            while let Some(chunk) = response
                .chunk()
                .await
                .map_err(|_| LastFmError::MetadataNetwork)?
            {
                if bytes.len().saturating_add(chunk.len())
                    > crate::enrichment::policy::MAX_JSON_BYTES
                {
                    return Err(LastFmError::ResponseTooLarge {
                        limit_bytes: crate::enrichment::policy::MAX_JSON_BYTES,
                    });
                }
                bytes.extend_from_slice(&chunk);
            }
            let image = page_image(&String::from_utf8_lossy(&bytes));
            cache::store(
                &key,
                &cache::entry(
                    bytes,
                    CacheValidators::default(),
                    crate::enrichment::policy::POPULAR_TRACKS_TTL,
                ),
            )
            .await
            .map_err(cache_error)?;
            return Ok(image);
        }
        unreachable!()
    }

    async fn get_api_secret(&self) -> LastFmResult<ProtectedSecret> {
        #[cfg(test)]
        if let Some(credentials) = &self.test_credentials {
            return Ok(credentials.api_secret.clone());
        }
        if let Some(secret) = self.secret_cache.lock().await.api_secret.clone() {
            return Ok(secret);
        }

        let secret = protected_secret(
            self.secure_store
                .lock()
                .await
                .get_secret("api_secret")
                .map_err(LastFmError::SecureStore)?,
        );
        self.secret_cache.lock().await.api_secret = Some(secret.clone());
        Ok(secret)
    }

    async fn get_api_key(&self) -> LastFmResult<String> {
        #[cfg(test)]
        if let Some(credentials) = &self.test_credentials {
            return Ok(credentials.api_key.clone());
        }
        let store = self.secure_store.lock().await;
        store
            .get("api_key")
            .map_err(LastFmError::SecureStore)?
            .and_then(|v| v.as_str().map(String::from))
            .ok_or_else(|| {
                LastFmError::SecureStore(SecureStoreError::Custom(
                    "API key not configured".to_string(),
                ))
            })
    }

    async fn get_session_key(&self) -> LastFmResult<ProtectedSecret> {
        #[cfg(test)]
        if let Some(credentials) = &self.test_credentials {
            return Ok(credentials.session_key.clone());
        }
        if let Some(session_key) = self.secret_cache.lock().await.session_key.clone() {
            return Ok(session_key);
        }

        let session_key = protected_secret(
            self.secure_store
                .lock()
                .await
                .get_secret("session_key")
                .map_err(LastFmError::SecureStore)?,
        );
        self.secret_cache.lock().await.session_key = Some(session_key.clone());
        Ok(session_key)
    }

    #[cfg(test)]
    async fn clear_cached_session_key(&self) {
        self.secret_cache.lock().await.session_key.take();
    }

    fn generate_signature(params: &[(&str, &str)], secret: &str) -> String {
        let mut sorted_params: Vec<(&str, &str)> = params.to_vec();
        sorted_params.sort_by(|a, b| a.0.cmp(b.0));

        let mut sig_string = Zeroizing::new(String::new());
        for (key, value) in sorted_params {
            sig_string.push_str(key);
            sig_string.push_str(value);
        }
        sig_string.push_str(secret);

        let digest = Md5::new().chain_update(sig_string.as_bytes()).finalize();
        format!("{:x}", digest)
    }

    pub async fn initialize_lastfm(&self, api_key: String, api_secret: String) -> LastFmResult<()> {
        let api_secret = Zeroizing::new(api_secret);
        let store = self.secure_store.lock().await;
        let credentials_changed = store
            .get("api_key")
            .map_err(LastFmError::SecureStore)?
            .and_then(|value| value.as_str().map(str::to_owned))
            .as_deref()
            != Some(api_key.as_str())
            || store
                .get_secret("api_secret")
                .map(Zeroizing::new)
                .map(|stored_secret| stored_secret.as_str() != api_secret.as_str())
                .unwrap_or(true);

        if credentials_changed {
            if store.get_secret("session_key").is_ok() {
                store
                    .delete_secret("session_key")
                    .map_err(LastFmError::SecureStore)?;
            }
            store.delete("username").map_err(LastFmError::SecureStore)?;
        }
        store
            .set("api_key".into(), api_key.into())
            .map_err(LastFmError::SecureStore)?;
        store
            .set_secret("api_secret", api_secret.as_str())
            .map_err(LastFmError::SecureStore)?;
        store.save_data().map_err(LastFmError::SecureStore)?;
        drop(store);

        let mut cache = self.secret_cache.lock().await;
        cache.api_secret = Some(Arc::new(api_secret));
        if credentials_changed {
            cache.session_key.take();
        }
        Ok(())
    }

    pub async fn verify_credentials(&self) -> LastFmResult<String> {
        let store = self.secure_store.lock().await;
        let api_key = store
            .get("api_key")
            .map_err(LastFmError::SecureStore)?
            .and_then(|v| v.as_str().map(String::from))
            .ok_or_else(|| {
                LastFmError::SecureStore(SecureStoreError::Custom("API key not found".to_string()))
            })?;

        let secret = Zeroizing::new(
            store
                .get_secret("api_secret")
                .map_err(LastFmError::SecureStore)?,
        );

        if api_key.trim().is_empty() || secret.trim().is_empty() {
            return Err(LastFmError::Custom(
                "Last.fm credentials are empty".to_string(),
            ));
        }
        Ok("Last.fm credentials are configured".to_string())
    }

    pub async fn get_auth_token(&self) -> LastFmResult<AuthTokenResponse> {
        enforce_rate_limit().await?;

        let api_key = self.get_api_key().await?;
        let secret = self.get_api_secret().await?;

        let params = vec![("method", "auth.getToken"), ("api_key", &api_key)];
        let sig = Self::generate_signature(&params, secret.as_str());

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

        let api_key = self.get_api_key().await?;
        let secret = self.get_api_secret().await?;

        let mut params = vec![
            ("api_key", api_key.as_str()),
            ("method", "auth.getSession"),
            ("token", token.as_str()),
        ];
        params.sort_by(|a, b| a.0.cmp(b.0));
        let sig = Self::generate_signature(&params, secret.as_str());

        let mut json = self
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
            .as_object_mut()
            .ok_or_else(|| LastFmError::Custom("No session object".to_string()))?;
        let username = session
            .remove("name")
            .and_then(|value| value.as_str().map(str::to_owned))
            .ok_or_else(|| LastFmError::Custom("No username".to_string()))?;
        let session_key = match session.remove("key") {
            Some(Value::String(secret)) => Zeroizing::new(secret),
            _ => return Err(LastFmError::Custom("No session key".to_string())),
        };

        #[cfg(test)]
        if self.test_credentials.is_some() {
            return Ok(SessionResponse { username });
        }

        let store = self.secure_store.lock().await;
        store
            .set_secret("session_key", session_key.as_str())
            .map_err(LastFmError::SecureStore)?;
        store
            .set("username".into(), username.clone().into())
            .map_err(LastFmError::SecureStore)?;
        store.save_data().map_err(LastFmError::SecureStore)?;
        drop(store);
        self.secret_cache.lock().await.session_key = Some(Arc::new(session_key));

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

        let session_key = self.get_session_key().await?;
        let api_key = self.get_api_key().await?;
        let secret = self.get_api_secret().await?;

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
        let sig = Self::generate_signature(&params, secret.as_str());

        // ✅ 'format' ONLY in POST body (NOT in signature params)
        let mut form = vec![
            ("method", "track.updateNowPlaying"),
            ("api_key", &api_key),
            ("api_sig", &sig),
            ("sk", session_key.as_str()),
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

        let session_key = self.get_session_key().await?;
        let api_key = self.get_api_key().await?;
        let secret = self.get_api_secret().await?;

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
        let sig = Self::generate_signature(&params, secret.as_str());

        // ✅ 'format' ONLY in POST body
        let mut form = vec![
            ("method", "track.scrobble"),
            ("api_key", &api_key),
            ("api_sig", &sig),
            ("sk", session_key.as_str()),
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
        self.get_session_key().await.is_ok()
    }

    /// Returns the locally persisted Last.fm username, if the account has
    /// completed the authorization flow.
    pub async fn username(&self) -> LastFmResult<Option<String>> {
        let store = self.secure_store.lock().await;
        Ok(store
            .get("username")
            .map_err(LastFmError::SecureStore)?
            .and_then(|value| value.as_str().map(str::to_owned)))
    }

    pub async fn disconnect_lastfm(&self) -> LastFmResult<()> {
        let store = self.secure_store.lock().await;
        store
            .delete_secret("session_key")
            .map_err(LastFmError::SecureStore)?;
        store
            .delete_secret("api_secret")
            .map_err(LastFmError::SecureStore)?;
        store.delete("api_key").map_err(LastFmError::SecureStore)?;
        store.delete("username").map_err(LastFmError::SecureStore)?;
        store.save_data().map_err(LastFmError::SecureStore)?;
        drop(store);
        let mut cache = self.secret_cache.lock().await;
        cache.api_secret.take();
        cache.session_key.take();
        Ok(())
    }

    #[cfg(debug_assertions)]
    pub async fn debug_store(&self) -> LastFmResult<String> {
        let store = self.secure_store.lock().await;
        store
            .get("api_key")
            .map_err(LastFmError::SecureStore)?
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
            Ok(key) => {
                let key = Zeroizing::new(key);
                Ok(format!("Session key found ({} chars)", key.len()))
            }
            Err(e) => Ok(format!("Session key not found: {}", e)),
        }
    }

    #[cfg(debug_assertions)]
    pub async fn debug_credentials(&self) -> LastFmResult<String> {
        let api_key = self.get_api_key().await?;
        let secret = self.get_api_secret().await?;
        Ok(credentials_diagnostic(&api_key, secret.as_str()))
    }
}

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

    #[test]
    fn response_body_is_rejected_before_exceeding_its_memory_limit() {
        let mut body = vec![0; MAX_LASTFM_RESPONSE_BYTES - 2];
        append_response_chunk(&mut body, &[1, 2]).expect("accept response at exact limit");
        assert_eq!(body.len(), MAX_LASTFM_RESPONSE_BYTES);

        let error = append_response_chunk(&mut body, &[3]).unwrap_err();
        assert!(matches!(
            error,
            LastFmError::ResponseTooLarge { limit_bytes }
                if limit_bytes == MAX_LASTFM_RESPONSE_BYTES
        ));
        assert_eq!(body.len(), MAX_LASTFM_RESPONSE_BYTES);
    }

    #[test]
    fn metadata_headers_are_bounded_and_preserved() {
        let mut headers = header::HeaderMap::new();
        headers.insert(
            header::ETAG,
            header::HeaderValue::from_static("\"artist-v1\""),
        );
        headers.insert(
            header::LAST_MODIFIED,
            header::HeaderValue::from_static("Mon, 15 Sep 2026 12:00:00 GMT"),
        );
        headers.insert(
            header::CACHE_CONTROL,
            header::HeaderValue::from_static("public, max-age=3600"),
        );
        headers.insert(
            header::EXPIRES,
            header::HeaderValue::from_static("Mon, 15 Sep 2026 13:00:00 GMT"),
        );
        headers.insert(header::RETRY_AFTER, header::HeaderValue::from_static("120"));

        let parsed = metadata_response_headers(&headers);
        assert_eq!(parsed.validators.etag.as_deref(), Some("\"artist-v1\""));
        assert_eq!(
            parsed.validators.last_modified.as_deref(),
            Some("Mon, 15 Sep 2026 12:00:00 GMT")
        );
        assert_eq!(
            parsed.cache_control.as_deref(),
            Some("public, max-age=3600")
        );
        assert_eq!(
            parsed.expires.as_deref(),
            Some("Mon, 15 Sep 2026 13:00:00 GMT")
        );
        assert_eq!(parsed.retry_after.as_deref(), Some("120"));
    }

    #[test]
    fn casey_page_selects_photo_and_rejects_placeholder_or_untrusted_hosts() {
        let photo = "https://lastfm.freetls.fastly.net/i/u/300x300/casey.webp";
        let html = format!("<meta content='{photo}' property='og:image'>");
        assert_eq!(page_image(&html).as_deref(), Some(photo));
        assert!(
            page_image("<meta property='og:image' content='https://evil.test/photo.jpg'>")
                .is_none()
        );
        assert!(page_image("<meta property='og:image' content='https://lastfm.freetls.fastly.net/i/u/300x300/2a96cbd8b46e442fc41c2b86b821562f.png'>").is_none());
        assert!(page_image("<html>No image</html>").is_none());
    }

    #[test]
    fn metadata_images_accept_only_supported_mime_types() {
        assert!(valid_lastfm_image_mime(Some("image/jpeg")));
        assert!(valid_lastfm_image_mime(Some("image/png; charset=binary")));
        assert!(valid_lastfm_image_mime(None));
        assert!(valid_lastfm_image_mime(Some("image/gif")));
        assert!(valid_lastfm_image_mime(Some("image/webp")));
        assert!(valid_lastfm_image_mime(Some("application/octet-stream")));
        assert!(!valid_lastfm_image_mime(Some("text/html")));
    }

    #[tokio::test]
    async fn not_modified_renews_raw_metadata_and_returns_body_for_portrait_materialization() {
        use crate::enrichment::cache;
        let path = std::env::temp_dir().join(format!(
            "durvald-lastfm-304-{}-{}.sqlite",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        cache::CACHE_CONTEXT
            .scope((path.clone(), true), async {
                let body = serde_json::json!({"artist":{"name":"Casey MQ","image":[],"bio":null}});
                let old = LastFmResponseHeaders {
                    validators: CacheValidators {
                        etag: Some("v1".into()),
                        last_modified: None,
                    },
                    ..Default::default()
                };
                let mut entry = cache::entry(
                    serde_json::to_vec(&(body.clone(), old)).unwrap(),
                    CacheValidators::default(),
                    Duration::ZERO,
                );
                entry.expires_at = 0;
                let response = renew_metadata_representation(
                    "lastfm-json:test",
                    &entry,
                    LastFmResponseHeaders::default(),
                )
                .await
                .unwrap();
                let LastFmMetadataResponse::Modified {
                    body: received,
                    headers,
                } = response
                else {
                    panic!("missing body");
                };
                assert_eq!(received, body);
                assert_eq!(headers.validators.etag.as_deref(), Some("v1"));
                assert!(
                    cache::load("lastfm-json:test")
                        .await
                        .unwrap()
                        .unwrap()
                        .fresh()
                );
            })
            .await;
        std::fs::remove_file(path).unwrap();
    }

    #[tokio::test]
    async fn unknown_mbid_is_persisted_without_storing_request_credentials() {
        use crate::enrichment::cache;
        let directory = std::env::temp_dir().join(format!(
            "durvald-negative-lastfm-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let store = SecureStore::new(directory.clone(), "durvald-test".into()).unwrap();
        let (client, transport) = LastFmClient::with_test_transport(
            Arc::new(Mutex::new(store)),
            serde_json::json!({"error":7,"message":"Artist not found"}),
        )
        .unwrap();
        let path = directory.join("http.sqlite");
        cache::CACHE_CONTEXT
            .scope((path.clone(), false), async {
                for _ in 0..2 {
                    assert!(matches!(
                        client
                            .get_metadata_json(
                                "artist.getInfo",
                                &[("mbid", "unknown")],
                                &CacheValidators::default()
                            )
                            .await,
                        Err(LastFmError::Api { code: 7, .. })
                    ));
                }
                assert_eq!(transport.metadata_queries.lock().unwrap().len(), 1);
            })
            .await;
        let database = rusqlite::Connection::open(&path).unwrap();
        let key: String = database
            .query_row("SELECT key FROM http_cache", [], |row| row.get(0))
            .unwrap();
        assert!(key.starts_with("lastfm-json:"));
        assert!(!key.contains("unknown"));
        drop(database);
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[tokio::test]
    async fn public_metadata_uses_the_shared_client_without_session_credentials() {
        LAST_REQUEST_MS.store(0, Ordering::SeqCst);
        let directory = std::env::temp_dir().join(format!(
            "durvald-lastfm-metadata-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let store = SecureStore::new(directory.clone(), "durvald-test".to_string()).unwrap();
        let (client, transport) = LastFmClient::with_test_transport(
            Arc::new(Mutex::new(store)),
            serde_json::json!({"artist": {"name": "Wendy Carlos"}}),
        )
        .expect("build test client");
        let client = Arc::new(client);
        let adapter = crate::enrichment::providers::lastfm::LastFm::new(client.clone());
        assert!(adapter.shares_client(&client));

        let response = adapter
            .metadata_json(
                "artist.getInfo",
                &[("mbid", "some-mbid"), ("lang", "pt")],
                &CacheValidators::default(),
            )
            .await
            .expect("read public metadata");
        match response {
            LastFmMetadataResponse::Modified { body, headers } => {
                assert_eq!(body["artist"]["name"], "Wendy Carlos");
                assert_eq!(headers, LastFmResponseHeaders::default());
            }
            LastFmMetadataResponse::NotModified { .. } => {
                panic!("unconditional test request returned not modified")
            }
        }

        let queries = transport.metadata_queries.lock().unwrap();
        assert_eq!(queries.len(), 1);
        let query = &queries[0];
        assert!(query.contains(&("method".to_string(), "artist.getInfo".to_string())));
        assert!(query.contains(&("api_key".to_string(), "test-api-key".to_string())));
        assert!(query.contains(&("format".to_string(), "json".to_string())));
        assert!(query.contains(&("mbid".to_string(), "some-mbid".to_string())));
        assert!(
            !query
                .iter()
                .any(|(key, _)| matches!(key.as_str(), "sk" | "api_sig"))
        );
        drop(queries);
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[tokio::test]
    async fn metadata_method_and_reserved_parameters_are_rejected() {
        assert!(valid_metadata_component("artist.getInfo", true));
        assert!(!valid_metadata_component("artist/getInfo", true));
        assert!(!valid_metadata_component("", true));
        assert!(LASTFM_USER_AGENT.starts_with("Durvald/"));
        assert!(LASTFM_USER_AGENT.contains("Last.fm integration"));

        let directory = std::env::temp_dir().join(format!(
            "durvald-lastfm-invalid-metadata-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let store = SecureStore::new(directory.clone(), "durvald-test".to_string()).unwrap();
        let (client, transport) =
            LastFmClient::with_test_transport(Arc::new(Mutex::new(store)), serde_json::json!({}))
                .expect("build test client");
        assert!(matches!(
            client
                .get_metadata_json(
                    "artist.getInfo",
                    &[("api_key", "override")],
                    &CacheValidators::default(),
                )
                .await,
            Err(LastFmError::Custom(_))
        ));
        assert!(transport.metadata_queries.lock().unwrap().is_empty());
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[tokio::test]
    async fn cached_secrets_share_protected_storage_and_session_cache_is_released() {
        let directory = std::env::temp_dir().join(format!(
            "durvald-lastfm-secret-cache-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let store = SecureStore::new(directory.clone(), "durvald-test".to_string()).unwrap();
        let client = LastFmClient::new(Arc::new(Mutex::new(store))).expect("build test client");

        let api_secret = protected_secret("protected-api-secret".to_string());
        client.secret_cache.lock().await.api_secret = Some(api_secret.clone());
        let first = client.get_api_secret().await.unwrap();
        let second = client.get_api_secret().await.unwrap();
        assert!(Arc::ptr_eq(&first, &second));

        let session_key = protected_secret("protected-session-key".to_string());
        let session_ownership = Arc::downgrade(&session_key);
        client.secret_cache.lock().await.session_key = Some(session_key.clone());
        drop(session_key);
        client.clear_cached_session_key().await;
        assert!(session_ownership.upgrade().is_none());

        std::fs::remove_dir_all(directory).unwrap();
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
        )
        .expect("build test client");
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
            LastFmClient::with_test_transport(Arc::new(Mutex::new(store)), serde_json::json!({}))
                .expect("build test client");

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
            LastFmClient::with_test_transport(Arc::new(Mutex::new(store)), serde_json::json!({}))
                .expect("build test client");

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
        )
        .expect("build test client");

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
        let client = LastFmClient::new(Arc::new(Mutex::new(store))).expect("build test client");

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
