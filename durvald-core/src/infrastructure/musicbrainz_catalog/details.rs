//! Progressive, read-only metadata. Cache and provider transports are shared with enrichment.
use super::*;
use crate::{
    api::*,
    enrichment::{
        models::ProviderResponse,
        providers::{
            commons::Commons, cover_art_archive::CoverArtArchive, lastfm::LastFm,
            wikidata::Wikidata, wikipedia::Wikipedia,
        },
    },
};
#[derive(Deserialize)]
struct Entity {
    #[serde(flatten)]
    item: RemoteItem,
    #[serde(default)]
    media: Vec<Medium>,
    #[serde(rename = "release-group")]
    group: Option<RemoteItem>,
}
#[derive(Deserialize)]
struct Medium {
    #[serde(default)]
    tracks: Vec<RemoteTrack>,
}
#[derive(Deserialize)]
struct RemoteTrack {
    id: Option<String>,
    title: Option<String>,
    length: Option<u64>,
    recording: Option<RemoteItem>,
}
#[derive(Deserialize)]
struct Browse {
    #[serde(alias = "release-count", alias = "release-group-count")]
    count: u64,
    #[serde(alias = "release-offset", alias = "release-group-offset")]
    offset: u64,
    #[serde(default)]
    releases: Vec<RemoteItem>,
    #[serde(default, rename = "release-groups")]
    groups: Vec<RemoteItem>,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Cursor {
    version: u8,
    key: String,
    offset: u64,
}
fn fingerprint(r: &CatalogDetailRequest) -> String {
    cache::key(
        "detail-cursor:v1",
        &serde_json::to_string(&(&r.reference, r.section, &r.language))
            .expect("primitive detail key"),
    )
}
fn offset(r: &CatalogDetailRequest) -> Result<u64, IntegrationError> {
    let Some(value) = &r.cursor else {
        return Ok(0);
    };
    if !matches!(
        r.section,
        CatalogDetailSection::Editions | CatalogDetailSection::Discography
    ) {
        return Err(invalid());
    }
    let c: Cursor = serde_json::from_str(value).map_err(|_| invalid())?;
    if c.version != 1 || c.key != fingerprint(r) || c.offset > u32::MAX as u64 {
        return Err(invalid());
    }
    Ok(c.offset)
}
fn empty(r: &CatalogDetailRequest) -> CatalogDetailPage {
    CatalogDetailPage {
        reference: r.reference.clone(),
        section: r.section,
        generation: r.generation,
        items: vec![],
        profile: None,
        image: None,
        attribution: None,
        next_cursor: None,
        failure: None,
        retry_after_seconds: None,
        from_cache: false,
    }
}
fn endpoint(kind: CatalogItemKind) -> Result<(&'static str, ExternalEntityKind), IntegrationError> {
    match kind {
        CatalogItemKind::Artist => Ok(("artist", ExternalEntityKind::Artist)),
        CatalogItemKind::ReleaseGroup => Ok(("release-group", ExternalEntityKind::ReleaseGroup)),
        CatalogItemKind::ReleaseEdition => Ok(("release", ExternalEntityKind::ReleaseEdition)),
        CatalogItemKind::Recording => Ok(("recording", ExternalEntityKind::Recording)),
        _ => Err(IntegrationError::UnsupportedCapability),
    }
}
fn entry(item: RemoteItem, kind: CatalogItemKind) -> Result<CatalogEntry, IntegrationError> {
    let (path, external) = endpoint(kind)?;
    let summary = item.summary(external)?;
    let CatalogEntityRef::External(identity) = summary.identity else {
        return Err(IntegrationError::InvalidResponse);
    };
    Ok(CatalogEntry {
        reference: CatalogReference {
            provider: "musicbrainz".into(),
            kind,
            id: identity.external_id().into(),
        },
        title: summary.title,
        artist_credit: summary.artist_credit,
        version_label: summary.version_label,
        duration_seconds: summary.duration_seconds,
        canonical_url: Some(format!(
            "https://musicbrainz.org/{path}/{}",
            identity.external_id()
        )),
    })
}
fn mb_attribution(r: &CatalogReference) -> EnrichmentAttribution {
    EnrichmentAttribution {
        source_url: format!(
            "https://musicbrainz.org/{}/{}",
            endpoint(r.kind).map(|v| v.0).unwrap_or("artist"),
            r.id
        ),
        author: None,
        license_name: Some("CC0".into()),
        license_url: Some("https://creativecommons.org/publicdomain/zero/1.0/".into()),
        revision: None,
    }
}
impl MusicBrainzCatalog {
    async fn entity(&self, r: &CatalogReference, inc: &str) -> Result<Entity, IntegrationError> {
        let (path, _) = endpoint(r.kind)?;
        let client = self
            .client
            .get_or_init(MusicBrainz::new)
            .as_ref()
            .map_err(|e| map_error(e.clone()))?;
        match client
            .http
            .get_json::<Entity>(
                &format!("ws/2/{path}/{}", r.id),
                &[("fmt", "json"), ("inc", inc)],
                &CacheValidators::default(),
            )
            .await
            .map_err(map_error)?
        {
            JsonResponse::Modified { body, .. }
                if normalize_mbid(&body.item.id).as_deref() == Some(r.id.as_str()) =>
            {
                Ok(body)
            }
            _ => Err(IntegrationError::InvalidResponse),
        }
    }
    pub(super) async fn load_section(
        &self,
        r: CatalogDetailRequest,
    ) -> Result<CatalogDetailPage, IntegrationError> {
        if r.reference.provider != "musicbrainz"
            || normalize_mbid(&r.reference.id).as_deref() != Some(&r.reference.id)
        {
            return Err(invalid());
        }
        let start = offset(&r)?;
        endpoint(r.reference.kind)?;
        let key = cache::key(
            "catalog-detail:v1",
            &serde_json::to_string(&(1u8, &r.reference, r.section, &r.language, &r.cursor))
                .map_err(|_| invalid())?,
        );
        let _lock = cache::request_lock(&key).await.map_err(map_error)?;
        if let Some(cached) = cache::load(&key)
            .await
            .map_err(map_error)?
            .filter(|e| e.fresh() && e.failure.is_none())
        {
            if let Ok((version, mut page)) =
                serde_json::from_slice::<(u8, CatalogDetailPage)>(&cached.body)
            {
                if version == 1
                    && page.reference == r.reference
                    && page.section == r.section
                    && page.failure.is_none()
                {
                    page.generation = r.generation;
                    page.from_cache = true;
                    return Ok(page);
                }
            }
        }
        let mut page = empty(&r);
        let client = self
            .client
            .get_or_init(MusicBrainz::new)
            .as_ref()
            .map_err(|e| map_error(e.clone()))?;
        match r.section {
            CatalogDetailSection::Basic => {
                let entity = self
                    .entity(
                        &r.reference,
                        if r.reference.kind == CatalogItemKind::Artist {
                            "url-rels"
                        } else {
                            "artist-credits+url-rels"
                        },
                    )
                    .await?;
                let credits = entity
                    .item
                    .credit
                    .iter()
                    .filter_map(|c| c.artist.as_ref())
                    .filter_map(|a| {
                        a.id.as_deref()
                            .and_then(normalize_mbid)
                            .map(|id| CatalogEntry {
                                reference: CatalogReference {
                                    provider: "musicbrainz".into(),
                                    kind: CatalogItemKind::Artist,
                                    id: id.clone(),
                                },
                                title: a.name.clone(),
                                artist_credit: None,
                                version_label: None,
                                duration_seconds: None,
                                canonical_url: Some(format!("https://musicbrainz.org/artist/{id}")),
                            })
                    })
                    .collect::<Vec<_>>();
                page.items.push(entry(entity.item, r.reference.kind)?);
                page.items.extend(credits);
            }
            CatalogDetailSection::Discography | CatalogDetailSection::Editions => {
                let (path, parameter, kind) = match (r.section, r.reference.kind) {
                    (CatalogDetailSection::Discography, CatalogItemKind::Artist) => {
                        ("release-group", "artist", CatalogItemKind::ReleaseGroup)
                    }
                    (CatalogDetailSection::Editions, CatalogItemKind::ReleaseGroup) => {
                        ("release", "release-group", CatalogItemKind::ReleaseEdition)
                    }
                    _ => return Err(IntegrationError::UnsupportedCapability),
                };
                let JsonResponse::Modified { body, .. } = client
                    .http
                    .get_json::<Browse>(
                        &format!("ws/2/{path}/"),
                        &[
                            (parameter, &r.reference.id),
                            ("fmt", "json"),
                            ("inc", "artist-credits"),
                            ("limit", "20"),
                            ("offset", &start.to_string()),
                        ],
                        &CacheValidators::default(),
                    )
                    .await
                    .map_err(map_error)?
                else {
                    return Err(IntegrationError::InvalidResponse);
                };
                let rows = if kind == CatalogItemKind::ReleaseEdition {
                    body.releases
                } else {
                    body.groups
                };
                if body.offset != start
                    || rows.len() > 20
                    || (rows.is_empty() && body.count > start)
                {
                    return Err(IntegrationError::InvalidResponse);
                }
                let next = start + rows.len() as u64;
                page.items = rows
                    .into_iter()
                    .map(|v| entry(v, kind))
                    .collect::<Result<_, _>>()?;
                if next < body.count && next <= u32::MAX as u64 {
                    page.next_cursor = Some(
                        serde_json::to_string(&Cursor {
                            version: 1,
                            key: fingerprint(&r),
                            offset: next,
                        })
                        .map_err(|_| invalid())?,
                    );
                }
            }
            CatalogDetailSection::Tracklist => {
                if r.reference.kind != CatalogItemKind::ReleaseEdition {
                    return Err(IntegrationError::UnsupportedCapability);
                }
                let entity = self
                    .entity(&r.reference, "recordings+artist-credits")
                    .await?;
                for (disc, medium) in entity.media.into_iter().enumerate() {
                    for (position, t) in medium.tracks.into_iter().enumerate() {
                        let recording = t.recording;
                        let id = recording
                            .as_ref()
                            .and_then(|v| normalize_mbid(&v.id))
                            .or_else(|| t.id.as_deref().and_then(normalize_mbid))
                            .ok_or(IntegrationError::InvalidResponse)?;
                        let kind = if recording.is_some() {
                            CatalogItemKind::Recording
                        } else {
                            CatalogItemKind::ReleaseTrack
                        };
                        let title = t
                            .title
                            .or_else(|| recording.as_ref().and_then(|v| v.title.clone()))
                            .filter(|v| !v.is_empty())
                            .ok_or(IntegrationError::InvalidResponse)?;
                        let duration = t
                            .length
                            .or_else(|| recording.and_then(|v| v.length))
                            .map(|v| v / 1000);
                        page.items.push(CatalogEntry {
                            reference: CatalogReference {
                                provider: "musicbrainz".into(),
                                kind,
                                id: id.clone(),
                            },
                            title,
                            artist_credit: None,
                            version_label: Some(format!("{}.{}", disc + 1, position + 1)),
                            duration_seconds: duration,
                            canonical_url: (kind == CatalogItemKind::Recording)
                                .then(|| format!("https://musicbrainz.org/recording/{id}")),
                        });
                    }
                }
            }
            CatalogDetailSection::Profile => {
                if r.reference.kind != CatalogItemKind::Artist {
                    return Err(IntegrationError::UnsupportedCapability);
                }
                if let Some(id) = client
                    .wikidata_id(&r.reference.id)
                    .await
                    .map_err(map_error)?
                {
                    if let ProviderResponse::Modified { value, .. } = Wikidata::new()
                        .map_err(map_error)?
                        .profile(&id, &r.language, &CacheValidators::default())
                        .await
                        .map_err(map_error)?
                    {
                        let mut profile = value.profile;
                        if let (Some(title), Some(language)) =
                            (value.article_title, value.article_language)
                        {
                            if let Ok(ProviderResponse::Modified { value, .. }) =
                                Wikipedia::new(&language)
                                    .map_err(map_error)?
                                    .introduction(&title, &language, &CacheValidators::default())
                                    .await
                            {
                                profile.biography = value.biography;
                                page.attribution = Some(value.attribution);
                            }
                        }
                        if page.attribution.is_none() {
                            page.attribution = Some(profile.attribution.clone());
                        }
                        page.profile = Some(profile);
                    }
                }
            }
            CatalogDetailSection::Cover => match r.reference.kind {
                CatalogItemKind::Artist => {
                    if let Some(id) = client
                        .wikidata_id(&r.reference.id)
                        .await
                        .map_err(map_error)?
                    {
                        if let ProviderResponse::Modified { value, .. } = Wikidata::new()
                            .map_err(map_error)?
                            .profile(&id, &r.language, &CacheValidators::default())
                            .await
                            .map_err(map_error)?
                        {
                            if let Some(file) = value.commons_file {
                                let commons = Commons::new().map_err(map_error)?;
                                let image = commons.metadata(&file).await.map_err(map_error)?;
                                page.image = Some(
                                    commons
                                        .download(&image.download_url)
                                        .await
                                        .map_err(map_error)?,
                                );
                                page.attribution = Some(image.attribution);
                            }
                        }
                    }
                }
                CatalogItemKind::ReleaseGroup | CatalogItemKind::ReleaseEdition => {
                    let cover = CoverArtArchive::new().map_err(map_error)?;
                    let group = if r.reference.kind == CatalogItemKind::ReleaseEdition {
                        self.entity(&r.reference, "release-groups")
                            .await?
                            .group
                            .and_then(|g| normalize_mbid(&g.id))
                            .ok_or(IntegrationError::InvalidResponse)?
                    } else {
                        r.reference.id.clone()
                    };
                    if let Some(candidate) = cover
                        .artwork(
                            (r.reference.kind == CatalogItemKind::ReleaseEdition)
                                .then_some(r.reference.id.as_str()),
                            &group,
                        )
                        .await
                        .map_err(map_error)?
                    {
                        let image = cover.download(candidate).await.map_err(map_error)?;
                        page.attribution = Some(image.candidate.attribution);
                        page.image = Some(image.bytes);
                    }
                }
                _ => return Err(IntegrationError::UnsupportedCapability),
            },
            CatalogDetailSection::Similar => {
                if r.reference.kind != CatalogItemKind::Artist {
                    return Err(IntegrationError::UnsupportedCapability);
                }
                let lastfm = self.lastfm.clone().ok_or(IntegrationError::Disabled)?;
                let artist = self.entity(&r.reference, "url-rels").await?;
                let name = artist.item.name.ok_or(IntegrationError::InvalidResponse)?;
                for value in LastFm::new(lastfm)
                    .similar_artists(&name)
                    .await
                    .map_err(map_error)?
                {
                    let (reference, url) = if let Some(id) =
                        value.musicbrainz_id.as_deref().and_then(normalize_mbid)
                    {
                        (
                            CatalogReference {
                                provider: "musicbrainz".into(),
                                kind: CatalogItemKind::Artist,
                                id: id.clone(),
                            },
                            format!("https://musicbrainz.org/artist/{id}"),
                        )
                    } else {
                        (
                            CatalogReference {
                                provider: "last_fm".into(),
                                kind: CatalogItemKind::Artist,
                                id: value.lastfm_url.clone(),
                            },
                            value.lastfm_url,
                        )
                    };
                    page.items.push(CatalogEntry {
                        reference,
                        title: value.name,
                        artist_credit: None,
                        version_label: Some("Last.fm".into()),
                        duration_seconds: None,
                        canonical_url: Some(url),
                    });
                }
                page.attribution = Some(EnrichmentAttribution {
                    source_url: format!(
                        "https://www.last.fm/music/{}",
                        url::form_urlencoded::byte_serialize(name.as_bytes()).collect::<String>()
                    ),
                    author: Some("Last.fm".into()),
                    license_name: None,
                    license_url: None,
                    revision: None,
                });
            }
        }
        if page.attribution.is_none() {
            page.attribution = Some(mb_attribution(&r.reference));
        }
        cache::store(
            &key,
            &cache::entry(
                serde_json::to_vec(&(1u8, &page)).map_err(|_| IntegrationError::InvalidResponse)?,
                CacheValidators::default(),
                SEARCH_TTL,
            ),
        )
        .await
        .map_err(map_error)?;
        Ok(page)
    }
}

impl MusicBrainzCatalog {
    pub(super) async fn legacy_details(
        &self,
        target: CatalogEntityRef,
    ) -> Result<CatalogEntityDetails, IntegrationError> {
        let CatalogEntityRef::External(target) = target else {
            return Err(invalid());
        };
        let kind = match target.kind() {
            ExternalEntityKind::Artist => CatalogItemKind::Artist,
            ExternalEntityKind::ReleaseGroup => CatalogItemKind::ReleaseGroup,
            ExternalEntityKind::ReleaseEdition => CatalogItemKind::ReleaseEdition,
            ExternalEntityKind::Recording => CatalogItemKind::Recording,
            _ => return Err(IntegrationError::UnsupportedCapability),
        };
        let page = self
            .load_section(CatalogDetailRequest {
                reference: CatalogReference {
                    provider: target.provider().as_str().into(),
                    kind,
                    id: target.external_id().into(),
                },
                section: CatalogDetailSection::Basic,
                language: "und".into(),
                cursor: None,
                generation: 1,
            })
            .await?;
        let mut items = page.items.into_iter().map(|v| {
            Ok(CatalogEntitySummary {
                identity: CatalogEntityRef::External(
                    ExternalEntityRef::new(
                        ProviderId::new(v.reference.provider)
                            .map_err(IntegrationError::InvalidInput)?,
                        endpoint(v.reference.kind)?.1,
                        v.reference.id,
                    )
                    .map_err(IntegrationError::InvalidInput)?,
                ),
                title: v.title,
                artist_credit: v.artist_credit,
                version_label: v.version_label,
                duration_seconds: v.duration_seconds,
            })
        });
        let summary = items.next().ok_or(IntegrationError::InvalidResponse)??;
        Ok(CatalogEntityDetails {
            summary,
            related: items.collect::<Result<_, IntegrationError>>()?,
            completeness: DetailCompleteness::Basic,
        })
    }
}
