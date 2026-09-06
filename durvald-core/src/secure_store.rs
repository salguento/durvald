//! Secure storage module backed by the platform credential service on macOS,
//! Windows, and Linux. The encrypted filesystem format is retained only to
//! migrate credentials written by older releases.

use base64::{Engine, engine::general_purpose::STANDARD as BASE64};
#[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
use keyring::Entry;
use once_cell::sync::Lazy;
use ring::{
    aead::{self, Aad, LessSafeKey, Nonce, UnboundKey},
    digest,
    rand::{self, SecureRandom},
};
use serde_json::Value;
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use thiserror::Error;

static TEMP_FILE_COUNTER: AtomicU64 = AtomicU64::new(0);

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
    #[error("Secure store mutex is poisoned: {0}")]
    MutexPoisoned(&'static str),
    #[error("{0}")]
    Custom(String),
}

pub type SecureStoreResult<T> = Result<T, SecureStoreError>;

#[cfg(unix)]
fn create_secure_dir(path: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::DirBuilderExt;
    use std::os::unix::fs::PermissionsExt;

    let mut builder = std::fs::DirBuilder::new();
    builder.recursive(true);
    builder.mode(0o700);
    builder.create(path)?;

    let meta = std::fs::metadata(path)?;
    let mut perms = meta.permissions();
    if perms.mode() & 0o777 != 0o700 {
        perms.set_mode(0o700);
        std::fs::set_permissions(path, perms)?;
    }
    Ok(())
}

#[cfg(not(unix))]
fn create_secure_dir(path: &Path) -> std::io::Result<()> {
    fs::create_dir_all(path)
}

#[cfg(unix)]
fn write_secure_file(path: &Path, data: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    use std::os::unix::fs::PermissionsExt;

    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("data");
    let temp_path = path.with_file_name(format!(
        ".{file_name}.tmp-{}-{}",
        std::process::id(),
        TEMP_FILE_COUNTER.fetch_add(1, Ordering::Relaxed)
    ));
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temp_path)?;
    let write_result = (|| {
        file.write_all(data)?;
        file.sync_all()?;
        let meta = file.metadata()?;
        let mut perms = meta.permissions();
        if perms.mode() & 0o777 != 0o600 {
            perms.set_mode(0o600);
            std::fs::set_permissions(&temp_path, perms)?;
        }
        std::fs::rename(&temp_path, path)
    })();
    write_result.inspect_err(|_| {
        let _ = std::fs::remove_file(&temp_path);
    })?;
    Ok(())
}

#[cfg(not(unix))]
fn write_secure_file(path: &Path, data: &[u8]) -> std::io::Result<()> {
    fs::write(path, data)
}

/// Production-grade secure storage using the OS credential service. On Linux,
/// keyring is backed by the freedesktop Secret Service over D-Bus.
#[derive(Clone)]
pub struct SecureStore {
    /// Path for non-sensitive data (API key, username)
    data_path: PathBuf,

    /// Credential service name used by every supported desktop platform.
    #[cfg_attr(
        not(any(target_os = "macos", target_os = "windows", target_os = "linux")),
        allow(dead_code)
    )]
    keychain_service: String,

    /// In-memory cache of non-sensitive data
    data: Arc<Mutex<HashMap<String, Value>>>,
}

impl SecureStore {
    pub fn new(data_dir: PathBuf, keychain_service: String) -> SecureStoreResult<Self> {
        create_secure_dir(&data_dir)?;
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

    fn lock_data(&self) -> SecureStoreResult<MutexGuard<'_, HashMap<String, Value>>> {
        self.data
            .lock()
            .map_err(|_| SecureStoreError::MutexPoisoned("non-secret data"))
    }

    pub fn save_data(&self) -> SecureStoreResult<()> {
        let contents = {
            let data = self.lock_data()?;
            serde_json::to_string(&*data)?
        };
        write_secure_file(&self.data_path, contents.as_bytes())?;
        Ok(())
    }

    // ===== SECRETS =====
    // macOS   → Apple Keychain
    // Windows → Windows Credential Manager
    // Linux   → freedesktop Secret Service
    // Other targets retain the encrypted-file implementation as a compatibility fallback.

    pub fn set_secret(&self, name: &str, value: &str) -> SecureStoreResult<()> {
        #[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
        {
            let entry = Entry::new(&self.keychain_service, name)?;
            entry.set_password(value)?;
            self.delete_encrypted_secret_file(name)?;
            self.delete_legacy_master_key_if_unused()?;
            Ok(())
        }

        #[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
        {
            self.write_encrypted_secret(name, value)
        }
    }

    pub fn get_secret(&self, name: &str) -> SecureStoreResult<String> {
        #[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
        {
            let entry = Entry::new(&self.keychain_service, name)?;
            match entry.get_password() {
                Ok(password) => Ok(password),
                Err(keyring::Error::NoEntry) => {
                    // Migration check: if a file-based secret exists from prior versions, migrate it
                    if let Ok(legacy_secret) = self.read_encrypted_secret(name) {
                        entry.set_password(&legacy_secret)?;
                        self.delete_encrypted_secret_file(name)?;
                        self.delete_legacy_master_key_if_unused()?;
                        return Ok(legacy_secret);
                    }
                    Err(SecureStoreError::Custom("Not found".to_string()))
                }
                Err(e) => Err(SecureStoreError::Keyring(e)),
            }
        }

        #[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
        {
            self.read_encrypted_secret(name)
        }
    }

    pub fn delete_secret(&self, name: &str) -> SecureStoreResult<()> {
        #[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
        {
            let entry = Entry::new(&self.keychain_service, name)?;
            match entry.delete_credential() {
                Ok(()) | Err(keyring::Error::NoEntry) => {}
                Err(error) => return Err(SecureStoreError::Keyring(error)),
            }
            self.delete_encrypted_secret_file(name)?;
            self.delete_legacy_master_key_if_unused()?;
            Ok(())
        }

        #[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
        {
            self.delete_encrypted_secret_file(name)
        }
    }

    // ===== ENCRYPTED FILE HELPERS =====

    fn secrets_dir(&self) -> SecureStoreResult<PathBuf> {
        let parent = self.data_path.parent().ok_or_else(|| {
            SecureStoreError::Custom("No parent directory for data_path".to_string())
        })?;
        let dir = parent.join(".secrets");
        create_secure_dir(&dir)?;
        Ok(dir)
    }

    fn secret_path(&self, name: &str) -> SecureStoreResult<PathBuf> {
        let dir = self.secrets_dir()?;
        Ok(dir.join(format!("secret_{name}.enc")))
    }

    fn legacy_secret_path(&self, name: &str) -> SecureStoreResult<PathBuf> {
        let parent = self.data_path.parent().ok_or_else(|| {
            SecureStoreError::Custom("No parent directory for data_path".to_string())
        })?;
        Ok(parent.join(format!("secret_{name}.enc")))
    }

    fn master_key(&self) -> SecureStoreResult<[u8; 32]> {
        let secrets_dir = self.secrets_dir()?;
        let key_path = secrets_dir.join("master.key");

        if key_path.exists() {
            let encoded = fs::read_to_string(&key_path)?;
            let key_bytes = BASE64.decode(encoded.trim())?;
            let key: [u8; 32] = key_bytes.try_into().map_err(|_| {
                SecureStoreError::Custom("Invalid master key length in store".to_string())
            })?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let meta = fs::metadata(&key_path)?;
                if meta.permissions().mode() & 0o777 != 0o600 {
                    fs::set_permissions(&key_path, fs::Permissions::from_mode(0o600))?;
                }
            }
            return Ok(key);
        }

        // Generate a new 256-bit random master key using system CSPRNG
        let rng = rand::SystemRandom::new();
        let mut key = [0u8; 32];
        rng.fill(&mut key).map_err(|_| {
            SecureStoreError::Ring("RNG failed during master key generation".to_string())
        })?;

        let encoded = BASE64.encode(key);
        let temp_path = secrets_dir.join(format!(
            ".master.key.tmp-{}-{}",
            std::process::id(),
            TEMP_FILE_COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        write_secure_file(&temp_path, encoded.as_bytes())?;

        // A hard link publishes a fully-written key only if no other process won the race.
        let published = match fs::hard_link(&temp_path, &key_path) {
            Ok(()) => true,
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => false,
            Err(error) => {
                let _ = fs::remove_file(&temp_path);
                return Err(error.into());
            }
        };
        fs::remove_file(&temp_path)?;
        if published {
            Ok(key)
        } else {
            let encoded = fs::read_to_string(&key_path)?;
            let bytes = BASE64.decode(encoded.trim())?;
            bytes.try_into().map_err(|_| {
                SecureStoreError::Custom("Invalid master key length in store".to_string())
            })
        }
    }

    /// Removes the old file-based master key only after every ciphertext that
    /// depends on it has been migrated or deleted.
    fn delete_legacy_master_key_if_unused(&self) -> SecureStoreResult<()> {
        let secrets_dir = self.secrets_dir()?;
        let has_encrypted_secrets = fs::read_dir(&secrets_dir)?.try_fold(
            false,
            |found, entry| -> std::io::Result<bool> {
                if found {
                    return Ok(true);
                }
                let path = entry?.path();
                Ok(path.extension().and_then(|extension| extension.to_str()) == Some("enc"))
            },
        )?;
        if !has_encrypted_secrets {
            let key_path = secrets_dir.join("master.key");
            match fs::remove_file(key_path) {
                Ok(()) => {}
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => return Err(error.into()),
            }
        }
        Ok(())
    }

    fn legacy_machine_key(&self) -> SecureStoreResult<[u8; 32]> {
        #[cfg(windows)]
        let machine_id = format!(
            "{}|{}",
            std::env::var("USERNAME").unwrap_or_default(),
            std::env::var("COMPUTERNAME").unwrap_or_default()
        );

        #[cfg(not(windows))]
        let machine_id = {
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
            .map_err(|_| SecureStoreError::Custom("Legacy key derivation failed".to_string()))
    }

    pub(crate) fn write_encrypted_secret(&self, name: &str, value: &str) -> SecureStoreResult<()> {
        let key_bytes = self.master_key()?;

        let rng = rand::SystemRandom::new();
        let mut nonce = [0u8; 12];
        rng.fill(&mut nonce).map_err(|_| {
            SecureStoreError::Ring("RNG failed during nonce generation".to_string())
        })?;

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

        let mut final_buf = nonce.to_vec();
        final_buf.extend_from_slice(&in_out);

        let path = self.secret_path(name)?;
        write_secure_file(&path, BASE64.encode(&final_buf).as_bytes())?;

        // If a legacy unhardened secret file existed at the parent path, remove it
        if let Ok(legacy_path) = self.legacy_secret_path(name) {
            if legacy_path.exists() && legacy_path != path {
                fs::remove_file(&legacy_path)?;
            }
        }

        Ok(())
    }

    pub(crate) fn read_encrypted_secret(&self, name: &str) -> SecureStoreResult<String> {
        let primary_path = self.secret_path(name)?;
        let legacy_path = self.legacy_secret_path(name)?;

        let (path, is_legacy) = if primary_path.exists() {
            (primary_path, false)
        } else if legacy_path.exists() {
            (legacy_path, true)
        } else {
            return Err(SecureStoreError::Custom("Not found".to_string()));
        };

        let raw = fs::read_to_string(&path)?;
        let decoded = BASE64.decode(raw.trim())?;

        if decoded.len() < 12 + 16 {
            return Err(SecureStoreError::Custom(
                "Invalid ciphertext length".to_string(),
            ));
        }

        let nonce: [u8; 12] = decoded[..12]
            .try_into()
            .map_err(|_| SecureStoreError::Custom("Invalid nonce length".to_string()))?;

        // 1. Try decrypting with secure master key
        if let Ok(key_bytes) = self.master_key() {
            if let Ok(opening_key) =
                UnboundKey::new(&aead::AES_256_GCM, &key_bytes).map(LessSafeKey::new)
            {
                let mut buf = decoded[12..].to_vec();
                if let Ok(plaintext) = opening_key.open_in_place(
                    Nonce::try_assume_unique_for_key(&nonce)
                        .map_err(|_| SecureStoreError::Ring("Invalid nonce".to_string()))?,
                    Aad::empty(),
                    &mut buf,
                ) {
                    let result = String::from_utf8(plaintext.to_vec())?;
                    // If read from the legacy location, migrate to the secure directory
                    if is_legacy {
                        self.write_encrypted_secret(name, &result)?;
                    }
                    return Ok(result);
                }
            }
        }

        // 2. Legacy fallback migration: decrypt with legacy machine-id key
        if let Ok(legacy_key) = self.legacy_machine_key() {
            if let Ok(opening_key) =
                UnboundKey::new(&aead::AES_256_GCM, &legacy_key).map(LessSafeKey::new)
            {
                let mut buf = decoded[12..].to_vec();
                if let Ok(plaintext) = opening_key.open_in_place(
                    Nonce::try_assume_unique_for_key(&nonce)
                        .map_err(|_| SecureStoreError::Ring("Invalid nonce".to_string()))?,
                    Aad::empty(),
                    &mut buf,
                ) {
                    let result = String::from_utf8(plaintext.to_vec())?;
                    // Automatically re-encrypt with the new master key and hardened permissions
                    self.write_encrypted_secret(name, &result)?;
                    return Ok(result);
                }
            }
        }

        Err(SecureStoreError::Ring(
            "Decryption failed (corrupted data or invalid key)".to_string(),
        ))
    }

    pub(crate) fn delete_encrypted_secret_file(&self, name: &str) -> SecureStoreResult<()> {
        let path = self.secret_path(name)?;
        if path.exists() {
            fs::remove_file(&path)?;
        }
        let legacy_path = self.legacy_secret_path(name)?;
        if legacy_path.exists() {
            fs::remove_file(&legacy_path)?;
        }
        Ok(())
    }

    // ===== NON-SECRET DATA (FILESYSTEM) =====

    pub fn get(&self, key: &str) -> SecureStoreResult<Option<Value>> {
        Ok(self.lock_data()?.get(key).cloned())
    }

    pub fn set(&self, key: String, value: Value) -> SecureStoreResult<()> {
        self.lock_data()?.insert(key, value);
        Ok(())
    }

    pub fn delete(&self, key: &str) -> SecureStoreResult<()> {
        self.lock_data()?.remove(key);
        Ok(())
    }
}

/// Global store instance (initialized once during app setup)
pub static SECURE_STORE: Lazy<Mutex<Option<SecureStore>>> = Lazy::new(|| Mutex::new(None));

pub fn init_secure_store(data_dir: PathBuf, keychain_service: String) -> SecureStoreResult<()> {
    let mut store = SECURE_STORE
        .lock()
        .map_err(|_| SecureStoreError::MutexPoisoned("global store"))?;
    *store = Some(SecureStore::new(data_dir, keychain_service)?);
    Ok(())
}

pub fn get_secure_store() -> SecureStoreResult<SecureStore> {
    let store = SECURE_STORE
        .lock()
        .map_err(|_| SecureStoreError::MutexPoisoned("global store"))?;
    store
        .as_ref()
        .cloned()
        .ok_or_else(|| SecureStoreError::Custom("Store not initialized".to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_store() -> (SecureStore, PathBuf) {
        let dir = std::env::temp_dir().join(format!(
            "durvald-secstore-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let store = SecureStore::new(dir.clone(), "durvald-test-service".to_string()).unwrap();
        (store, dir)
    }

    #[test]
    fn encrypted_secret_roundtrip() {
        let (store, dir) = test_store();
        store
            .write_encrypted_secret("api_token", "super_secret_123")
            .unwrap();
        let loaded = store.read_encrypted_secret("api_token").unwrap();
        assert_eq!(loaded, "super_secret_123");

        store.delete_encrypted_secret_file("api_token").unwrap();
        assert!(store.read_encrypted_secret("api_token").is_err());
        let _ = fs::remove_dir_all(dir);
    }

    #[cfg(unix)]
    #[test]
    fn secure_permissions_enforced_on_unix() {
        use std::os::unix::fs::PermissionsExt;

        let (store, dir) = test_store();
        store
            .write_encrypted_secret("token", "secret_value")
            .unwrap();

        let secrets_dir = store.secrets_dir().unwrap();
        let dir_mode = fs::metadata(&secrets_dir).unwrap().permissions().mode() & 0o777;
        assert_eq!(dir_mode, 0o700, "Secrets directory must be 0700");

        let key_file = secrets_dir.join("master.key");
        let key_mode = fs::metadata(&key_file).unwrap().permissions().mode() & 0o777;
        assert_eq!(key_mode, 0o600, "Master key file must be 0600");

        let secret_file = store.secret_path("token").unwrap();
        let secret_mode = fs::metadata(&secret_file).unwrap().permissions().mode() & 0o777;
        assert_eq!(secret_mode, 0o600, "Secret file must be 0600");

        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn tampered_ciphertext_fails_decryption() {
        let (store, dir) = test_store();
        store
            .write_encrypted_secret("tamper_test", "original_payload")
            .unwrap();
        let path = store.secret_path("tamper_test").unwrap();

        let mut data = BASE64
            .decode(fs::read_to_string(&path).unwrap().trim())
            .unwrap();
        // Tamper with the last byte (part of authentication tag)
        let last = data.len() - 1;
        data[last] ^= 0xFF;
        write_secure_file(&path, BASE64.encode(&data).as_bytes()).unwrap();

        let res = store.read_encrypted_secret("tamper_test");
        assert!(res.is_err(), "Tampered ciphertext must fail decryption");
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn concurrent_first_writes_share_one_master_key() {
        use std::sync::{Arc, Barrier};

        let (store, dir) = test_store();
        let barrier = Arc::new(Barrier::new(8));
        let handles: Vec<_> = (0..8)
            .map(|index| {
                let store = store.clone();
                let barrier = Arc::clone(&barrier);
                std::thread::spawn(move || {
                    barrier.wait();
                    let name = format!("concurrent_{index}");
                    let value = format!("secret_{index}");
                    store.write_encrypted_secret(&name, &value).unwrap();
                })
            })
            .collect();

        for handle in handles {
            handle.join().unwrap();
        }
        for index in 0..8 {
            assert_eq!(
                store
                    .read_encrypted_secret(&format!("concurrent_{index}"))
                    .unwrap(),
                format!("secret_{index}")
            );
        }
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn legacy_master_key_is_removed_only_after_the_last_ciphertext() {
        let (store, dir) = test_store();
        store.write_encrypted_secret("first", "secret-1").unwrap();
        store.write_encrypted_secret("second", "secret-2").unwrap();
        let key_path = store.secrets_dir().unwrap().join("master.key");
        assert!(key_path.exists());

        store.delete_encrypted_secret_file("first").unwrap();
        store.delete_legacy_master_key_if_unused().unwrap();
        assert!(key_path.exists());

        store.delete_encrypted_secret_file("second").unwrap();
        store.delete_legacy_master_key_if_unused().unwrap();
        assert!(!key_path.exists());
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn poisoned_data_mutex_returns_errors_instead_of_panicking() {
        let (store, dir) = test_store();
        let data = Arc::clone(&store.data);
        let poisoner = std::thread::spawn(move || {
            let _guard = data.lock().expect("lock test data");
            panic!("poison secure-store data mutex");
        });
        assert!(poisoner.join().is_err());

        assert!(matches!(
            store.get("api_key"),
            Err(SecureStoreError::MutexPoisoned("non-secret data"))
        ));
        assert!(matches!(
            store.set("api_key".into(), Value::String("key".into())),
            Err(SecureStoreError::MutexPoisoned("non-secret data"))
        ));
        assert!(matches!(
            store.delete("api_key"),
            Err(SecureStoreError::MutexPoisoned("non-secret data"))
        ));
        assert!(matches!(
            store.save_data(),
            Err(SecureStoreError::MutexPoisoned("non-secret data"))
        ));

        let _ = fs::remove_dir_all(dir);
    }

    #[cfg(unix)]
    #[test]
    fn existing_permissions_are_hardened() {
        use std::os::unix::fs::PermissionsExt;

        let (store, dir) = test_store();
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o755)).unwrap();
        let secrets_dir = store.secrets_dir().unwrap();
        fs::set_permissions(&secrets_dir, fs::Permissions::from_mode(0o755)).unwrap();

        store
            .write_encrypted_secret("permission_test", "secret")
            .unwrap();

        assert_eq!(
            fs::metadata(&dir).unwrap().permissions().mode() & 0o777,
            0o755
        );
        assert_eq!(
            fs::metadata(&secrets_dir).unwrap().permissions().mode() & 0o777,
            0o700
        );
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn legacy_secret_migrates_automatically() {
        let (store, dir) = test_store();
        let legacy_key = store.legacy_machine_key().unwrap();
        let legacy_path = store.legacy_secret_path("migrated_key").unwrap();

        // Encrypt with legacy key and place in legacy path
        let rng = rand::SystemRandom::new();
        let mut nonce = [0u8; 12];
        rng.fill(&mut nonce).unwrap();
        let sealing_key =
            LessSafeKey::new(UnboundKey::new(&aead::AES_256_GCM, &legacy_key).unwrap());
        let mut in_out = b"legacy_secret_value".to_vec();
        sealing_key
            .seal_in_place_append_tag(
                Nonce::try_assume_unique_for_key(&nonce).unwrap(),
                Aad::empty(),
                &mut in_out,
            )
            .unwrap();
        let mut final_buf = nonce.to_vec();
        final_buf.extend_from_slice(&in_out);
        fs::write(&legacy_path, BASE64.encode(&final_buf)).unwrap();

        assert!(legacy_path.exists());
        let read = store.read_encrypted_secret("migrated_key").unwrap();
        assert_eq!(read, "legacy_secret_value");

        // Verify that it migrated: primary path now exists, and legacy path is removed
        let primary_path = store.secret_path("migrated_key").unwrap();
        assert!(primary_path.exists());
        assert!(!legacy_path.exists());

        // And reading again succeeds using master key
        assert_eq!(
            store.read_encrypted_secret("migrated_key").unwrap(),
            "legacy_secret_value"
        );
        let _ = fs::remove_dir_all(dir);
    }
}
