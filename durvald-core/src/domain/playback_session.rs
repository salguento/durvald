//! Playback-session state independent from its SQLite representation.

pub(crate) struct PlaybackSessionState {
    pub(crate) current_track_id: Option<i64>,
    pub(crate) progress_seconds: f64,
    pub(crate) volume: f64,
    pub(crate) shuffle_enabled: bool,
    pub(crate) repeat_mode: String,
    pub(crate) queue: Vec<i64>,
    pub(crate) queue_position: u64,
    pub(crate) source_context: String,
    pub(crate) updated_at: String,
}

/// Versioned occurrence metadata in the existing session context column.
/// Legacy sessions only identify the current origin; never guess later occurrences.
#[derive(serde::Serialize, serde::Deserialize)]
struct SessionContexts {
    version: u8,
    contexts: Vec<String>,
    #[serde(default)]
    collection: Option<StoredCollection>,
    #[serde(default)]
    occurrences: Vec<String>,
    #[serde(default)]
    attempt: Option<StoredAttempt>,
    #[serde(default)]
    navigation: Vec<StoredNavigationItem>,
}

#[cfg(test)]
pub(crate) fn encode_contexts(contexts: Vec<String>) -> String {
    serde_json::to_string(&SessionContexts {
        version: 1,
        contexts,
        collection: None,
        occurrences: Vec::new(),
        attempt: None,
        navigation: Vec::new(),
    })
    .unwrap_or_default()
}

pub(crate) fn decode_contexts(value: &str) -> Vec<String> {
    match serde_json::from_str::<SessionContexts>(value) {
        Ok(saved) if (1..=4).contains(&saved.version) => saved.contexts,
        _ if value.starts_with('{') => Vec::new(),
        _ => vec![value.to_string()],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn occurrence_contexts_roundtrip_and_legacy_contexts_remain_conservative() {
        let contexts = vec!["playlist:7#2".into(), "release:8".into(), String::new()];
        assert_eq!(
            decode_contexts(&encode_contexts(contexts.clone())),
            contexts
        );
        assert_eq!(decode_contexts("release:8"), vec!["release:8"]);
        assert!(decode_contexts(r#"{"version":5,"contexts":["release:8"]}"#).is_empty());
    }
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub(crate) struct StoredCollectionItem {
    #[serde(default)]
    pub(crate) occurrence_id: String,
    pub(crate) track_id: i64,
    pub(crate) source_context: String,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub(crate) struct StoredCollection {
    pub(crate) items: Vec<StoredCollectionItem>,
    pub(crate) excluded: Vec<usize>,
    pub(crate) positions: Vec<Option<usize>>,
}

pub(crate) fn decode_collection(value: &str) -> Option<StoredCollection> {
    let saved: SessionContexts = serde_json::from_str(value).ok()?;
    if (2..=4).contains(&saved.version) {
        saved.collection
    } else {
        None
    }
}

pub(crate) fn encode_session(
    contexts: Vec<String>,
    collection: Option<StoredCollection>,
    occurrences: Vec<String>,
    attempt: Option<StoredAttempt>,
    navigation: Vec<StoredNavigationItem>,
) -> String {
    serde_json::to_string(&SessionContexts {
        version: 4,
        contexts,
        collection,
        occurrences,
        attempt,
        navigation,
    })
    .unwrap_or_default()
}
pub(crate) fn decode_occurrences(value: &str) -> Vec<String> {
    serde_json::from_str::<SessionContexts>(value)
        .ok()
        .filter(|s| (3..=4).contains(&s.version))
        .map(|s| s.occurrences)
        .unwrap_or_default()
}

/// Durable identity and listening evidence; never stores media URLs or host generations.
#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
pub(crate) struct StoredAttempt {
    pub id: String,
    pub track_id: i64,
    pub occurrence_id: String,
    pub source_id: Option<i64>,
    pub exclusive: bool,
    pub heard_seconds: f64,
    pub duration_seconds: Option<f64>,
    pub history_allowed: bool,
}
pub(crate) fn decode_attempt(value: &str) -> Option<StoredAttempt> {
    let state: SessionContexts = serde_json::from_str(value).ok()?;
    let a = state.attempt?;
    (state.version == 4
        && !a.id.is_empty()
        && a.id.len() <= 200
        && !a.occurrence_id.is_empty()
        && a.heard_seconds.is_finite()
        && (0.0..=604800.0).contains(&a.heard_seconds)
        && a.duration_seconds
            .is_none_or(|d| d.is_finite() && d > 0.0 && d <= 604800.0))
    .then_some(a)
}

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
pub(crate) struct StoredNavigationItem {
    pub track_id: i64,
    pub occurrence_id: String,
    pub source_context: String,
    pub collection_position: Option<usize>,
}
pub(crate) fn decode_navigation(value: &str) -> Vec<StoredNavigationItem> {
    serde_json::from_str::<SessionContexts>(value)
        .ok()
        .filter(|s| s.version == 4)
        .map(|s| s.navigation.into_iter().take(10000).collect())
        .unwrap_or_default()
}
