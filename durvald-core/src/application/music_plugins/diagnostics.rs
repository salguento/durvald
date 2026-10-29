//! No I/O or background tasks. At most 64 timing samples per declared operation.
use crate::{
    api::*,
    domain::music::{
        IntegrationError,
        plugins::{PluginCapability, PluginError},
    },
};
use std::{
    collections::{BTreeMap, VecDeque},
    sync::{Arc, Mutex},
};
use tokio::time::Instant;
#[derive(Default)]
pub(super) struct Diagnostics(Mutex<BTreeMap<PluginCapability, Measurement>>);
#[derive(Default)]
struct Measurement {
    active: u64,
    completed: u64,
    succeeded: u64,
    cancelled: u64,
    failed: u64,
    samples: VecDeque<(u64, u64)>,
    last: Option<IntegrationOutcome>,
}
pub(super) struct Observation {
    diagnostics: Arc<Diagnostics>,
    capability: PluginCapability,
    start: Instant,
    queue_ms: Option<u64>,
    outcome: IntegrationOutcome,
}
fn millis(duration: std::time::Duration) -> u64 {
    duration.as_millis().min(u64::MAX as u128) as u64
}
impl Diagnostics {
    pub(super) fn begin(self: &Arc<Self>, capability: PluginCapability) -> Observation {
        self.0
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .entry(capability)
            .or_default()
            .active += 1;
        Observation {
            diagnostics: self.clone(),
            capability,
            start: Instant::now(),
            queue_ms: None,
            outcome: IntegrationOutcome::Cancelled,
        }
    }
    pub(super) fn snapshot(&self) -> Vec<IntegrationMeasurement> {
        self.0
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .iter()
            .map(|(capability, m)| {
                let mut elapsed: Vec<_> = m.samples.iter().map(|s| s.0).collect();
                let mut queue: Vec<_> = m.samples.iter().map(|s| s.1).collect();
                elapsed.sort_unstable();
                queue.sort_unstable();
                let p95 = |v: &[u64]| {
                    v.get((v.len() * 95).div_ceil(100).saturating_sub(1))
                        .copied()
                        .unwrap_or(0)
                };
                IntegrationMeasurement {
                    operation: match capability {
                        PluginCapability::CatalogSearch => IntegrationOperation::CatalogSearch,
                        PluginCapability::Metadata => IntegrationOperation::Metadata,
                        PluginCapability::SourceSearch => IntegrationOperation::SourceSearch,
                        PluginCapability::Playback => IntegrationOperation::PlaybackResolution,
                        PluginCapability::DownloadSearch => IntegrationOperation::DownloadSearch,
                        PluginCapability::DownloadTransfer => {
                            IntegrationOperation::DownloadTransfer
                        }
                        PluginCapability::CollectionRead => IntegrationOperation::CollectionRead,
                        _ => IntegrationOperation::Other,
                    },
                    active: m.active,
                    completed: m.completed,
                    succeeded: m.succeeded,
                    cancelled: m.cancelled,
                    failed: m.failed,
                    sample_count: m.samples.len() as u32,
                    p95_elapsed_ms: p95(&elapsed),
                    p95_queue_ms: p95(&queue),
                    last_outcome: m.last,
                }
            })
            .collect()
    }
}
impl Observation {
    pub(super) fn dispatched(&mut self) {
        self.queue_ms = Some(millis(self.start.elapsed()));
    }
    pub(super) fn finish<T>(&mut self, result: &Result<T, PluginError>) {
        self.outcome = match result {
            Ok(_) => IntegrationOutcome::Succeeded,
            Err(PluginError::Cancelled | PluginError::Adapter(IntegrationError::Cancelled)) => {
                IntegrationOutcome::Cancelled
            }
            Err(PluginError::Timeout | PluginError::Adapter(IntegrationError::Timeout)) => {
                IntegrationOutcome::TimedOut
            }
            Err(PluginError::Disabled) => IntegrationOutcome::Disabled,
            Err(PluginError::Busy) => IntegrationOutcome::Busy,
            Err(
                PluginError::MissingCredential
                | PluginError::Adapter(
                    IntegrationError::AuthenticationRequired | IntegrationError::AccessDenied,
                ),
            ) => IntegrationOutcome::Authentication,
            Err(PluginError::Adapter(IntegrationError::RateLimited { .. })) => {
                IntegrationOutcome::RateLimited
            }
            _ => IntegrationOutcome::Unavailable,
        };
    }
}
impl Drop for Observation {
    fn drop(&mut self) {
        let elapsed = millis(self.start.elapsed());
        let mut values = self
            .diagnostics
            .0
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let m = values.entry(self.capability).or_default();
        m.active -= 1;
        m.completed = m.completed.saturating_add(1);
        m.last = Some(self.outcome);
        match self.outcome {
            IntegrationOutcome::Succeeded => m.succeeded = m.succeeded.saturating_add(1),
            IntegrationOutcome::Cancelled => m.cancelled = m.cancelled.saturating_add(1),
            _ => m.failed = m.failed.saturating_add(1),
        }
        if m.samples.len() == 64 {
            m.samples.pop_front();
        }
        m.samples
            .push_back((elapsed, self.queue_ms.unwrap_or(elapsed)));
    }
}
