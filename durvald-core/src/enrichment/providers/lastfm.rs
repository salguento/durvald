//! Last.fm artist metadata adapter over the application's shared client.

use crate::api::{ArtistEntityKind, ArtistPopularTrack, ArtistProfile, EnrichmentAttribution};
use crate::enrichment::models::{CacheValidators, ProviderResponse};
use crate::enrichment::transport::TransportError;
#[cfg(test)]
use crate::lastfm::LastFmResult;
use crate::lastfm::{LastFmClient, LastFmError, LastFmMetadataResponse, LastFmResponseHeaders};
use md5::{Digest, Md5};
use serde::Deserialize;
use std::sync::Arc;

#[derive(Clone)]
pub struct LastFm {
    client: Arc<LastFmClient>,
}

#[derive(Debug)]
pub struct LastFmArtistInfo {
    pub profile: Option<ArtistProfile>,
    pub portrait: Option<LastFmPortrait>,
    pub expires_at: i64,
}

#[derive(Debug, Clone)]
pub struct LastFmPortrait {
    pub provider_id: String,
    pub download_url: String,
    pub source_url: String,
    pub attribution: EnrichmentAttribution,
}

#[derive(Debug, Deserialize)]
struct ArtistInfoResponse {
    artist: RemoteArtist,
}

#[derive(Debug, Deserialize)]
struct TopTracksResponse {
    #[serde(default, deserialize_with = "deserialize_toptracks")]
    toptracks: RemoteTopTracks,
}

#[derive(Debug, Default, Deserialize)]
struct RemoteTopTracks {
    #[serde(default, deserialize_with = "deserialize_tracks")]
    track: Vec<RemoteTopTrack>,
}

#[derive(Debug, Deserialize)]
struct RemoteTopTrack {
    name: String,
    #[serde(default, deserialize_with = "deserialize_optional_string")]
    mbid: String,
    url: String,
    #[serde(default, deserialize_with = "deserialize_u64")]
    playcount: u64,
    #[serde(default, deserialize_with = "deserialize_u64")]
    listeners: u64,
}

#[derive(Debug, Deserialize)]
struct RemoteArtist {
    name: String,
    #[serde(default)]
    url: String,
    #[serde(default, deserialize_with = "deserialize_images")]
    image: Vec<RemoteImage>,
    #[serde(default)]
    bio: Option<RemoteBio>,
}

#[derive(Debug, Deserialize)]
struct RemoteImage {
    #[serde(rename = "#text", default)]
    url: String,
    #[serde(default)]
    size: String,
}

#[derive(Debug, Deserialize)]
struct RemoteBio {
    #[serde(default)]
    summary: String,
    #[serde(default)]
    content: String,
}

fn deserialize_toptracks<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> Result<RemoteTopTracks, D::Error> {
    Ok(Option::<RemoteTopTracks>::deserialize(deserializer)?.unwrap_or_default())
}
fn deserialize_images<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> Result<Vec<RemoteImage>, D::Error> {
    Ok(Option::<Vec<RemoteImage>>::deserialize(deserializer)?.unwrap_or_default())
}
fn deserialize_optional_string<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> Result<String, D::Error> {
    Ok(Option::<String>::deserialize(deserializer)?.unwrap_or_default())
}
fn deserialize_tracks<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> Result<Vec<RemoteTopTrack>, D::Error> {
    let value = serde_json::Value::deserialize(deserializer)?;
    if value.is_null() || value.as_str() == Some("") {
        return Ok(Vec::new());
    }
    serde_json::from_value(if value.is_object() {
        serde_json::Value::Array(vec![value])
    } else {
        value
    })
    .map_err(serde::de::Error::custom)
}

impl LastFm {
    pub fn new(client: Arc<LastFmClient>) -> Self {
        Self { client }
    }

    #[cfg(test)]
    pub(crate) async fn metadata_json(
        &self,
        method: &str,
        parameters: &[(&str, &str)],
        validators: &CacheValidators,
    ) -> LastFmResult<LastFmMetadataResponse> {
        self.client
            .get_metadata_json(method, parameters, validators)
            .await
    }

    pub async fn artist_info(
        &self,
        mbid: &str,
        artist_name: &str,
        language: &str,
        validators: &CacheValidators,
    ) -> Result<ProviderResponse<LastFmArtistInfo>, TransportError> {
        let mbid = crate::enrichment::identity::normalize_mbid(mbid)
            .ok_or(TransportError::InvalidRequest)?;
        let language = crate::enrichment::policy::normalize_language(language)
            .map_err(|_| TransportError::InvalidRequest)?;
        let response = self
            .client
            .get_metadata_json(
                "artist.getInfo",
                &[("mbid", &mbid), ("lang", &language), ("autocorrect", "0")],
                validators,
            )
            .await;
        let mut used_name = false;
        let mut response = match response {
            Err(LastFmError::Api { code: 7, .. }) if !artist_name.trim().is_empty() => {
                used_name = true;
                self.client
                    .get_metadata_json(
                        "artist.getInfo",
                        &[
                            ("artist", artist_name),
                            ("lang", &language),
                            ("autocorrect", "0"),
                        ],
                        &CacheValidators::default(),
                    )
                    .await
                    .map_err(map_error)?
            }
            value => value.map_err(map_error)?,
        };
        let mbid_result_is_empty = match &response {
            LastFmMetadataResponse::Modified { body, headers } if !used_name => {
                serde_json::from_value::<ArtistInfoResponse>(body.clone())
                    .ok()
                    .and_then(|remote| normalize_artist_info(remote.artist, headers.clone()).ok())
                    .is_some_and(|value| value.profile.is_none() && value.portrait.is_none())
            }
            _ => false,
        };
        if mbid_result_is_empty && !artist_name.trim().is_empty() {
            response = self
                .client
                .get_metadata_json(
                    "artist.getInfo",
                    &[
                        ("artist", artist_name),
                        ("lang", &language),
                        ("autocorrect", "0"),
                    ],
                    &CacheValidators::default(),
                )
                .await
                .map_err(map_error)?;
        }
        match response {
            LastFmMetadataResponse::NotModified { headers } => Ok(ProviderResponse::NotModified {
                validators: headers.validators,
            }),
            LastFmMetadataResponse::Modified { body, headers } => {
                let remote: ArtistInfoResponse =
                    serde_json::from_value(body).map_err(|_| TransportError::InvalidJson)?;
                let source_url = normalize_catalog_url(&remote.artist.url, &remote.artist.name)
                    .ok_or(TransportError::InvalidJson)?;
                let mut value = normalize_artist_info(remote.artist, headers.clone())?;
                if value.portrait.is_none() {
                    match self.client.artist_page_image(&source_url).await {
                        Ok(Some(download_url)) => {
                            value.portrait = Some(portrait_for_url(download_url, source_url))
                        }
                        Err(error @ LastFmError::HttpStatus { status: 429, .. }) => {
                            return Err(map_error(error));
                        }
                        // The API biography remains usable when a public page is
                        // blocked or has no portrait; the page has its own TTL.
                        _ => {}
                    }
                }
                Ok(ProviderResponse::Modified {
                    value,
                    validators: headers.validators,
                })
            }
        }
    }

    pub async fn top_tracks(
        &self,
        mbid: &str,
        artist_name: &str,
        validators: &CacheValidators,
    ) -> Result<ProviderResponse<(Vec<ArtistPopularTrack>, i64)>, TransportError> {
        let mbid = crate::enrichment::identity::normalize_mbid(mbid)
            .ok_or(TransportError::InvalidRequest)?;
        let response = self
            .client
            .get_metadata_json(
                "artist.getTopTracks",
                &[("mbid", &mbid), ("limit", "10"), ("autocorrect", "0")],
                validators,
            )
            .await;
        let used_name = matches!(&response, Err(LastFmError::Api { code: 7, .. }));
        let response = match response {
            Err(LastFmError::Api { code: 7, .. }) if !artist_name.trim().is_empty() => self
                .client
                .get_metadata_json(
                    "artist.getTopTracks",
                    &[
                        ("artist", artist_name),
                        ("limit", "10"),
                        ("autocorrect", "0"),
                    ],
                    &CacheValidators::default(),
                )
                .await
                .map_err(map_error)?,
            value => value.map_err(map_error)?,
        };
        let response = match &response {
            LastFmMetadataResponse::Modified { body, .. }
                if !used_name
                    && !artist_name.trim().is_empty()
                    && serde_json::from_value::<TopTracksResponse>(body.clone())
                        .is_ok_and(|remote| remote.toptracks.track.is_empty()) =>
            {
                self.client
                    .get_metadata_json(
                        "artist.getTopTracks",
                        &[
                            ("artist", artist_name),
                            ("limit", "10"),
                            ("autocorrect", "0"),
                        ],
                        &CacheValidators::default(),
                    )
                    .await
                    .map_err(map_error)?
            }
            _ => response,
        };
        match response {
            LastFmMetadataResponse::NotModified { headers } => Ok(ProviderResponse::NotModified {
                validators: headers.validators,
            }),
            LastFmMetadataResponse::Modified { body, headers } => {
                let remote: TopTracksResponse =
                    serde_json::from_value(body).map_err(|_| TransportError::InvalidJson)?;
                let tracks = normalize_top_tracks(remote.toptracks.track)?;
                let expires_at = cache_expiry(
                    &headers,
                    chrono::Utc::now().timestamp(),
                    crate::enrichment::policy::POPULAR_TRACKS_TTL,
                );
                Ok(ProviderResponse::Modified {
                    value: (tracks, expires_at),
                    validators: headers.validators,
                })
            }
        }
    }

    pub async fn download(&self, url: &str) -> Result<Vec<u8>, TransportError> {
        self.client
            .download_metadata_image(url)
            .await
            .map_err(map_image_error)
    }

    #[cfg(test)]
    pub(crate) fn shares_client(&self, client: &Arc<LastFmClient>) -> bool {
        Arc::ptr_eq(&self.client, client)
    }

    #[cfg(test)]
    pub(crate) fn metadata_query_count(&self) -> usize {
        self.client.metadata_query_count()
    }
}

fn normalize_artist_info(
    remote: RemoteArtist,
    headers: LastFmResponseHeaders,
) -> Result<LastFmArtistInfo, TransportError> {
    let artist_name = remote.name.trim();
    if artist_name.is_empty() || artist_name.len() > 500 {
        return Err(TransportError::InvalidJson);
    }
    let source_url =
        normalize_catalog_url(&remote.url, artist_name).ok_or(TransportError::InvalidJson)?;
    let attribution = EnrichmentAttribution {
        source_url: source_url.clone(),
        author: Some("Last.fm community".into()),
        license_name: None,
        license_url: None,
        revision: None,
    };
    let biography = remote.bio.as_ref().and_then(normalize_biography);
    let profile = biography.map(|biography| ArtistProfile {
        entity_kind: ArtistEntityKind::Unknown,
        birth_date: None,
        birth_place: None,
        formation_date: None,
        formation_place: None,
        origin_place: None,
        biography: Some(biography),
        attribution: attribution.clone(),
    });
    let portrait = remote
        .image
        .into_iter()
        .filter_map(|image| {
            if image.url.contains("2a96cbd8b46e442fc41c2b86b821562f") {
                return None;
            }
            let mut url = reqwest::Url::parse(image.url.trim()).ok()?;
            (crate::lastfm::valid_lastfm_image_url(&url)).then(|| {
                url.set_fragment(None);
                (image_rank(&image.size), url.to_string())
            })
        })
        .max_by_key(|(rank, _)| *rank)
        .map(|(_, download_url)| LastFmPortrait {
            provider_id: {
                let mut digest = Md5::new();
                digest.update(download_url.as_bytes());
                format!("{:x}", digest.finalize())
            },
            download_url,
            source_url: source_url.clone(),
            attribution,
        });
    Ok(LastFmArtistInfo {
        profile,
        portrait,
        expires_at: cache_expiry(
            &headers,
            chrono::Utc::now().timestamp(),
            crate::enrichment::policy::PROFILE_TTL,
        ),
    })
}

fn portrait_for_url(download_url: String, source_url: String) -> LastFmPortrait {
    LastFmPortrait {
        provider_id: format!("{:x}", Md5::digest(download_url.as_bytes())),
        download_url,
        attribution: EnrichmentAttribution {
            source_url: source_url.clone(),
            author: Some("Last.fm community".into()),
            license_name: None,
            license_url: None,
            revision: None,
        },
        source_url,
    }
}

fn normalize_catalog_url(value: &str, artist_name: &str) -> Option<String> {
    let mut url = if value.trim().is_empty() {
        let mut fallback = reqwest::Url::parse("https://www.last.fm/music/").ok()?;
        fallback.path_segments_mut().ok()?.push(artist_name);
        fallback
    } else {
        reqwest::Url::parse(value.trim()).ok()?
    };
    let host = url.host_str()?;
    if !matches!(host, "www.last.fm" | "last.fm")
        || !url.username().is_empty()
        || url.password().is_some()
        || url.port().is_some()
    {
        return None;
    }
    url.set_scheme("https").ok()?;
    Some(url.to_string())
}

fn normalize_biography(bio: &RemoteBio) -> Option<String> {
    let source = if bio.content.trim().is_empty() {
        &bio.summary
    } else {
        &bio.content
    };
    let text = strip_html(source)
        .replace("Read more on Last.fm", "")
        .replace("Read more at Last.fm", "");
    let text = text.split_whitespace().collect::<Vec<_>>().join(" ");
    (!text.is_empty() && text.len() <= 100_000).then_some(text)
}

fn normalize_top_tracks(
    tracks: Vec<RemoteTopTrack>,
) -> Result<Vec<ArtistPopularTrack>, TransportError> {
    tracks
        .into_iter()
        .take(10)
        .enumerate()
        .map(|(index, track)| {
            let title = track.title_or_name();
            if title.is_empty() || title.len() > 500 {
                return Err(TransportError::InvalidJson);
            }
            let lastfm_url = normalize_lastfm_url(&track.url).ok_or(TransportError::InvalidJson)?;
            let musicbrainz_id = if track.mbid.trim().is_empty() {
                None
            } else {
                crate::enrichment::identity::normalize_mbid(&track.mbid)
            };
            Ok(ArtistPopularTrack {
                rank: index as u32 + 1,
                title: title.to_owned(),
                musicbrainz_id,
                play_count: track.playcount,
                listeners: track.listeners,
                lastfm_url,
                local_track_id: None,
            })
        })
        .collect()
}

impl RemoteTopTrack {
    fn title_or_name(&self) -> &str {
        self.name.trim()
    }
}

fn normalize_lastfm_url(value: &str) -> Option<String> {
    let mut url = reqwest::Url::parse(value.trim()).ok()?;
    if !matches!(url.host_str()?, "www.last.fm" | "last.fm")
        || !matches!(url.scheme(), "http" | "https")
        || !url.username().is_empty()
        || url.password().is_some()
        || url.port().is_some()
    {
        return None;
    }
    url.set_scheme("https").ok()?;
    Some(url.to_string())
}

fn deserialize_u64<'de, D>(deserializer: D) -> Result<u64, D::Error>
where
    D: serde::Deserializer<'de>,
{
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum Number {
        Integer(u64),
        Text(String),
    }
    match Option::<Number>::deserialize(deserializer)? {
        None => Ok(0),
        Some(Number::Integer(value)) => Ok(value),
        Some(Number::Text(value)) => value.trim().parse().map_err(serde::de::Error::custom),
    }
}

fn strip_html(value: &str) -> String {
    let mut result = String::with_capacity(value.len());
    let mut in_tag = false;
    for character in value.chars() {
        match character {
            '<' => in_tag = true,
            '>' => in_tag = false,
            _ if !in_tag => result.push(character),
            _ => {}
        }
    }
    result
        .replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&apos;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
}

fn image_rank(size: &str) -> u8 {
    match size.trim().to_ascii_lowercase().as_str() {
        "mega" => 6,
        "extralarge" => 5,
        "large" => 4,
        "medium" => 3,
        "small" => 2,
        _ => 1,
    }
}

fn cache_expiry(headers: &LastFmResponseHeaders, now: i64, fallback: std::time::Duration) -> i64 {
    const MAX_CACHE_SECONDS: i64 = 90 * 24 * 60 * 60;
    let max_age = headers.cache_control.as_deref().and_then(|value| {
        value.split(',').find_map(|directive| {
            directive
                .trim()
                .strip_prefix("max-age=")
                .and_then(|value| value.trim_matches('"').parse::<i64>().ok())
        })
    });
    let expires = headers.expires.as_deref().and_then(|value| {
        chrono::DateTime::parse_from_rfc2822(value)
            .ok()
            .map(|date| date.timestamp().saturating_sub(now))
    });
    let seconds = max_age
        .or(expires)
        .unwrap_or(fallback.as_secs() as i64)
        .clamp(0, MAX_CACHE_SECONDS);
    now.saturating_add(seconds)
}

fn map_error(error: LastFmError) -> TransportError {
    match error {
        LastFmError::Api { code: 29, .. } => TransportError::RateLimited {
            retry_after_seconds: 60,
        },
        LastFmError::Api { code: 11 | 16, .. } => TransportError::HttpStatus {
            status: 503,
            retry_after_seconds: None,
        },
        LastFmError::Api { code: 7, .. } => TransportError::HttpStatus {
            status: 404,
            retry_after_seconds: None,
        },
        LastFmError::Api { code: 10 | 26, .. } => TransportError::NotConfigured,
        LastFmError::SecureStore(crate::secure_store::SecureStoreError::Keyring(
            keyring::Error::NoEntry,
        )) => TransportError::NotConfigured,
        LastFmError::SecureStore(crate::secure_store::SecureStoreError::Custom(message))
            if message == "Not found"
                || message == "API key not configured"
                || message == "API key not found" =>
        {
            TransportError::NotConfigured
        }
        LastFmError::SecureStore(_) => TransportError::Configuration,
        LastFmError::Api { .. } => TransportError::InvalidRequest,
        LastFmError::HttpStatus {
            status,
            retry_after,
        } => TransportError::HttpStatus {
            status,
            retry_after_seconds: retry_after.as_deref().and_then(parse_retry_after),
        },
        LastFmError::MetadataNetwork | LastFmError::Network(_) => TransportError::Network,
        LastFmError::MetadataStorage { extended_code } => TransportError::Storage { extended_code },
        LastFmError::Json(_) => TransportError::InvalidJson,
        LastFmError::ResponseTooLarge { .. } => TransportError::BodyTooLarge,
        LastFmError::RateLimit(_) => TransportError::RateLimited {
            retry_after_seconds: 60,
        },
        LastFmError::Time(_) => TransportError::Network,
        LastFmError::NotConnected => TransportError::NotConfigured,
        LastFmError::Custom(_) => TransportError::InvalidRequest,
    }
}

fn map_image_error(error: LastFmError) -> TransportError {
    match error {
        LastFmError::Custom(_) => TransportError::InvalidImage,
        other => map_error(other),
    }
}

fn parse_retry_after(value: &str) -> Option<u64> {
    value.trim().parse::<u64>().ok().or_else(|| {
        chrono::DateTime::parse_from_rfc2822(value)
            .ok()
            .map(|date| {
                date.timestamp()
                    .saturating_sub(chrono::Utc::now().timestamp())
                    .max(0) as u64
            })
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn headers(cache_control: Option<&str>) -> LastFmResponseHeaders {
        LastFmResponseHeaders {
            cache_control: cache_control.map(str::to_owned),
            ..Default::default()
        }
    }

    #[test]
    fn cache_storage_errors_are_never_reported_as_invalid_images() {
        assert_eq!(
            map_image_error(LastFmError::MetadataStorage {
                extended_code: Some(5)
            }),
            TransportError::Storage {
                extended_code: Some(5)
            }
        );
    }

    #[test]
    fn toptracks_accepts_missing_null_and_singleton_api_shapes() {
        for body in [serde_json::json!({}), serde_json::json!({"toptracks":null})] {
            assert!(
                serde_json::from_value::<TopTracksResponse>(body)
                    .unwrap()
                    .toptracks
                    .track
                    .is_empty()
            );
        }
        let artist: ArtistInfoResponse =
            serde_json::from_value(serde_json::json!({"artist":{"name":"Artist", "image":null}}))
                .unwrap();
        assert!(artist.artist.image.is_empty());

        for tracks in [
            serde_json::json!({}),
            serde_json::json!({"track":null}),
            serde_json::json!({"track":""}),
        ] {
            let parsed: TopTracksResponse =
                serde_json::from_value(serde_json::json!({"toptracks":tracks})).unwrap();
            assert!(parsed.toptracks.track.is_empty());
        }
        let parsed: TopTracksResponse =
            serde_json::from_value(serde_json::json!({"toptracks":{"track":{
                "name":"Track", "url":"https://www.last.fm/music/Artist/_/Track", "mbid":null
            }}}))
            .unwrap();
        assert_eq!(
            normalize_top_tracks(parsed.toptracks.track).unwrap().len(),
            1
        );
    }

    #[test]
    fn normalizes_biography_catalog_url_and_largest_https_image() {
        let remote: ArtistInfoResponse = serde_json::from_value(serde_json::json!({
            "artist": {
                "name": "Wendy Carlos",
                "url": "http://www.last.fm/music/Wendy+Carlos",
                "image": [
                    {"#text": "https://lastfm.freetls.fastly.net/i/u/64/a.jpg", "size": "small"},
                    {"#text": "https://lastfm.freetls.fastly.net/i/u/300/b.jpg", "size": "extralarge"},
                    {"#text": "http://userserve-ak.last.fm/unsafe.jpg", "size": "mega"}
                ],
                "bio": {"summary": "short", "content": "<p>Pioneer &amp; composer.</p><a>Read more on Last.fm</a>"}
            }
        }))
        .unwrap();
        let info =
            normalize_artist_info(remote.artist, headers(Some("public, max-age=60"))).unwrap();
        assert_eq!(
            info.profile.unwrap().biography.as_deref(),
            Some("Pioneer & composer.")
        );
        let portrait = info.portrait.unwrap();
        assert!(portrait.download_url.ends_with("/300/b.jpg"));
        assert!(portrait.source_url.starts_with("https://www.last.fm/"));
        let now = chrono::Utc::now().timestamp();
        assert!((now + 58..=now + 60).contains(&info.expires_at));
    }

    #[test]
    fn missing_optional_content_is_not_a_malformed_response() {
        let remote: ArtistInfoResponse = serde_json::from_value(serde_json::json!({
            "artist": {"name": "Artist", "url": "https://www.last.fm/music/Artist"}
        }))
        .unwrap();
        let info = normalize_artist_info(remote.artist, headers(None)).unwrap();
        assert!(info.profile.is_none());
        assert!(info.portrait.is_none());
    }

    #[test]
    fn biography_and_portrait_are_independent_optional_fields() {
        let biography_only: ArtistInfoResponse = serde_json::from_value(serde_json::json!({
            "artist": {
                "name": "Artist",
                "url": "https://www.last.fm/music/Artist",
                "bio": {"summary": "Biography only"}
            }
        }))
        .unwrap();
        let biography_only = normalize_artist_info(biography_only.artist, headers(None)).unwrap();
        assert_eq!(
            biography_only.profile.unwrap().biography.as_deref(),
            Some("Biography only")
        );
        assert!(biography_only.portrait.is_none());

        let portrait_only: ArtistInfoResponse = serde_json::from_value(serde_json::json!({
            "artist": {
                "name": "Artist",
                "url": "https://www.last.fm/music/Artist",
                "image": [{
                    "#text": "https://lastfm.freetls.fastly.net/i/u/300/portrait.jpg",
                    "size": "extralarge"
                }]
            }
        }))
        .unwrap();
        let portrait_only = normalize_artist_info(portrait_only.artist, headers(None)).unwrap();
        assert!(portrait_only.profile.is_none());
        assert!(portrait_only.portrait.is_some());
    }

    #[test]
    fn shared_lastfm_placeholder_is_not_an_artist_photo() {
        let remote: ArtistInfoResponse = serde_json::from_value(serde_json::json!({
            "artist": { "name": "Casey MQ", "image": [{ "size": "mega", "#text": "https://lastfm.freetls.fastly.net/i/u/300x300/2a96cbd8b46e442fc41c2b86b821562f.png" }] }
        })).unwrap();
        assert!(
            normalize_artist_info(remote.artist, headers(None))
                .unwrap()
                .portrait
                .is_none()
        );
    }

    #[test]
    fn malformed_optional_track_mbid_does_not_discard_ranking() {
        let remote: TopTracksResponse = serde_json::from_value(serde_json::json!({
            "toptracks": {"track": [{"name": "Track", "url": "https://www.last.fm/music/Casey+MQ/_/Track", "mbid": "not-a-uuid"}]}
        })).unwrap();
        let tracks = normalize_top_tracks(remote.toptracks.track).unwrap();
        assert_eq!(tracks.len(), 1);
        assert!(tracks[0].musicbrainz_id.is_none());
    }

    #[test]
    fn insecure_lastfm_images_are_ignored() {
        let remote: ArtistInfoResponse = serde_json::from_value(serde_json::json!({
            "artist": {
                "name": "Artist",
                "url": "https://www.last.fm/music/Artist",
                "image": [{
                    "#text": "http://userserve-ak.last.fm/portrait.jpg",
                    "size": "mega"
                }]
            }
        }))
        .unwrap();
        let info = normalize_artist_info(remote.artist, headers(None)).unwrap();
        assert!(info.portrait.is_none());
    }

    #[test]
    fn lastfm_error_codes_have_stable_enrichment_semantics() {
        assert!(matches!(
            map_error(LastFmError::Api {
                code: 29,
                message: "rate".into()
            }),
            TransportError::RateLimited { .. }
        ));
        for code in [11, 16] {
            assert!(matches!(
                map_error(LastFmError::Api {
                    code,
                    message: "temporary".into()
                }),
                TransportError::HttpStatus { status: 503, .. }
            ));
        }
        for code in [10, 26] {
            assert_eq!(
                map_error(LastFmError::Api {
                    code,
                    message: "configuration".into()
                }),
                TransportError::NotConfigured
            );
        }
    }

    #[test]
    fn top_tracks_normalize_string_counts_empty_mbids_and_limit() {
        let remote: TopTracksResponse = serde_json::from_value(serde_json::json!({
            "toptracks": {
                "track": (0..12).map(|index| serde_json::json!({
                    "name": format!("Track {index}"),
                    "mbid": if index == 0 { "11111111-1111-4111-8111-111111111111" } else { "" },
                    "url": format!("http://www.last.fm/music/Artist/_/Track+{index}"),
                    "playcount": format!("{}", 100 - index),
                    "listeners": 50 - index
                })).collect::<Vec<_>>()
            }
        }))
        .unwrap();
        let tracks = normalize_top_tracks(remote.toptracks.track).unwrap();
        assert_eq!(tracks.len(), 10);
        assert_eq!(tracks[0].rank, 1);
        assert_eq!(tracks[0].play_count, 100);
        assert_eq!(tracks[0].listeners, 50);
        assert!(tracks[0].musicbrainz_id.is_some());
        assert!(tracks[1].musicbrainz_id.is_none());
        assert!(
            tracks
                .iter()
                .all(|track| track.lastfm_url.starts_with("https://"))
        );
        assert!(tracks.iter().all(|track| track.local_track_id.is_none()));
    }

    #[test]
    fn top_tracks_accept_fewer_than_ten_results() {
        let remote: TopTracksResponse = serde_json::from_value(serde_json::json!({
            "toptracks": {"track": [{
                "name": "Only Track",
                "mbid": "",
                "url": "https://www.last.fm/music/Artist/_/Only+Track",
                "playcount": "7",
                "listeners": "3"
            }]}
        }))
        .unwrap();
        let tracks = normalize_top_tracks(remote.toptracks.track).unwrap();
        assert_eq!(tracks.len(), 1);
        assert_eq!(tracks[0].rank, 1);
        assert_eq!(tracks[0].musicbrainz_id, None);
    }

    #[test]
    fn malformed_top_tracks_payload_is_rejected() {
        assert!(
            serde_json::from_value::<TopTracksResponse>(serde_json::json!({
                "toptracks": {"track": [{
                    "name": "Track",
                    "url": "https://www.last.fm/music/Artist/_/Track",
                    "playcount": "not-a-number"
                }]}
            }))
            .is_err()
        );
    }
}
