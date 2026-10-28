//! Canonical service pages; expand only explicit SoundCloud sharing links.
//! No scraping, extraction, embed or media promises.
use crate::{
    application::{
        music_catalog::{IntegrationFuture, SourceFinder},
        music_plugins::{MusicPlugin, PluginContext},
    },
    domain::music::{IntegrationError, identity::*, plugins::*, sources::*},
};
use std::collections::BTreeMap;
pub(crate) struct ServiceLinks;
pub(crate) fn canonical_link(value: &str) -> Option<RemoteMediaRef> {
    if value.len() > 2048 {
        return None;
    }
    let url = CanonicalMediaUrl::new(value).ok()?;
    let mut parsed = url::Url::parse(url.as_str()).ok()?;
    if parsed.scheme() != "https" || parsed.port().is_some() {
        return None;
    }
    let host = parsed.host_str()?.to_lowercase();
    let parts: Vec<_> = parsed
        .path_segments()?
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
        .collect();
    let (provider, kind, id) = if host == "soundcloud.com" || host == "www.soundcloud.com" {
        if parts.len() != 2
            || [
                "sets",
                "likes",
                "reposts",
                "popular-tracks",
                "tracks",
                "albums",
            ]
            .contains(&parts[1].as_str())
            || parts[0] == "discover"
            || parts[0] == "search"
        {
            return None;
        }
        parsed.set_host(Some("soundcloud.com")).ok()?;
        (
            "soundcloud",
            ExternalEntityKind::AudioTrack,
            parts.join("/"),
        )
    } else if host == "youtu.be"
        || host == "www.youtube.com"
        || host == "youtube.com"
        || host == "m.youtube.com"
    {
        let id = if host == "youtu.be" && parts.len() == 1 {
            parts[0].clone()
        } else if parts.as_slice() == ["watch"] {
            parsed.query_pairs().find(|(k, _)| k == "v")?.1.into_owned()
        } else {
            return None;
        };
        if id.len() != 11
            || !id
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'_' | b'-'))
        {
            return None;
        }
        parsed = url::Url::parse(&format!("https://www.youtube.com/watch?v={id}")).ok()?;
        ("youtube", ExternalEntityKind::Video, id)
    } else if host.ends_with(".bandcamp.com")
        && host.split('.').count() == 3
        && parts.len() == 2
        && parts[0] == "track"
    {
        (
            "bandcamp",
            ExternalEntityKind::AudioTrack,
            format!("{host}/{}", parts.join("/")),
        )
    } else {
        return None;
    };
    // Tracking tokens, playlist context and fragments are never durable identities.
    if provider != "youtube" {
        parsed.set_query(None);
    }
    parsed.set_fragment(None);
    RemoteMediaRef::new(
        ExternalEntityRef::new(ProviderId::new(provider).ok()?, kind, id).ok()?,
        CanonicalMediaUrl::new(parsed.as_str()).ok()?,
    )
    .ok()
}
pub(crate) fn candidate(media: RemoteMediaRef) -> SourceCandidate {
    SourceCandidate {
        title: format!("Link {}", media.entity().provider().as_str()),
        reference: media,
        uploader: None,
        version_label: None,
        duration_seconds: None,
        availability: SourceAvailability::Unknown,
        capabilities: SourceCapabilities {
            playback: vec![PlaybackCapability {
                mode: PlaybackMode::ExternalOpen,
                seek: false,
                known_duration: false,
                preload: false,
                observable_progress: false,
                observable_end: false,
            }],
            authentication_required: false,
        },
    }
}
impl MusicPlugin for ServiceLinks {
    fn manifest(&self) -> PluginManifest {
        PluginManifest {
            id: ProviderId::new("service-links").unwrap(),
            version: PluginVersion {
                major: 1,
                minor: 1,
                patch: 0,
            },
            api_version: PLUGIN_API_VERSION,
            capabilities: [PluginCapability::SourceSearch].into(),
            permissions: [PluginPermission::Network].into(),
            primary_host: Some("on.soundcloud.com".into()),
            settings: BTreeMap::new(),
            flags: Default::default(),
            credentials: Default::default(),
        }
    }
    fn sources(&self) -> Option<&dyn SourceFinder> {
        Some(self)
    }
}
impl SourceFinder for ServiceLinks {
    fn find_sources(
        &self,
        _context: PluginContext,
        request: SourceSearchRequest,
    ) -> IntegrationFuture<'_, Vec<SourceCandidate>> {
        Box::pin(async move {
            match request.link {
                None => Ok(vec![]),
                Some(link) => canonical_link(&super::soundcloud_links::expand(&link).await?)
                    .map(|m| vec![candidate(m)])
                    .ok_or(IntegrationError::InvalidInput(
                        crate::domain::music::ContractError::InvalidCanonicalUrl,
                    )),
            }
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn individual_links_have_stable_identity_and_no_tracking_secrets() {
        for (url, provider, id) in [
            (
                "https://www.soundcloud.com/artist/song?secret_token=discard#t=3",
                "soundcloud",
                "artist/song",
            ),
            (
                "https://youtu.be/abcdefghijk?list=discard",
                "youtube",
                "abcdefghijk",
            ),
            (
                "https://m.youtube.com/watch?v=abcdefghijk&t=3",
                "youtube",
                "abcdefghijk",
            ),
            (
                "https://artist.bandcamp.com/track/song?from=discard",
                "bandcamp",
                "artist.bandcamp.com/track/song",
            ),
        ] {
            let media = canonical_link(url).unwrap();
            assert_eq!(media.entity().provider().as_str(), provider);
            assert_eq!(media.entity().external_id(), id);
            assert!(!media.canonical_url().as_str().contains("discard"));
            let c = candidate(media);
            assert_eq!(c.availability, SourceAvailability::Unknown);
            assert_eq!(c.capabilities.playback[0].mode, PlaybackMode::ExternalOpen);
        }
    }
    #[test]
    fn rejects_collections_untrusted_hosts_credentials_and_temporary_media() {
        for url in [
            "http://soundcloud.com/artist/song",
            "https://soundcloud.com/artist/sets/album",
            "https://soundcloud.com/artist/tracks",
            "https://youtube.com/playlist?list=abc",
            "https://artist.bandcamp.com/album/name",
            "https://youtube.com.evil.test/watch?v=abcdefghijk",
            "https://user:password@youtube.com/watch?v=abcdefghijk",
            "https://youtube.com/watch?v=invalid",
            "https://example.test/audio.mp3?token=secret",
            "https://soundcloud.com:444/artist/song",
        ] {
            assert!(canonical_link(url).is_none(), "accepted {url}");
        }
    }
}
