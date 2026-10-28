//! Source policy for one selected occurrence; resolution never adopts library data.
use super::{
    music_plugins::{PluginRuntime, context::RequestScope},
    playback::PlaybackApplication,
    playback_embedded::EmbeddedStart,
};
use crate::{
    api::*,
    domain::music::{
        identity::ProviderId,
        sources::{ResolvedLocation, SourceReference},
    },
};
use std::sync::Arc;
pub(super) enum PreparedSource {
    Local(Box<crate::audio::player::PreparedSound>, TrackSource),
    Embedded(String, TrackSource),
}
impl PlaybackApplication {
    pub(crate) async fn initialize_soundcloud(&self, runtime: Arc<PluginRuntime>) {
        let _ = runtime
            .register_builtin_with_default(
                Arc::new(crate::infrastructure::soundcloud_playback::SoundCloudPlayback),
                true,
            )
            .await;
        let _ = runtime
            .register_builtin_with_default(
                Arc::new(crate::infrastructure::youtube_playback::YouTubePlayback),
                false,
            )
            .await;
        *self.integration_runtime.lock().await = Some(runtime);
    }
    pub(crate) async fn embedded_provider_enabled(&self, provider: &str) -> bool {
        let runtime = self.integration_runtime.lock().await.clone();
        if let Some(runtime) = runtime {
            runtime.list().await.is_ok_and(|list| {
                list.iter()
                    .any(|s| s.manifest.id.as_str() == provider && s.enabled)
            })
        } else {
            false
        }
    }
    pub(crate) async fn soundcloud_enabled(&self) -> bool {
        self.embedded_provider_enabled("soundcloud").await
    }
    pub(crate) async fn set_soundcloud_enabled(&self, enabled: bool) -> CoreResult<()> {
        self.set_embedded_provider_enabled("soundcloud", enabled)
            .await
    }
    pub(crate) async fn set_embedded_provider_enabled(
        &self,
        provider: &str,
        enabled: bool,
    ) -> CoreResult<()> {
        if !["soundcloud", "youtube"].contains(&provider) {
            return Err(error("Player não suportado."));
        }
        let _transition = self.playback_transition.lock().await;
        let runtime = self
            .integration_runtime
            .lock()
            .await
            .clone()
            .ok_or_else(|| error("Integração indisponível."))?;
        let active = self
            .embedded
            .lock()
            .await
            .as_ref()
            .and_then(|s| crate::infrastructure::service_links::canonical_link(&s.url))
            .is_some_and(|m| m.entity().provider().as_str() == provider);
        if !enabled && active {
            self.stop_embedded_locked().await?;
        }
        runtime
            .set_enabled(&ProviderId::new(provider).unwrap(), enabled)
            .await
            .map_err(|_| error("Não foi possível alterar este player."))?;
        Ok(())
    }
    pub(super) async fn resolve_embedded(&self, url: &str) -> CoreResult<String> {
        if self.embedded_host.lock().await.is_none() {
            return Err(error(
                "O player integrado não está disponível nesta plataforma.",
            ));
        }
        let media = crate::infrastructure::service_links::canonical_link(url)
            .filter(|m| ["soundcloud", "youtube"].contains(&m.entity().provider().as_str()))
            .ok_or_else(|| error("Selecione uma faixa SoundCloud ou um vídeo YouTube."))?;
        let provider = media.entity().provider().clone();
        if provider.as_str() == "youtube"
            && !self
                .track_query
                .youtube_finite_verified(media.entity().external_id().into())
                .await?
        {
            return Err(error(
                "Verifique este vídeo na importação de serviços antes de reproduzir. Lives, estreias e vídeos sem metadados finitos verificados não são suportados.",
            ));
        }
        let runtime = self
            .integration_runtime
            .lock()
            .await
            .clone()
            .ok_or_else(|| error("Integração indisponível."))?;
        let scope = RequestScope::default();
        let resolved=runtime.resolve(&provider,scope.begin(),SourceReference::Remote(media)).await.map_err(|_|error("O player deste serviço está desativado ou indisponível. Confira os Ajustes de serviços."))?;
        match resolved.location {
            ResolvedLocation::EmbeddedPlayer(url) => Ok(url.as_str().into()),
            _ => Err(error("Modo de reprodução não suportado.")),
        }
    }
    pub(super) async fn ordered_sources(
        &self,
        track: i64,
        explicit: Option<i64>,
    ) -> CoreResult<Vec<TrackSource>> {
        let mut sources = self.track_query.sources(track).await?;
        if let Some(id) = explicit {
            return sources
                .into_iter()
                .find(|s| s.source_id == id && s.enabled)
                .map(|s| vec![s])
                .ok_or_else(|| {
                    error("A origem escolhida está desativada ou não pertence à faixa.")
                });
        }
        sources.retain(|s| {
            s.enabled
                && (s.provider == "local"
                    || s.provider == "soundcloud"
                    || s.provider == "youtube"
                    || s.preferred)
        });
        sources.sort_by_key(|s| {
            (
                !s.preferred,
                s.provider != "local",
                std::cmp::Reverse(s.priority),
                s.source_id,
            )
        });
        sources.truncate(8);
        Ok(sources)
    }
    pub(super) async fn prepare_source(&self, source: TrackSource) -> CoreResult<PreparedSource> {
        if source.provider == "local" {
            let path = self
                .track_query
                .source_media_path(source.track_id, source.source_id)
                .await?;
            Ok(PreparedSource::Local(
                Box::new(self.prepare_sound(path).await?),
                source,
            ))
        } else if ["soundcloud", "youtube"].contains(&source.provider.as_str()) {
            let url = self
                .track_query
                .embedded_source_url(source.track_id, source.source_id)
                .await?;
            let canonical = crate::infrastructure::service_links::canonical_link(&url)
                .ok_or_else(|| error("Invalid source URL"))?;
            if source.external_id.as_deref() != Some(canonical.entity().external_id()) {
                return Err(error("A identidade da origem não corresponde ao link."));
            }
            Ok(PreparedSource::Embedded(
                self.resolve_embedded(&url).await?,
                source,
            ))
        } else {
            Err(error("Esta origem permite somente abrir no serviço."))
        }
    }
    pub(super) async fn prepare_selection(
        &self,
        track: i64,
        explicit: Option<i64>,
    ) -> CoreResult<(PreparedSource, Vec<i64>, bool)> {
        let sources = self.ordered_sources(track, explicit).await?;
        let ids: Vec<_> = sources.iter().map(|s| s.source_id).collect();
        let mut last =
            error("A faixa não tem uma origem de áudio disponível. Escolha outra origem.");
        for (index, source) in sources.into_iter().enumerate() {
            match self.prepare_source(source).await {
                Ok(prepared) => {
                    return Ok((
                        prepared,
                        ids.into_iter().skip(index + 1).collect(),
                        index > 0,
                    ));
                }
                Err(e) => {
                    last = e;
                }
            }
        }
        Err(last)
    }
    pub(super) async fn source_selected(&self, source: &TrackSource, fallback: bool) {
        *self.source_status.lock().await = Some(PlaybackSourceStatus {
            preferred_source_id: None,
            source_id: Some(source.source_id),
            provider: source.provider.clone(),
            message: fallback.then(|| {
                format!(
                    "A origem anterior não estava disponível; usando {}.",
                    if source.provider == "local" {
                        "arquivo local"
                    } else if source.provider == "youtube" {
                        "YouTube"
                    } else {
                        "SoundCloud"
                    }
                )
            }),
        });
    }
    pub(crate) async fn playback_source_status(&self) -> Option<PlaybackSourceStatus> {
        let current = self.audio_player.lock().await.get_current_song_id();
        let Some(track) = current else {
            return self.source_status.lock().await.clone();
        };
        let sources = self.track_query.sources(track).await.unwrap_or_default();
        let preferred = sources.iter().find(|s| s.preferred).map(|s| s.source_id);
        let mut status = self.source_status.lock().await.clone();
        if status.is_none() {
            if let Some(a) = self.restored_attempt.lock().await.as_ref() {
                let source = sources.iter().find(|s| Some(s.source_id) == a.source_id);
                status=Some(PlaybackSourceStatus{source_id:a.source_id,preferred_source_id:preferred,provider:source.map(|s|s.provider.clone()).unwrap_or_else(||"unavailable".into()),message:Some("Sessão restaurada e pausada. A origem será verificada ao retomar; a fila foi preservada.".into())});
            }
        }
        if let Some(s) = status.as_mut() {
            s.preferred_source_id = preferred;
        }
        status
    }
    #[allow(clippy::too_many_arguments)]
    pub(super) async fn start_embedded_selection_locked(
        &self,
        track: Track,
        source: TrackSource,
        url: String,
        remaining: Vec<i64>,
        context: String,
        occurrence: Option<String>,
        fallback: bool,
    ) -> CoreResult<()> {
        self.source_selected(&source, fallback).await;
        let entry = track_entry(&track);
        self.begin_embedded_locked(EmbeddedStart {
            track: Some(track),
            entry,
            candidate: None,
            source_id: Some(source.source_id),
            url,
            remaining,
            context,
            occurrence,
        })
        .await
    }
    pub(super) async fn fallback_before_audio_locked(&self) -> CoreResult<bool> {
        let Some(previous) = self.embedded.lock().await.clone() else {
            return Ok(false);
        };
        if previous.started {
            return Ok(false);
        }
        let Some(track_id) = previous.snapshot.track_id else {
            return Ok(false);
        };
        let ids = previous.remaining.clone();
        for (i, id) in ids.iter().enumerate() {
            let Ok(mut sources) = self.ordered_sources(track_id, Some(*id)).await else {
                continue;
            };
            let Ok(prepared) = self.prepare_source(sources.remove(0)).await else {
                continue;
            };
            match prepared {
                PreparedSource::Local(sound, source) => {
                    self.stop_embedded_locked().await?;
                    let mut player = self.audio_player.lock().await;
                    player
                        .play_song_prepared(track_id, *sound)
                        .map_err(|e| error(&e.to_string()))?;
                    player.set_source_context(previous.context.clone());
                    player.set_current_occurrence(previous.occurrence.clone());
                    drop(player);
                    self.source_selected(&source, true).await;
                    self.begin_native_attempt(previous.stored_attempt()).await;
                    self.persist_session().await?;
                    self.wake_automatic_coordination();
                    self.report_track_started(track_id).await;
                    return Ok(true);
                }
                PreparedSource::Embedded(url, source) => {
                    let track = self.find_track(track_id).await?;
                    if self
                        .start_embedded_selection_locked(
                            track,
                            source,
                            url,
                            ids[i + 1..].to_vec(),
                            previous.context.clone(),
                            Some(previous.occurrence.clone()),
                            true,
                        )
                        .await
                        .is_ok()
                    {
                        if let Some(s) = self.embedded.lock().await.as_mut() {
                            s.logical_id = previous.logical_id.clone();
                        }
                        return Ok(true);
                    }
                }
            }
        }
        Ok(false)
    }
}
pub(super) fn track_entry(track: &Track) -> CatalogEntry {
    CatalogEntry {
        reference: CatalogReference {
            provider: "library".into(),
            kind: CatalogItemKind::Track,
            id: track.id.to_string(),
        },
        title: track.title.clone(),
        artist_credit: Some(track.artist.clone()),
        version_label: Some(track.release.clone()),
        duration_seconds: Some(track.duration_seconds.max(0.0) as u64),
        canonical_url: None,
    }
}
fn error(message: &str) -> CoreError {
    CoreError::Playback {
        message: message.into(),
    }
}
