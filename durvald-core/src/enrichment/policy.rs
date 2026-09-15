use crate::api::{CoreError, CoreResult, EnrichmentProvider, EnrichmentSettings};
use std::time::Duration;

pub const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
/// Includes queueing, retries and reading the entire body.
pub const OPERATION_TIMEOUT: Duration = Duration::from_secs(20);
pub const MAX_JSON_BYTES: usize = 2 * 1024 * 1024;
pub const PROFILE_TTL: Duration = Duration::from_secs(30 * 24 * 60 * 60);
pub const POPULAR_TRACKS_TTL: Duration = Duration::from_secs(24 * 60 * 60);
pub const DISCOGRAPHY_TTL: Duration = Duration::from_secs(7 * 24 * 60 * 60);
pub const EXTERNAL_RELEASE_DETAILS_TTL: Duration = Duration::from_secs(30 * 24 * 60 * 60);
pub const NOT_FOUND_TTL: Duration = Duration::from_secs(24 * 60 * 60);
pub const PERMANENT_FAILURE_TTL: Duration = Duration::from_secs(7 * 24 * 60 * 60);
pub const COVER_NOT_FOUND_TTL: Duration = Duration::from_secs(30 * 24 * 60 * 60);
pub const COVER_INVALID_IMAGE_TTL: Duration = Duration::from_secs(7 * 24 * 60 * 60);
pub const COVER_TRANSIENT_FAILURE_TTL: Duration = Duration::from_secs(15 * 60);

/// Accept bounded language tags, not URLs or arbitrary SQL/cache-key fragments.
/// Provider adapters will separately map tags to supported Wikipedia editions.
pub fn normalize_language(value: &str) -> CoreResult<String> {
    let value = value.trim();
    let mut parts = value.split('-');
    let first = parts.next().unwrap_or_default();
    if value.len() > 35
        || !(2..=8).contains(&first.len())
        || !first.bytes().all(|b| b.is_ascii_alphabetic())
        || !parts.all(|part| {
            (1..=8).contains(&part.len()) && part.bytes().all(|b| b.is_ascii_alphanumeric())
        })
    {
        return Err(CoreError::InvalidInput {
            message: "Expected a language tag such as pt, pt-BR or en".into(),
        });
    }
    Ok(value.to_ascii_lowercase())
}

pub fn normalized_settings(mut settings: EnrichmentSettings) -> CoreResult<EnrichmentSettings> {
    settings.preferred_language = normalize_language(&settings.preferred_language)?;
    Ok(settings)
}

pub fn network_allowed(settings: &EnrichmentSettings) -> bool {
    settings.enabled && !settings.offline
}

impl EnrichmentProvider {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::MusicBrainz => "music_brainz",
            Self::Wikidata => "wikidata",
            Self::Wikipedia => "wikipedia",
            Self::Commons => "commons",
            Self::CoverArtArchive => "cover_art_archive",
            Self::LastFm => "last_fm",
            Self::TheAudioDb => "the_audio_db",
            Self::YouTube => "you_tube",
        }
    }
}

impl crate::api::ArtistProfileField {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::EntityKind => "entity_kind",
            Self::BirthDate => "birth_date",
            Self::BirthPlace => "birth_place",
            Self::FormationDate => "formation_date",
            Self::FormationPlace => "formation_place",
            Self::OriginPlace => "origin_place",
            Self::Biography => "biography",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn language_keys_are_normalized_and_bounded() {
        assert_eq!(EnrichmentProvider::LastFm.as_str(), "last_fm");
        assert_eq!(normalize_language(" pt-BR ").unwrap(), "pt-br");
        for invalid in ["", "p", "pt_BR", "en/../../", "en--us", "éé", "en-"] {
            assert!(normalize_language(invalid).is_err(), "{invalid}");
        }
        assert!(!network_allowed(&EnrichmentSettings::default()));
        assert!(!network_allowed(&EnrichmentSettings {
            enabled: true,
            offline: true,
            ..Default::default()
        }));
    }

    #[test]
    fn cover_negative_ttls_distinguish_confirmed_and_transient_failures() {
        assert!(COVER_NOT_FOUND_TTL > COVER_INVALID_IMAGE_TTL);
        assert!(COVER_INVALID_IMAGE_TTL > COVER_TRANSIENT_FAILURE_TTL);
    }
}
