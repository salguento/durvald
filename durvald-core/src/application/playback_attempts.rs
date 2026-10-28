//! Durable logical listens shared by native and platform transports.
use super::playback::PlaybackApplication;
use crate::{
    api::*,
    domain::{ids::TrackId, playback_session::StoredAttempt},
};
use tokio::time::Instant;

pub(super) struct NativeAttempt {
    pub saved: StoredAttempt,
    counter: f64,
    finished: bool,
}
impl PlaybackApplication {
    pub(crate) async fn restore_attempt(&self, saved: Option<StoredAttempt>) {
        let identity = self
            .audio_player
            .lock()
            .await
            .queue_occurrences()
            .first()
            .cloned();
        let saved = saved.filter(|a| {
            identity
                .as_ref()
                .is_some_and(|(track, id)| *track == a.track_id && id == &a.occurrence_id)
        });
        if let Some(a) = saved.as_ref().filter(|a| a.exclusive) {
            *self.source_override.lock().await = a.source_id.map(|s| (a.occurrence_id.clone(), s));
        }
        *self.restored_attempt.lock().await = saved;
    }
    pub(super) async fn begin_native_attempt(&self, restored: Option<StoredAttempt>) {
        let (track, occurrence, duration, path) = {
            let p = self.audio_player.lock().await;
            let Some(track) = p.get_current_song_id() else {
                return;
            };
            let Some((_, occurrence)) = p.queue_occurrences().first().cloned() else {
                return;
            };
            let (_, duration) = p.get_progress();
            (
                track,
                occurrence,
                duration.map(|d| d.as_secs_f64()),
                p.current_media_path(),
            )
        };
        let source = self
            .track_query
            .sources(track)
            .await
            .unwrap_or_default()
            .into_iter()
            .find(|s| s.provider == "local" && s.local_path == path)
            .map(|s| s.source_id);
        let exclusive = self
            .source_override
            .lock()
            .await
            .as_ref()
            .is_some_and(|(id, _)| id == &occurrence);
        let mut saved = restored
            .filter(|s| s.track_id == track && s.occurrence_id == occurrence)
            .unwrap_or(StoredAttempt {
                id: crate::audio::player::new_occurrence_id(),
                track_id: track,
                occurrence_id: occurrence,
                source_id: source,
                exclusive,
                heard_seconds: 0.0,
                duration_seconds: duration,
                history_allowed: true,
            });
        if let Some(id) = source {
            let mut status = self.source_status.lock().await;
            let message = status
                .as_ref()
                .filter(|s| s.source_id == Some(id))
                .and_then(|s| s.message.clone());
            *status = Some(PlaybackSourceStatus {
                source_id: Some(id),
                preferred_source_id: None,
                provider: "local".into(),
                message,
            });
        }
        if saved.source_id != source && saved.heard_seconds > 0.0 {
            saved.id = crate::audio::player::new_occurrence_id();
            saved.heard_seconds = 0.0;
        }
        // Native playback has prepared a complete local file. A pre-audio
        // fallback must not inherit a remote preview's history restriction.
        saved.history_allowed = true;
        saved.source_id = source;
        saved.duration_seconds = duration;
        saved.exclusive = exclusive;
        *self.native_attempt.lock().await = Some(NativeAttempt {
            saved,
            counter: 0.0,
            finished: false,
        });
        *self.restored_attempt.lock().await = None;
    }
    pub(super) async fn observe_native(&self) {
        let (id, occurrence, counter) = {
            let p = self.audio_player.lock().await;
            (
                p.get_current_song_id(),
                p.queue_occurrences().first().map(|i| i.1.clone()),
                p.listened_seconds(),
            )
        };
        if let Some(a) = self.native_attempt.lock().await.as_mut() {
            if Some(a.saved.track_id) == id && Some(&a.saved.occurrence_id) == occurrence.as_ref() {
                a.saved.heard_seconds =
                    (a.saved.heard_seconds + (counter - a.counter).max(0.0)).min(604800.0);
                a.counter = counter;
            }
        }
    }
    pub(super) async fn finish_native_attempt(&self, rendered: Option<f64>) {
        let saved = {
            let mut current = self.native_attempt.lock().await;
            let Some(a) = current.as_mut() else { return };
            if a.finished {
                return;
            }
            if let Some(counter) = rendered {
                a.saved.heard_seconds =
                    (a.saved.heard_seconds + (counter - a.counter).max(0.0)).min(604800.0);
                a.counter = counter;
            }
            a.saved.clone()
        };
        if self.record_attempt(&saved).await.is_ok() {
            if let Some(a) = self
                .native_attempt
                .lock()
                .await
                .as_mut()
                .filter(|a| a.saved.id == saved.id)
            {
                a.finished = true;
            }
            let _ = self.persist_session().await;
        }
    }
    pub(super) async fn record_attempt(&self, a: &StoredAttempt) -> CoreResult<()> {
        let Some(duration) = a
            .duration_seconds
            .filter(|d| *d >= 1.0 && a.heard_seconds >= (*d / 2.0).min(240.0))
        else {
            return Ok(());
        };
        if !a.history_allowed {
            return Ok(());
        }
        self.history_repository
            .record_completed(
                TrackId::try_from(a.track_id).map_err(|_| CoreError::InvalidInput {
                    message: "Invalid playback identity".into(),
                })?,
                a.source_id,
                a.id.clone(),
                a.heard_seconds.round() as u64,
                duration.ceil() as u64,
            )
            .await
            .map_err(|message| CoreError::Storage { message })?;
        Ok(())
    }
    pub(super) async fn durable_attempt(&self) -> Option<StoredAttempt> {
        if let Some(s) = self.embedded.lock().await.as_ref() {
            let mut attempt = s.stored_attempt();
            if let Some(a) = attempt.as_mut() {
                a.exclusive = self
                    .source_override
                    .lock()
                    .await
                    .as_ref()
                    .is_some_and(|(id, _)| id == &a.occurrence_id);
            }
            return attempt;
        }
        if let Some(a) = self.native_attempt.lock().await.as_ref() {
            return Some(a.saved.clone());
        }
        self.restored_attempt.lock().await.clone()
    }
    pub(super) async fn persist_active_progress(&self) {
        let now = Instant::now();
        let mut last = self.last_session_write.lock().await;
        if now.duration_since(*last).as_secs_f64() < 1.0 {
            return;
        }
        *last = now;
        drop(last);
        let _ = self.persist_session().await;
    }
}
