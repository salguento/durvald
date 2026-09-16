//! Durable HTTP representations complement the domain snapshots in the library DB.
//! Context is scoped to one provider operation; request credentials and request URLs are never stored as keys.
use super::{models::CacheValidators, transport::TransportError};
use md5::{Digest, Md5};
use rusqlite::{OptionalExtension, params};
use std::path::PathBuf;

pub(crate) type RequestLocks =
    std::sync::Mutex<std::collections::HashMap<String, std::sync::Weak<tokio::sync::Mutex<()>>>>;
tokio::task_local! {
pub(crate) static CACHE_CONTEXT: (PathBuf, bool);
pub(crate) static REQUEST_LOCKS: std::sync::Arc<RequestLocks>;}
/// Same-library requests for one representation share a lock and recheck
/// freshness after acquiring it. Cancellation releases the lock automatically.
pub(crate) async fn request_lock(
    key: &str,
) -> Result<Option<tokio::sync::OwnedMutexGuard<()>>, TransportError> {
    let Ok(locks) = REQUEST_LOCKS.try_with(std::sync::Arc::clone) else {
        return Ok(None);
    };
    let lock = {
        let mut map = locks.lock().map_err(|_| TransportError::Storage {
            extended_code: None,
        })?;
        map.retain(|_, value| value.strong_count() > 0);
        if let Some(lock) = map.get(key).and_then(std::sync::Weak::upgrade) {
            lock
        } else {
            let lock = std::sync::Arc::new(tokio::sync::Mutex::new(()));
            map.insert(key.to_owned(), std::sync::Arc::downgrade(&lock));
            lock
        }
    };
    Ok(Some(lock.lock_owned().await))
}

#[derive(Clone, serde::Serialize, serde::Deserialize)]
pub(crate) struct Entry {
    pub body: Vec<u8>,
    pub validators: CacheValidators,
    pub expires_at: i64,
    #[serde(default)]
    pub failure: Option<TransportError>,
}
impl Entry {
    pub fn fresh(&self) -> bool {
        self.expires_at > chrono::Utc::now().timestamp()
    }
}
pub(crate) fn forced() -> bool {
    CACHE_CONTEXT.try_with(|(_, force)| *force).unwrap_or(false)
}
pub(crate) fn key(namespace: &str, resource: &str) -> String {
    format!("{namespace}:{:x}", Md5::digest(resource.as_bytes()))
}
async fn database<T: Send + 'static>(
    operation: impl FnOnce(&rusqlite::Connection) -> Result<T, rusqlite::Error> + Send + 'static,
) -> Result<Option<T>, TransportError> {
    let Ok(path) = CACHE_CONTEXT.try_with(|(path, _)| path.clone()) else {
        return Ok(None);
    };
    tokio::task::spawn_blocking(move || {
        if let Some(parent) = path.parent() { std::fs::create_dir_all(parent).map_err(|_| TransportError::Storage { extended_code: None })?; }
        let conn = rusqlite::Connection::open(path).map_err(storage)?;
        conn.busy_timeout(std::time::Duration::from_secs(2)).map_err(storage)?;
        conn.execute_batch("CREATE TABLE IF NOT EXISTS http_cache (key TEXT PRIMARY KEY, payload BLOB NOT NULL, updated_at INTEGER NOT NULL);").map_err(storage)?;
        operation(&conn).map(Some).map_err(storage)
    }).await.map_err(|_| TransportError::Storage { extended_code: None })?
}
fn storage(error: rusqlite::Error) -> TransportError {
    TransportError::Storage {
        extended_code: match error {
            rusqlite::Error::SqliteFailure(code, _) => Some(code.extended_code),
            _ => None,
        },
    }
}
pub(crate) async fn load(key: &str) -> Result<Option<Entry>, TransportError> {
    let key = key.to_owned();
    let value = database(move |conn| {
        conn.query_row(
            "SELECT payload FROM http_cache WHERE key=?1",
            [key],
            |row| row.get::<_, Vec<u8>>(0),
        )
        .optional()
    })
    .await?
    .flatten();
    // A corrupt representation is a cache miss; it cannot reach a provider parser.
    Ok(value.and_then(|bytes| serde_json::from_slice(&bytes).ok()))
}
pub(crate) async fn store(key: &str, entry: &Entry) -> Result<(), TransportError> {
    let key = key.to_owned();
    let payload = serde_json::to_vec(entry).map_err(|_| TransportError::InvalidJson)?;
    database(move |conn| {
        conn.execute("INSERT INTO http_cache VALUES (?1,?2,?3) ON CONFLICT(key) DO UPDATE SET payload=excluded.payload, updated_at=excluded.updated_at", params![key,payload,chrono::Utc::now().timestamp()])?;
        // Bound only replaceable HTTP representations. Published domain
        // snapshots and managed artwork remain available offline.
        conn.execute("DELETE FROM http_cache WHERE key IN (
            SELECT key FROM (SELECT key, SUM(length(payload)) OVER
              (ORDER BY updated_at DESC, key) AS retained_bytes,
              ROW_NUMBER() OVER (ORDER BY updated_at DESC, key) AS retained_rows
              FROM http_cache) WHERE retained_bytes > 268435456 OR retained_rows > 10000)", [])?;
        Ok(())
    }).await?;
    Ok(())
}
pub(crate) fn entry(body: Vec<u8>, validators: CacheValidators, ttl: std::time::Duration) -> Entry {
    Entry {
        body,
        validators,
        failure: None,
        expires_at: chrono::Utc::now()
            .timestamp()
            .saturating_add(ttl.as_secs() as i64),
    }
}

pub(crate) fn negative(error: TransportError, ttl: std::time::Duration) -> Entry {
    Entry {
        failure: Some(error),
        ..entry(Vec::new(), CacheValidators::default(), ttl)
    }
}
pub(crate) async fn cooldown(namespace: &str) -> Result<(), TransportError> {
    if let Some(entry) = load(&format!("cooldown:{namespace}"))
        .await?
        .filter(|entry| entry.fresh())
    {
        return Err(TransportError::RateLimited {
            retry_after_seconds: entry
                .expires_at
                .saturating_sub(chrono::Utc::now().timestamp())
                .max(1) as u64,
        });
    }
    Ok(())
}
pub(crate) async fn defer(namespace: &str, seconds: u64) -> Result<(), TransportError> {
    let key = format!("cooldown:{namespace}");
    let current = load(&key).await?;
    let mut value = entry(
        Vec::new(),
        CacheValidators::default(),
        std::time::Duration::from_secs(seconds.min(86400)),
    );
    if let Some(old) = current {
        value.expires_at = value.expires_at.max(old.expires_at);
    }
    store(&key, &value).await
}
pub(crate) async fn clear_provider(
    provider: crate::api::EnrichmentProvider,
    failures_only: bool,
) -> Result<(), TransportError> {
    use crate::api::EnrichmentProvider::*;
    let hosts: &[&str] = match provider {
        LastFm => &["lastfm"],
        MusicBrainz => &["musicbrainz.org"],
        Wikidata => &["www.wikidata.org"],
        Wikipedia => &[".wikipedia.org"],
        Commons => &["commons.wikimedia.org"],
        CoverArtArchive => &["coverartarchive.org"],
        TheAudioDb => &["www.theaudiodb.com"],
        YouTube => &["www.googleapis.com"],
    };
    let patterns: Vec<String> = hosts
        .iter()
        .map(|host| {
            if failures_only {
                format!("cooldown:%{host}%")
            } else {
                format!("%{host}%")
            }
        })
        .collect();
    database(move |conn| {
        for pattern in patterns {
            conn.execute("DELETE FROM http_cache WHERE key LIKE ?1", [pattern])?;
        }
        Ok(())
    })
    .await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn representations_survive_reopening_and_force_only_bypasses_freshness() {
        let path =
            std::env::temp_dir().join(format!("durvald-http-cache-{}.sqlite", std::process::id()));
        let _ = std::fs::remove_file(&path);
        let resource = key("lastfm", "Casey MQ");
        let value = entry(
            b"cached".to_vec(),
            CacheValidators {
                etag: Some("v1".into()),
                last_modified: None,
            },
            std::time::Duration::from_secs(60),
        );
        CACHE_CONTEXT
            .scope((path.clone(), false), async {
                store(&resource, &value).await.unwrap();
            })
            .await;
        CACHE_CONTEXT
            .scope((path.clone(), true), async {
                assert!(forced());
                let stored = load(&resource).await.unwrap().unwrap();
                assert_eq!(stored.body, b"cached");
                assert_eq!(stored.validators, value.validators);
                assert!(stored.fresh());
            })
            .await;
        std::fs::remove_file(path).unwrap();
    }
}
