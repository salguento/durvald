//! SQLite ownership and source observations, separate from catalog personal data.
use crate::api::*;
use rusqlite::{Connection, OptionalExtension, params};
use std::sync::Arc;
type Pool = r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>;
#[derive(Clone)]
pub(crate) struct SqliteSources {
    pool: Arc<Pool>,
}
impl SqliteSources {
    pub(crate) fn new(pool: Arc<Pool>) -> Self {
        Self { pool }
    }
    async fn run<T: Send + 'static>(
        &self,
        f: impl FnOnce(&mut Connection) -> CoreResult<T> + Send + 'static,
    ) -> CoreResult<T> {
        let pool = self.pool.clone();
        tokio::task::spawn_blocking(move || {
            let mut c = pool.get().map_err(storage)?;
            f(&mut c)
        })
        .await
        .map_err(storage)?
    }
    pub(crate) async fn list(&self, track: i64) -> CoreResult<Vec<TrackSource>> {
        self.run(move |c| {
            require_track(c, track)?;
            let mut q = c.prepare(SELECT).map_err(storage)?;
            q.query_map([track], row)
                .map_err(storage)?
                .map(|r| r.map_err(storage))
                .collect()
        })
        .await
    }
    pub(crate) async fn get(&self, track: i64, source: i64) -> CoreResult<TrackSource> {
        self.list(track)
            .await?
            .into_iter()
            .find(|s| s.source_id == source)
            .ok_or_else(not_found)
    }
    pub(crate) async fn target(&self, track: i64) -> CoreResult<Option<CatalogReference>> {
        self.run(move|c|{
        require_track(c,track)?;
        let reference=c.query_row("SELECT provider,entity_kind,external_id FROM catalog_track_references WHERE song_id=?1 AND provider='musicbrainz' ORDER BY external_id",[track],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?,r.get::<_,String>(2)?))).optional().map_err(storage)?;
        if let Some((provider,kind,id))=reference {let kind=serde_json::from_str(&kind).map_err(storage)?;return Ok(Some(CatalogReference{provider,kind,id}));}
        let payload:Option<String>=c.query_row("SELECT payload FROM song_musicbrainz_tags WHERE song_id=?1",[track],|r|r.get(0)).optional().map_err(storage)?;
        let ids=payload.and_then(|p|serde_json::from_str::<serde_json::Value>(&p).ok()).and_then(|p|p.get("recordings").and_then(|r|r.as_array()).cloned()).unwrap_or_default();
        let ids:std::collections::BTreeSet<_>=ids.iter().filter_map(|s|s.as_str()).filter_map(crate::enrichment::identity::normalize_mbid).collect();
        Ok((ids.len()==1).then(||CatalogReference{provider:"musicbrainz".into(),kind:CatalogItemKind::Recording,id:ids.into_iter().next().unwrap()}))
    }).await
    }
    pub(crate) async fn attach(
        &self,
        target: Option<i64>,
        entry: CatalogEntry,
        candidate: SourceCandidate,
        origin: String,
    ) -> CoreResult<TrackSource> {
        let track=self.run(move|c|{
            let tx=c.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate).map_err(storage)?;
            let track=if let Some(id)=target {require_track(&tx,id)?;id}else{crate::database::source_catalog::save_remote_inner(&tx,&entry,false).map_err(storage)?};
            let owner:Option<(i64,i64)>=tx.query_row("SELECT source_id,song_id FROM track_sources WHERE provider=?1 AND external_id=?2",params![candidate.provider,candidate.external_id],|r|Ok((r.get(0)?,r.get(1)?))).optional().map_err(storage)?;
            let source=match owner {
                Some((_,owner)) if owner!=track=>return Err(invalid(&format!("Source already belongs to track {owner}"))),
                Some((source,_))=>source,
                None=>{
                    tx.execute("INSERT INTO track_sources(song_id,provider,external_id,canonical_url,association_origin) VALUES(?1,?2,?3,?4,?5)",params![track,candidate.provider,candidate.external_id,candidate.canonical_url,origin]).map_err(storage)?;
                    tx.last_insert_rowid()
                }
            };
            observation(&tx,source,&candidate)?;
            tx.commit().map_err(storage)?;Ok((track,source))
        }).await?;
        self.get(track.0, track.1).await
    }
    pub(crate) async fn attach_local(&self, track: i64, path: String) -> CoreResult<TrackSource> {
        let source=self.run(move|c|{let tx=c.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate).map_err(storage)?;require_track(&tx,track)?;
            let owner:Option<(i64,i64)>=tx.query_row("SELECT source_id,song_id FROM track_sources WHERE local_path_key=durvald_local_path_key(?1)",[&path],|r|Ok((r.get(0)?,r.get(1)?))).optional().map_err(storage)?;
            let id=match owner {Some((_,id)) if id!=track=>return Err(invalid(&format!("File already belongs to track {id}"))),Some((id,_))=>id,None=>{
                tx.execute("INSERT INTO track_sources(song_id,local_path,local_path_key,association_origin) VALUES(?1,?2,durvald_local_path_key(?2),'user_confirmed')",params![track,path]).map_err(storage)?;
                let id=tx.last_insert_rowid();tx.execute("UPDATE track_source_metadata SET bitrate=NULL,sample_rate=NULL,bit_depth=NULL WHERE source_id=?1",[id]).map_err(storage)?;id
            }};tx.commit().map_err(storage)?;Ok(id)
        }).await?;
        self.get(track, source).await
    }
    pub(crate) async fn enabled(
        &self,
        track: i64,
        source: i64,
        enabled: bool,
    ) -> CoreResult<TrackSource> {
        self.mutate(track,source,move|c|{c.execute("UPDATE track_sources SET enabled=?3,updated_at=CURRENT_TIMESTAMP WHERE source_id=?1 AND song_id=?2",params![source,track,enabled]).map_err(storage)?;Ok(())}).await?;
        self.get(track, source).await
    }
    pub(crate) async fn remove(&self, track: i64, source: i64) -> CoreResult<()> {
        self.mutate(track, source, move |c| {
            c.execute(
                "DELETE FROM track_sources WHERE source_id=?1 AND song_id=?2",
                [source, track],
            )
            .map_err(storage)?;
            Ok(())
        })
        .await
    }
    pub(crate) async fn prefer(&self, track: i64, source: Option<i64>) -> CoreResult<()> {
        self.run(move|c|{
        let tx=c.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate).map_err(storage)?;require_track(&tx,track)?;
        if let Some(id)=source {require_source(&tx,track,id)?;tx.execute("INSERT INTO playback_source_preferences(song_id,source_id) VALUES(?1,?2) ON CONFLICT(song_id) DO UPDATE SET source_id=excluded.source_id",[track,id]).map_err(storage)?;}
        else{tx.execute("DELETE FROM playback_source_preferences WHERE song_id=?1",[track]).map_err(storage)?;}
        tx.commit().map_err(storage)
    }).await
    }
    async fn mutate(
        &self,
        track: i64,
        source: i64,
        f: impl FnOnce(&Connection) -> CoreResult<()> + Send + 'static,
    ) -> CoreResult<()> {
        self.run(move |c| {
            let tx = c
                .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
                .map_err(storage)?;
            require_source(&tx, track, source)?;
            f(&tx)?;
            tx.commit().map_err(storage)
        })
        .await
    }
    pub(crate) async fn tested(
        &self,
        track: i64,
        source: i64,
        expected_path: Option<String>,
        capability: SourceCapability,
        available: &'static str,
    ) -> CoreResult<TrackSource> {
        self.mutate(track,source,move|c|{
            let current:Option<String>=c.query_row("SELECT local_path FROM track_sources WHERE source_id=?1",[source],|r|r.get(0)).map_err(storage)?;
            if current!=expected_path {return Err(invalid("Source changed during verification; retry"));}
            c.execute("UPDATE track_source_state SET availability=?2,last_checked_at=CURRENT_TIMESTAMP,last_success_at=CASE WHEN ?2='available' THEN CURRENT_TIMESTAMP ELSE last_success_at END,last_failure_at=CASE WHEN ?2='unavailable' THEN CURRENT_TIMESTAMP ELSE last_failure_at END WHERE source_id=?1",params![source,available]).map_err(storage)?;
            let mut value=c.query_row("SELECT payload FROM track_source_observations WHERE source_id=?1",[source],|r|r.get::<_,String>(0)).optional().map_err(storage)?.and_then(|p|serde_json::from_str::<serde_json::Value>(&p).ok()).unwrap_or_else(||serde_json::json!({}));
            value["capability"]=serde_json::to_value(capability).map_err(storage)?;
            c.execute("INSERT INTO track_source_observations(source_id,payload) VALUES(?1,?2) ON CONFLICT(source_id) DO UPDATE SET payload=excluded.payload",params![source,value.to_string()]).map_err(storage)?;Ok(())
        }).await?;
        self.get(track, source).await
    }
}
const SELECT: &str = "SELECT s.source_id,s.song_id,s.provider,s.external_id,s.canonical_url,s.local_path,s.enabled,s.priority,st.availability,st.last_checked_at,(p.source_id IS NOT NULL),o.payload FROM track_sources s JOIN track_source_state st USING(source_id) LEFT JOIN playback_source_preferences p ON p.song_id=s.song_id AND p.source_id=s.source_id LEFT JOIN track_source_observations o USING(source_id) WHERE s.song_id=?1 ORDER BY (p.source_id IS NOT NULL) DESC,s.priority DESC,s.source_id";
fn row(r: &rusqlite::Row<'_>) -> rusqlite::Result<TrackSource> {
    let payload: Option<String> = r.get(11)?;
    let o: serde_json::Value = payload
        .and_then(|p| serde_json::from_str(&p).ok())
        .unwrap_or_default();
    let availability: String = r.get(8)?;
    let local: Option<String> = r.get(5)?;
    let capability = if local.is_some() {
        match availability.as_str() {
            "available" => SourceCapability::FullAudio,
            "unavailable" => SourceCapability::Unavailable,
            _ => SourceCapability::Unknown,
        }
    } else {
        o.get("capability")
            .and_then(|v| serde_json::from_value(v.clone()).ok())
            .unwrap_or(SourceCapability::Unknown)
    };
    Ok(TrackSource {
        source_id: r.get(0)?,
        track_id: r.get(1)?,
        provider: r.get(2)?,
        external_id: r.get(3)?,
        canonical_url: r.get(4)?,
        local_path: local,
        enabled: r.get(6)?,
        priority: r.get(7)?,
        availability,
        last_checked_at: r.get(9)?,
        preferred: r.get(10)?,
        title: o.get("title").and_then(|v| v.as_str()).map(str::to_owned),
        uploader: o
            .get("uploader")
            .and_then(|v| v.as_str())
            .map(str::to_owned),
        version_label: o
            .get("version_label")
            .and_then(|v| v.as_str())
            .map(str::to_owned),
        duration_seconds: o.get("duration_seconds").and_then(|v| v.as_u64()),
        capability,
    })
}
fn observation(c: &Connection, id: i64, s: &SourceCandidate) -> CoreResult<()> {
    let mut v = serde_json::to_value(s).map_err(storage)?;
    v.as_object_mut().unwrap().remove("candidate_id");
    c.execute("INSERT INTO track_source_observations(source_id,payload) VALUES(?1,?2) ON CONFLICT(source_id) DO UPDATE SET payload=excluded.payload",params![id,v.to_string()]).map_err(storage)?;
    Ok(())
}
fn require_track(c: &Connection, id: i64) -> CoreResult<()> {
    if c.query_row(
        "SELECT EXISTS(SELECT 1 FROM songs WHERE song_id=?1)",
        [id],
        |r| r.get::<_, bool>(0),
    )
    .map_err(storage)?
    {
        Ok(())
    } else {
        Err(not_found())
    }
}
fn require_source(c: &Connection, track: i64, source: i64) -> CoreResult<()> {
    if c.query_row(
        "SELECT EXISTS(SELECT 1 FROM track_sources WHERE source_id=?1 AND song_id=?2)",
        [source, track],
        |r| r.get::<_, bool>(0),
    )
    .map_err(storage)?
    {
        Ok(())
    } else {
        Err(not_found())
    }
}
fn not_found() -> CoreError {
    CoreError::NotFound {
        message: "Track or source not found".into(),
    }
}
fn invalid(message: &str) -> CoreError {
    CoreError::InvalidInput {
        message: message.into(),
    }
}
fn storage(e: impl std::fmt::Display) -> CoreError {
    CoreError::Storage {
        message: format!("Source storage: {e}"),
    }
}
