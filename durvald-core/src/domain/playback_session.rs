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
}

pub(crate) fn encode_contexts(contexts: Vec<String>) -> String {
    serde_json::to_string(&SessionContexts {
        version: 1,
        contexts,
    })
    .unwrap_or_default()
}

pub(crate) fn decode_contexts(value: &str) -> Vec<String> {
    match serde_json::from_str::<SessionContexts>(value) {
        Ok(saved) if saved.version == 1 => saved.contexts,
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
        assert!(decode_contexts(r#"{"version":2,"contexts":["release:8"]}"#).is_empty());
    }
}
