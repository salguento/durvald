use crate::api::{EnrichmentAttribution, EnrichmentProvider};
use crate::enrichment::{models::CacheValidators, transport::*};
use serde::Deserialize;
use std::collections::HashMap;

pub struct Commons {
    pub(crate) http: EnrichmentHttpClient,
}

#[derive(Debug)]
pub struct CommonsImage {
    pub provider_id: String,
    pub download_url: String,
    pub source_url: String,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub attribution: EnrichmentAttribution,
}

#[derive(Deserialize)]
struct QueryResponse {
    query: Query,
}
#[derive(Deserialize)]
struct Query {
    pages: Vec<Page>,
}
#[derive(Deserialize)]
struct Page {
    #[serde(default)]
    missing: bool,
    title: String,
    #[serde(default)]
    imageinfo: Vec<ImageInfo>,
}
#[derive(Deserialize)]
struct ImageInfo {
    url: String,
    #[serde(default)]
    thumburl: Option<String>,
    descriptionurl: String,
    #[serde(default)]
    width: Option<u32>,
    #[serde(default)]
    height: Option<u32>,
    #[serde(default)]
    thumbwidth: Option<u32>,
    #[serde(default)]
    thumbheight: Option<u32>,
    #[serde(default)]
    mime: String,
    #[serde(default)]
    extmetadata: HashMap<String, MetadataValue>,
}
#[derive(Deserialize)]
struct MetadataValue {
    // Commons may return numbers for unrelated metadata extension fields.
    value: serde_json::Value,
}

impl Commons {
    pub fn new() -> Result<Self, TransportError> {
        Ok(Self {
            http: EnrichmentHttpClient::new(
                EnrichmentProvider::Commons,
                None,
                concat!(
                    "Durvald/",
                    env!("CARGO_PKG_VERSION"),
                    " (https://github.com/salguento/durvald)"
                ),
            )?,
        })
    }

    pub async fn metadata(&self, filename: &str) -> Result<CommonsImage, TransportError> {
        let filename = filename.trim();
        if filename.is_empty() || filename.len() > 500 || filename.contains(['\n', '\r']) {
            return Err(TransportError::InvalidRequest);
        }
        let title = if filename.starts_with("File:") {
            filename.to_owned()
        } else {
            format!("File:{filename}")
        };
        let JsonResponse::Modified { body, .. } = self
            .http
            .get_json::<QueryResponse>(
                "w/api.php",
                &[
                    ("action", "query"),
                    ("prop", "imageinfo"),
                    ("titles", &title),
                    ("iiprop", "url|size|mime|extmetadata"),
                    ("iiurlwidth", "1200"),
                    ("format", "json"),
                    ("formatversion", "2"),
                ],
                &CacheValidators::default(),
            )
            .await?
        else {
            return Err(TransportError::InvalidJson);
        };
        let page = body
            .query
            .pages
            .into_iter()
            .next()
            .ok_or(TransportError::InvalidJson)?;
        if page.missing {
            return Err(TransportError::HttpStatus {
                status: 404,
                retry_after_seconds: None,
            });
        }
        let info = page
            .imageinfo
            .into_iter()
            .next()
            .ok_or(TransportError::InvalidJson)?;
        if !matches!(info.mime.as_str(), "image/jpeg" | "image/png") {
            return Err(TransportError::InvalidJson);
        }
        let (download_url, width, height) = match info.thumburl {
            Some(url) => (url, info.thumbwidth, info.thumbheight),
            None => (info.url, info.width, info.height),
        };
        Ok(CommonsImage {
            provider_id: page.title.trim_start_matches("File:").to_owned(),
            download_url,
            source_url: info.descriptionurl,
            width,
            height,
            attribution: EnrichmentAttribution {
                source_url: String::new(), // Filled with the canonical description page below.
                author: metadata(&info.extmetadata, "Artist").map(clean_metadata),
                license_name: metadata(&info.extmetadata, "LicenseShortName").map(clean_metadata),
                license_url: metadata(&info.extmetadata, "LicenseUrl").map(str::to_owned),
                revision: None,
            },
        }
        .with_source())
    }

    pub async fn download(&self, url: &str) -> Result<Vec<u8>, TransportError> {
        self.http
            .get_image(url, &["upload.wikimedia.org", "thumb.wikimedia.org"])
            .await
    }
}

impl CommonsImage {
    fn with_source(mut self) -> Self {
        self.attribution.source_url = self.source_url.clone();
        self
    }
}

fn metadata<'a>(values: &'a HashMap<String, MetadataValue>, key: &str) -> Option<&'a str> {
    values
        .get(key)
        .and_then(|entry| entry.value.as_str())
        .map(str::trim)
        .filter(|value| !value.is_empty())
}

fn clean_metadata(value: &str) -> String {
    let mut result = String::new();
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
        .trim()
        .to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::enrichment::transport::tests::{client, response};

    #[tokio::test(start_paused = true)]
    async fn selects_thumbnail_and_preserves_license_metadata() {
        let json = r#"{"query":{"pages":[{"title":"File:Portrait.jpg","imageinfo":[{"url":"https://upload.wikimedia.org/original.jpg","thumburl":"https://upload.wikimedia.org/thumb.jpg","descriptionurl":"https://commons.wikimedia.org/wiki/File:Portrait.jpg","width":3000,"height":2000,"thumbwidth":1200,"thumbheight":800,"mime":"image/jpeg","extmetadata":{"Artist":{"value":"<b>Alice &amp; Bob</b>"},"LicenseShortName":{"value":"CC BY-SA 4.0"},"LicenseUrl":{"value":"https://creativecommons.org/licenses/by-sa/4.0/"}}}]}]}}"#;
        let (http, mock) = client(vec![response(200, &[], &[json], None)]);
        let image = Commons { http }.metadata("Portrait.jpg").await.unwrap();
        assert_eq!(image.provider_id, "Portrait.jpg");
        assert_eq!(image.download_url, "https://upload.wikimedia.org/thumb.jpg");
        assert_eq!(image.width, Some(1200));
        assert_eq!(image.attribution.author.as_deref(), Some("Alice & Bob"));
        assert_eq!(
            image.attribution.license_name.as_deref(),
            Some("CC BY-SA 4.0")
        );
        assert!(mock.urls()[0].contains("iiurlwidth=1200"));
    }

    #[tokio::test(start_paused = true)]
    async fn rejects_non_image_media() {
        let json = r#"{"query":{"pages":[{"title":"File:Vector.svg","imageinfo":[{"url":"https://upload.wikimedia.org/a.svg","descriptionurl":"https://commons.wikimedia.org/wiki/File:Vector.svg","mime":"image/svg+xml","extmetadata":{}}]}]}}"#;
        let (http, _) = client(vec![response(200, &[], &[json], None)]);
        assert!(Commons { http }.metadata("Vector.svg").await.is_err());
    }
}
