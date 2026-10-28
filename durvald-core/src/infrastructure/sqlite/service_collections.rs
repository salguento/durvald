//! Public, normalized metadata cache and transactional per-occurrence import receipts.
use crate::{
    api::*,
    application::{service_collection_ports::ServicePage, service_collections::StoredCollection},
};
use rusqlite::{Connection, OptionalExtension, params};
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};
type Pool = r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>;
pub(crate) const SCHEMA: &str = r#"
CREATE TABLE service_collection_jobs(job_id TEXT PRIMARY KEY,canonical_url TEXT NOT NULL UNIQUE,payload TEXT NOT NULL CHECK(json_valid(payload)),created_at INTEGER NOT NULL);
CREATE TABLE service_media_policy(provider TEXT NOT NULL,external_id TEXT NOT NULL,preview_only INTEGER NOT NULL,finite_video INTEGER NOT NULL,verified_at INTEGER NOT NULL,PRIMARY KEY(provider,external_id));
CREATE TABLE service_collection_cache(cache_key TEXT PRIMARY KEY,payload TEXT NOT NULL CHECK(json_valid(payload)),expires_at INTEGER NOT NULL);
"#;
#[derive(Clone)]
pub(crate) struct ServiceCollectionRepository {
    pool: Arc<Pool>,
}
fn storage(_: impl std::fmt::Display) -> CoreError {
    CoreError::Storage {
        message: "Não foi possível acessar as importações de serviços.".into(),
    }
}
impl ServiceCollectionRepository {
    pub(crate) fn new(pool: Arc<Pool>) -> Self {
        Self { pool }
    }
    pub(crate) async fn run<T: Send + 'static>(
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
    pub(crate) async fn list(&self) -> CoreResult<Vec<StoredCollection>> {
        self.run(|c|{let mut q=c.prepare("SELECT payload FROM service_collection_jobs ORDER BY created_at DESC,job_id LIMIT 100").map_err(storage)?;q.query_map([],|r|r.get::<_,String>(0)).map_err(storage)?.map(|s|serde_json::from_str(&s.map_err(storage)?).map_err(storage)).collect()}).await
    }
    pub(crate) async fn get(&self, id: String) -> CoreResult<StoredCollection> {
        self.run(move |c| {
            let s = c
                .query_row(
                    "SELECT payload FROM service_collection_jobs WHERE job_id=?1",
                    [id],
                    |r| r.get::<_, String>(0),
                )
                .optional()
                .map_err(storage)?
                .ok_or(CoreError::NotFound {
                    message: "Importação não encontrada.".into(),
                })?;
            serde_json::from_str(&s).map_err(storage)
        })
        .await
    }
    pub(crate) async fn create(&self, job: StoredCollection) -> CoreResult<StoredCollection> {
        self.run(move|c|{let tx=c.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate).map_err(storage)?;if let Some(s)=tx.query_row("SELECT payload FROM service_collection_jobs WHERE canonical_url=?1",[&job.job.canonical_url],|r|r.get::<_,String>(0)).optional().map_err(storage)?{return serde_json::from_str(&s).map_err(storage);}
        let count:i64=tx.query_row("SELECT COUNT(*) FROM service_collection_jobs",[],|r|r.get(0)).map_err(storage)?;if count>=100{return Err(CoreError::InvalidInput{message:"O limite de 100 capturas de coleções foi atingido.".into()});}
        tx.execute("INSERT INTO service_collection_jobs(job_id,canonical_url,payload,created_at) VALUES(?1,?2,?3,?4)",params![job.job.job_id,job.job.canonical_url,serde_json::to_string(&job).map_err(storage)?,chrono::Utc::now().timestamp()]).map_err(storage)?;tx.commit().map_err(storage)?;Ok(job)
    }).await
    }
    pub(crate) async fn save(&self, job: StoredCollection) -> CoreResult<()> {
        self.run(move |c| {
            save(c, &job)?;
            Ok(())
        })
        .await
    }
    pub(crate) async fn cached(&self, key: String) -> CoreResult<Option<ServicePage>> {
        self.run(move |c| {
            c.query_row(
                "SELECT payload FROM service_collection_cache WHERE cache_key=?1 AND expires_at>?2",
                params![key, chrono::Utc::now().timestamp()],
                |r| r.get::<_, String>(0),
            )
            .optional()
            .map_err(storage)?
            .map(|s| serde_json::from_str(&s).map_err(storage))
            .transpose()
        })
        .await
    }
    pub(crate) async fn cache(&self, key: String, page: ServicePage) -> CoreResult<()> {
        self.run(move |c| {
            for item in &page.items {
                if let Some(entry)=&item.entry {
                    let preview=item.access==ServiceMediaAccess::Preview;
                    let finite=entry.reference.provider=="youtube"&&item.access==ServiceMediaAccess::Unknown&&entry.duration_seconds.is_some_and(|d|d>0);
                    c.execute("INSERT INTO service_media_policy(provider,external_id,preview_only,finite_video,verified_at) VALUES(?1,?2,?3,?4,?5) ON CONFLICT(provider,external_id) DO UPDATE SET preview_only=CASE WHEN ?6 THEN excluded.preview_only ELSE service_media_policy.preview_only END,finite_video=excluded.finite_video,verified_at=excluded.verified_at",params![entry.reference.provider,entry.reference.id,preview,finite,chrono::Utc::now().timestamp(),matches!(item.access,ServiceMediaAccess::Preview|ServiceMediaAccess::StreamObserved)]).map_err(storage)?;
                }
            }
            c.execute("DELETE FROM service_collection_cache WHERE expires_at<=?1",[chrono::Utc::now().timestamp()]).map_err(storage)?;
            c.execute("INSERT INTO service_collection_cache(cache_key,payload,expires_at) VALUES(?1,?2,?3) ON CONFLICT(cache_key) DO UPDATE SET payload=excluded.payload,expires_at=excluded.expires_at",params![key,serde_json::to_string(&page).map_err(storage)?,chrono::Utc::now().timestamp()+3600]).map_err(storage)?;
            Ok(())
        }).await
    }
    pub(crate) async fn apply(
        &self,
        mut job: StoredCollection,
        selected: Vec<String>,
        cancel: Arc<AtomicBool>,
    ) -> CoreResult<StoredCollection> {
        self.run(move|c|{
        for i in 0..job.job.items.len(){
            if cancel.load(Ordering::SeqCst){job.job.cancelled=true;job.job.failure=Some(ServiceImportFailure::Cancelled);save(c,&job)?;break;}
            let item=job.job.items[i].clone();if !selected.contains(&item.occurrence_id)||item.saved_track_id.is_some(){continue;}
            if item.entry.is_none()||matches!(item.access,ServiceMediaAccess::Restricted|ServiceMediaAccess::Unavailable|ServiceMediaAccess::UnsupportedLive){continue;}
            let result=(||->CoreResult<(i64,Option<i64>)>{
                let tx=c.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate).map_err(storage)?;
                let entry=item.entry.as_ref().unwrap();
                let source_owner:Option<i64>=tx.query_row("SELECT song_id FROM track_sources WHERE provider=?1 AND external_id=?2",params![entry.reference.provider,entry.reference.id],|r|r.get(0)).optional().map_err(storage)?;
                let track=if let Some(owner)=source_owner {owner}else{crate::database::source_catalog::save_remote_inner(&tx,entry,true).map_err(storage)?};
                let source:Option<i64>=tx.query_row("SELECT source_id FROM track_sources WHERE provider=?1 AND external_id=?2",params![entry.reference.provider,entry.reference.id],|r|r.get(0)).optional().map_err(storage)?;
                let source=if let Some(source)=source{source}else{tx.execute("INSERT INTO track_sources(song_id,provider,external_id,canonical_url,association_origin) VALUES(?1,?2,?3,?4,'reviewed_service_import')",params![track,entry.reference.provider,entry.reference.id,entry.canonical_url]).map_err(storage)?;tx.last_insert_rowid()};
                let capability=if job.job.provider==ServiceProvider::Bandcamp {SourceCapability::ExternalOpen}else if item.access==ServiceMediaAccess::Preview{SourceCapability::Preview}else{SourceCapability::EmbeddedPlayer};
                let observation=serde_json::json!({"title":entry.title,"uploader":entry.artist_credit,"duration_seconds":entry.duration_seconds,"capability":capability,"access":item.access,"finite_video":job.job.provider==ServiceProvider::YouTube&&item.access==ServiceMediaAccess::Unknown&&entry.duration_seconds.is_some_and(|s|s>0),"video_verified_at":chrono::Utc::now().timestamp()});
                tx.execute("INSERT INTO track_source_observations(source_id,payload) VALUES(?1,?2) ON CONFLICT(source_id) DO UPDATE SET payload=json_patch(track_source_observations.payload,excluded.payload)",params![source,observation.to_string()]).map_err(storage)?;
                let playlist=if job.job.is_collection {
                    let id=if let Some(id)=job.job.playlist_id {if !tx.query_row("SELECT EXISTS(SELECT 1 FROM playlists WHERE id=?1)",[id],|r|r.get::<_,bool>(0)).map_err(storage)?{return Err(CoreError::InvalidInput{message:"A playlist importada foi removida. Seus itens salvos foram preservados.".into()});}id}else{tx.execute("INSERT INTO playlists(name,description) VALUES(?1,'Importação revisada de coleção externa')",[&job.job.title]).map_err(storage)?;tx.last_insert_rowid()};
                    if tx.query_row("SELECT EXISTS(SELECT 1 FROM playlist_songs WHERE playlist_id=?1 AND position=?2)",params![id,item.position],|r|r.get::<_,bool>(0)).map_err(storage)? {return Err(CoreError::InvalidInput{message:"A posição na playlist foi editada. A importação não substitui suas alterações.".into()});}
                    tx.execute("INSERT INTO playlist_songs(playlist_id,song_id,position) VALUES(?1,?2,?3)",params![id,track,item.position]).map_err(storage)?;Some(id)
                }else{None};
                let mut committed=job.clone();committed.job.items[i].saved_track_id=Some(track);committed.job.items[i].failure=None;committed.job.playlist_id=playlist;
                save(&tx,&committed)?;
                if cancel.load(Ordering::SeqCst){return Err(CoreError::InvalidInput{message:"Importação cancelada antes de confirmar este item.".into()});}
                tx.commit().map_err(storage)?;Ok((track,playlist))
            })();
            match result {Ok((track,playlist))=>{job.job.items[i].saved_track_id=Some(track);job.job.items[i].failure=None;job.job.playlist_id=playlist;},Err(_)=>{job.job.items[i].failure=Some(ServiceImportFailure::InvalidResponse);save(c,&job)?;}}
        }
        Ok(job)
    }).await
    }
}
fn save(c: &Connection, job: &StoredCollection) -> CoreResult<()> {
    c.execute(
        "UPDATE service_collection_jobs SET payload=?2 WHERE job_id=?1",
        params![job.job.job_id, serde_json::to_string(job).map_err(storage)?],
    )
    .map_err(storage)?;
    Ok(())
}
