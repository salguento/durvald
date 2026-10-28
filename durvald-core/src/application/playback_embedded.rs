//! One platform-hosted transport at a time. The native upcoming queue stays in the core.
use super::playback::PlaybackApplication;
use crate::api::*;
use std::{sync::Arc, time::Duration};
use tokio::time::Instant;

/// A bounded, ordered host mailbox survives cancellation of individual API callers.
/// Load and Stop cannot overtake each other, including during a cancelled handoff.
pub(super) struct EmbeddedHostDispatcher {
    sender: tokio::sync::mpsc::Sender<(
        EmbeddedPlaybackCommand,
        tokio::sync::oneshot::Sender<CoreResult<()>>,
    )>,
}
impl EmbeddedHostDispatcher {
    fn new(host: Box<dyn EmbeddedPlaybackHost>) -> Arc<Self> {
        let host: Arc<dyn EmbeddedPlaybackHost> = Arc::from(host);
        let (sender, mut receiver) = tokio::sync::mpsc::channel::<(
            EmbeddedPlaybackCommand,
            tokio::sync::oneshot::Sender<CoreResult<()>>,
        )>(16);
        tokio::spawn(async move {
            while let Some((command, reply)) = receiver.recv().await {
                let callback = host.clone();
                let result =
                    match tokio::task::spawn_blocking(move || callback.execute(command)).await {
                        Ok(true) => Ok(()),
                        Ok(false) => Err(failure("Embedded player did not accept the command")),
                        Err(_) => Err(failure("Embedded player host failed")),
                    };
                let _ = reply.send(result);
            }
        });
        Arc::new(Self { sender })
    }
    async fn execute(&self, command: EmbeddedPlaybackCommand) -> CoreResult<()> {
        let (reply, result) = tokio::sync::oneshot::channel();
        self.sender
            .send((command, reply))
            .await
            .map_err(|_| failure("Embedded player host closed"))?;
        result
            .await
            .map_err(|_| failure("Embedded player host closed"))?
    }
}

pub(super) struct EmbeddedStart {
    pub track: Option<Track>,
    pub entry: CatalogEntry,
    pub candidate: Option<SourceCandidate>,
    pub source_id: Option<i64>,
    pub url: String,
    pub remaining: Vec<i64>,
    pub context: String,
    pub occurrence: Option<String>,
}
#[derive(Clone)]
pub(super) struct EmbeddedSession {
    pub snapshot: EmbeddedPlaybackSnapshot,
    pub track: Option<Track>,
    pub entry: CatalogEntry,
    pub candidate: Option<SourceCandidate>,
    pub url: String,
    pub occurrence: String,
    pub remaining: Vec<i64>,
    pub context: String,
    pub started: bool,
    position: f64,
    duration: Option<f64>,
    sequence: u64,
    heard: f64,
    last_event: Instant,
    last_progress: Instant,
}
impl PlaybackApplication {
    pub(crate) async fn set_embedded_host(
        &self,
        host: Box<dyn EmbeddedPlaybackHost>,
    ) -> CoreResult<()> {
        let _transition = self.playback_transition.lock().await;
        self.stop_embedded_locked().await?;
        *self.embedded_host.lock().await = Some(EmbeddedHostDispatcher::new(host));
        Ok(())
    }
    pub(crate) async fn detach_embedded_host(&self) -> CoreResult<()> {
        let _transition = self.playback_transition.lock().await;
        self.stop_embedded_locked().await?;
        *self.embedded_host.lock().await = None;
        Ok(())
    }
    async fn deliver_embedded(&self, command: EmbeddedPlaybackCommand) -> CoreResult<()> {
        let host =
            self.embedded_host.lock().await.clone().ok_or_else(|| {
                failure("No visible embedded player is registered on this platform")
            })?;
        host.execute(command).await
    }
    pub(crate) async fn embedded_playback(&self) -> Option<EmbeddedPlaybackSnapshot> {
        self.embedded
            .lock()
            .await
            .as_ref()
            .map(|s| s.snapshot.clone())
    }
    pub(crate) async fn play_embedded_source(
        &self,
        track_id: i64,
        source_id: i64,
    ) -> CoreResult<PlaybackSnapshot> {
        let track = self.find_track(track_id).await?;
        let _transition = self.playback_transition.lock().await;
        let mut candidates = self.ordered_sources(track_id, Some(source_id)).await?;
        let selected = candidates.remove(0);
        if selected.provider != "soundcloud" {
            return Err(failure("Escolha uma origem SoundCloud habilitada."));
        }
        let super::playback_sources::PreparedSource::Embedded(url, selected) =
            self.prepare_source(selected).await?
        else {
            return Err(failure("Esta origem não oferece player integrado."));
        };
        self.source_selected(&selected, false).await;
        self.begin_embedded_locked(EmbeddedStart {
            entry: super::playback_sources::track_entry(&track),
            track: Some(track),
            candidate: None,
            source_id: Some(source_id),
            url,
            remaining: vec![],
            context: String::new(),
            occurrence: None,
        })
        .await?;
        Ok(self.playback().await)
    }
    pub(super) async fn begin_embedded_locked(&self, start: EmbeddedStart) -> CoreResult<()> {
        if self.embedded_host.lock().await.is_none() {
            return Err(failure("This platform has no visible embedded player"));
        }
        self.stop_embedded_locked().await?;
        self.audio_player
            .lock()
            .await
            .stop_for_embedded()
            .map_err(|e| failure(&e.to_string()))?;
        self.clear_lastfm_tracking().await;
        let generation = crate::audio::player::new_occurrence_id();
        let snapshot = EmbeddedPlaybackSnapshot {
            generation: generation.clone(),
            track_id: start.track.as_ref().map(|t| t.id),
            source_id: start.source_id,
            canonical_url: start.url.clone(),
            title: start.entry.title.clone(),
            artist: start.entry.artist_credit.clone(),
            state: EmbeddedPlaybackState::Loading,
            seek_available: false,
            message: None,
        };
        let url = start.url.clone();
        *self.embedded.lock().await = Some(EmbeddedSession {
            snapshot,
            track: start.track,
            entry: start.entry,
            candidate: start.candidate,
            url: start.url,
            occurrence: start.occurrence.unwrap_or_else(|| generation.clone()),
            remaining: start.remaining,
            context: start.context,
            started: false,
            position: 0.0,
            duration: None,
            sequence: 0,
            heard: 0.0,
            last_event: Instant::now(),
            last_progress: Instant::now(),
        });
        let volume = self.audio_player.lock().await.volume();
        if let Err(error) = self
            .deliver_embedded(EmbeddedPlaybackCommand {
                generation,
                kind: EmbeddedCommandKind::Load,
                url: Some(url),
                value: volume as f64,
            })
            .await
        {
            self.fail_embedded_locked("Não foi possível abrir o player integrado.")
                .await;
            return Err(error);
        }
        self.persist_session().await
    }
    pub(crate) async fn preview_candidate(
        &self,
        entry: CatalogEntry,
        candidate: SourceCandidate,
    ) -> CoreResult<PlaybackSnapshot> {
        let _transition = self.playback_transition.lock().await;
        let url = self.resolve_soundcloud(&candidate.canonical_url).await?;
        *self.source_status.lock().await = Some(PlaybackSourceStatus {
            source_id: None,
            provider: "soundcloud".into(),
            message: Some(
                "Audição temporária: a faixa ainda não foi salva na biblioteca ou no histórico."
                    .into(),
            ),
        });
        self.begin_embedded_locked(EmbeddedStart {
            track: None,
            entry,
            candidate: Some(candidate),
            source_id: None,
            url,
            remaining: vec![],
            context: "preview:soundcloud".into(),
            occurrence: None,
        })
        .await?;
        Ok(self.playback().await)
    }
    pub(crate) async fn save_listening_source(
        &self,
        generation: String,
        target: Option<i64>,
        confirmed: bool,
    ) -> CoreResult<TrackSource> {
        if !confirmed {
            return Err(CoreError::InvalidInput {
                message: "Revise artista e versão antes de associar a origem.".into(),
            });
        }
        let _transition = self.playback_transition.lock().await;
        let current = self
            .embedded
            .lock()
            .await
            .clone()
            .filter(|s| s.snapshot.generation == generation)
            .ok_or_else(|| failure("A audição mudou. Revise a origem atual."))?;
        if let (Some(track), Some(source)) = (current.snapshot.track_id, current.snapshot.source_id)
        {
            if target.is_some_and(|id| id != track) {
                return Err(failure("A origem já está associada a outra faixa."));
            }
            return self
                .track_query
                .sources(track)
                .await?
                .into_iter()
                .find(|s| s.source_id == source)
                .ok_or_else(|| failure("Origem removida."));
        }
        let candidate = current
            .candidate
            .ok_or_else(|| failure("Nenhum candidato em reprodução."))?;
        let target = target.or_else(|| {
            (current.entry.reference.provider == "library")
                .then(|| current.entry.reference.id.parse().ok())
                .flatten()
        });
        let saved = self
            .track_query
            .attach_candidate(current.entry, candidate, target)
            .await?;
        let track = self.find_track(saved.track_id).await?;
        if let Some(s) = self.embedded.lock().await.as_mut() {
            s.snapshot.track_id = Some(saved.track_id);
            s.snapshot.source_id = Some(saved.source_id);
            s.track = Some(track);
            s.candidate = None;
        }
        self.source_selected(&saved, false).await;
        Ok(saved)
    }
    pub(super) async fn stop_embedded_locked(&self) -> CoreResult<()> {
        let current = self.embedded.lock().await.clone();
        if let Some(s) = current {
            self.deliver_embedded(EmbeddedPlaybackCommand {
                generation: s.snapshot.generation,
                kind: EmbeddedCommandKind::Stop,
                url: None,
                value: 0.0,
            })
            .await?;
            *self.embedded.lock().await = None;
        }
        Ok(())
    }
    pub(super) async fn embedded_command(
        &self,
        kind: EmbeddedCommandKind,
        value: f64,
    ) -> CoreResult<bool> {
        let _transition = self.playback_transition.lock().await;
        let Some(s) = self.embedded.lock().await.clone() else {
            return Ok(false);
        };
        if kind == EmbeddedCommandKind::Seek
            && (!s.snapshot.seek_available || s.duration.is_none_or(|d| value > d))
        {
            return Err(failure("Seeking is not available at this position"));
        }
        if matches!(
            s.snapshot.state,
            EmbeddedPlaybackState::Ended | EmbeddedPlaybackState::Failed
        ) && kind == EmbeddedCommandKind::Play
        {
            self.restart_embedded_locked(s).await?;
        } else if !matches!(
            s.snapshot.state,
            EmbeddedPlaybackState::Ended | EmbeddedPlaybackState::Failed
        ) {
            self.deliver_embedded(EmbeddedPlaybackCommand {
                generation: s.snapshot.generation,
                kind,
                url: None,
                value,
            })
            .await?;
        }
        Ok(true)
    }
    async fn restart_embedded_locked(&self, mut s: EmbeddedSession) -> CoreResult<()> {
        if let (Some(track), Some(source)) = (s.snapshot.track_id, s.snapshot.source_id) {
            s.url = self.track_query.embedded_source_url(track, source).await?;
        }
        s.url = self.resolve_soundcloud(&s.url).await?;
        self.stop_embedded_locked().await?;
        s.snapshot.generation = crate::audio::player::new_occurrence_id();
        s.snapshot.state = EmbeddedPlaybackState::Loading;
        s.snapshot.seek_available = false;
        s.snapshot.message = None;
        s.position = 0.0;
        s.duration = None;
        s.sequence = 0;
        s.heard = 0.0;
        s.started = false;
        s.remaining.clear();
        s.last_event = Instant::now();
        s.last_progress = Instant::now();
        let command = EmbeddedPlaybackCommand {
            generation: s.snapshot.generation.clone(),
            kind: EmbeddedCommandKind::Load,
            url: Some(s.url.clone()),
            value: self.audio_player.lock().await.volume() as f64,
        };
        *self.embedded.lock().await = Some(s);
        if let Err(e) = self.deliver_embedded(command).await {
            self.fail_embedded_locked("Falha ao reiniciar o player.")
                .await;
            return Err(e);
        }
        Ok(())
    }
    pub(super) async fn overlay_embedded(&self, snapshot: &mut PlaybackSnapshot) {
        let Some(s) = self.embedded.lock().await.clone() else {
            return;
        };
        if snapshot.current_track.is_some() && !snapshot.queue.is_empty() {
            snapshot.queue.remove(0);
        }
        // Personal values may change while WebKit owns the transport. Read the
        // canonical row as native playback does; never freeze favorite/rating UI.
        snapshot.current_track = if let Some(track) = s.track {
            self.find_track(track.id).await.ok().or(Some(track))
        } else {
            None
        };
        snapshot.source_context = if s.context.is_empty() {
            "embedded:soundcloud".into()
        } else {
            s.context
        };
        snapshot.position_seconds = s.position;
        snapshot.duration_seconds = s.duration;
        snapshot.is_playing = s.snapshot.state == EmbeddedPlaybackState::Playing;
        snapshot.is_paused = s.snapshot.state != EmbeddedPlaybackState::Playing;
        if let Some(track_id) = s.snapshot.track_id {
            snapshot.queue.insert(
                0,
                QueueItem {
                    track_id,
                    occurrence_id: s.occurrence,
                    position: 0,
                },
            );
        }
        for (i, item) in snapshot.queue.iter_mut().enumerate() {
            item.position = i as u64;
        }
    }
    pub(crate) async fn embedded_event(&self, event: EmbeddedPlaybackEvent) -> CoreResult<()> {
        if !event.position_seconds.is_finite()
            || !(0.0..=604800.0).contains(&event.position_seconds)
            || event
                .duration_seconds
                .is_some_and(|d| !d.is_finite() || d <= 0.0 || d > 604800.0)
        {
            return Err(CoreError::InvalidInput {
                message: "Invalid embedded timing event".into(),
            });
        }
        let _transition = self.playback_transition.lock().await;
        let mut finished = None;
        {
            let mut state = self.embedded.lock().await;
            let Some(s) = state.as_mut() else {
                return Ok(());
            };
            if s.snapshot.generation != event.generation
                || event.sequence <= s.sequence
                || matches!(
                    s.snapshot.state,
                    EmbeddedPlaybackState::Ended | EmbeddedPlaybackState::Failed
                )
            {
                return Ok(());
            }
            s.sequence = event.sequence;
            let now = Instant::now();
            if let Some(duration) = event.duration_seconds {
                s.duration = Some(duration);
            }
            if event.kind == EmbeddedEventKind::Progress && event.position_seconds > 0.0 {
                // An observed advancing clock also rules out a pre-audio fallback
                // if a provider ever drops its PLAY notification.
                s.started = true;
                s.remaining.clear();
            }
            if event.kind == EmbeddedEventKind::Progress
                && s.snapshot.state == EmbeddedPlaybackState::Playing
            {
                let delta = event.position_seconds - s.position;
                if delta > 0.0 {
                    s.heard += delta.min(now.duration_since(s.last_event).as_secs_f64() + 0.1);
                    s.last_progress = now;
                }
            }
            s.position = event.position_seconds.min(s.duration.unwrap_or(604800.0));
            s.last_event = now;
            match event.kind {
                EmbeddedEventKind::Ready => {
                    s.snapshot.seek_available = s.duration.is_some();
                }
                EmbeddedEventKind::Playing => {
                    s.snapshot.state = EmbeddedPlaybackState::Playing;
                    s.started = true;
                    s.remaining.clear();
                    s.last_progress = now;
                }
                EmbeddedEventKind::Paused => {
                    s.snapshot.state = EmbeddedPlaybackState::Paused;
                }
                EmbeddedEventKind::Ended => {
                    s.snapshot.state = EmbeddedPlaybackState::Ended;
                    if let Some(d) = s
                        .duration
                        .filter(|d| *d >= 1.0 && s.heard >= (d / 2.0).min(240.0))
                    {
                        finished = s.snapshot.track_id.map(|id| (id, d as u64));
                    }
                }
                EmbeddedEventKind::Failed => {
                    s.snapshot.state = EmbeddedPlaybackState::Failed;
                    s.snapshot.message = Some("O serviço não conseguiu reproduzir esta faixa. Confira o acesso no SoundCloud.".into());
                }
                _ => {}
            }
        }
        if event.kind == EmbeddedEventKind::Failed {
            self.fail_embedded_locked("O serviço não conseguiu reproduzir esta faixa.")
                .await;
            self.fallback_before_audio_locked().await?;
        }
        if let Some((id, duration)) = finished {
            self.history_repository
                .record_completed(
                    crate::domain::ids::TrackId::try_from(id)
                        .map_err(|_| failure("Invalid track"))?,
                    duration,
                )
                .await
                .map_err(|message| CoreError::Storage { message })?;
        }
        if event.kind == EmbeddedEventKind::Ended {
            // Completion is terminal before history/advance, making repeated FINISH idempotent.
            let mode = self.audio_player.lock().await.repeat_mode();
            let queued = !self.audio_player.lock().await.get_queue().is_empty();
            if mode == RepeatMode::One || (mode == RepeatMode::All && !queued) {
                let current = self.embedded.lock().await.clone();
                if let Some(s) = current {
                    self.restart_embedded_locked(s).await?;
                }
            } else if queued {
                let plan = self.audio_player.lock().await.plan_next();
                if let Some(plan) = plan {
                    if self.commit_navigation_plan(plan).await.is_err() {
                        if let Some(s) = self.embedded.lock().await.as_mut() {
                            s.snapshot.message = Some("A próxima faixa não possui uma origem local disponível. Escolha uma origem para continuar.".into());
                        }
                    }
                }
            }
        }
        Ok(())
    }
    pub(super) async fn next_from_embedded(&self) -> CoreResult<PlaybackSnapshot> {
        let _transition = self.playback_transition.lock().await;
        let plan = self
            .audio_player
            .lock()
            .await
            .plan_next()
            .ok_or_else(|| failure("No upcoming local track"))?;
        self.commit_navigation_plan(plan).await
    }
    pub(super) async fn check_embedded_timeout_locked(&self) {
        let expired = self.embedded.lock().await.as_ref().is_some_and(|s| {
            (s.snapshot.state == EmbeddedPlaybackState::Loading
                && s.last_event.elapsed() > Duration::from_secs(30))
                || (s.snapshot.state == EmbeddedPlaybackState::Playing
                    && s.last_progress.elapsed() > Duration::from_secs(30))
        });
        if expired {
            self.fail_embedded_locked(
                "O player não respondeu ou a reprodução parou de avançar. Tente novamente.",
            )
            .await;
            let _ = self.fallback_before_audio_locked().await;
        }
    }
    async fn fail_embedded_locked(&self, message: &str) {
        let generation = self
            .embedded
            .lock()
            .await
            .as_ref()
            .map(|s| s.snapshot.generation.clone());
        if let Some(generation) = generation {
            let _ = self
                .deliver_embedded(EmbeddedPlaybackCommand {
                    generation,
                    kind: EmbeddedCommandKind::Stop,
                    url: None,
                    value: 0.0,
                })
                .await;
            if let Some(s) = self.embedded.lock().await.as_mut() {
                s.snapshot.state = EmbeddedPlaybackState::Failed;
                s.snapshot.message = Some(message.into());
            }
        }
    }
}
fn failure(message: &str) -> CoreError {
    CoreError::Playback {
        message: message.into(),
    }
}
