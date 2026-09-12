use crate::api::*;
use crate::enrichment::{
    models::{CacheValidators, ProviderResponse},
    transport::*,
};
use serde::Deserialize;

pub struct Wikipedia {
    pub(crate) http: EnrichmentHttpClient,
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
    #[serde(default)]
    extract: String,
    #[serde(default)]
    canonicalurl: Option<String>,
    #[serde(default)]
    revisions: Vec<Revision>,
}
#[derive(Deserialize)]
struct Revision {
    revid: u64,
}

impl Wikipedia {
    pub fn new(language: &str) -> Result<Self, TransportError> {
        Ok(Self {
            http: EnrichmentHttpClient::new(
                EnrichmentProvider::Wikipedia,
                Some(language),
                concat!(
                    "Durvald/",
                    env!("CARGO_PKG_VERSION"),
                    " (https://github.com/salguento/durvald)"
                ),
            )?,
        })
    }

    pub async fn introduction(
        &self,
        title: &str,
        language: &str,
        validators: &CacheValidators,
    ) -> Result<ProviderResponse<ArtistProfile>, TransportError> {
        if title.trim().is_empty() || title.len() > 500 {
            return Err(TransportError::InvalidRequest);
        }
        let response = self
            .http
            .get_json::<QueryResponse>(
                "w/api.php",
                &[
                    ("action", "query"),
                    ("prop", "extracts|info|revisions"),
                    ("titles", title),
                    ("exintro", "1"),
                    ("explaintext", "1"),
                    ("inprop", "url"),
                    ("rvprop", "ids"),
                    ("redirects", "1"),
                    ("format", "json"),
                    ("formatversion", "2"),
                ],
                validators,
            )
            .await?;
        let (body, validators) = match response {
            JsonResponse::Modified { body, validators } => (body, validators),
            JsonResponse::NotModified { validators } => {
                return Ok(ProviderResponse::NotModified { validators });
            }
        };
        let page = body
            .query
            .pages
            .into_iter()
            .next()
            .ok_or(TransportError::InvalidJson)?;
        if page.missing || page.extract.trim().is_empty() {
            return Err(TransportError::HttpStatus {
                status: 404,
                retry_after_seconds: None,
            });
        }
        Ok(ProviderResponse::Modified {
            value: ArtistProfile {
                entity_kind: ArtistEntityKind::Unknown,
                birth_date: None,
                birth_place: None,
                formation_date: None,
                formation_place: None,
                origin_place: None,
                biography: Some(page.extract),
                attribution: EnrichmentAttribution {
                    source_url: page.canonicalurl.unwrap_or_else(|| {
                        format!(
                            "https://{language}.wikipedia.org/wiki/{}",
                            title.replace(' ', "_")
                        )
                    }),
                    author: Some("Wikipedia contributors".into()),
                    license_name: Some("CC BY-SA 4.0".into()),
                    license_url: Some("https://creativecommons.org/licenses/by-sa/4.0/".into()),
                    revision: page
                        .revisions
                        .first()
                        .map(|revision| revision.revid.to_string()),
                },
            },
            validators,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::enrichment::transport::tests::{client, response};

    #[tokio::test(start_paused = true)]
    async fn normalizes_intro_and_provenance() {
        let json = r#"{"query":{"pages":[{"extract":"Uma biografia.","canonicalurl":"https://pt.wikipedia.org/wiki/Artista","revisions":[{"revid":123}]}]}}"#;
        let (http, _) = client(vec![response(200, &[], &[json], None)]);
        let ProviderResponse::Modified { value: profile, .. } = Wikipedia { http }
            .introduction("Artista", "pt", &CacheValidators::default())
            .await
            .unwrap()
        else {
            panic!("expected modified response")
        };
        assert_eq!(profile.biography.as_deref(), Some("Uma biografia."));
        assert_eq!(profile.attribution.revision.as_deref(), Some("123"));
    }

    #[tokio::test(start_paused = true)]
    async fn propagates_not_modified_with_refreshed_validators() {
        let validators = CacheValidators {
            etag: Some("\"intro-v1\"".into()),
            last_modified: None,
        };
        let (http, _) = client(vec![response(304, &[], &[], None)]);
        let response = Wikipedia { http }
            .introduction("Artista", "pt", &validators)
            .await
            .unwrap();
        assert!(matches!(
            response,
            ProviderResponse::NotModified { validators: received } if received == validators
        ));
    }
}
