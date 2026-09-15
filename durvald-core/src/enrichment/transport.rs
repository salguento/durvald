//! Bounded, cancellation-safe GET transport for JSON provider adapters.
//!
//! No background workers: dropping the future releases permits and cancels I/O.
//! JSON redirects are deliberately disabled. Artwork CDN redirects belong to the
//! later artwork adapter and must not inherit API credentials.

use super::models::CacheValidators;
use super::policy::{self, normalize_language};
use crate::api::EnrichmentProvider;
use reqwest::{Client, StatusCode, Url, header};
use ring::rand::SecureRandom;
use serde::de::DeserializeOwned;
use std::sync::{Arc, LazyLock};
use std::time::Duration;
use tokio::sync::{Mutex, Semaphore};
use tokio::time::{Instant, sleep, sleep_until, timeout};

/// No error stores a request URL, response body or reqwest error containing keys.
#[derive(Debug, Clone, thiserror::Error, PartialEq, Eq)]
pub enum TransportError {
    #[error("Invalid enrichment HTTP configuration")]
    Configuration,
    #[error("Invalid enrichment request")]
    InvalidRequest,
    #[error("Enrichment request timed out")]
    Timeout,
    #[error("Enrichment connection failed")]
    Connection,
    #[error("Enrichment network request failed")]
    Network,
    #[error("Enrichment response exceeded its byte limit")]
    BodyTooLarge,
    #[error("Invalid enrichment JSON response")]
    InvalidJson,
    #[error("Invalid enrichment image response")]
    InvalidImage,
    #[error("Enrichment provider returned HTTP {status}")]
    HttpStatus {
        status: u16,
        retry_after_seconds: Option<u64>,
    },
    #[error("Enrichment provider is rate limited")]
    RateLimited { retry_after_seconds: u64 },
    #[error("Enrichment SQLite operation failed")]
    Storage { extended_code: Option<i32> },
}

impl TransportError {
    fn is_retryable_io(&self) -> bool {
        matches!(self, Self::Timeout | Self::Connection | Self::Network)
    }

    pub fn is_transient(&self) -> bool {
        matches!(
            self,
            Self::Timeout
                | Self::Connection
                | Self::Network
                | Self::RateLimited { .. }
                | Self::HttpStatus {
                    status: 429 | 500 | 502 | 503 | 504,
                    ..
                }
        )
    }

    pub fn retry_after_seconds(&self) -> Option<u64> {
        match self {
            Self::RateLimited {
                retry_after_seconds,
            } => Some(*retry_after_seconds),
            Self::HttpStatus {
                retry_after_seconds,
                ..
            } => *retry_after_seconds,
            _ => None,
        }
    }
}

#[derive(Debug)]
pub enum JsonResponse<T> {
    Modified {
        body: T,
        validators: CacheValidators,
    },
    NotModified {
        validators: CacheValidators,
    },
}

struct ProviderGate {
    next_allowed: Mutex<Instant>,
    interval: Duration,
    slots: Semaphore,
}

impl ProviderGate {
    fn new(interval: Duration) -> Self {
        Self {
            next_allowed: Mutex::new(Instant::now()),
            interval,
            slots: Semaphore::new(2),
        }
    }

    async fn wait(&self) {
        loop {
            let mut next = self.next_allowed.lock().await;
            let now = Instant::now();
            if *next <= now {
                *next = now + self.interval;
                return;
            }
            let due = *next;
            drop(next);
            // Recheck after waking: a concurrent 429 may extend the cooldown.
            sleep_until(due).await;
        }
    }

    async fn defer(&self, delay: Duration) {
        let mut next = self.next_allowed.lock().await;
        let until = Instant::now() + delay;
        *next = (*next).max(until);
    }
}

// Wikimedia projects share one budget. Different clients/core instances in this
// process must not multiply the MusicBrainz allowance. Other intervals are
// conservative local defaults, not claims about provider quotas.
static GATES: LazyLock<[Arc<ProviderGate>; 5]> = LazyLock::new(|| {
    [
        Arc::new(ProviderGate::new(Duration::from_secs(1))),
        Arc::new(ProviderGate::new(Duration::from_millis(250))),
        Arc::new(ProviderGate::new(Duration::from_millis(250))),
        Arc::new(ProviderGate::new(Duration::from_secs(2))),
        Arc::new(ProviderGate::new(Duration::from_millis(250))),
    ]
});

fn gate_index(provider: EnrichmentProvider) -> usize {
    match provider {
        EnrichmentProvider::MusicBrainz => 0,
        EnrichmentProvider::Wikidata
        | EnrichmentProvider::Wikipedia
        | EnrichmentProvider::Commons => 1,
        EnrichmentProvider::CoverArtArchive => 2,
        EnrichmentProvider::LastFm => {
            unreachable!("Last.fm must use the shared LastFmClient")
        }
        EnrichmentProvider::TheAudioDb => 3,
        EnrichmentProvider::YouTube => 4,
    }
}

#[derive(Clone)]
struct TransportPolicy {
    connect_timeout: Duration,
    operation_timeout: Duration,
    max_bytes: usize,
    retry_base: Duration,
}

impl Default for TransportPolicy {
    fn default() -> Self {
        Self {
            connect_timeout: policy::CONNECT_TIMEOUT,
            operation_timeout: policy::OPERATION_TIMEOUT,
            max_bytes: policy::MAX_JSON_BYTES,
            retry_base: Duration::from_millis(250),
        }
    }
}

#[derive(Clone)]
pub struct EnrichmentHttpClient {
    client: Client,
    base: Url,
    gate: Arc<ProviderGate>,
    policy: TransportPolicy,
    user_agent: String,
    #[cfg(test)]
    scripted: Option<Arc<tests::MockTransport>>,
}

struct HttpResponse {
    status: StatusCode,
    headers: header::HeaderMap,
    content_length: Option<u64>,
    body: ResponseBody,
}

enum ResponseBody {
    Http(reqwest::Response),
    #[cfg(test)]
    Scripted {
        chunks: std::collections::VecDeque<Vec<u8>>,
        delay: Duration,
    },
}

impl ResponseBody {
    async fn chunk(&mut self) -> Result<Option<Vec<u8>>, TransportError> {
        match self {
            Self::Http(response) => response
                .chunk()
                .await
                .map(|chunk| chunk.map(|bytes| bytes.to_vec()))
                .map_err(network_error),
            #[cfg(test)]
            Self::Scripted { chunks, delay } => {
                sleep(*delay).await;
                Ok(chunks.pop_front())
            }
        }
    }
}

fn network_error(error: reqwest::Error) -> TransportError {
    if error.is_builder() {
        TransportError::InvalidRequest
    } else if error.is_timeout() {
        TransportError::Timeout
    } else if error.is_connect() {
        TransportError::Connection
    } else {
        TransportError::Network
    }
}

impl EnrichmentHttpClient {
    #[cfg(test)]
    pub(crate) fn local_test_client(base: &str) -> Self {
        Self::build(
            Url::parse(base).unwrap(),
            Arc::new(ProviderGate::new(Duration::ZERO)),
            TransportPolicy::default(),
            "DurvaldTest/1.0 (local fixture)",
        )
        .unwrap()
    }

    /// `wikipedia_edition` must be a resolved edition, not an arbitrary user locale.
    /// A meaningful User-Agent (application/version and contact) comes from the adapter.
    pub fn new(
        provider: EnrichmentProvider,
        wikipedia_edition: Option<&str>,
        user_agent: &str,
    ) -> Result<Self, TransportError> {
        let base = match provider {
            EnrichmentProvider::MusicBrainz => "https://musicbrainz.org/".to_string(),
            EnrichmentProvider::Wikidata => "https://www.wikidata.org/".to_string(),
            EnrichmentProvider::Wikipedia => {
                let edition =
                    normalize_language(wikipedia_edition.ok_or(TransportError::Configuration)?)
                        .map_err(|_| TransportError::Configuration)?;
                format!("https://{edition}.wikipedia.org/")
            }
            EnrichmentProvider::Commons => "https://commons.wikimedia.org/".to_string(),
            EnrichmentProvider::CoverArtArchive => "https://coverartarchive.org/".to_string(),
            EnrichmentProvider::LastFm => return Err(TransportError::Configuration),
            EnrichmentProvider::TheAudioDb => "https://www.theaudiodb.com/".to_string(),
            EnrichmentProvider::YouTube => "https://www.googleapis.com/".to_string(),
        };
        Self::build(
            Url::parse(&base).map_err(|_| TransportError::Configuration)?,
            GATES[gate_index(provider)].clone(),
            TransportPolicy::default(),
            user_agent,
        )
    }

    fn build(
        base: Url,
        gate: Arc<ProviderGate>,
        policy: TransportPolicy,
        user_agent: &str,
    ) -> Result<Self, TransportError> {
        if user_agent.trim().is_empty() {
            return Err(TransportError::Configuration);
        }
        let client = Client::builder()
            .user_agent(user_agent)
            .connect_timeout(policy.connect_timeout)
            .timeout(policy.operation_timeout)
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|_| TransportError::Configuration)?;
        Ok(Self {
            client,
            base,
            gate,
            policy,
            user_agent: user_agent.into(),
            #[cfg(test)]
            scripted: None,
        })
    }

    pub async fn get_json<T: DeserializeOwned>(
        &self,
        path: &str,
        query: &[(&str, &str)],
        validators: &CacheValidators,
    ) -> Result<JsonResponse<T>, TransportError> {
        // Queries are encoded by reqwest, including keys; never splice them into a URL.
        if path.contains(['?', '#', '\\']) {
            return Err(TransportError::InvalidRequest);
        }
        let url = self
            .base
            .join(path)
            .map_err(|_| TransportError::InvalidRequest)?;
        if url.origin() != self.base.origin()
            || !url.username().is_empty()
            || url.password().is_some()
        {
            return Err(TransportError::InvalidRequest);
        }
        timeout(
            self.policy.operation_timeout,
            self.request(url, query, validators, None),
        )
        .await
        .map_err(|_| TransportError::Timeout)?
    }

    /// Fetches public JSON while allowing only explicitly trusted HTTPS
    /// redirect hosts. Query parameters and validators are not forwarded after
    /// a redirect, preventing cross-origin metadata leakage.
    pub async fn get_json_with_redirects<T: DeserializeOwned>(
        &self,
        path: &str,
        query: &[(&str, &str)],
        validators: &CacheValidators,
        allowed_hosts: &[&str],
    ) -> Result<JsonResponse<T>, TransportError> {
        if path.contains(['?', '#', '\\']) {
            return Err(TransportError::InvalidRequest);
        }
        let url = self
            .base
            .join(path)
            .map_err(|_| TransportError::InvalidRequest)?;
        if url.origin() != self.base.origin()
            || !url.username().is_empty()
            || url.password().is_some()
        {
            return Err(TransportError::InvalidRequest);
        }
        validate_public_url(&url, allowed_hosts)?;
        timeout(
            self.policy.operation_timeout,
            self.request(url, query, validators, Some(allowed_hosts)),
        )
        .await
        .map_err(|_| TransportError::Timeout)?
    }

    /// Downloads public image bytes without forwarding API credentials. Every
    /// redirect target is revalidated against the adapter's explicit host set.
    /// A dot-prefixed entry permits only subdomains of that DNS suffix.
    pub async fn get_image(
        &self,
        url: &str,
        allowed_hosts: &[&str],
    ) -> Result<Vec<u8>, TransportError> {
        let url = Url::parse(url).map_err(|_| TransportError::InvalidRequest)?;
        validate_public_url(&url, allowed_hosts)?;
        timeout(
            self.policy.operation_timeout,
            self.request_image(url, allowed_hosts),
        )
        .await
        .map_err(|_| TransportError::Timeout)?
    }

    async fn request_image(
        &self,
        mut url: Url,
        allowed_hosts: &[&str],
    ) -> Result<Vec<u8>, TransportError> {
        let _permit = self
            .gate
            .slots
            .acquire()
            .await
            .map_err(|_| TransportError::Network)?;
        let mut redirect = 0_u32;
        let mut attempt = 0_u32;
        loop {
            self.gate.wait().await;
            let request = self
                .client
                .get(url.clone())
                .header(header::USER_AGENT, self.user_agent.as_str())
                .header(header::ACCEPT, "image/jpeg,image/png")
                .build()
                .map_err(|_| TransportError::InvalidRequest)?;
            let mut response = match self.send(request).await {
                Ok(response) => response,
                Err(error) if attempt < 2 && error.is_retryable_io() => {
                    self.backoff(attempt).await;
                    attempt += 1;
                    continue;
                }
                Err(error) => return Err(error),
            };
            if response.status.is_redirection() {
                if redirect >= 3 {
                    return Err(TransportError::HttpStatus {
                        status: response.status.as_u16(),
                        retry_after_seconds: None,
                    });
                }
                let location = response
                    .headers
                    .get(header::LOCATION)
                    .and_then(|value| value.to_str().ok())
                    .ok_or(TransportError::InvalidRequest)?;
                url = url
                    .join(location)
                    .map_err(|_| TransportError::InvalidRequest)?;
                validate_public_url(&url, allowed_hosts)?;
                redirect += 1;
                continue;
            }
            if response.status == StatusCode::TOO_MANY_REQUESTS {
                let seconds = response
                    .headers
                    .get(header::RETRY_AFTER)
                    .and_then(|value| value.to_str().ok())
                    .and_then(|value| retry_after_seconds(value, chrono::Utc::now().timestamp()))
                    .unwrap_or(60);
                self.gate.defer(Duration::from_secs(seconds)).await;
                return Err(TransportError::RateLimited {
                    retry_after_seconds: seconds,
                });
            }
            let retry_after = response
                .headers
                .get(header::RETRY_AFTER)
                .and_then(|value| value.to_str().ok())
                .and_then(|value| retry_after_seconds(value, chrono::Utc::now().timestamp()));
            if response.status == StatusCode::SERVICE_UNAVAILABLE {
                if let Some(seconds @ 1..) = retry_after {
                    self.gate.defer(Duration::from_secs(seconds)).await;
                    return Err(TransportError::HttpStatus {
                        status: response.status.as_u16(),
                        retry_after_seconds: Some(seconds),
                    });
                }
            }
            if matches!(response.status.as_u16(), 500 | 502 | 503 | 504) && attempt < 2 {
                drop(response);
                self.backoff(attempt).await;
                attempt += 1;
                continue;
            }
            if !response.status.is_success() {
                return Err(TransportError::HttpStatus {
                    status: response.status.as_u16(),
                    retry_after_seconds: retry_after,
                });
            }
            if response
                .headers
                .get(header::CONTENT_TYPE)
                .and_then(|value| value.to_str().ok())
                .map(|value| value.split(';').next().unwrap_or_default().trim())
                .is_some_and(|mime| !matches!(mime, "image/jpeg" | "image/png"))
            {
                return Err(TransportError::InvalidImage);
            }
            match self
                .read_body_limit(&mut response, crate::metadata::MAX_ARTWORK_BYTES)
                .await
            {
                Err(error) if attempt < 2 && error.is_retryable_io() => {
                    self.backoff(attempt).await;
                    attempt += 1;
                }
                result => return result,
            }
        }
    }

    async fn request<T: DeserializeOwned>(
        &self,
        mut url: Url,
        mut query: &[(&str, &str)],
        validators: &CacheValidators,
        allowed_redirect_hosts: Option<&[&str]>,
    ) -> Result<JsonResponse<T>, TransportError> {
        let _permit = self
            .gate
            .slots
            .acquire()
            .await
            .map_err(|_| TransportError::Network)?;
        let mut validators = validators.clone();
        let mut redirects = 0;
        let mut attempt = 0_u32;
        loop {
            self.gate.wait().await;
            let mut request = self
                .client
                .get(url.clone())
                .header(header::USER_AGENT, self.user_agent.as_str())
                .query(query)
                .header(header::ACCEPT, "application/json");
            if let Some(etag) = &validators.etag {
                request = request.header(header::IF_NONE_MATCH, etag);
            }
            if let Some(modified) = &validators.last_modified {
                request = request.header(header::IF_MODIFIED_SINCE, modified);
            }
            let request = request
                .build()
                .map_err(|_| TransportError::InvalidRequest)?;
            let mut response = match self.send(request).await {
                Ok(response) => response,
                Err(error) => {
                    if attempt < 2 && error.is_retryable_io() {
                        self.backoff(attempt).await;
                        attempt += 1;
                        continue;
                    }
                    return Err(error);
                }
            };
            let status = response.status;
            if status.is_redirection() && status != StatusCode::NOT_MODIFIED {
                let Some(allowed_hosts) = allowed_redirect_hosts else {
                    return Err(TransportError::HttpStatus {
                        status: status.as_u16(),
                        retry_after_seconds: None,
                    });
                };
                if redirects >= 2 {
                    return Err(TransportError::HttpStatus {
                        status: status.as_u16(),
                        retry_after_seconds: None,
                    });
                }
                let location = response
                    .headers
                    .get(header::LOCATION)
                    .and_then(|value| value.to_str().ok())
                    .ok_or(TransportError::InvalidRequest)?;
                url = url
                    .join(location)
                    .map_err(|_| TransportError::InvalidRequest)?;
                validate_public_url(&url, allowed_hosts)?;
                query = &[];
                validators = CacheValidators::default();
                redirects += 1;
                continue;
            }
            let retry_after = response
                .headers
                .get(header::RETRY_AFTER)
                .and_then(|v| v.to_str().ok())
                .and_then(|v| retry_after_seconds(v, chrono::Utc::now().timestamp()));
            if status == StatusCode::TOO_MANY_REQUESTS {
                let seconds = retry_after.unwrap_or(60);
                self.gate.defer(Duration::from_secs(seconds)).await;
                return Err(TransportError::RateLimited {
                    retry_after_seconds: seconds,
                });
            }
            if status == StatusCode::SERVICE_UNAVAILABLE {
                if let Some(seconds @ 1..) = retry_after {
                    self.gate.defer(Duration::from_secs(seconds)).await;
                    return Err(TransportError::HttpStatus {
                        status: status.as_u16(),
                        retry_after_seconds: Some(seconds),
                    });
                }
            }
            if matches!(status.as_u16(), 500 | 502 | 503 | 504) && attempt < 2 {
                drop(response);
                self.backoff(attempt).await;
                attempt += 1;
                continue;
            }
            let received = CacheValidators {
                etag: response
                    .headers
                    .get(header::ETAG)
                    .and_then(|h| h.to_str().ok())
                    .map(str::to_string),
                last_modified: response
                    .headers
                    .get(header::LAST_MODIFIED)
                    .and_then(|h| h.to_str().ok())
                    .map(str::to_string),
            };
            if status == StatusCode::NOT_MODIFIED
                && (validators.etag.is_some() || validators.last_modified.is_some())
            {
                return Ok(JsonResponse::NotModified {
                    validators: CacheValidators {
                        etag: received.etag.or_else(|| validators.etag.clone()),
                        last_modified: received
                            .last_modified
                            .or_else(|| validators.last_modified.clone()),
                    },
                });
            }
            if !status.is_success() {
                return Err(TransportError::HttpStatus {
                    status: status.as_u16(),
                    retry_after_seconds: retry_after,
                });
            }
            let body = self.read_body(&mut response).await?;
            return Ok(JsonResponse::Modified {
                body: serde_json::from_slice(&body).map_err(|_| TransportError::InvalidJson)?,
                validators: received,
            });
        }
    }

    async fn backoff(&self, attempt: u32) {
        let mut random = [0u8; 1];
        let jitter = if self.policy.retry_base.is_zero() {
            0
        } else {
            let _ = ring::rand::SystemRandom::new().fill(&mut random);
            u64::from(random[0]) % 101
        };
        sleep(self.policy.retry_base * (1 << attempt) + Duration::from_millis(jitter)).await;
    }

    async fn send(&self, request: reqwest::Request) -> Result<HttpResponse, TransportError> {
        #[cfg(test)]
        if let Some(scripted) = &self.scripted {
            return scripted.send(request).await;
        }
        let response = self.client.execute(request).await.map_err(network_error)?;
        Ok(HttpResponse {
            status: response.status(),
            headers: response.headers().clone(),
            content_length: response.content_length(),
            body: ResponseBody::Http(response),
        })
    }

    async fn read_body(&self, response: &mut HttpResponse) -> Result<Vec<u8>, TransportError> {
        self.read_body_limit(response, self.policy.max_bytes).await
    }

    async fn read_body_limit(
        &self,
        response: &mut HttpResponse,
        max_bytes: usize,
    ) -> Result<Vec<u8>, TransportError> {
        if response
            .content_length
            .is_some_and(|len| len > max_bytes as u64)
        {
            return Err(TransportError::BodyTooLarge);
        }
        let mut body = Vec::new();
        while let Some(chunk) = response.body.chunk().await? {
            if body.len().saturating_add(chunk.len()) > max_bytes {
                return Err(TransportError::BodyTooLarge);
            }
            body.extend_from_slice(&chunk);
        }
        Ok(body)
    }
}

fn validate_public_url(url: &Url, allowed_hosts: &[&str]) -> Result<(), TransportError> {
    if url.scheme() != "https"
        || !url.username().is_empty()
        || url.password().is_some()
        || url.port().is_some()
        || !url.host_str().is_some_and(|host| {
            allowed_hosts.iter().any(|allowed| {
                allowed
                    .strip_prefix('.')
                    .map_or(host == *allowed, |suffix| {
                        host.len() > suffix.len()
                            && host.ends_with(suffix)
                            && host.as_bytes()[host.len() - suffix.len() - 1] == b'.'
                    })
            })
        })
    {
        return Err(TransportError::InvalidRequest);
    }
    Ok(())
}

fn retry_after_seconds(value: &str, now: i64) -> Option<u64> {
    let value = value.trim();
    let seconds = value.parse::<u64>().ok().or_else(|| {
        chrono::DateTime::parse_from_rfc2822(value)
            .ok()
            .map(|date| date.timestamp().saturating_sub(now).max(0) as u64)
    })?;
    // Bound untrusted durations to a representable monotonic-clock offset.
    Some(seconds.min(u64::from(u32::MAX)))
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::collections::VecDeque;
    use std::sync::Mutex as StdMutex;

    pub(crate) struct Step {
        pub(crate) delay: Duration,
        response: Result<HttpResponse, TransportError>,
    }

    pub(crate) struct MockTransport {
        steps: StdMutex<VecDeque<Step>>,
        requests: StdMutex<Vec<reqwest::Request>>,
    }

    impl MockTransport {
        pub(super) async fn send(
            &self,
            request: reqwest::Request,
        ) -> Result<HttpResponse, TransportError> {
            self.requests.lock().unwrap().push(request);
            let step = self
                .steps
                .lock()
                .unwrap()
                .pop_front()
                .expect("Unexpected HTTP attempt");
            sleep(step.delay).await;
            step.response
        }

        pub(crate) fn urls(&self) -> Vec<String> {
            self.requests
                .lock()
                .unwrap()
                .iter()
                .map(|r| r.url().to_string())
                .collect()
        }

        pub(crate) fn calls(&self) -> usize {
            self.requests.lock().unwrap().len()
        }
    }

    pub(crate) fn response(
        status: u16,
        headers: &[(&'static str, &'static str)],
        chunks: &[&str],
        length: Option<u64>,
    ) -> Step {
        let chunks: Vec<&[u8]> = chunks.iter().map(|chunk| chunk.as_bytes()).collect();
        response_bytes(status, headers, &chunks, length)
    }

    pub(crate) fn response_bytes(
        status: u16,
        headers: &[(&'static str, &'static str)],
        chunks: &[&[u8]],
        length: Option<u64>,
    ) -> Step {
        let mut map = header::HeaderMap::new();
        for (name, value) in headers {
            map.insert(
                header::HeaderName::from_static(name),
                header::HeaderValue::from_static(value),
            );
        }
        Step {
            delay: Duration::ZERO,
            response: Ok(HttpResponse {
                status: StatusCode::from_u16(status).unwrap(),
                headers: map,
                content_length: length,
                body: ResponseBody::Scripted {
                    chunks: chunks.iter().map(|chunk| chunk.to_vec()).collect(),
                    delay: Duration::ZERO,
                },
            }),
        }
    }

    pub(crate) fn client_for(
        base: &str,
        steps: Vec<Step>,
    ) -> (EnrichmentHttpClient, Arc<MockTransport>) {
        let scripted = Arc::new(MockTransport {
            steps: StdMutex::new(steps.into()),
            requests: StdMutex::new(Vec::new()),
        });
        let mut client = EnrichmentHttpClient::build(
            Url::parse(base).unwrap(),
            Arc::new(ProviderGate::new(Duration::ZERO)),
            TransportPolicy {
                operation_timeout: Duration::from_secs(2),
                retry_base: Duration::ZERO,
                ..Default::default()
            },
            "DurvaldTest/1.0 (in-memory fixture)",
        )
        .unwrap();
        client.scripted = Some(scripted.clone());
        (client, scripted)
    }

    pub(crate) fn client(steps: Vec<Step>) -> (EnrichmentHttpClient, Arc<MockTransport>) {
        client_for("https://musicbrainz.org/", steps)
    }

    async fn get(
        client: &EnrichmentHttpClient,
    ) -> Result<JsonResponse<serde_json::Value>, TransportError> {
        client
            .get_json("data", &[], &CacheValidators::default())
            .await
    }

    #[tokio::test(start_paused = true)]
    async fn transient_status_retries_and_keeps_conditional_metadata() {
        let (client, mock) = client(vec![
            response(503, &[], &[], None),
            response(200, &[("etag", "\"v2\"")], &["{\"ok\":true}"], None),
        ]);
        let result = get(&client).await.unwrap();
        assert!(
            matches!(result, JsonResponse::Modified { validators, .. } if validators.etag.as_deref() == Some("\"v2\""))
        );
        assert_eq!(mock.calls(), 2);
    }

    #[tokio::test(start_paused = true)]
    async fn retries_stop_after_three_attempts() {
        let (client, mock) = client((0..3).map(|_| response(502, &[], &[], None)).collect());
        assert!(matches!(
            get(&client).await,
            Err(TransportError::HttpStatus { status: 502, .. })
        ));
        assert_eq!(mock.calls(), 3);
    }

    #[tokio::test(start_paused = true)]
    async fn redirect_after_exhausted_retries_does_not_fall_through_or_leak_metadata() {
        let (client, mock) = client(vec![
            Step {
                delay: Duration::ZERO,
                response: Err(TransportError::Network),
            },
            Step {
                delay: Duration::ZERO,
                response: Err(TransportError::Timeout),
            },
            response(
                307,
                &[("location", "https://archive.org/metadata/cover")],
                &[],
                None,
            ),
            response(200, &[], &["{\"ok\":true}"], None),
        ]);
        let validators = CacheValidators {
            etag: Some("\"private-validator\"".into()),
            last_modified: None,
        };

        let result = client
            .get_json_with_redirects::<serde_json::Value>(
                "data",
                &[("key", "private-value")],
                &validators,
                &["musicbrainz.org", "archive.org"],
            )
            .await;

        assert!(result.is_ok());
        assert_eq!(mock.calls(), 4);
        let requests = mock.requests.lock().unwrap();
        assert_eq!(
            requests[3].url().as_str(),
            "https://archive.org/metadata/cover"
        );
        assert!(requests[3].headers().get(header::IF_NONE_MATCH).is_none());
    }

    #[tokio::test(start_paused = true)]
    async fn failed_connection_is_retried_without_exposing_url() {
        let (client, mock) = client(vec![
            Step {
                delay: Duration::ZERO,
                response: Err(TransportError::Network),
            },
            response(200, &[], &["{}"], None),
        ]);
        assert!(get(&client).await.is_ok());
        assert_eq!(mock.calls(), 2);
    }

    #[tokio::test(start_paused = true)]
    async fn permanent_errors_and_bad_json_are_not_retried() {
        for status in [401, 403, 404, 200] {
            let (client, mock) = client(vec![response(status, &[], &["not json"], None)]);
            let result = get(&client).await;
            if status == 200 {
                assert!(matches!(result, Err(TransportError::InvalidJson)));
            } else {
                assert!(
                    matches!(result, Err(TransportError::HttpStatus { status: actual, .. }) if actual == status)
                );
            }
            assert_eq!(mock.calls(), 1);
        }
    }

    #[tokio::test(start_paused = true)]
    async fn response_limit_applies_with_and_without_content_length() {
        for length in [Some(10), None] {
            let (mut client, mock) = client(vec![response(200, &[], &["12345", "67890"], length)]);
            client.policy.max_bytes = 8;
            assert!(matches!(
                get(&client).await,
                Err(TransportError::BodyTooLarge)
            ));
            assert_eq!(mock.calls(), 1);
        }
    }

    #[tokio::test(start_paused = true)]
    async fn rate_limit_blocks_shared_clients_until_cooldown_expires() {
        let (client, mock) = client(vec![
            response(429, &[("retry-after", "60")], &[], None),
            response(200, &[], &["{}"], None),
        ]);
        assert!(matches!(
            get(&client).await,
            Err(TransportError::RateLimited {
                retry_after_seconds: 60
            })
        ));
        let mut other = client.clone();
        other.policy.operation_timeout = Duration::from_secs(1);
        assert!(matches!(get(&other).await, Err(TransportError::Timeout)));
        assert_eq!(mock.calls(), 1);
        let independent = ProviderGate::new(Duration::ZERO);
        timeout(Duration::from_millis(1), independent.wait())
            .await
            .unwrap();
        tokio::time::advance(Duration::from_secs(60)).await;
        assert!(get(&other).await.is_ok());
        assert_eq!(mock.calls(), 2);
    }

    #[tokio::test(start_paused = true)]
    async fn unavailable_retry_after_is_returned_without_spending_retry_budget() {
        let (client, mock) = client(vec![response(503, &[("retry-after", "120")], &[], None)]);
        assert!(matches!(
            get(&client).await,
            Err(TransportError::HttpStatus {
                status: 503,
                retry_after_seconds: Some(120)
            })
        ));
        assert_eq!(mock.calls(), 1);
    }

    #[tokio::test(start_paused = true)]
    async fn zero_retry_after_on_unavailable_uses_bounded_retry_policy() {
        let (client, mock) = client(vec![
            response(503, &[("retry-after", "0")], &[], None),
            response(200, &[], &["{}"], None),
        ]);
        assert!(get(&client).await.is_ok());
        assert_eq!(mock.calls(), 2);
    }

    #[tokio::test(start_paused = true)]
    async fn timeout_covers_headers_and_streaming_body_and_releases_permits() {
        for delay_headers in [true, false] {
            let mut step = response(200, &[], &["{}"], None);
            if delay_headers {
                step.delay = Duration::from_secs(30);
            } else {
                step.response.as_mut().unwrap().body = ResponseBody::Scripted {
                    chunks: [b"{}".to_vec()].into(),
                    delay: Duration::from_secs(30),
                };
            }
            let (client, _) = client(vec![step]);
            assert!(matches!(get(&client).await, Err(TransportError::Timeout)));
            assert_eq!(client.gate.slots.available_permits(), 2);
        }
    }

    #[tokio::test(start_paused = true)]
    async fn dropping_request_cancels_work_and_releases_permits() {
        let mut step = response(200, &[], &["{}"], None);
        step.delay = Duration::from_secs(30);
        let (client, mock) = client(vec![step]);
        let task_client = client.clone();
        let task = tokio::spawn(async move { get(&task_client).await });
        tokio::task::yield_now().await;
        assert_eq!(mock.calls(), 1);
        assert_eq!(client.gate.slots.available_permits(), 1);
        task.abort();
        assert!(task.await.unwrap_err().is_cancelled());
        assert_eq!(client.gate.slots.available_permits(), 2);
    }

    #[tokio::test(start_paused = true)]
    async fn monotonic_gate_spaces_calls_and_observes_extended_cooldowns() {
        let gate = Arc::new(ProviderGate::new(Duration::from_secs(1)));
        gate.wait().await;
        let started = Instant::now();
        let waiting_gate = gate.clone();
        let waiter = tokio::spawn(async move { waiting_gate.wait().await });
        tokio::task::yield_now().await;
        gate.defer(Duration::from_secs(5)).await;
        waiter.await.unwrap();
        assert!(started.elapsed() >= Duration::from_secs(5));
    }

    #[tokio::test(start_paused = true)]
    async fn validators_query_encoding_and_not_modified_are_preserved() {
        let (client, mock) = client(vec![response(304, &[], &[], None)]);
        let validators = CacheValidators {
            etag: Some("\"v1\"".into()),
            last_modified: None,
        };
        let result = client
            .get_json::<serde_json::Value>("data", &[("artist", "AC/DC & friends")], &validators)
            .await
            .unwrap();
        assert!(
            matches!(result, JsonResponse::NotModified { validators: received } if received == validators)
        );
        let requests = mock.requests.lock().unwrap();
        assert!(
            requests[0]
                .url()
                .as_str()
                .contains("artist=AC%2FDC+%26+friends")
        );
        assert_eq!(
            requests[0].headers().get(header::IF_NONE_MATCH).unwrap(),
            "\"v1\""
        );
    }

    #[tokio::test(start_paused = true)]
    async fn redirects_and_cross_origin_requests_do_not_leak_credentials() {
        let (client, mock) = client(vec![response(
            302,
            &[("location", "https://example.com/secret")],
            &[],
            None,
        )]);
        let error = client
            .get_json::<serde_json::Value>(
                "data",
                &[("key", "private-value")],
                &CacheValidators::default(),
            )
            .await
            .unwrap_err();
        assert!(matches!(
            error,
            TransportError::HttpStatus { status: 302, .. }
        ));
        assert!(!format!("{error:?}").contains("private-value"));
        assert!(matches!(
            client
                .get_json::<serde_json::Value>(
                    "https://example.com/data",
                    &[],
                    &CacheValidators::default()
                )
                .await,
            Err(TransportError::InvalidRequest)
        ));
        assert_eq!(mock.calls(), 1);
    }

    #[tokio::test(start_paused = true)]
    async fn image_redirects_are_revalidated_against_an_explicit_host_set() {
        let (client, mock) = client(vec![response(
            302,
            &[("location", "https://evil.example/portrait.jpg")],
            &[],
            None,
        )]);
        assert!(matches!(
            client
                .get_image(
                    "https://upload.wikimedia.org/portrait.jpg",
                    &["upload.wikimedia.org"]
                )
                .await,
            Err(TransportError::InvalidRequest)
        ));
        assert_eq!(mock.calls(), 1);
        for invalid in [
            "http://upload.wikimedia.org/portrait.jpg",
            "https://user@upload.wikimedia.org/portrait.jpg",
            "https://upload.wikimedia.org:8443/portrait.jpg",
            "https://example.org/portrait.jpg",
        ] {
            assert!(
                client
                    .get_image(invalid, &["upload.wikimedia.org"])
                    .await
                    .is_err()
            );
        }
        assert_eq!(mock.calls(), 1);
        for valid in [
            "https://archive.org/download/cover.jpg",
            "https://ia801.us.archive.org/download/cover.jpg",
        ] {
            validate_public_url(
                &Url::parse(valid).unwrap(),
                &["archive.org", ".archive.org"],
            )
            .unwrap();
        }
        for invalid in [
            "https://evilarchive.org/cover.jpg",
            "https://archive.org.evil.example/cover.jpg",
        ] {
            assert!(
                validate_public_url(
                    &Url::parse(invalid).unwrap(),
                    &["archive.org", ".archive.org"]
                )
                .is_err()
            );
        }

        let (mime_client, _) = self::client(vec![response(
            200,
            &[("content-type", "text/html")],
            &["not an image"],
            None,
        )]);
        assert!(matches!(
            mime_client
                .get_image("https://musicbrainz.org/cover.jpg", &["musicbrainz.org"])
                .await,
            Err(TransportError::InvalidImage)
        ));
    }

    #[test]
    fn musicbrainz_gate_is_process_wide_and_limited_to_one_request_per_second() {
        let first = EnrichmentHttpClient::new(
            EnrichmentProvider::MusicBrainz,
            None,
            "DurvaldTest/1.0 (tests@example.test)",
        )
        .unwrap();
        let second = EnrichmentHttpClient::new(
            EnrichmentProvider::MusicBrainz,
            None,
            "DurvaldTest/1.0 (tests@example.test)",
        )
        .unwrap();
        assert!(Arc::ptr_eq(&first.gate, &second.gate));
        assert_eq!(first.gate.interval, Duration::from_secs(1));
    }

    #[test]
    fn lastfm_cannot_create_a_second_enrichment_http_client() {
        assert!(matches!(
            EnrichmentHttpClient::new(
                EnrichmentProvider::LastFm,
                None,
                "DurvaldTest/1.0 (tests@example.test)",
            ),
            Err(TransportError::Configuration)
        ));
    }

    #[tokio::test(start_paused = true)]
    async fn connection_failures_are_retried_as_transient() {
        let (client, mock) = client(vec![
            Step {
                delay: Duration::ZERO,
                response: Err(TransportError::Connection),
            },
            response(200, &[], &["{\"ok\":true}"], None),
        ]);
        assert!(get(&client).await.is_ok());
        assert_eq!(mock.calls(), 2);
    }

    #[tokio::test(start_paused = true)]
    async fn configured_user_agent_is_sent() {
        let (client, mock) = client(vec![response(200, &[], &["{\"ok\":true}"], None)]);
        get(&client).await.unwrap();
        let requests = mock.requests.lock().unwrap();
        assert_eq!(
            requests[0]
                .headers()
                .get(header::USER_AGENT)
                .and_then(|value| value.to_str().ok()),
            Some("DurvaldTest/1.0 (in-memory fixture)")
        );
    }

    #[test]
    fn retry_after_supports_seconds_and_http_dates() {
        assert_eq!(retry_after_seconds("120", 0), Some(120));
        assert_eq!(
            retry_after_seconds("Thu, 01 Jan 1970 00:02:00 GMT", 60),
            Some(60)
        );
        assert_eq!(
            retry_after_seconds("Thu, 01 Jan 1970 00:02:00 GMT", 180),
            Some(0)
        );
        assert_eq!(retry_after_seconds("invalid", 0), None);
        assert_eq!(
            gate_index(EnrichmentProvider::Wikidata),
            gate_index(EnrichmentProvider::Commons)
        );
    }
}
