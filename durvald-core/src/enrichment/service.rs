//! Explicit, bounded identity lookups; no permanent worker or audio state.

use crate::api::*;
use crate::database::enrichment;
use crate::enrichment::policy::{normalize_language, normalized_settings};
use std::sync::Arc;

type LookupResult = CoreResult<ArtistIdentityCandidates>;
struct IdentityFlight {
    receiver: tokio::sync::watch::Receiver<Option<LookupResult>>,
    abort: tokio::task::AbortHandle,
}
impl Drop for IdentityFlight {
    fn drop(&mut self) {
        self.abort.abort();
    }
}

#[derive(Clone)]
pub struct EnrichmentService {
    flights: Arc<std::sync::Mutex<std::collections::HashMap<i64, std::sync::Weak<IdentityFlight>>>>,
    musicbrainz: Arc<
        std::sync::OnceLock<
            Result<super::providers::musicbrainz::MusicBrainz, super::transport::TransportError>,
        >,
    >,
    pool: Arc<r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>>,
}

impl EnrichmentService {
    pub fn new(pool: Arc<r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>>) -> Self {
        Self {
            pool,
            musicbrainz: Arc::new(std::sync::OnceLock::new()),
            flights: Arc::default(),
        }
    }

    async fn database<T, F>(&self, operation: F) -> CoreResult<T>
    where
        T: Send + 'static,
        F: FnOnce(&rusqlite::Connection) -> CoreResult<T> + Send + 'static,
    {
        let pool = self.pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = pool.get().map_err(|error| CoreError::Storage {
                message: error.to_string(),
            })?;
            operation(&conn)
        })
        .await
        .map_err(|error| CoreError::Storage {
            message: format!("Enrichment database task failed: {error}"),
        })?
    }

    pub async fn artist_identity(&self, artist_id: i64) -> CoreResult<ArtistIdentity> {
        self.database(move |conn| crate::database::identity::read(conn, artist_id))
            .await
    }

    pub async fn confirm_artist_identity(
        &self,
        artist_id: i64,
        mbid: Option<String>,
    ) -> CoreResult<ArtistIdentity> {
        self.database(move |conn| crate::database::identity::confirm(conn, artist_id, mbid))
            .await
    }

    /// Subscribers share a bounded task. The last subscriber dropping aborts it.
    pub async fn resolve_artist_candidates(&self, artist_id: i64) -> LookupResult {
        let flight = {
            let mut flights = self.flights.lock().map_err(|_| CoreError::Storage {
                message: "Identity coordinator unavailable".into(),
            })?;
            flights.retain(|_, flight| flight.strong_count() > 0);
            if let Some(flight) = flights.get(&artist_id).and_then(std::sync::Weak::upgrade) {
                flight
            } else {
                let (sender, receiver) = tokio::sync::watch::channel(None);
                let service = self.clone();
                let task = tokio::spawn(async move {
                    let result = service.resolve_identity_once(artist_id).await;
                    let _ = sender.send(Some(result));
                });
                let flight = Arc::new(IdentityFlight {
                    receiver,
                    abort: task.abort_handle(),
                });
                flights.insert(artist_id, Arc::downgrade(&flight));
                flight
            }
        };
        let mut receiver = flight.receiver.clone();
        loop {
            if let Some(result) = receiver.borrow_and_update().clone() {
                return result;
            }
            receiver.changed().await.map_err(|_| CoreError::Network {
                message: "Identity lookup interrupted".into(),
            })?;
        }
    }

    async fn resolve_identity_once(&self, artist_id: i64) -> CoreResult<ArtistIdentityCandidates> {
        use super::transport::TransportError;
        use crate::database::identity;
        let mut result = self
            .database(move |conn| identity::candidates(conn, artist_id))
            .await?;
        let settings = self.settings().await?;
        if !settings.enabled || settings.offline {
            result.lookup_status = if settings.offline {
                ArtistIdentityLookupStatus::Offline
            } else {
                ArtistIdentityLookupStatus::Disabled
            };
            return Ok(result);
        }
        if result.identity.status == ArtistIdentityStatus::Resolved
            || result.identity.conflicting_tags
        {
            return Ok(result);
        }
        let generation = result.identity.generation;
        let (name, releases) = self
            .database(move |conn| identity::local_context(conn, artist_id))
            .await?;
        let provider = self
            .musicbrainz
            .get_or_init(super::providers::musicbrainz::MusicBrainz::new)
            .as_ref()
            .map_err(|e| CoreError::Network {
                message: e.to_string(),
            })?;
        let response = tokio::time::timeout(
            std::time::Duration::from_secs(30),
            provider.search(&name, &releases),
        )
        .await
        .unwrap_or(Err(TransportError::Timeout));
        match response {
            Ok((candidates, truncated)) => {
                let stored = self
                    .database(move |conn| {
                        identity::store_candidates(
                            conn,
                            artist_id,
                            generation,
                            &candidates,
                            truncated,
                        )
                    })
                    .await?;
                result = self
                    .database(move |conn| identity::candidates(conn, artist_id))
                    .await?;
                if !stored {
                    result.lookup_status = ArtistIdentityLookupStatus::Superseded;
                }
            }
            Err(error) => {
                result = self
                    .database(move |conn| identity::candidates(conn, artist_id))
                    .await?;
                result.lookup_status = ArtistIdentityLookupStatus::Unavailable;
                match error {
                    TransportError::RateLimited {
                        retry_after_seconds,
                    } => {
                        result.lookup_status = ArtistIdentityLookupStatus::RateLimited;
                        result.retry_after_seconds = Some(retry_after_seconds);
                    }
                    TransportError::HttpStatus {
                        retry_after_seconds,
                        ..
                    } => result.retry_after_seconds = retry_after_seconds,
                    _ => {}
                }
            }
        }
        Ok(result)
    }

    pub async fn settings(&self) -> CoreResult<EnrichmentSettings> {
        self.database(enrichment::read_settings).await
    }

    pub async fn configure(&self, settings: EnrichmentSettings) -> CoreResult<()> {
        let settings = normalized_settings(settings)?;
        self.database(move |conn| enrichment::write_settings(conn, settings))
            .await
    }

    pub async fn artist_details(
        &self,
        artist_id: i64,
        language: String,
    ) -> CoreResult<ArtistDetails> {
        if artist_id < 0 {
            return Err(CoreError::InvalidInput {
                message: "Artist ID must be non-negative".into(),
            });
        }
        let language = normalize_language(&language)?;
        self.database(move |conn| {
            enrichment::read_artist_details(
                conn,
                artist_id,
                &language,
                chrono::Utc::now().timestamp(),
            )
        })
        .await
    }
}

#[cfg(test)]
mod tests {
    use super::super::{providers::musicbrainz::MusicBrainz, transport::EnrichmentHttpClient};
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    fn service() -> EnrichmentService {
        let manager = r2d2_sqlite::SqliteConnectionManager::memory().with_init(|conn| {
            conn.execute_batch("PRAGMA foreign_keys = ON")?;
            crate::database::operations::create_tables(conn)
                .map_err(|_| rusqlite::Error::InvalidQuery)?;
            crate::database::migrations::migrate_enrichment(conn)?;
            conn.execute(
                "INSERT INTO artists(artist_id, name) VALUES (1, 'Same Name')",
                [],
            )?;
            Ok(())
        });
        EnrichmentService::new(Arc::new(
            r2d2::Pool::builder().max_size(1).build(manager).unwrap(),
        ))
    }

    /// Real loopback HTTP plus SQLite: gates hold no database connection, and
    /// subscribers can cancel independently while a manual correction wins.
    #[tokio::test]
    async fn shared_http_releases_database_and_discards_response_after_confirmation() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}/", listener.local_addr().unwrap());
        let (started_tx, started_rx) = tokio::sync::oneshot::channel();
        let (release_tx, release_rx) = tokio::sync::oneshot::channel();
        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = vec![0; 8192];
            let count = socket.read(&mut request).await.unwrap();
            let request = String::from_utf8_lossy(&request[..count]);
            assert!(request.starts_with("GET /ws/2/artist/"));
            assert!(request.contains("query=artist%3A%22Same+Name%22"));
            started_tx.send(()).unwrap();
            release_rx.await.unwrap();
            let body = include_str!("../../tests/fixtures/musicbrainz-homonyms.json");
            socket.write_all(format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).as_bytes()).await.unwrap();
        });
        let service = service();
        assert!(
            service
                .musicbrainz
                .set(Ok(MusicBrainz {
                    http: EnrichmentHttpClient::local_test_client(&base)
                }))
                .is_ok()
        );
        service
            .configure(EnrichmentSettings {
                enabled: true,
                offline: false,
                preferred_language: "pt".into(),
            })
            .await
            .unwrap();
        let first_service = service.clone();
        let first = tokio::spawn(async move { first_service.resolve_artist_candidates(1).await });
        started_rx.await.unwrap();
        let second_service = service.clone();
        let second = tokio::spawn(async move { second_service.resolve_artist_candidates(1).await });
        // Wait until the second subscriber has joined the same flight.
        tokio::time::timeout(std::time::Duration::from_secs(2), async {
            loop {
                if service
                    .flights
                    .lock()
                    .unwrap()
                    .get(&1)
                    .unwrap()
                    .strong_count()
                    == 2
                {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        first.abort();
        let confirmed = tokio::time::timeout(
            std::time::Duration::from_secs(2),
            service.confirm_artist_identity(1, Some("33333333-3333-4333-8333-333333333333".into())),
        )
        .await
        .unwrap()
        .unwrap();
        release_tx.send(()).unwrap();
        let result = second.await.unwrap().unwrap();
        assert_eq!(result.identity, confirmed);
        assert_eq!(result.lookup_status, ArtistIdentityLookupStatus::Superseded);
        assert!(result.candidates.is_empty());
        server.await.unwrap();
    }

    #[tokio::test]
    async fn disabled_and_offline_do_not_construct_http_clients() {
        let service = service();
        assert_eq!(
            service
                .resolve_artist_candidates(1)
                .await
                .unwrap()
                .lookup_status,
            ArtistIdentityLookupStatus::Disabled
        );
        service
            .configure(EnrichmentSettings {
                enabled: true,
                offline: true,
                preferred_language: "pt".into(),
            })
            .await
            .unwrap();
        assert_eq!(
            service
                .resolve_artist_candidates(1)
                .await
                .unwrap()
                .lookup_status,
            ArtistIdentityLookupStatus::Offline
        );
        assert!(service.musicbrainz.get().is_none());
    }
}
