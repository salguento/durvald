use crate::api::{EnrichmentAttribution, EnrichmentProvider, ExternalArtworkScope};
use crate::enrichment::{
    identity::normalize_mbid,
    models::{CacheValidators, CoverArtCandidate, DownloadedCoverArt},
    transport::{EnrichmentHttpClient, JsonResponse, TransportError},
};
use reqwest::Url;
use serde::Deserialize;
use std::collections::HashMap;

const MAX_IMAGES_PER_RESPONSE: usize = 1_000;
const MAX_PROVIDER_ID_LENGTH: usize = 32;
const CAA_HOST: &str = "coverartarchive.org";
const ARCHIVE_HOST_SUFFIX: &str = ".archive.org";

pub struct CoverArtArchive {
    pub(crate) http: EnrichmentHttpClient,
}

#[derive(Deserialize)]
struct ArtworkResponse {
    release: String,
    images: Vec<RemoteImage>,
}

#[derive(Deserialize)]
struct RemoteImage {
    id: serde_json::Value,
    image: String,
    #[serde(default)]
    thumbnails: HashMap<String, String>,
    #[serde(default)]
    front: bool,
    #[serde(default)]
    edit: Option<u64>,
}

#[derive(Clone, Copy)]
enum LookupScope {
    ExactRelease,
    ReleaseGroup,
}

impl CoverArtArchive {
    pub fn new() -> Result<Self, TransportError> {
        Ok(Self {
            http: EnrichmentHttpClient::new(
                EnrichmentProvider::CoverArtArchive,
                None,
                concat!(
                    "Durvald/",
                    env!("CARGO_PKG_VERSION"),
                    " (https://github.com/salguento/durvald)"
                ),
            )?,
        })
    }

    /// Looks up an edition-specific cover first. A release-group request is
    /// made only when the exact release has no usable artwork or returns 404.
    pub async fn artwork(
        &self,
        exact_release_mbid: Option<&str>,
        release_group_mbid: &str,
    ) -> Result<Option<CoverArtCandidate>, TransportError> {
        let release_group_mbid =
            normalize_mbid(release_group_mbid).ok_or(TransportError::InvalidRequest)?;
        if let Some(release_mbid) = exact_release_mbid {
            let release_mbid =
                normalize_mbid(release_mbid).ok_or(TransportError::InvalidRequest)?;
            match self
                .metadata(
                    LookupScope::ExactRelease,
                    &release_mbid,
                    &release_group_mbid,
                )
                .await
            {
                Ok(Some(candidate)) => return Ok(Some(candidate)),
                Ok(None) | Err(TransportError::HttpStatus { status: 404, .. }) => {}
                Err(error) => return Err(error),
            }
        }
        match self
            .metadata(
                LookupScope::ReleaseGroup,
                &release_group_mbid,
                &release_group_mbid,
            )
            .await
        {
            Err(TransportError::HttpStatus { status: 404, .. }) => Ok(None),
            result => result,
        }
    }

    /// Downloads and decodes the selected image under the same strict limits
    /// used for embedded and Commons artwork.
    pub async fn download(
        &self,
        candidate: CoverArtCandidate,
    ) -> Result<DownloadedCoverArt, TransportError> {
        let bytes = self
            .http
            .get_image(
                &candidate.download_url,
                &[CAA_HOST, "archive.org", ARCHIVE_HOST_SUFFIX],
            )
            .await?;
        let (width, height) = crate::metadata::validate_artwork_bytes(&bytes)
            .map_err(|_| TransportError::InvalidJson)?;
        Ok(DownloadedCoverArt {
            candidate,
            bytes,
            width,
            height,
        })
    }

    async fn metadata(
        &self,
        scope: LookupScope,
        lookup_mbid: &str,
        release_group_mbid: &str,
    ) -> Result<Option<CoverArtCandidate>, TransportError> {
        let kind = match scope {
            LookupScope::ExactRelease => "release",
            LookupScope::ReleaseGroup => "release-group",
        };
        let path = format!("{kind}/{lookup_mbid}");
        let JsonResponse::Modified { body, .. } = self
            .http
            .get_json_with_redirects::<ArtworkResponse>(
                &path,
                &[],
                &CacheValidators::default(),
                &[CAA_HOST, "archive.org", ARCHIVE_HOST_SUFFIX],
            )
            .await?
        else {
            return Err(TransportError::InvalidJson);
        };
        if body.images.len() > MAX_IMAGES_PER_RESPONSE {
            return Err(TransportError::InvalidJson);
        }
        let source_release_mbid = musicbrainz_release_mbid(&body.release)?;
        if matches!(scope, LookupScope::ExactRelease) && source_release_mbid != lookup_mbid {
            return Err(TransportError::InvalidJson);
        }
        let selected = body
            .images
            .iter()
            .find(|image| image.front)
            .or_else(|| body.images.first());
        let Some(selected) = selected else {
            return Ok(None);
        };
        let provider_id = provider_id(&selected.id)?;
        let raw_download_url = ["1200", "500", "250"]
            .into_iter()
            .find_map(|size| selected.thumbnails.get(size))
            .unwrap_or(&selected.image);
        let download_url =
            normalized_caa_image_url(raw_download_url, &source_release_mbid, &provider_id)?;
        let source_url = format!("https://{CAA_HOST}/release/{source_release_mbid}/{provider_id}");
        Ok(Some(CoverArtCandidate {
            provider_id,
            release_group_mbid: release_group_mbid.to_owned(),
            source_release_mbid: source_release_mbid.clone(),
            exact_release_mbid: matches!(scope, LookupScope::ExactRelease)
                .then_some(source_release_mbid),
            scope: match scope {
                LookupScope::ExactRelease => ExternalArtworkScope::ExactRelease,
                LookupScope::ReleaseGroup => ExternalArtworkScope::ReleaseGroup,
            },
            download_url,
            source_url: source_url.clone(),
            attribution: EnrichmentAttribution {
                source_url,
                author: None,
                license_name: None,
                license_url: None,
                revision: selected.edit.map(|edit| edit.to_string()),
            },
        }))
    }
}

fn provider_id(value: &serde_json::Value) -> Result<String, TransportError> {
    let value = match value {
        serde_json::Value::String(value) => value.clone(),
        serde_json::Value::Number(value) => value.to_string(),
        _ => return Err(TransportError::InvalidJson),
    };
    if value.is_empty()
        || value.len() > MAX_PROVIDER_ID_LENGTH
        || !value.bytes().all(|byte| byte.is_ascii_digit())
    {
        return Err(TransportError::InvalidJson);
    }
    Ok(value)
}

fn musicbrainz_release_mbid(value: &str) -> Result<String, TransportError> {
    let url = Url::parse(value).map_err(|_| TransportError::InvalidJson)?;
    if !matches!(url.scheme(), "http" | "https")
        || !url.username().is_empty()
        || url.password().is_some()
        || url.port().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
        || !matches!(
            url.host_str(),
            Some("musicbrainz.org" | "www.musicbrainz.org")
        )
    {
        return Err(TransportError::InvalidJson);
    }
    let mut segments = url
        .path_segments()
        .ok_or(TransportError::InvalidJson)?
        .filter(|segment| !segment.is_empty());
    if segments.next() != Some("release") {
        return Err(TransportError::InvalidJson);
    }
    let mbid = segments.next().ok_or(TransportError::InvalidJson)?;
    if segments.next().is_some() {
        return Err(TransportError::InvalidJson);
    }
    normalize_mbid(mbid).ok_or(TransportError::InvalidJson)
}

fn normalized_caa_image_url(
    value: &str,
    source_release_mbid: &str,
    provider_id: &str,
) -> Result<String, TransportError> {
    let mut url = Url::parse(value).map_err(|_| TransportError::InvalidJson)?;
    if url.scheme() == "http" && url.host_str() == Some(CAA_HOST) {
        url.set_scheme("https")
            .map_err(|_| TransportError::InvalidJson)?;
    }
    if url.scheme() != "https"
        || !url.username().is_empty()
        || url.password().is_some()
        || url.port().is_some()
        || url.host_str() != Some(CAA_HOST)
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err(TransportError::InvalidJson);
    }
    let segments = url
        .path_segments()
        .ok_or(TransportError::InvalidJson)?
        .filter(|segment| !segment.is_empty())
        .collect::<Vec<_>>();
    if segments.len() != 3
        || segments[0] != "release"
        || segments[1] != source_release_mbid
        || ![
            format!("{provider_id}.jpg"),
            format!("{provider_id}.jpeg"),
            format!("{provider_id}.png"),
            format!("{provider_id}-250.jpg"),
            format!("{provider_id}-500.jpg"),
            format!("{provider_id}-1200.jpg"),
        ]
        .iter()
        .any(|expected| expected == segments[2])
    {
        return Err(TransportError::InvalidJson);
    }
    Ok(url.into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::enrichment::transport::tests::{client_for, response, response_bytes};
    use image::ImageFormat;
    use std::io::Cursor;

    const RELEASE: &str = "11111111-1111-4111-8111-111111111111";
    const GROUP: &str = "22222222-2222-4222-8222-222222222222";

    fn png(width: u32, height: u32) -> Vec<u8> {
        let mut bytes = Vec::new();
        image::DynamicImage::new_rgb8(width, height)
            .write_to(&mut Cursor::new(&mut bytes), ImageFormat::Png)
            .unwrap();
        bytes
    }

    #[tokio::test(start_paused = true)]
    async fn exact_release_prefers_front_and_validates_cdn_download() {
        let json = format!(
            r#"{{"release":"https://musicbrainz.org/release/{RELEASE}","images":[
                {{"id":"10","image":"https://coverartarchive.org/release/{RELEASE}/10.jpg","front":false,"edit":1}},
                {{"id":20,"image":"http://coverartarchive.org/release/{RELEASE}/20.png","front":true,"edit":2,
                 "thumbnails":{{"500":"https://coverartarchive.org/release/{RELEASE}/20-500.jpg",
                 "1200":"http://coverartarchive.org/release/{RELEASE}/20-1200.jpg"}}}}
            ]}}"#
        );
        let bytes = png(3, 2);
        let (http, mock) = client_for(
            "https://coverartarchive.org/",
            vec![
                response(200, &[], &[json.as_str()], None),
                response(
                    307,
                    &[(
                        "location",
                        "https://ia801.example.archive.org/download/cover.png",
                    )],
                    &[],
                    None,
                ),
                response_bytes(
                    200,
                    &[("content-type", "image/png")],
                    &[&bytes],
                    Some(bytes.len() as u64),
                ),
            ],
        );
        let archive = CoverArtArchive { http };
        let candidate = archive
            .artwork(Some(RELEASE), GROUP)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(candidate.provider_id, "20");
        assert_eq!(candidate.scope, ExternalArtworkScope::ExactRelease);
        assert_eq!(candidate.exact_release_mbid.as_deref(), Some(RELEASE));
        assert_eq!(candidate.release_group_mbid, GROUP);
        assert_eq!(candidate.source_release_mbid, RELEASE);
        assert_eq!(
            candidate.download_url,
            format!("https://coverartarchive.org/release/{RELEASE}/20-1200.jpg")
        );
        assert_eq!(candidate.attribution.revision.as_deref(), Some("2"));

        let downloaded = archive.download(candidate).await.unwrap();
        assert_eq!((downloaded.width, downloaded.height), (3, 2));
        assert_eq!(downloaded.bytes, bytes);
        assert_eq!(mock.calls(), 3);
        assert!(mock.urls()[2].starts_with("https://ia801.example.archive.org/"));
    }

    #[tokio::test(start_paused = true)]
    async fn release_group_is_used_only_as_identified_404_fallback() {
        let source_release = "33333333-3333-4333-8333-333333333333";
        let group_json = format!(
            r#"{{"release":"https://musicbrainz.org/release/{source_release}","images":[{{
                "id":"30","image":"https://coverartarchive.org/release/{source_release}/30.jpg",
                "front":false,"edit":7
            }}]}}"#
        );
        let (http, mock) = client_for(
            "https://coverartarchive.org/",
            vec![
                response(404, &[], &[], None),
                response(
                    307,
                    &[(
                        "location",
                        "https://archive.org/download/mbid-test/index.json",
                    )],
                    &[],
                    None,
                ),
                response(200, &[], &[group_json.as_str()], None),
            ],
        );
        let candidate = CoverArtArchive { http }
            .artwork(Some(RELEASE), GROUP)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(candidate.scope, ExternalArtworkScope::ReleaseGroup);
        assert_eq!(candidate.exact_release_mbid, None);
        assert_eq!(candidate.source_release_mbid, source_release);
        assert_eq!(candidate.release_group_mbid, GROUP);
        let urls = mock.urls();
        assert!(urls[0].contains(&format!("/release/{RELEASE}")));
        assert!(urls[1].contains(&format!("/release-group/{GROUP}")));
        assert_eq!(urls[2], "https://archive.org/download/mbid-test/index.json");
    }

    #[tokio::test(start_paused = true)]
    async fn malformed_metadata_and_unsafe_or_oversized_images_are_rejected() {
        let unsafe_json = format!(
            r#"{{"release":"https://musicbrainz.org/release/{RELEASE}","images":[{{
                "id":"40","image":"https://evil.example/cover.jpg","front":true
            }}]}}"#
        );
        let (http, _) = client_for(
            "https://coverartarchive.org/",
            vec![response(200, &[], &[unsafe_json.as_str()], None)],
        );
        assert!(matches!(
            CoverArtArchive { http }.artwork(Some(RELEASE), GROUP).await,
            Err(TransportError::InvalidJson)
        ));

        let safe_json = format!(
            r#"{{"release":"https://musicbrainz.org/release/{RELEASE}","images":[{{
                "id":"41","image":"https://coverartarchive.org/release/{RELEASE}/41.png","front":true
            }}]}}"#
        );
        let too_wide = png(4097, 1);
        let (http, _) = client_for(
            "https://coverartarchive.org/",
            vec![
                response(200, &[], &[safe_json.as_str()], None),
                response_bytes(
                    200,
                    &[("content-type", "image/png")],
                    &[&too_wide],
                    Some(too_wide.len() as u64),
                ),
            ],
        );
        let archive = CoverArtArchive { http };
        let candidate = archive
            .artwork(Some(RELEASE), GROUP)
            .await
            .unwrap()
            .unwrap();
        assert!(matches!(
            archive.download(candidate).await,
            Err(TransportError::InvalidJson)
        ));

        let (http, _) = client_for(
            "https://coverartarchive.org/",
            vec![
                response(200, &[], &[safe_json.as_str()], None),
                response_bytes(
                    200,
                    &[("content-type", "image/jpeg")],
                    &[b"short"],
                    Some(crate::metadata::MAX_ARTWORK_BYTES as u64 + 1),
                ),
            ],
        );
        let archive = CoverArtArchive { http };
        let candidate = archive
            .artwork(Some(RELEASE), GROUP)
            .await
            .unwrap()
            .unwrap();
        assert!(matches!(
            archive.download(candidate).await,
            Err(TransportError::BodyTooLarge)
        ));
    }
}
