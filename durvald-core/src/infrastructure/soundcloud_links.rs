//! Resolve only SoundCloud's sharing redirects, without fetching audio or page bodies.
use crate::domain::music::{ContractError, IntegrationError};
use std::{collections::HashSet, future::Future, sync::OnceLock, time::Duration};
use url::Url;
struct Redirect {
    status: u16,
    location: Option<String>,
    retry_after: Option<u64>,
}
fn short_url(value: &str) -> Option<Url> {
    if value.len() > 2048 || value.chars().any(char::is_control) {
        return None;
    }
    let mut url = Url::parse(value).ok()?;
    if url.scheme() != "https"
        || url.host_str() != Some("on.soundcloud.com")
        || url.port().is_some()
        || !url.username().is_empty()
        || url.password().is_some()
    {
        return None;
    }
    let parts: Vec<_> = url.path_segments()?.filter(|s| !s.is_empty()).collect();
    if parts.len() != 1
        || parts[0].len() > 128
        || !parts[0]
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'-' | b'_'))
    {
        return None;
    }
    url.set_query(None);
    url.set_fragment(None);
    Some(url)
}
pub(crate) fn is_short_link(value: &str) -> bool {
    short_url(value).is_some()
}
pub(crate) async fn expand(value: &str) -> Result<String, IntegrationError> {
    expand_mode(value, false).await
}
pub(crate) async fn expand_service_link(value: &str) -> Result<String, IntegrationError> {
    expand_mode(value, true).await
}
async fn expand_mode(value: &str, allow_collections: bool) -> Result<String, IntegrationError> {
    // Ordinary complete links remain entirely offline.
    if !is_short_link(value) {
        return Ok(value.to_owned());
    }
    static CLIENT: OnceLock<Result<reqwest::Client, IntegrationError>> = OnceLock::new();
    let client = CLIENT
        .get_or_init(|| {
            reqwest::Client::builder()
                .https_only(true)
                .redirect(reqwest::redirect::Policy::none())
                .user_agent("Durvald/0.1 SoundCloudLinkResolver")
                .connect_timeout(Duration::from_secs(3))
                .timeout(Duration::from_secs(5))
                .build()
                .map_err(|_| IntegrationError::TemporarilyUnavailable)
        })
        .as_ref()
        .map_err(|e| *e)?;
    tokio::time::timeout(
        Duration::from_secs(15),
        expand_with_allowed(
            value,
            |url| async move {
                let response = client.head(url).send().await.map_err(|e| {
                    if e.is_timeout() {
                        IntegrationError::Timeout
                    } else {
                        IntegrationError::TemporarilyUnavailable
                    }
                })?;
                Ok(Redirect {
                    status: response.status().as_u16(),
                    location: response
                        .headers()
                        .get(reqwest::header::LOCATION)
                        .and_then(|h| h.to_str().ok())
                        .map(str::to_owned),
                    retry_after: response
                        .headers()
                        .get(reqwest::header::RETRY_AFTER)
                        .and_then(|h| h.to_str().ok())
                        .and_then(|h| h.parse::<u64>().ok())
                        .map(|s| s.min(3600)),
                })
            },
            allow_collections,
        ),
    )
    .await
    .map_err(|_| IntegrationError::Timeout)?
}
async fn expand_with_allowed<F, Fut>(
    value: &str,
    mut head: F,
    allow_collections: bool,
) -> Result<String, IntegrationError>
where
    F: FnMut(Url) -> Fut,
    Fut: Future<Output = Result<Redirect, IntegrationError>>,
{
    let mut current = short_url(value).ok_or_else(invalid)?;
    let mut visited = HashSet::new();
    for _ in 0..3 {
        if !visited.insert(current.as_str().to_owned()) {
            return Err(IntegrationError::InvalidResponse);
        }
        let response = head(current.clone()).await?;
        match response.status {
            429 => {
                return Err(IntegrationError::RateLimited {
                    retry_after_seconds: response.retry_after,
                });
            }
            404 | 410 => return Err(IntegrationError::NotFound),
            401 | 403 => return Err(IntegrationError::AccessDenied),
            301 | 302 | 303 | 307 | 308 => {}
            _ => return Err(IntegrationError::InvalidResponse),
        }
        let location = response
            .location
            .filter(|s| s.len() <= 2048 && !s.chars().any(char::is_control))
            .ok_or(IntegrationError::InvalidResponse)?;
        let next = current.join(&location).map_err(|_| invalid())?;
        if let Some(media) = super::service_links::canonical_link(next.as_str())
            .filter(|m| m.entity().provider().as_str() == "soundcloud")
        {
            return Ok(media.canonical_url().as_str().to_owned());
        }
        if allow_collections {
            if let Ok(location) = super::public_services::locate(next.as_str()) {
                if location.provider == crate::api::ServiceProvider::SoundCloud
                    && location.collection
                {
                    return Ok(location.url);
                }
            }
        }
        // Validate before following: never request arbitrary hosts, downgrade TLS,
        // or follow redirects to media/CDNs. A final track page isn't downloaded.
        current = short_url(next.as_str()).ok_or_else(invalid)?;
    }
    Err(IntegrationError::InvalidResponse)
}
#[cfg(test)]
async fn expand_with<F, Fut>(value: &str, head: F) -> Result<String, IntegrationError>
where
    F: FnMut(Url) -> Fut,
    Fut: Future<Output = Result<Redirect, IntegrationError>>,
{
    expand_with_allowed(value, head, false).await
}
fn invalid() -> IntegrationError {
    IntegrationError::InvalidInput(ContractError::InvalidCanonicalUrl)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn resolves_shared_link_to_track_and_removes_tracking_without_fetching_the_page() {
        let mut calls = 0;
        let url = expand_with(
            "https://on.soundcloud.com/shared?si=discard#secret",
            |url| {
                calls += 1;
                assert_eq!(url.as_str(), "https://on.soundcloud.com/shared");
                std::future::ready(Ok(Redirect {
                    status: 302,
                    location: Some(
                        "https://soundcloud.com/goldlip/snooze-this-on?ref=discard&si=secret"
                            .into(),
                    ),
                    retry_after: None,
                }))
            },
        )
        .await
        .unwrap();
        assert_eq!(url, "https://soundcloud.com/goldlip/snooze-this-on");
        assert_eq!(calls, 1);
    }
    #[tokio::test]
    async fn rejects_untrusted_redirects_profiles_and_collections_before_following() {
        for target in [
            "https://example.test/artist/track",
            "http://soundcloud.com/artist/track",
            "https://127.0.0.1/artist/track",
            "https://soundcloud.com/artist",
            "https://soundcloud.com/artist/sets/album",
            "https://user:secret@on.soundcloud.com/next",
            "https://on.soundcloud.com:444/next",
        ] {
            let mut calls = 0;
            assert!(
                expand_with("https://on.soundcloud.com/shared", |_| {
                    calls += 1;
                    std::future::ready(Ok(Redirect {
                        status: 302,
                        location: Some(target.into()),
                        retry_after: None,
                    }))
                })
                .await
                .is_err()
            );
            assert_eq!(calls, 1);
        }
    }
    #[tokio::test]
    async fn redirects_are_bounded_and_relative_locations_are_supported() {
        let mut calls = 0;
        let result = expand_with("https://on.soundcloud.com/first", |_| {
            calls += 1;
            std::future::ready(Ok(Redirect {
                status: 302,
                location: Some(format!("/hop{calls}")),
                retry_after: None,
            }))
        })
        .await;
        assert_eq!(result, Err(IntegrationError::InvalidResponse));
        assert_eq!(calls, 3);
        let mut calls = 0;
        assert!(
            expand_with("https://on.soundcloud.com/first", |_| {
                calls += 1;
                std::future::ready(Ok(Redirect {
                    status: 302,
                    location: Some("/first".into()),
                    retry_after: None,
                }))
            })
            .await
            .is_err()
        );
        assert_eq!(calls, 1);
    }
    #[tokio::test]
    async fn invalid_inputs_are_offline_and_provider_failures_are_typed() {
        for value in [
            "https://on.soundcloud.com/",
            "https://on.soundcloud.com/a/b",
            "https://on.soundcloud.com.evil.test/a",
            "https://on.soundcloud.com/%2f",
            "http://on.soundcloud.com/a",
        ] {
            assert!(!is_short_link(value));
        }
        let full = "https://soundcloud.com/artist/track";
        assert_eq!(expand(full).await.unwrap(), full);
        assert_eq!(
            expand_with("https://on.soundcloud.com/shared", |_| std::future::ready(
                Ok(Redirect {
                    status: 429,
                    location: None,
                    retry_after: Some(5)
                })
            ))
            .await,
            Err(IntegrationError::RateLimited {
                retry_after_seconds: Some(5)
            })
        );
        assert_eq!(
            expand_with("https://on.soundcloud.com/shared", |_| std::future::ready(
                Ok(Redirect {
                    status: 404,
                    location: None,
                    retry_after: None
                })
            ))
            .await,
            Err(IntegrationError::NotFound)
        );
    }
    #[tokio::test]
    async fn collection_expansion_accepts_only_public_soundcloud_playlists_when_requested() {
        let result = expand_with_allowed(
            "https://on.soundcloud.com/shared",
            |_| {
                std::future::ready(Ok(Redirect {
                    status: 302,
                    location: Some("https://soundcloud.com/artist/sets/album?si=discard".into()),
                    retry_after: None,
                }))
            },
            true,
        )
        .await
        .unwrap();
        assert_eq!(result, "https://soundcloud.com/artist/sets/album");
        assert!(
            expand_with_allowed(
                "https://on.soundcloud.com/shared",
                |_| std::future::ready(Ok(Redirect {
                    status: 302,
                    location: Some("https://soundcloud.com/artist".into()),
                    retry_after: None
                })),
                true
            )
            .await
            .is_err()
        );
    }
}
