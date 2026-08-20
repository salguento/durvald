//! Secure storage module - adapted to work without Tauri AppHandle

#[cfg(not(target_os = "macos"))]
use base64::{Engine, engine::general_purpose::STANDARD as BASE64};
#[cfg(target_os = "macos")]
use keyring::Entry;
use once_cell::sync::Lazy;
#[cfg(not(target_os = "macos"))]
use ring::{
    aead::{self, Aad, LessSafeKey, Nonce, UnboundKey},
    digest, rand,
};
use serde_json::Value;
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use thiserror::Error;

#[derive(Error, Debug)]
pub enum SecureStoreError {
    #[error("Keyring error: {0}")]
    Keyring(#[from] keyring::Error),
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
    #[error("JSON error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("Base64 error: {0}")]
    Base64(#[from] base64::DecodeError),
    #[error("Ring error: {0}")]
    Ring(String),
    #[error("UTF-8 error: {0}")]
    Utf8(#[from] std::string::FromUtf8Error),
    #[error("{0}")]
    Custom(String),
}

pub type SecureStoreResult<T> = Result<T, SecureStoreError>;

/// Production-grade secure storage using OS keychain for secrets (macOS only),
/// and AES-256-GCM encrypted filesystem storage for Windows and Linux.
#[derive(Clone)]
pub struct SecureStore {
    /// Path for non-sensitive data (API key, username)
    data_path: PathBuf,

    /// Keychain service name — only used on macOS
    #[cfg_attr(not(target_os = "macos"), allow(dead_code))]
    keychain_service: String,

    /// In-memory cache of non-sensitive data
    data: Arc<Mutex<HashMap<String, Value>>>,
}

impl SecureStore {
    pub fn new(data_dir: PathBuf, keychain_service: String) -> SecureStoreResult<Self> {
        fs::create_dir_all(&data_dir)?;
        let data_path = data_dir.join("lastfm_data.json");

        let data = if data_path.exists() {
            Self::load_data(&data_path)?
        } else {
            HashMap::new()
        };

        Ok(Self {
            data_path,
            keychain_service,
            data: Arc::new(Mutex::new(data)),
        })
    }

    fn load_data(path: &PathBuf) -> SecureStoreResult<HashMap<String, Value>> {
        let contents = fs::read_to_string(path)?;
        let data = serde_json::from_str(&contents)?;
        Ok(data)
    }

    pub fn save_data(&self) -> SecureStoreResult<()> {
        let data = self.data.lock().unwrap();
        let contents = serde_json::to_string(&*data)?;
        fs::write(&self.data_path, contents)?;
        Ok(())
    }

    // ===== SECRETS =====
    // macOS  → OS Keychain via keyring crate (always reliable)
    // Windows → AES-256-GCM encrypted file, key derived from USERNAME|COMPUTERNAME
    // Linux   → AES-256-GCM encrypted file, key derived from /etc/machine-id|USER

    pub fn set_secret(&self, name: &str, value: &str) -> SecureStoreResult<()> {
        #[cfg(target_os = "macos")]
        {
            let entry = Entry::new(&self.keychain_service, name)?;
            entry.set_password(value)?;
            Ok(())
        }

        #[cfg(not(target_os = "macos"))]
        {
            self.write_encrypted_secret(name, value)?;
            Ok(())
        }
    }

    pub fn get_secret(&self, name: &str) -> SecureStoreResult<String> {
        #[cfg(target_os = "macos")]
        {
            let entry = Entry::new(&self.keychain_service, name)?;
            let password = entry.get_password()?;
            Ok(password)
        }

        #[cfg(not(target_os = "macos"))]
        {
            self.read_encrypted_secret(name)
        }
    }

    pub fn delete_secret(&self, name: &str) -> SecureStoreResult<()> {
        #[cfg(target_os = "macos")]
        {
            let entry = keyring::Entry::new(&self.keychain_service, name)?;
            entry.delete_credential()?;
            Ok(())
        }

        #[cfg(not(target_os = "macos"))]
        {
            let path = self.secret_path(name)?;
            if path.exists() {
                fs::remove_file(&path)?;
            }
            Ok(())
        }
    }

    // ===== ENCRYPTED FILE HELPERS (Windows + Linux) =====

    #[cfg(not(target_os = "macos"))]
    fn machine_key(&self) -> SecureStoreResult<[u8; 32]> {
        #[cfg(windows)]
        let machine_id = format!(
            "{}|{}",
            std::env::var("USERNAME").unwrap_or_default(),
            std::env::var("COMPUTERNAME").unwrap_or_default()
        );

        #[cfg(target_os = "linux")]
        let machine_id = {
            // /etc/machine-id is a stable UUID present on all systemd-based distros.
            // Fall back to /var/lib/dbus/machine-id on older systems.
            let mid = fs::read_to_string("/etc/machine-id")
                .or_else(|_| fs::read_to_string("/var/lib/dbus/machine-id"))
                .unwrap_or_default()
                .trim()
                .to_string();
            let user = std::env::var("USER").unwrap_or_default();
            format!("{}|{}", mid, user)
        };

        let mut ctx = digest::Context::new(&digest::SHA256);
        ctx.update(machine_id.as_bytes());
        let digest = ctx.finish();
        digest
            .as_ref()
            .try_into()
            .map_err(|_| SecureStoreError::Custom("Key derivation failed".to_string()))
    }

    #[cfg(not(target_os = "macos"))]
    fn secret_path(&self, name: &str) -> SecureStoreResult<PathBuf> {
        let dir = self.data_path.parent().ok_or_else(|| {
            SecureStoreError::Custom("No parent directory for data_path".to_string())
        })?;
        fs::create_dir_all(dir)?;
        Ok(dir.join(format!("secret_{}.enc", name)))
    }

    #[cfg(not(target_os = "macos"))]
    fn write_encrypted_secret(&self, name: &str, value: &str) -> SecureStoreResult<()> {
        let key_bytes = self.machine_key()?;

        let rng = rand::SystemRandom::new();
        let nonce: [u8; 12] = rand::generate(&rng)
            .map_err(|_| SecureStoreError::Ring("RNG failed".to_string()))?
            .expose();

        let sealing_key = LessSafeKey::new(
            UnboundKey::new(&aead::AES_256_GCM, &key_bytes)
                .map_err(|_| SecureStoreError::Ring("Key setup failed".to_string()))?,
        );

        let mut in_out = value.as_bytes().to_vec();
        sealing_key
            .seal_in_place_append_tag(
                Nonce::try_assume_unique_for_key(&nonce)
                    .map_err(|_| SecureStoreError::Ring("Nonce creation failed".to_string()))?,
                Aad::empty(),
                &mut in_out,
            )
            .map_err(|_| SecureStoreError::Ring("Encryption failed".to_string()))?;

        // Layout: [nonce (12 bytes)][ciphertext + GCM tag]
        let mut final_buf = nonce.to_vec();
        final_buf.extend_from_slice(&in_out);

        let path = self.secret_path(name)?;
        fs::write(&path, BASE64.encode(&final_buf))?;

        Ok(())
    }

    #[cfg(not(target_os = "macos"))]
    fn read_encrypted_secret(&self, name: &str) -> SecureStoreResult<String> {
        let key_bytes = self.machine_key()?;
        let path = self.secret_path(name)?;

        if !path.exists() {
            return Err(SecureStoreError::Custom("Not found".to_string()));
        }

        let raw = fs::read(&path)?;
        let decoded = BASE64.decode(&raw)?;

        if decoded.len() < 12 {
            return Err(SecureStoreError::Custom(
                "Invalid ciphertext length".to_string(),
            ));
        }

        let nonce: [u8; 12] = decoded[..12]
            .try_into()
            .map_err(|_| SecureStoreError::Custom("Invalid nonce length".to_string()))?;

        let opening_key = LessSafeKey::new(
            UnboundKey::new(&aead::AES_256_GCM, &key_bytes)
                .map_err(|_| SecureStoreError::Ring("Key setup failed".to_string()))?,
        );

        let mut buf = decoded[12..].to_vec();
        let plaintext = opening_key
            .open_in_place(
                Nonce::try_assume_unique_for_key(&nonce)
                    .map_err(|_| SecureStoreError::Ring("Invalid nonce".to_string()))?,
                Aad::empty(),
                &mut buf,
            )
            .map_err(|_| {
                SecureStoreError::Ring(
                    "Decryption failed (wrong machine or corrupted data)".to_string(),
                )
            })?;

        String::from_utf8(plaintext.to_vec()).map_err(SecureStoreError::from)
    }

    // ===== NON-SECRET DATA (FILESYSTEM) =====

    pub fn get(&self, key: &str) -> Option<Value> {
        self.data.lock().unwrap().get(key).cloned()
    }

    pub fn set(&self, key: String, value: Value) {
        self.data.lock().unwrap().insert(key, value);
    }

    pub fn delete(&self, key: &str) {
        self.data.lock().unwrap().remove(key);
    }
}

/// Global store instance (initialized once during app setup)
pub static SECURE_STORE: Lazy<Mutex<Option<SecureStore>>> = Lazy::new(|| Mutex::new(None));

pub fn init_secure_store(data_dir: PathBuf, keychain_service: String) -> SecureStoreResult<()> {
    let mut store = SECURE_STORE.lock().unwrap();
    *store = Some(SecureStore::new(data_dir, keychain_service)?);
    Ok(())
}

pub fn get_secure_store() -> SecureStoreResult<SecureStore> {
    let store = SECURE_STORE.lock().unwrap();
    store
        .as_ref()
        .cloned()
        .ok_or_else(|| SecureStoreError::Custom("Store not initialized".to_string()))
}
