//! Visible official video player; never isolated audio or downloads.
use crate::{
    application::{
        music_catalog::{IntegrationFuture, MediaResolver},
        music_plugins::{MusicPlugin, PluginContext},
    },
    domain::music::{IntegrationError, identity::ProviderId, plugins::*, sources::*},
};
pub(crate) struct YouTubePlayback;
impl MusicPlugin for YouTubePlayback {
    fn manifest(&self) -> PluginManifest {
        PluginManifest {
            id: ProviderId::new("youtube").unwrap(),
            version: PluginVersion {
                major: 1,
                minor: 0,
                patch: 0,
            },
            api_version: PLUGIN_API_VERSION,
            capabilities: [PluginCapability::Playback].into(),
            permissions: [PluginPermission::Network].into(),
            primary_host: Some("www.youtube.com".into()),
            settings: Default::default(),
            flags: Default::default(),
            credentials: Default::default(),
        }
    }
    fn resolver(&self) -> Option<&dyn MediaResolver> {
        Some(self)
    }
}
impl MediaResolver for YouTubePlayback {
    fn resolve(
        &self,
        _: PluginContext,
        source: SourceReference,
    ) -> IntegrationFuture<'_, ResolvedMedia> {
        Box::pin(async move {
            let SourceReference::Remote(media) = &source else {
                return Err(IntegrationError::UnsupportedCapability);
            };
            let canonical = super::service_links::canonical_link(media.canonical_url().as_str())
                .filter(|m| {
                    m.entity() == media.entity() && m.entity().provider().as_str() == "youtube"
                })
                .ok_or(IntegrationError::UnsupportedCapability)?;
            Ok(ResolvedMedia {
                location: ResolvedLocation::EmbeddedPlayer(canonical.canonical_url().clone()),
                source,
                expires_at_unix_seconds: None,
            })
        })
    }
}
