//! Valid internal representation of persisted application settings.

pub(crate) struct ApplicationSettings {
    pub(crate) cross_fade: bool,
    pub(crate) cross_fade_duration: u32,
    pub(crate) normalize_volume: bool,
    pub(crate) explicit_content: bool,
    pub(crate) autoplay: bool,
    pub(crate) preferred_audio_quality: u32,
    pub(crate) preferred_audio_source: String,
    pub(crate) download_path: String,
    pub(crate) open_on_startup: bool,
    pub(crate) minimize_on_close: bool,
    pub(crate) onboarding_complete: bool,
    pub(crate) preferred_output_device_id: Option<String>,
}

pub(crate) fn normalized_cross_fade_duration(value: i32) -> u32 {
    u32::try_from(value).unwrap_or_default().min(60)
}

pub(crate) fn normalized_audio_quality(value: i32) -> u32 {
    u32::try_from(value)
        .ok()
        .filter(|value| (1..=1411).contains(value))
        .unwrap_or(320)
}
