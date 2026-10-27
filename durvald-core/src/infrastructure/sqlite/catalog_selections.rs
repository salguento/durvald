//! Explicit catalog bookmarks; discovery has no access to this write adapter.
use crate::api::*;
use rusqlite::{OptionalExtension, TransactionBehavior, params};
use std::sync::Arc;
type Pool = r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>;
pub(crate) struct SqliteCatalogSelections {
    pool: Arc<Pool>,
}
impl SqliteCatalogSelections {
    pub(crate) fn new(pool: Arc<Pool>) -> Self {
        Self { pool }
    }
    pub(crate) async fn get(
        &self,
        reference: CatalogReference,
    ) -> CoreResult<Option<CatalogSelection>> {
        let pool = self.pool.clone();
        tokio::task::spawn_blocking(move || {
            let c = pool.get().map_err(storage)?;
            get(&c, &reference)
        })
        .await
        .map_err(storage)?
    }
    pub(crate) async fn list(&self) -> CoreResult<Vec<CatalogSelection>> {
        let pool = self.pool.clone();
        tokio::task::spawn_blocking(move || {
            let c = pool.get().map_err(storage)?;
            let mut statement = c.prepare("SELECT payload,local_artist_id,saved_at FROM catalog_selections ORDER BY saved_at DESC,provider,entity_kind,external_id").map_err(storage)?;
            statement.query_map([], row).map_err(storage)?.map(|r| r.map_err(storage)).collect()
        }).await.map_err(storage)?
    }
    pub(crate) async fn save(&self, entry: CatalogEntry) -> CoreResult<CatalogSelection> {
        let pool = self.pool.clone();
        tokio::task::spawn_blocking(move || {
            let mut c = pool.get().map_err(storage)?;
            let tx = c.transaction_with_behavior(TransactionBehavior::Immediate).map_err(storage)?;
            if let Some(saved) = get(&tx, &entry.reference)? { return Ok(saved); }
            let now = chrono::Utc::now().timestamp();
            let local_artist_id = if entry.reference.kind == CatalogItemKind::Artist {
                Some(crate::database::enrichment::upsert_discovered_artist_inner(
                    &tx, &entry.title, &entry.reference.provider, &entry.reference.id,
                    (entry.reference.provider == "musicbrainz").then_some(entry.reference.id.as_str()),
                    "remote_search", now,
                )?)
            } else { None };
            tx.execute("INSERT INTO catalog_selections(provider,entity_kind,external_id,payload,local_artist_id,saved_at) VALUES (?1,?2,?3,?4,?5,?6)",
                params![entry.reference.provider, kind(&entry.reference)?, entry.reference.id, serde_json::to_string(&entry).map_err(storage)?, local_artist_id, now]).map_err(storage)?;
            tx.commit().map_err(storage)?;
            Ok(CatalogSelection { entry, local_artist_id, saved_at: now })
        }).await.map_err(storage)?
    }
}
fn kind(reference: &CatalogReference) -> CoreResult<String> {
    serde_json::to_string(&reference.kind).map_err(storage)
}
fn get(
    c: &rusqlite::Connection,
    reference: &CatalogReference,
) -> CoreResult<Option<CatalogSelection>> {
    c.query_row("SELECT payload,local_artist_id,saved_at FROM catalog_selections WHERE provider=?1 AND entity_kind=?2 AND external_id=?3", params![reference.provider,kind(reference)?,reference.id], row).optional().map_err(storage)
}
fn row(r: &rusqlite::Row<'_>) -> rusqlite::Result<CatalogSelection> {
    let value: String = r.get(0)?;
    let entry = serde_json::from_str(&value).map_err(|e| {
        rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(e))
    })?;
    Ok(CatalogSelection {
        entry,
        local_artist_id: r.get(1)?,
        saved_at: r.get(2)?,
    })
}
fn storage(e: impl std::fmt::Display) -> CoreError {
    CoreError::Storage {
        message: format!("Catalog selection: {e}"),
    }
}
