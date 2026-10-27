//! Lightweight discovery: one search per requested entity index, never candidate enrichment.
use crate::{
    application::{
        music_catalog::{CatalogReader, IntegrationFuture},
        music_plugins::{MusicPlugin, PluginContext},
    },
    domain::music::{ContractError, IntegrationError, catalog::*, identity::*, plugins::*},
    enrichment::{
        cache,
        identity::normalize_mbid,
        models::CacheValidators,
        providers::musicbrainz::{MusicBrainz, phrase},
        transport::{JsonResponse, TransportError},
    },
};
use serde::{Deserialize, Serialize};
use std::{collections::BTreeMap, sync::OnceLock, time::Duration};

const SEARCH_TTL: Duration = Duration::from_secs(15 * 60);
pub(crate) struct MusicBrainzCatalog {
    client: OnceLock<Result<MusicBrainz, TransportError>>,
    lastfm: Option<std::sync::Arc<crate::lastfm::LastFmClient>>,
}
impl MusicBrainzCatalog {
    pub(crate) fn new() -> Self {
        Self {
            client: OnceLock::new(),
            lastfm: None,
        }
    }
    pub(crate) fn with_lastfm(client: std::sync::Arc<crate::lastfm::LastFmClient>) -> Self {
        Self {
            lastfm: Some(client),
            ..Self::new()
        }
    }
    #[cfg(test)]
    fn with_http(http: crate::enrichment::transport::EnrichmentHttpClient) -> Self {
        Self {
            client: OnceLock::from(Ok(MusicBrainz { http })),
            lastfm: None,
        }
    }
}
impl MusicPlugin for MusicBrainzCatalog {
    fn manifest(&self) -> PluginManifest {
        PluginManifest {
            id: ProviderId::new("musicbrainz").expect("built-in ID"),
            version: PluginVersion {
                major: 1,
                minor: 0,
                patch: 0,
            },
            api_version: PLUGIN_API_VERSION,
            capabilities: [PluginCapability::CatalogSearch, PluginCapability::Metadata].into(),
            permissions: [PluginPermission::Network].into(),
            primary_host: Some("musicbrainz.org".into()),
            settings: BTreeMap::new(),
            flags: Default::default(),
            credentials: BTreeMap::new(),
        }
    }
    fn catalog(&self) -> Option<&dyn CatalogReader> {
        Some(self)
    }
}
impl CatalogReader for MusicBrainzCatalog {
    fn search(
        &self,
        context: PluginContext,
        request: CatalogSearchRequest,
    ) -> IntegrationFuture<'_, CatalogSearchPage> {
        Box::pin(async move {
            if request.scope != SearchScope::Explore || request.page_size() > 50 {
                return Err(invalid());
            }
            let direct = musicbrainz_url(request.query())?;
            if direct.is_some() {
                if request.cursor().is_some() {
                    return Err(invalid());
                }
            } else {
                let indexes = if request.filter == SearchEntityFilter::All {
                    3
                } else {
                    1
                };
                SearchCursor::read(&request, "musicbrainz", indexes)
                    .map_err(IntegrationError::InvalidInput)?;
            }
            let key = cache::key(
                "catalog-search:v1:musicbrainz",
                &serde_json::to_string(&(
                    query_fingerprint(&request, "musicbrainz"),
                    request.cursor(),
                ))
                .map_err(|_| invalid())?,
            );
            let _lock = cache::request_lock(&key).await.map_err(map_error)?;
            if let Some(entry) = cache::load(&key)
                .await
                .map_err(map_error)?
                .filter(|entry| entry.fresh() && entry.failure.is_none())
            {
                if let Ok(cached) = serde_json::from_slice::<CachedPage>(&entry.body) {
                    if let Ok(page) = cached.into_page() {
                        return Ok(page);
                    }
                }
            }
            if request.is_cache_only() {
                return Ok(CatalogSearchPage {
                    items: vec![],
                    next_cursor: None,
                    from_cache: false,
                });
            }
            if context.is_cancelled() {
                return Err(IntegrationError::Cancelled);
            }
            let client = self
                .client
                .get_or_init(MusicBrainz::new)
                .as_ref()
                .map_err(|error| map_error(error.clone()))?;
            let page = if let Some((endpoint, kind, id)) = direct {
                let params = if kind == ExternalEntityKind::Artist {
                    vec![("fmt", "json")]
                } else {
                    vec![("fmt", "json"), ("inc", "artist-credits")]
                };
                let JsonResponse::Modified { body, .. } = client
                    .http
                    .get_json::<RemoteItem>(
                        &format!("ws/2/{endpoint}/{id}"),
                        &params,
                        &CacheValidators::default(),
                    )
                    .await
                    .map_err(map_error)?
                else {
                    return Err(IntegrationError::InvalidResponse);
                };
                CatalogSearchPage {
                    items: vec![body.summary(kind)?],
                    next_cursor: None,
                    from_cache: false,
                }
            } else {
                let endpoints = match request.filter {
                    SearchEntityFilter::All => vec![
                        ("artist", ExternalEntityKind::Artist),
                        ("release-group", ExternalEntityKind::ReleaseGroup),
                        ("recording", ExternalEntityKind::Recording),
                    ],
                    SearchEntityFilter::Artists => vec![("artist", ExternalEntityKind::Artist)],
                    SearchEntityFilter::Releases => {
                        vec![("release-group", ExternalEntityKind::ReleaseGroup)]
                    }
                    SearchEntityFilter::Tracks => {
                        vec![("recording", ExternalEntityKind::Recording)]
                    }
                };
                let mut offsets = SearchCursor::read(&request, "musicbrainz", endpoints.len())
                    .map_err(IntegrationError::InvalidInput)?;
                let mut items = Vec::new();
                for (index, (endpoint, kind)) in endpoints.iter().enumerate() {
                    let Some(offset) = offsets[index] else {
                        continue;
                    };
                    let field = match kind {
                        ExternalEntityKind::Artist => "artist",
                        ExternalEntityKind::ReleaseGroup => "releasegroup",
                        _ => "recording",
                    };
                    let query = format!("{field}:{}", phrase(&normalized_query(request.query())));
                    let limit = request.page_size().to_string();
                    let offset_value = offset.to_string();
                    let JsonResponse::Modified { body, .. } = client
                        .http
                        .get_json::<RemotePage>(
                            &format!("ws/2/{endpoint}/"),
                            &[
                                ("query", &query),
                                ("fmt", "json"),
                                ("limit", &limit),
                                ("offset", &offset_value),
                            ],
                            &CacheValidators::default(),
                        )
                        .await
                        .map_err(map_error)?
                    else {
                        return Err(IntegrationError::InvalidResponse);
                    };
                    let rows = match kind {
                        ExternalEntityKind::Artist => body.artists,
                        ExternalEntityKind::ReleaseGroup => body.groups,
                        _ => body.recordings,
                    };
                    if body.offset != offset
                        || rows.len() > request.page_size() as usize
                        || (rows.is_empty() && body.count > offset)
                    {
                        return Err(IntegrationError::InvalidResponse);
                    }
                    let end = offset + rows.len() as u64;
                    offsets[index] = (end < body.count && end <= u32::MAX as u64).then_some(end);
                    items.extend(
                        rows.into_iter()
                            .map(|row| row.summary(*kind))
                            .collect::<Result<Vec<_>, _>>()?,
                    );
                }
                CatalogSearchPage {
                    items,
                    next_cursor: SearchCursor::encode(&request, "musicbrainz", offsets),
                    from_cache: false,
                }
            };
            cache::store(
                &key,
                &cache::entry(
                    serde_json::to_vec(&CachedPage::from_page(&page)?)
                        .map_err(|_| IntegrationError::InvalidResponse)?,
                    CacheValidators::default(),
                    SEARCH_TTL,
                ),
            )
            .await
            .map_err(map_error)?;
            Ok(page)
        })
    }
    fn detail_section(
        &self,
        _context: PluginContext,
        request: crate::api::CatalogDetailRequest,
    ) -> IntegrationFuture<'_, crate::api::CatalogDetailPage> {
        Box::pin(self.load_section(request))
    }
    fn details(
        &self,
        _context: PluginContext,
        target: CatalogEntityRef,
    ) -> IntegrationFuture<'_, CatalogEntityDetails> {
        Box::pin(self.legacy_details(target))
    }
}
fn invalid() -> IntegrationError {
    IntegrationError::InvalidInput(ContractError::InvalidSearch)
}
fn map_error(error: TransportError) -> IntegrationError {
    match error {
        TransportError::RateLimited {
            retry_after_seconds,
        } => IntegrationError::RateLimited {
            retry_after_seconds: Some(retry_after_seconds),
        },
        TransportError::HttpStatus {
            status: 429,
            retry_after_seconds,
        } => IntegrationError::RateLimited {
            retry_after_seconds,
        },
        TransportError::HttpStatus { status: 404, .. } => IntegrationError::NotFound,
        TransportError::HttpStatus {
            status: 400 | 422, ..
        } => invalid(),
        TransportError::Timeout => IntegrationError::Timeout,
        TransportError::InvalidJson | TransportError::BodyTooLarge => {
            IntegrationError::InvalidResponse
        }
        _ => IntegrationError::TemporarilyUnavailable,
    }
}

pub(crate) fn musicbrainz_url(
    value: &str,
) -> Result<Option<(&'static str, ExternalEntityKind, String)>, IntegrationError> {
    if !value.starts_with("https://") && !value.starts_with("http://") {
        return Ok(None);
    }
    let url = url::Url::parse(value).map_err(|_| invalid())?;
    if !matches!(
        url.host_str(),
        Some("musicbrainz.org" | "www.musicbrainz.org")
    ) || !url.username().is_empty()
        || url.password().is_some()
        || url.port().is_some()
        || url.query().is_some()
    {
        return Err(invalid());
    }
    let parts = url.path().trim_matches('/').split('/').collect::<Vec<_>>();
    if parts.len() != 2 {
        return Err(invalid());
    }
    let id = normalize_mbid(parts[1]).ok_or_else(invalid)?;
    let kind = match parts[0] {
        "artist" => ("artist", ExternalEntityKind::Artist),
        "release-group" => ("release-group", ExternalEntityKind::ReleaseGroup),
        "release" => ("release", ExternalEntityKind::ReleaseEdition),
        "recording" => ("recording", ExternalEntityKind::Recording),
        _ => return Err(invalid()),
    };
    Ok(Some((kind.0, kind.1, id)))
}
#[derive(Deserialize)]
struct RemotePage {
    count: u64,
    offset: u64,
    #[serde(default)]
    artists: Vec<RemoteItem>,
    #[serde(default, rename = "release-groups")]
    groups: Vec<RemoteItem>,
    #[serde(default)]
    recordings: Vec<RemoteItem>,
}
#[derive(Deserialize)]
struct RemoteItem {
    id: String,
    name: Option<String>,
    title: Option<String>,
    #[serde(default)]
    disambiguation: String,
    #[serde(default, rename = "artist-credit")]
    credit: Vec<Credit>,
    length: Option<u64>,
    #[serde(rename = "first-release-date")]
    date: Option<String>,
    #[serde(rename = "type")]
    kind: Option<String>,
}
#[derive(Deserialize)]
struct Credit {
    name: Option<String>,
    artist: Option<CreditArtist>,
    #[serde(default)]
    joinphrase: String,
}
#[derive(Deserialize)]
struct CreditArtist {
    name: String,
    id: Option<String>,
}
impl RemoteItem {
    fn summary(self, kind: ExternalEntityKind) -> Result<CatalogEntitySummary, IntegrationError> {
        let id = normalize_mbid(&self.id).ok_or(IntegrationError::InvalidResponse)?;
        let title = self
            .name
            .or(self.title)
            .filter(|title| !title.trim().is_empty())
            .ok_or(IntegrationError::InvalidResponse)?;
        let credit = self
            .credit
            .into_iter()
            .map(|credit| {
                format!(
                    "{}{}",
                    credit
                        .name
                        .or(credit.artist.map(|artist| artist.name))
                        .unwrap_or_default(),
                    credit.joinphrase
                )
            })
            .collect::<String>();
        let version = [Some(self.disambiguation), self.date, self.kind]
            .into_iter()
            .flatten()
            .filter(|value| !value.is_empty())
            .collect::<Vec<_>>()
            .join(" · ");
        Ok(CatalogEntitySummary {
            identity: CatalogEntityRef::External(
                ExternalEntityRef::new(
                    ProviderId::new("musicbrainz").expect("built-in ID"),
                    kind,
                    id,
                )
                .map_err(IntegrationError::InvalidInput)?,
            ),
            title,
            artist_credit: (!credit.is_empty()).then_some(credit),
            version_label: (!version.is_empty()).then_some(version),
            duration_seconds: self.length.map(|ms| ms / 1000),
        })
    }
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct CachedPage {
    version: u8,
    items: Vec<CachedItem>,
    next_cursor: Option<String>,
}
#[derive(Serialize, Deserialize)]
struct CachedItem {
    kind: String,
    id: String,
    title: String,
    artist_credit: Option<String>,
    version_label: Option<String>,
    duration_seconds: Option<u64>,
}
impl CachedPage {
    fn from_page(page: &CatalogSearchPage) -> Result<Self, IntegrationError> {
        let items = page
            .items
            .iter()
            .map(|item| {
                let CatalogEntityRef::External(reference) = &item.identity else {
                    return Err(IntegrationError::InvalidResponse);
                };
                Ok(CachedItem {
                    kind: format!("{:?}", reference.kind()),
                    id: reference.external_id().into(),
                    title: item.title.clone(),
                    artist_credit: item.artist_credit.clone(),
                    version_label: item.version_label.clone(),
                    duration_seconds: item.duration_seconds,
                })
            })
            .collect::<Result<_, _>>()?;
        Ok(Self {
            version: 1,
            items,
            next_cursor: page.next_cursor.clone(),
        })
    }
    fn into_page(self) -> Result<CatalogSearchPage, IntegrationError> {
        if self.version != 1 || self.items.len() > 150 {
            return Err(IntegrationError::InvalidResponse);
        }
        let items = self
            .items
            .into_iter()
            .map(|item| {
                let kind = match item.kind.as_str() {
                    "Artist" => ExternalEntityKind::Artist,
                    "ReleaseGroup" => ExternalEntityKind::ReleaseGroup,
                    "ReleaseEdition" => ExternalEntityKind::ReleaseEdition,
                    "Recording" => ExternalEntityKind::Recording,
                    _ => return Err(IntegrationError::InvalidResponse),
                };
                let id = normalize_mbid(&item.id).ok_or(IntegrationError::InvalidResponse)?;
                Ok(CatalogEntitySummary {
                    identity: CatalogEntityRef::External(
                        ExternalEntityRef::new(
                            ProviderId::new("musicbrainz").expect("built-in ID"),
                            kind,
                            id,
                        )
                        .map_err(IntegrationError::InvalidInput)?,
                    ),
                    title: item.title,
                    artist_credit: item.artist_credit,
                    version_label: item.version_label,
                    duration_seconds: item.duration_seconds,
                })
            })
            .collect::<Result<_, _>>()?;
        Ok(CatalogSearchPage {
            items,
            next_cursor: self.next_cursor,
            from_cache: true,
        })
    }
}

#[cfg(test)]
mod tests;

mod details;
