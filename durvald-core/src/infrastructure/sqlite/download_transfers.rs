//! Durable acquisition journal, isolated from playback/session persistence.
use crate::{api::*, application::download_transfers::StoredJob};
use rusqlite::{Connection, OptionalExtension, params};
use std::sync::Arc;
type Pool = r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>;
pub(crate) const SCHEMA: &str = r#"
CREATE TABLE download_transfer_settings(id INTEGER PRIMARY KEY CHECK(id=1),payload TEXT NOT NULL CHECK(json_valid(payload)));
CREATE TABLE download_transfer_jobs(job_id TEXT PRIMARY KEY,request_key TEXT NOT NULL UNIQUE,payload TEXT NOT NULL CHECK(json_valid(payload)),created_at INTEGER NOT NULL);
"#;
#[derive(Clone)]
pub(crate) struct TransferRepository {
    pub(crate) pool: Arc<Pool>,
}
pub(crate) fn storage(_: impl std::fmt::Display) -> CoreError {
    CoreError::Storage {
        message: "Não foi possível acessar o registro de transferências.".into(),
    }
}
impl TransferRepository {
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
    pub(crate) async fn settings(&self) -> CoreResult<DownloadTransferSettings> {
        self.run(|c| {
            c.query_row(
                "SELECT payload FROM download_transfer_settings WHERE id=1",
                [],
                |r| r.get::<_, String>(0),
            )
            .optional()
            .map_err(storage)?
            .map(|s| serde_json::from_str(&s).map_err(storage))
            .transpose()
            .map(|s| s.unwrap_or_default())
        })
        .await
    }
    pub(crate) async fn configure(
        &self,
        value: DownloadTransferSettings,
    ) -> CoreResult<DownloadTransferSettings> {
        self.run(move|c|{c.execute("INSERT INTO download_transfer_settings(id,payload) VALUES(1,?1) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",[serde_json::to_string(&value).map_err(storage)?]).map_err(storage)?;Ok(value)}).await
    }
    pub(crate) async fn list(&self) -> CoreResult<Vec<StoredJob>> {
        self.run(|c|{let mut q=c.prepare("SELECT payload FROM download_transfer_jobs ORDER BY created_at DESC,job_id LIMIT 200").map_err(storage)?;q.query_map([],|r|r.get::<_,String>(0)).map_err(storage)?.map(|r|serde_json::from_str(&r.map_err(storage)?).map_err(storage)).collect()}).await
    }
    pub(crate) async fn get(&self, id: String) -> CoreResult<StoredJob> {
        self.run(move |c| {
            let s = c
                .query_row(
                    "SELECT payload FROM download_transfer_jobs WHERE job_id=?1",
                    [id],
                    |r| r.get::<_, String>(0),
                )
                .optional()
                .map_err(storage)?
                .ok_or(CoreError::NotFound {
                    message: "Transferência não encontrada.".into(),
                })?;
            serde_json::from_str(&s).map_err(storage)
        })
        .await
    }
    pub(crate) async fn create(&self, value: StoredJob) -> CoreResult<(StoredJob, bool)> {
        self.run(move|c|{
        let tx=c.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate).map_err(storage)?;
        let existing:Option<String>=tx.query_row("SELECT payload FROM download_transfer_jobs WHERE request_key=?1",[&value.request_key],|r|r.get(0)).optional().map_err(storage)?;
        if let Some(s)=existing {return Ok((serde_json::from_str(&s).map_err(storage)?,false));}
        let count:i64=tx.query_row("SELECT COUNT(*) FROM download_transfer_jobs",[],|r|r.get(0)).map_err(storage)?;
        if count>=200 {return Err(CoreError::InvalidInput{message:"O limite de 200 lotes foi atingido. Revise os lotes existentes.".into()});}
        tx.execute("INSERT INTO download_transfer_jobs(job_id,request_key,payload,created_at) VALUES(?1,?2,?3,?4)",params![value.job.job_id,value.request_key,serde_json::to_string(&value).map_err(storage)?,value.job.created_at]).map_err(storage)?;tx.commit().map_err(storage)?;Ok((value,true))
    }).await
    }
    pub(crate) async fn save(&self, value: StoredJob) -> CoreResult<()> {
        self.run(move |c| {
            c.execute(
                "UPDATE download_transfer_jobs SET payload=?2 WHERE job_id=?1",
                params![
                    value.job.job_id,
                    serde_json::to_string(&value).map_err(storage)?
                ],
            )
            .map_err(storage)?;
            Ok(())
        })
        .await
    }
}

impl TransferRepository {
    pub(crate) async fn commit_import(
        &self,
        mut job: StoredJob,
        index: u32,
        metadata: crate::metadata::AudioMetadata,
        cancel: Arc<std::sync::atomic::AtomicBool>,
    ) -> CoreResult<StoredJob> {
        self.run(move|c|{
            use std::sync::atomic::Ordering;
            let i=index as usize;let journal=job.details[i].import.as_ref().ok_or(CoreError::InvalidInput {message:"A revisão não está disponível.".into()})?.clone();
            let tx=c.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate).map_err(storage)?;
            let current:String=tx.query_row("SELECT payload FROM download_transfer_jobs WHERE job_id=?1",[&job.job.job_id],|r|r.get(0)).map_err(storage)?;
            let current:StoredJob=serde_json::from_str(&current).map_err(storage)?;
            if cancel.load(Ordering::SeqCst)||current.details.get(i).and_then(|d|d.import.as_ref()).is_none_or(|j|j.token!=journal.token||j.target!=journal.target||j.digest!=journal.digest){return Err(CoreError::InvalidInput {message:"A importação foi cancelada ou a revisão mudou.".into()});}
            let path=&metadata.file_path;
            if path!=&journal.destination{return Err(CoreError::InvalidInput {message:"Destino incompatível com a revisão.".into()});}
            let owner:Option<i64>=tx.query_row("SELECT song_id FROM track_sources WHERE local_path_key=durvald_local_path_key(?1)",[path],|r|r.get(0)).optional().map_err(storage)?;
            let track=if let Some(target)=journal.target {
                if !tx.query_row("SELECT EXISTS(SELECT 1 FROM songs WHERE song_id=?1)",[target],|r|r.get::<_,bool>(0)).map_err(storage)?||owner.is_some_and(|id|id!=target){return Err(CoreError::InvalidInput {message:"O destino não existe ou o arquivo já pertence a outra faixa.".into()});}
                if owner.is_none(){tx.execute("INSERT INTO track_sources(song_id,provider,local_path,local_path_key,association_origin) VALUES(?1,'local',?2,durvald_local_path_key(?2),'confirmed_download_import')",params![target,path]).map_err(storage)?;}
                crate::database::source_catalog::cache_scanned_source(&tx,&metadata,0,9).map_err(storage)?;
                tx.execute("UPDATE songs SET duration=?2 WHERE song_id=?1 AND (duration IS NULL OR duration<=0)",params![target,metadata.duration]).map_err(storage)?;
                target
            }else if let Some(owner)=owner {owner}else {
                crate::database::operations::persist_metadata_in_transaction(&tx,vec![metadata.clone()],vec![0],vec![None]).map_err(storage)?;
                tx.query_row("SELECT song_id FROM track_sources WHERE local_path_key=durvald_local_path_key(?1)",[path],|r|r.get(0)).optional().map_err(storage)?.ok_or(CoreError::InvalidInput {message:"Já existe uma faixa com estes metadados. Escolha a faixa existente como destino da associação.".into()})?
            };
            tx.execute("UPDATE track_source_state SET availability='available',last_checked_at=CURRENT_TIMESTAMP,last_success_at=CURRENT_TIMESTAMP WHERE source_id IN (SELECT source_id FROM track_sources WHERE local_path_key=durvald_local_path_key(?1))",[path]).map_err(storage)?;
            job.job.files[i].state=DownloadFileState::Imported;job.job.files[i].imported_track_id=Some(track);job.job.files[i].imported_path=Some(path.clone());job.job.files[i].message=None;job.job.message=None;
            tx.execute("UPDATE download_transfer_jobs SET payload=?2 WHERE job_id=?1",params![job.job.job_id,serde_json::to_string(&job).map_err(storage)?]).map_err(storage)?;
            if cancel.load(Ordering::SeqCst){return Err(CoreError::InvalidInput {message:"Importação cancelada antes de confirmar a biblioteca.".into()});}
            tx.commit().map_err(storage)?;Ok(job)
        }).await
    }
}
