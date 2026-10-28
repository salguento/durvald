//! Public metadata only. The official visible players keep control of media URLs.
mod bandcamp;
mod soundcloud;
mod youtube;
use crate::{
    api::*,
    application::{
        music_catalog::IntegrationFuture,
        music_plugins::{MusicPlugin, PluginContext},
        service_collection_ports::*,
    },
    domain::music::{ContractError, IntegrationError as E, identity::ProviderId, plugins::*},
};
use reqwest::header::{HeaderMap, HeaderValue};
use std::{collections::BTreeMap, sync::Arc, time::Duration};
use url::Url;
#[derive(Clone)]
pub(crate) struct Location {
    pub(crate) provider: ServiceProvider,
    pub(crate) url: String,
    pub(crate) id: String,
    pub(crate) collection: bool,
}
pub(crate) fn locate(value: &str) -> Result<Location, E> {
    let input = value.trim();
    if input.len() > 2048 || input.chars().any(char::is_control) {
        return Err(invalid());
    }
    let mut u = Url::parse(input).map_err(|_| invalid())?;
    if u.scheme() != "https"
        || u.port().is_some()
        || !u.username().is_empty()
        || u.password().is_some()
    {
        return Err(invalid());
    }
    let parts: Vec<_> = u
        .path_segments()
        .ok_or_else(invalid)?
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
        .collect();
    let host = u.host_str().ok_or_else(invalid)?.to_owned();
    let (provider, id, collection) = if host == "soundcloud.com" || host == "www.soundcloud.com" {
        let collection = parts.len() == 3 && parts[1] == "sets";
        if !collection && super::service_links::canonical_link(input).is_none() {
            return Err(invalid());
        }
        u.set_host(Some("soundcloud.com")).map_err(|_| invalid())?;
        (ServiceProvider::SoundCloud, parts.join("/"), collection)
    } else if host.ends_with(".bandcamp.com")
        && host.split('.').count() == 3
        && parts.len() == 2
        && ["track", "album"].contains(&parts[0].as_str())
    {
        (
            ServiceProvider::Bandcamp,
            format!("{host}/{}", parts.join("/")),
            parts[0] == "album",
        )
    } else if [
        "youtube.com",
        "www.youtube.com",
        "m.youtube.com",
        "youtu.be",
    ]
    .contains(&host.as_str())
    {
        if parts.as_slice() == ["playlist"] {
            let id = u
                .query_pairs()
                .find(|(k, _)| k == "list")
                .map(|(_, v)| v.into_owned())
                .filter(|s| {
                    s.len() >= 12
                        && s.len() <= 128
                        && !s.starts_with("RD")
                        && s.bytes()
                            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_'))
                })
                .ok_or_else(invalid)?;
            u = Url::parse("https://www.youtube.com/playlist").unwrap();
            u.query_pairs_mut().append_pair("list", &id);
            (ServiceProvider::YouTube, id, true)
        } else {
            let media = super::service_links::canonical_link(input)
                .filter(|m| m.entity().provider().as_str() == "youtube")
                .ok_or_else(invalid)?;
            u = Url::parse(media.canonical_url().as_str()).unwrap();
            (
                ServiceProvider::YouTube,
                media.entity().external_id().into(),
                false,
            )
        }
    } else {
        return Err(invalid());
    };
    if provider != ServiceProvider::YouTube {
        u.set_query(None);
    }
    u.set_fragment(None);
    Ok(Location {
        provider,
        url: u.as_str().into(),
        id,
        collection,
    })
}
fn invalid() -> E {
    E::InvalidInput(ContractError::InvalidSearch)
}
pub(crate) fn plugin_id(p: ServiceProvider) -> &'static str {
    match p {
        ServiceProvider::Bandcamp => "bandcamp-catalog",
        ServiceProvider::SoundCloud => "soundcloud-catalog",
        ServiceProvider::YouTube => "youtube-catalog",
    }
}
pub(crate) fn credential_key(p: ServiceProvider) -> Option<&'static str> {
    match p {
        ServiceProvider::Bandcamp => None,
        ServiceProvider::SoundCloud => Some("oauth_token"),
        ServiceProvider::YouTube => Some("api_key"),
    }
}
pub(crate) fn provider_name(p: ServiceProvider) -> &'static str {
    match p {
        ServiceProvider::Bandcamp => "bandcamp",
        ServiceProvider::SoundCloud => "soundcloud",
        ServiceProvider::YouTube => "youtube",
    }
}
pub(crate) struct Response {
    pub(crate) status: u16,
    pub(crate) location: Option<String>,
    pub(crate) retry: Option<u64>,
    pub(crate) body: Vec<u8>,
}
pub(crate) trait ServiceHttp: Send + Sync {
    fn get(&self, url: Url, headers: HeaderMap) -> IntegrationFuture<'_, Response>;
}
struct Http;
impl ServiceHttp for Http {
    fn get(&self, url: Url, headers: HeaderMap) -> IntegrationFuture<'_, Response> {
        Box::pin(async move {
            let client = reqwest::Client::builder()
                .redirect(reqwest::redirect::Policy::none())
                .connect_timeout(Duration::from_secs(3))
                .timeout(Duration::from_secs(8))
                .user_agent("Durvald/0.1 public-service-metadata")
                .build()
                .map_err(|_| E::TemporarilyUnavailable)?;
            let mut r = client.get(url).headers(headers).send().await.map_err(|e| {
                if e.is_timeout() {
                    E::Timeout
                } else {
                    E::TemporarilyUnavailable
                }
            })?;
            let mut result = Response {
                status: r.status().as_u16(),
                location: r
                    .headers()
                    .get("location")
                    .and_then(|v| v.to_str().ok())
                    .map(str::to_owned),
                retry: r
                    .headers()
                    .get("retry-after")
                    .and_then(|v| v.to_str().ok())
                    .and_then(|v| v.parse::<u64>().ok())
                    .map(|s| s.min(3600)),
                body: vec![],
            };
            const MAX: usize = 8 * 1024 * 1024;
            if r.content_length().is_some_and(|n| n > MAX as u64) {
                return Err(E::InvalidResponse);
            }
            while let Some(chunk) = r.chunk().await.map_err(|_| E::TemporarilyUnavailable)? {
                if result.body.len() + chunk.len() > MAX {
                    return Err(E::InvalidResponse);
                }
                result.body.extend_from_slice(&chunk);
            }
            Ok(result)
        })
    }
}
pub(crate) struct PublicService {
    pub(crate) provider: ServiceProvider,
    pub(crate) http: Arc<dyn ServiceHttp>,
}
impl PublicService {
    pub(crate) fn new(provider: ServiceProvider) -> Self {
        Self {
            provider,
            http: Arc::new(Http),
        }
    }
}
impl MusicPlugin for PublicService {
    fn manifest(&self) -> PluginManifest {
        let credentials = credential_key(self.provider)
            .map(|k| BTreeMap::from([(k.into(), false)]))
            .unwrap_or_default();
        PluginManifest {
            id: ProviderId::new(plugin_id(self.provider)).unwrap(),
            version: PluginVersion {
                major: 1,
                minor: 0,
                patch: 0,
            },
            api_version: PLUGIN_API_VERSION,
            capabilities: [PluginCapability::CollectionRead].into(),
            permissions: if credentials.is_empty() {
                [PluginPermission::Network].into()
            } else {
                [PluginPermission::Network, PluginPermission::Credentials].into()
            },
            primary_host: Some(
                match self.provider {
                    ServiceProvider::Bandcamp => "bandcamp.com",
                    ServiceProvider::SoundCloud => "api.soundcloud.com",
                    ServiceProvider::YouTube => "www.googleapis.com",
                }
                .into(),
            ),
            settings: Default::default(),
            flags: Default::default(),
            credentials,
        }
    }
    fn collection_reader(&self) -> Option<&dyn ServiceCollectionReader> {
        Some(self)
    }
}
impl ServiceCollectionReader for PublicService {
    fn read(
        &self,
        context: PluginContext,
        request: ServicePageRequest,
    ) -> IntegrationFuture<'_, ServicePage> {
        Box::pin(async move {
            let location = locate(&request.url)?;
            if location.provider != self.provider {
                return Err(invalid());
            }
            match self.provider {
                ServiceProvider::Bandcamp => {
                    bandcamp::read(self.http.as_ref(), location, request.cursor).await
                }
                ServiceProvider::SoundCloud => {
                    soundcloud::read(self.http.as_ref(), context, location, request.cursor).await
                }
                ServiceProvider::YouTube => {
                    youtube::read(self.http.as_ref(), context, location, request.cursor).await
                }
            }
        })
    }
}
fn status(response: &Response) -> Result<(), E> {
    match response.status {
        200 => Ok(()),
        401 => Err(E::AuthenticationRequired),
        403 => Err(E::AccessDenied),
        404 | 410 => Err(E::NotFound),
        429 => Err(E::RateLimited {
            retry_after_seconds: response.retry,
        }),
        _ => Err(E::TemporarilyUnavailable),
    }
}
async fn json(
    http: &dyn ServiceHttp,
    url: Url,
    headers: HeaderMap,
) -> Result<serde_json::Value, E> {
    let r = http.get(url, headers).await?;
    status(&r)?;
    serde_json::from_slice(&r.body).map_err(|_| E::InvalidResponse)
}
fn headers(context: &PluginContext, provider: ServiceProvider) -> Result<HeaderMap, E> {
    let key = context
        .credential(credential_key(provider).ok_or(E::AuthenticationRequired)?)
        .ok_or(E::AuthenticationRequired)?;
    let value = if provider == ServiceProvider::SoundCloud {
        format!("OAuth {}", key.expose())
    } else {
        key.expose().to_owned()
    };
    let mut v = HeaderValue::from_str(&value).map_err(|_| E::AuthenticationRequired)?;
    v.set_sensitive(true);
    let mut headers = HeaderMap::new();
    headers.insert(
        if provider == ServiceProvider::SoundCloud {
            "authorization"
        } else {
            "x-goog-api-key"
        },
        v,
    );
    Ok(headers)
}
fn text(value: &serde_json::Value, key: &str) -> Option<String> {
    value
        .get(key)
        .and_then(|v| v.as_str())
        .filter(|s| !s.trim().is_empty() && s.len() <= 2000 && !s.chars().any(char::is_control))
        .map(str::to_owned)
}
fn item(
    position: u32,
    occurrence: String,
    entry: Option<CatalogEntry>,
    access: ServiceMediaAccess,
) -> ServiceCollectionItem {
    ServiceCollectionItem {
        occurrence_id: occurrence,
        position,
        entry,
        access,
        saved_track_id: None,
        failure: None,
    }
}
fn entry(
    url: &str,
    title: String,
    artist: Option<String>,
    duration: Option<u64>,
) -> Option<CatalogEntry> {
    let m = super::service_links::canonical_link(url)?;
    Some(CatalogEntry {
        reference: CatalogReference {
            provider: m.entity().provider().as_str().into(),
            kind: if m.entity().provider().as_str() == "youtube" {
                CatalogItemKind::Video
            } else {
                CatalogItemKind::AudioTrack
            },
            id: m.entity().external_id().into(),
        },
        title,
        artist_credit: artist,
        version_label: None,
        duration_seconds: duration,
        canonical_url: Some(m.canonical_url().as_str().into()),
    })
}
fn snapshot_cursor(cursor: Option<String>, revision: &str) -> Result<usize, E> {
    if let Some(cursor) = cursor {
        let (n, hash) = cursor.split_once(':').ok_or_else(invalid)?;
        if hash != revision {
            return Err(E::InvalidResponse);
        }
        let n = n.parse::<usize>().map_err(|_| invalid())?;
        if n == 0 || n > 1000 || n % 50 != 0 {
            return Err(invalid());
        }
        Ok(n)
    } else {
        Ok(0)
    }
}
fn revision(ids: &[String]) -> String {
    use sha2::{Digest, Sha256};
    format!("{:x}", Sha256::digest(serde_json::to_vec(ids).unwrap()))
}

#[cfg(test)]
mod tests;
