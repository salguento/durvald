//! REST adapter for a user-owned daemon. Never manages shares or transfers.
use crate::{
    api::*,
    application::{
        music_catalog::{DownloadSearchHandle, DownloadSearcher, IntegrationFuture},
        music_plugins::{MusicPlugin, PluginContext},
    },
    domain::music::{IntegrationError as E, identity::ProviderId, plugins::*},
};
use reqwest::{Client, Method};
use serde::Deserialize;
use std::{
    collections::BTreeMap,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};
use url::Url;
pub(crate) struct SlskdSearch;
pub(crate) fn endpoint(value: &str) -> Result<Url, PluginError> {
    let mut url = Url::parse(value.trim()).map_err(|_| PluginError::InvalidConfiguration)?;
    let local = matches!(url.host_str(), Some("localhost" | "127.0.0.1" | "[::1]"));
    if value.chars().any(char::is_control)
        || value.len() > 2048
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
        || !(url.scheme() == "https" || (url.scheme() == "http" && local))
    {
        return Err(PluginError::InvalidConfiguration);
    }
    let path = url.path().trim_end_matches('/');
    let path = if path.ends_with("/api/v0") {
        format!("{path}/")
    } else {
        format!("{path}/api/v0/")
    };
    url.set_path(&path);
    Ok(url)
}
impl MusicPlugin for SlskdSearch {
    fn manifest(&self) -> PluginManifest {
        PluginManifest {
            id: ProviderId::new("slskd").unwrap(),
            version: PluginVersion {
                major: 1,
                minor: 0,
                patch: 0,
            },
            api_version: PLUGIN_API_VERSION,
            capabilities: [PluginCapability::DownloadSearch].into(),
            permissions: [PluginPermission::Network, PluginPermission::Credentials].into(),
            primary_host: Some("localhost".into()),
            settings: BTreeMap::from([(
                "endpoint".into(),
                ConfigurationField {
                    required: true,
                    default: Some("http://127.0.0.1:5030".into()),
                },
            )]),
            flags: ["sharing_acknowledged".into()].into(),
            // Missing/unavailable credentials must not prevent the library opening.
            credentials: BTreeMap::from([("api_key".into(), false)]),
        }
    }
    fn validate_configuration(&self, c: &PluginConfiguration) -> Result<(), PluginError> {
        endpoint(
            c.values
                .get("endpoint")
                .map(String::as_str)
                .unwrap_or_default(),
        )
        .map(|_| ())
    }
    fn request_host(&self, c: &PluginConfiguration) -> Option<String> {
        endpoint(c.values.get("endpoint")?)
            .ok()?
            .host_str()
            .map(str::to_owned)
    }
    fn download_search(&self) -> Option<&dyn DownloadSearcher> {
        Some(self)
    }
}
impl DownloadSearcher for SlskdSearch {
    fn begin(
        &self,
        context: PluginContext,
        request: DownloadSearchRequest,
    ) -> IntegrationFuture<'_, Arc<dyn DownloadSearchHandle>> {
        Box::pin(async move {
            if !context
                .configuration
                .flags
                .get("sharing_acknowledged")
                .copied()
                .unwrap_or(false)
            {
                return Err(E::AccessDenied);
            }
            let base = endpoint(
                context
                    .configuration
                    .values
                    .get("endpoint")
                    .map(String::as_str)
                    .unwrap_or_default(),
            )
            .map_err(|_| E::InvalidResponse)?;
            let key = context
                .credential("api_key")
                .ok_or(E::AuthenticationRequired)?;
            let mut header = reqwest::header::HeaderValue::from_str(key.expose())
                .map_err(|_| E::AuthenticationRequired)?;
            header.set_sensitive(true);
            let client = Client::builder()
                .default_headers(
                    [(
                        reqwest::header::HeaderName::from_static("x-api-key"),
                        header,
                    )]
                    .into_iter()
                    .collect(),
                )
                .redirect(reqwest::redirect::Policy::none())
                .no_proxy()
                .connect_timeout(Duration::from_secs(3))
                .timeout(Duration::from_secs(5))
                .build()
                .map_err(|_| E::TemporarilyUnavailable)?;
            let id = search_id()?;
            let lease = Arc::new(Lease {
                client,
                base,
                id,
                cleanup_claimed: AtomicBool::new(false),
            });
            let body = serde_json::json!({"id":lease.id,"searchText":request.query,"searchTimeout":20000,"responseLimit":200,"fileLimit":5000});
            let created = lease.json(Method::POST, "searches", Some(body)).await?;
            if created.get("id").and_then(|v| v.as_str()) != Some(lease.id.as_str()) {
                return Err(E::InvalidResponse);
            }
            Ok(lease as Arc<dyn DownloadSearchHandle>)
        })
    }
}
fn search_id() -> Result<String, E> {
    use ring::rand::{SecureRandom, SystemRandom};
    let mut bytes = [0u8; 16];
    SystemRandom::new()
        .fill(&mut bytes)
        .map_err(|_| E::TemporarilyUnavailable)?;
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    let h = bytes.iter().map(|b| format!("{b:02x}")).collect::<String>();
    Ok(format!(
        "{}-{}-{}-{}-{}",
        &h[..8],
        &h[8..12],
        &h[12..16],
        &h[16..20],
        &h[20..]
    ))
}
struct Lease {
    client: Client,
    base: Url,
    id: String,
    cleanup_claimed: AtomicBool,
}
impl Lease {
    async fn json(
        &self,
        method: Method,
        path: &str,
        body: Option<serde_json::Value>,
    ) -> Result<serde_json::Value, E> {
        request(&self.client, &self.base, method, path, body).await
    }
}
async fn request(
    client: &Client,
    base: &Url,
    method: Method,
    path: &str,
    body: Option<serde_json::Value>,
) -> Result<serde_json::Value, E> {
    let url = base.join(path).map_err(|_| E::InvalidResponse)?;
    let mut req = client.request(method, url);
    if let Some(body) = body {
        req = req.json(&body);
    }
    let mut response = req.send().await.map_err(network)?;
    match response.status().as_u16() {
        200..=299 => {}
        401 | 403 => return Err(E::AuthenticationRequired),
        404 => return Err(E::NotFound),
        429 => {
            return Err(E::RateLimited {
                retry_after_seconds: response
                    .headers()
                    .get("retry-after")
                    .and_then(|v| v.to_str().ok())
                    .and_then(|v| v.parse::<u64>().ok())
                    .map(|v| v.min(300)),
            });
        }
        _ => return Err(E::TemporarilyUnavailable),
    }
    const MAX: usize = 8 * 1024 * 1024;
    if response.content_length().is_some_and(|l| l > MAX as u64) {
        return Err(E::InvalidResponse);
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(network)? {
        if bytes.len().saturating_add(chunk.len()) > MAX {
            return Err(E::InvalidResponse);
        }
        bytes.extend_from_slice(&chunk);
    }
    if bytes.is_empty() {
        return Ok(serde_json::Value::Null);
    }
    serde_json::from_slice(&bytes).map_err(|_| E::InvalidResponse)
}
fn network(e: reqwest::Error) -> E {
    if e.is_timeout() {
        E::Timeout
    } else {
        E::TemporarilyUnavailable
    }
}
async fn cleanup(client: &Client, base: &Url, id: &str) -> Result<(), E> {
    let result = tokio::time::timeout(Duration::from_secs(6), async {
        let stop = request(client, base, Method::PUT, &format!("searches/{id}"), None).await;
        let remove = request(
            client,
            base,
            Method::DELETE,
            &format!("searches/{id}"),
            None,
        )
        .await;
        match (stop, remove) {
            (_, Ok(_)) | (_, Err(E::NotFound)) => Ok(()),
            (Err(e), _) | (_, Err(e)) => Err(e),
        }
    })
    .await;
    result.unwrap_or(Err(E::Timeout))
}
impl DownloadSearchHandle for Lease {
    fn poll(&self) -> IntegrationFuture<'_, DownloadSearchPage> {
        Box::pin(async move {
            let status = self
                .json(Method::GET, &format!("searches/{}", self.id), None)
                .await?;
            let state = status
                .get("state")
                .and_then(|v| v.as_str())
                .ok_or(E::InvalidResponse)?;
            let raw = self
                .json(
                    Method::GET,
                    &format!("searches/{}/responses", self.id),
                    None,
                )
                .await?;
            let responses: Vec<Response> =
                serde_json::from_value(raw).map_err(|_| E::InvalidResponse)?;
            let (groups, truncated) = groups(responses)?;
            let state = if state.contains("Errored") || state.contains("Failed") {
                return Err(E::TemporarilyUnavailable);
            } else if state.contains("TimedOut") {
                DownloadSearchState::TimedOut
            } else if state.contains("Cancelled") {
                DownloadSearchState::Cancelled
            } else if state.contains("Completed") {
                DownloadSearchState::Completed
            } else if state == "InProgress" || state == "Requested" {
                DownloadSearchState::Searching
            } else {
                return Err(E::InvalidResponse);
            };
            Ok(DownloadSearchPage {
                generation: 0,
                state,
                groups,
                failure: None,
                truncated,
                cleanup_pending: false,
            })
        })
    }
    fn cancel(&self) -> IntegrationFuture<'_, ()> {
        Box::pin(async move {
            if self.cleanup_claimed.swap(true, Ordering::SeqCst) {
                return Ok(());
            }
            cleanup(&self.client, &self.base, &self.id).await
        })
    }
}
impl Drop for Lease {
    fn drop(&mut self) {
        if !self.cleanup_claimed.swap(true, Ordering::SeqCst)
            && let Ok(runtime) = tokio::runtime::Handle::try_current()
        {
            let (client, base, id) = (self.client.clone(), self.base.clone(), self.id.clone());
            // Bounded cleanup of this UUID only, including cancellation during POST.
            runtime.spawn(async move {
                let _ = cleanup(&client, &base, &id).await;
            });
        }
    }
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Response {
    username: String,
    #[serde(default)]
    files: Vec<File>,
    has_free_upload_slot: Option<bool>,
    queue_length: Option<u64>,
    upload_speed: Option<u64>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct File {
    filename: String,
    size: u64,
    bit_rate: Option<u32>,
    length: Option<u64>,
    sample_rate: Option<u32>,
    bit_depth: Option<u32>,
    #[serde(default)]
    is_locked: bool,
}
fn groups(responses: Vec<Response>) -> Result<(Vec<DownloadOfferGroup>, bool), E> {
    let mut map: BTreeMap<(String, String), DownloadOfferGroup> = BTreeMap::new();
    let mut truncated = responses.len() > 200;
    let mut file_count = 0;
    for response in responses.into_iter().take(200) {
        if response.username.is_empty()
            || response.username.len() > 512
            || response.username.chars().any(char::is_control)
        {
            return Err(E::InvalidResponse);
        }
        for file in response.files {
            if file_count >= 5000 {
                truncated = true;
                break;
            }
            if file.is_locked
                || file.filename.len() > 4096
                || file.filename.chars().any(char::is_control)
            {
                continue;
            }
            let normalized = file.filename.replace('\\', "/");
            let Some((folder, name)) = normalized.rsplit_once('/') else {
                continue;
            };
            let folder = if crate::application::download_search::disc_folder(folder).is_some() {
                folder
                    .rsplit_once('/')
                    .map(|(parent, _)| parent)
                    .unwrap_or(folder)
            } else {
                folder
            };
            let format = name
                .rsplit_once('.')
                .map(|(_, e)| e.to_ascii_lowercase())
                .unwrap_or_default();
            if ![
                "flac", "mp3", "ogg", "oga", "wav", "m4a", "aac", "opus", "aiff", "alac",
            ]
            .contains(&format.as_str())
            {
                continue;
            }
            let group = map
                .entry((response.username.clone(), folder.into()))
                .or_insert_with(|| DownloadOfferGroup {
                    offer_id: String::new(),
                    peer: response.username.clone(),
                    folder: folder.into(),
                    files: vec![],
                    total_bytes: 0,
                    free_upload_slot: response.has_free_upload_slot,
                    queue_length: response.queue_length,
                    upload_speed_bytes: response.upload_speed,
                    matched_tracks: 0,
                    expected_tracks: 0,
                    duration_matches: 0,
                    comparison: String::new(),
                });
            if group.files.iter().any(|f| f.filename == file.filename) {
                continue;
            }
            group.total_bytes = group.total_bytes.saturating_add(file.size);
            group.files.push(DownloadOfferFile {
                filename: file.filename,
                size_bytes: file.size,
                format,
                duration_seconds: file.length.filter(|v| *v > 0),
                bitrate_kbps: file.bit_rate.filter(|v| *v > 0),
                sample_rate_hz: file.sample_rate.filter(|v| *v > 0),
                bit_depth: file.bit_depth.filter(|v| *v > 0),
            });
            file_count += 1;
        }
    }
    let mut groups: Vec<_> = map.into_values().collect();
    for g in &mut groups {
        g.files.sort_by(|a, b| a.filename.cmp(&b.filename));
    }
    Ok((groups, truncated))
}
