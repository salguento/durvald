//! Internal plugin manifest v1. Capabilities are independent of library adoption.
use std::collections::{BTreeMap, BTreeSet};

use super::{IntegrationError, identity::ProviderId};

pub(crate) const PLUGIN_API_VERSION: u16 = 1;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd)]
pub(crate) enum PluginCapability {
    CatalogSearch,
    Metadata,
    SourceSearch,
    Playback,
    DownloadSearch,
    DownloadTransfer,
    CollectionRead,
    ArtistNews,
    ExtraCommands,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd)]
pub(crate) enum PluginPermission {
    Network,
    Credentials,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct PluginVersion {
    pub(crate) major: u16,
    pub(crate) minor: u16,
    pub(crate) patch: u16,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct ConfigurationField {
    pub(crate) required: bool,
    pub(crate) default: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct PluginManifest {
    pub(crate) id: ProviderId,
    pub(crate) version: PluginVersion,
    pub(crate) api_version: u16,
    pub(crate) capabilities: BTreeSet<PluginCapability>,
    pub(crate) permissions: BTreeSet<PluginPermission>,
    /// Optional canonical HTTP host used by the existing durable cooldown store.
    pub(crate) primary_host: Option<String>,
    pub(crate) settings: BTreeMap<String, ConfigurationField>,
    pub(crate) flags: BTreeSet<String>,
    /// Values are required/optional, never the secrets themselves.
    pub(crate) credentials: BTreeMap<String, bool>,
}

#[derive(Clone, Default, Eq, PartialEq)]
pub(crate) struct PluginConfiguration {
    pub(crate) values: BTreeMap<String, String>,
    pub(crate) flags: BTreeMap<String, bool>,
}

impl std::fmt::Debug for PluginConfiguration {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PluginConfiguration")
            .field("setting_keys", &self.values.keys().collect::<Vec<_>>())
            .field("flags", &self.flags)
            .finish()
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct SavedPluginState {
    pub(crate) enabled: bool,
    pub(crate) removed: bool,
    pub(crate) configuration: PluginConfiguration,
}

pub(crate) type PluginPreferences = BTreeMap<String, SavedPluginState>;

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct PluginStatus {
    pub(crate) manifest: PluginManifest,
    pub(crate) enabled: bool,
    pub(crate) generation: u64,
    pub(crate) configuration: PluginConfiguration,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, thiserror::Error)]
pub(crate) enum PluginError {
    #[error("invalid plugin manifest")]
    InvalidManifest,
    #[error("unsupported plugin API version")]
    IncompatibleApi,
    #[error("plugin already registered")]
    AlreadyRegistered,
    #[error("plugin not registered")]
    NotRegistered,
    #[error("plugin is disabled")]
    Disabled,
    #[error("invalid plugin configuration")]
    InvalidConfiguration,
    #[error("permission or capability not granted")]
    PermissionDenied,
    #[error("required credential is missing")]
    MissingCredential,
    #[error("plugin storage unavailable")]
    Storage,
    #[error("plugin task capacity exhausted")]
    Busy,
    #[error("plugin operation cancelled or superseded")]
    Cancelled,
    #[error("plugin operation timed out")]
    Timeout,
    #[error("plugin task failed")]
    AdapterFailed,
    #[error("plugin adapter returned {0:?}")]
    Adapter(IntegrationError),
}

pub(crate) fn valid_configuration_key(key: &str) -> bool {
    !key.is_empty()
        && key.len() <= 64
        && key
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'_' | b'-' | b'.'))
}

impl PluginManifest {
    pub(crate) fn validate(&self) -> Result<(), PluginError> {
        if self.api_version != PLUGIN_API_VERSION {
            return Err(PluginError::IncompatibleApi);
        }
        if self.capabilities.is_empty()
            || self.settings.len() + self.flags.len() + self.credentials.len() > 64
            || self
                .settings
                .keys()
                .chain(&self.flags)
                .chain(self.credentials.keys())
                .any(|key| !valid_configuration_key(key))
            || self
                .settings
                .keys()
                .any(|key| self.flags.contains(key) || self.credentials.contains_key(key))
            || self
                .flags
                .iter()
                .any(|key| self.credentials.contains_key(key))
            || (!self.credentials.is_empty()
                && !self.permissions.contains(&PluginPermission::Credentials))
            || self
                .settings
                .values()
                .filter_map(|field| field.default.as_ref())
                .any(|value| value.len() > 4096)
        {
            return Err(PluginError::InvalidManifest);
        }
        match &self.primary_host {
            Some(host)
                if self.permissions.contains(&PluginPermission::Network)
                    && host.len() <= 253
                    && !host.is_empty()
                    && host.split('.').all(|part| {
                        !part.is_empty()
                            && part.len() <= 63
                            && !part.starts_with('-')
                            && !part.ends_with('-')
                            && part
                                .bytes()
                                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'-')
                    }) => {}
            None if !self.permissions.contains(&PluginPermission::Network) => {}
            _ => return Err(PluginError::InvalidManifest),
        }
        Ok(())
    }

    pub(crate) fn defaults(&self) -> PluginConfiguration {
        PluginConfiguration {
            values: self
                .settings
                .iter()
                .filter_map(|(key, field)| {
                    field
                        .default
                        .as_ref()
                        .map(|value| (key.clone(), value.clone()))
                })
                .collect(),
            flags: self.flags.iter().map(|key| (key.clone(), false)).collect(),
        }
    }

    pub(crate) fn validate_configuration(
        &self,
        configuration: &PluginConfiguration,
        enabling: bool,
    ) -> Result<(), PluginError> {
        if configuration
            .values
            .iter()
            .any(|(key, value)| !self.settings.contains_key(key) || value.len() > 4096)
            || configuration
                .flags
                .keys()
                .any(|key| !self.flags.contains(key))
            || (enabling
                && self.settings.iter().any(|(key, field)| {
                    field.required
                        && configuration
                            .values
                            .get(key)
                            .is_none_or(|value| value.trim().is_empty())
                }))
        {
            return Err(PluginError::InvalidConfiguration);
        }
        Ok(())
    }
}
