//! The official widget owns media authentication/expiry. Never return stream URLs.
use crate::{
    application::{
        music_catalog::{IntegrationFuture, MediaResolver},
        music_plugins::{MusicPlugin, PluginContext},
    },
    domain::music::{IntegrationError, identity::ProviderId, plugins::*, sources::*},
};
pub(crate) struct SoundCloudPlayback;
impl MusicPlugin for SoundCloudPlayback {
    fn manifest(&self) -> PluginManifest {
        PluginManifest {
            id: ProviderId::new("soundcloud").unwrap(),
            version: PluginVersion {
                major: 1,
                minor: 0,
                patch: 0,
            },
            api_version: PLUGIN_API_VERSION,
            capabilities: [PluginCapability::Playback].into(),
            permissions: [PluginPermission::Network].into(),
            primary_host: Some("w.soundcloud.com".into()),
            settings: Default::default(),
            flags: Default::default(),
            credentials: Default::default(),
        }
    }
    fn resolver(&self) -> Option<&dyn MediaResolver> {
        Some(self)
    }
}
impl MediaResolver for SoundCloudPlayback {
    fn resolve(
        &self,
        _context: PluginContext,
        source: SourceReference,
    ) -> IntegrationFuture<'_, ResolvedMedia> {
        Box::pin(async move {
            let SourceReference::Remote(media) = &source else {
                return Err(IntegrationError::UnsupportedCapability);
            };
            let canonical = super::service_links::canonical_link(media.canonical_url().as_str())
                .filter(|r| {
                    r.entity() == media.entity() && r.entity().provider().as_str() == "soundcloud"
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
