//! Persistent, explicit acquisition; no playback or automatic library adoption.
use crate::{
    api::*,
    application::{
        music_plugins::{PluginRuntime, context::RequestScope},
        transfer_ports::*,
    },
    infrastructure::{acquisition_files, sqlite::download_transfers::TransferRepository},
};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    sync::{
        Arc, Mutex as StdMutex,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};
use tokio::sync::Mutex;
#[derive(Clone, Serialize, Deserialize)]
pub(crate) struct ReviewedFile {
    pub(crate) token: String,
    pub(crate) path: String,
    pub(crate) digest: String,
    pub(crate) extension: String,
    pub(crate) metadata: crate::metadata::AudioMetadata,
}
#[derive(Clone, Serialize, Deserialize)]
pub(crate) struct ImportJournal {
    pub(crate) target: Option<i64>,
    pub(crate) destination: String,
    pub(crate) digest: String,
    pub(crate) token: String,
}
#[derive(Clone, Serialize, Deserialize, Default)]
pub(crate) struct FileDetails {
    pub(crate) batch_id: Option<String>,
    pub(crate) transfer_id: Option<String>,
    pub(crate) review: Option<ReviewedFile>,
    pub(crate) import: Option<ImportJournal>,
}
#[derive(Clone, Serialize, Deserialize)]
pub(crate) struct Attempt {
    #[serde(default)]
    pub(crate) not_submitted: bool,
    pub(crate) id: String,
    pub(crate) indices: Vec<u32>,
    pub(crate) receipt_seen: bool,
    pub(crate) previous: Vec<SavedIdentity>,
}
#[derive(Clone, Serialize, Deserialize)]
pub(crate) struct SavedIdentity {
    pub(crate) batch_id: String,
    pub(crate) transfer_id: String,
    pub(crate) filename: String,
    pub(crate) size: u64,
}
#[derive(Clone, Serialize, Deserialize)]
pub(crate) struct StoredJob {
    pub(crate) job: DownloadTransferJob,
    pub(crate) endpoint: String,
    pub(crate) request_key: String,
    pub(crate) attempts: Vec<Attempt>,
    pub(crate) details: Vec<FileDetails>,
}
struct Control {
    scope: RequestScope,
    cancel: Arc<AtomicBool>,
}
impl Default for Control {
    fn default() -> Self {
        Self {
            scope: RequestScope::default(),
            cancel: Arc::new(AtomicBool::new(false)),
        }
    }
}
pub(crate) struct DownloadTransfersApplication {
    pub(crate) repository: TransferRepository,
    runtime: Arc<PluginRuntime>,
    operations: Mutex<()>,
    controls: StdMutex<HashMap<String, Arc<Control>>>,
    metadata_lane: Arc<Mutex<()>>,
    covers: String,
}
pub(crate) fn invalid(message: &str) -> CoreError {
    CoreError::InvalidInput {
        message: message.into(),
    }
}
impl DownloadTransfersApplication {
    pub(crate) fn new(
        repository: TransferRepository,
        runtime: Arc<PluginRuntime>,
        metadata_lane: Arc<Mutex<()>>,
        covers: String,
    ) -> Self {
        Self {
            repository,
            runtime,
            operations: Mutex::new(()),
            controls: StdMutex::default(),
            metadata_lane,
            covers,
        }
    }
    fn control(&self, id: &str) -> Arc<Control> {
        self.controls
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .entry(id.into())
            .or_default()
            .clone()
    }
    pub(crate) async fn settings(&self) -> CoreResult<DownloadTransferSettings> {
        self.repository.settings().await
    }
    pub(crate) async fn configure(
        &self,
        value: DownloadTransferSettings,
    ) -> CoreResult<DownloadTransferSettings> {
        let _guard = self.operations.lock().await;
        let value = if value.enabled {
            acquisition_files::validate_settings(value).await?
        } else {
            value
        };
        self.repository.configure(value).await
    }
    pub(crate) async fn list(&self) -> CoreResult<Vec<DownloadTransferJob>> {
        Ok(self
            .repository
            .list()
            .await?
            .into_iter()
            .map(|j| j.job)
            .collect())
    }
    pub(crate) async fn enqueue(
        &self,
        endpoint: String,
        mut group: DownloadOfferGroup,
    ) -> CoreResult<DownloadTransferJob> {
        let _guard = self.operations.lock().await;
        let settings = acquisition_files::validate_settings(self.settings().await?).await?;
        group.files.sort_by(|a, b| a.filename.cmp(&b.filename));
        if group.files.is_empty()
            || group.files.len() > 500
            || group.files.iter().any(|f| {
                f.size_bytes == 0
                    || f.size_bytes > i64::MAX as u64
                    || !acquisition_files::supported(&f.filename)
            })
        {
            return Err(invalid(
                "Selecione até 500 arquivos MP3, WAV, FLAC ou Ogg de tamanho conhecido.",
            ));
        }
        use sha2::{Digest, Sha256};
        let key = format!(
            "{:x}",
            Sha256::digest(
                serde_json::to_vec(&(
                    &endpoint,
                    &group.peer,
                    &settings,
                    group
                        .files
                        .iter()
                        .map(|f| (&f.filename, f.size_bytes))
                        .collect::<Vec<_>>()
                ))
                .map_err(|_| invalid("Oferta inválida."))?
            )
        );
        let existing = self.repository.list().await?;
        if let Some(existing) = existing.iter().find(|j| j.request_key == key) {
            return Ok(existing.job.clone());
        }
        if let Some(existing) = existing.iter().find(|j| {
            j.endpoint == endpoint
                && j.job.peer == group.peer
                && j.job.library_destination == settings.library_destination
                && j.job.files.iter().any(|f| {
                    group
                        .files
                        .iter()
                        .any(|g| g.filename == f.filename && g.size_bytes == f.size_bytes)
                })
        }) {
            return Err(invalid(&format!(
                "Um dos arquivos já pertence ao lote {}. Use a fila de transferências para retomar ou importar.",
                existing.job.job_id
            )));
        }
        let id = crate::infrastructure::slskd_search::search_id()
            .map_err(|_| invalid("Não foi possível criar o lote."))?;
        let files: Vec<_> = group
            .files
            .into_iter()
            .enumerate()
            .map(|(i, f)| DownloadTransferFile {
                index: i as u32,
                filename: f.filename,
                size_bytes: f.size_bytes,
                bytes_transferred: 0,
                state: DownloadFileState::Prepared,
                queue_position: None,
                imported_track_id: None,
                imported_path: None,
                message: None,
            })
            .collect();
        let attempt = Attempt {
            not_submitted: false,
            id: crate::infrastructure::slskd_search::search_id()
                .map_err(|_| invalid("Não foi possível criar a tentativa."))?,
            indices: files.iter().map(|f| f.index).collect(),
            receipt_seen: false,
            previous: vec![],
        };
        let job = StoredJob {
            endpoint,
            request_key: key,
            details: vec![FileDetails::default(); files.len()],
            attempts: vec![attempt],
            job: DownloadTransferJob {
                job_id: id.clone(),
                peer: group.peer,
                folder: group.folder,
                created_at: chrono::Utc::now().timestamp(),
                relative_destination: format!("durvald/{id}"),
                remote_download_root: settings.remote_download_root,
                mapped_download_root: settings.mapped_download_root,
                library_destination: settings.library_destination,
                files,
                cancel_requested: false,
                message: None,
            },
        };
        let (mut job, created) = self.repository.create(job).await?;
        if created {
            self.submit(&mut job, 0).await?;
        }
        Ok(job.job)
    }
    async fn remote(
        &self,
        job: &StoredJob,
        action: TransferAction,
    ) -> Result<TransferReceipt, crate::domain::music::plugins::PluginError> {
        self.runtime
            .transfer(
                self.control(&job.job.job_id).scope.begin(),
                TransferCommand {
                    endpoint: job.endpoint.clone(),
                    action,
                },
            )
            .await
    }
    fn specs(job: &StoredJob, attempt: &Attempt) -> Vec<TransferFileSpec> {
        attempt
            .indices
            .iter()
            .map(|i| {
                let f = &job.job.files[*i as usize];
                TransferFileSpec {
                    filename: f.filename.clone(),
                    size: f.size_bytes,
                }
            })
            .collect()
    }
    async fn submit(&self, job: &mut StoredJob, index: usize) -> CoreResult<()> {
        let attempt = job.attempts[index].clone();
        for i in &attempt.indices {
            job.job.files[*i as usize].state = DownloadFileState::SubmissionUnknown;
            job.details[*i as usize].batch_id = Some(attempt.id.clone());
            job.details[*i as usize].transfer_id = None;
        }
        // Commit before the request: a crash/timeout can only reconcile this UUID, never blindly enqueue again.
        self.repository.save(job.clone()).await?;
        let action = TransferAction::Enqueue {
            batch_id: attempt.id.clone(),
            peer: job.job.peer.clone(),
            destination: job.job.relative_destination.clone(),
            files: Self::specs(job, &attempt),
            previous: attempt
                .previous
                .iter()
                .map(|p| TransferIdentity {
                    batch_id: p.batch_id.clone(),
                    transfer_id: p.transfer_id.clone(),
                    file: TransferFileSpec {
                        filename: p.filename.clone(),
                        size: p.size,
                    },
                })
                .collect(),
        };
        match self.remote(job, action).await {
            Ok(receipt) if receipt.not_submitted.is_some() => {
                job.attempts[index].not_submitted = true;
                let message = transfer_error(crate::domain::music::plugins::PluginError::Adapter(
                    receipt.not_submitted.unwrap(),
                ));
                for i in &attempt.indices {
                    job.job.files[*i as usize].state = DownloadFileState::Failed;
                    job.job.files[*i as usize].message = Some(message.clone());
                }
                job.job.message = Some(message);
            }
            Ok(receipt) => {
                Self::apply(job, index, receipt);
                job.job.message = None;
            }
            Err(e) => {
                use crate::domain::music::plugins::PluginError as P;
                if matches!(
                    e,
                    P::Disabled
                        | P::NotRegistered
                        | P::MissingCredential
                        | P::InvalidConfiguration
                        | P::Adapter(crate::domain::music::IntegrationError::RateLimited { .. })
                ) {
                    job.attempts[index].not_submitted = true;
                    for i in &attempt.indices {
                        job.job.files[*i as usize].state = DownloadFileState::Failed;
                    }
                }
                job.job.message = Some(transfer_error(e));
            }
        }
        self.repository.save(job.clone()).await
    }
    fn apply(job: &mut StoredJob, index: usize, receipt: TransferReceipt) {
        let attempt = job.attempts[index].clone();
        job.attempts[index].receipt_seen = true;
        for i in attempt.indices {
            let f = &mut job.job.files[i as usize];
            if matches!(
                f.state,
                DownloadFileState::Completed
                    | DownloadFileState::Imported
                    | DownloadFileState::Importing
            ) || job.details[i as usize]
                .batch_id
                .as_ref()
                .is_some_and(|b| b != &attempt.id)
            {
                continue;
            }
            if let Some(row) = receipt
                .rows
                .iter()
                .find(|r| r.file.filename == f.filename && r.file.size == f.size_bytes)
            {
                if job.details[i as usize]
                    .transfer_id
                    .as_ref()
                    .is_some_and(|id| id != &row.transfer_id)
                {
                    job.job.message=Some("A identidade de uma transferência mudou no backend. O registro original foi preservado.".into());
                    continue;
                }
                job.details[i as usize].batch_id = Some(attempt.id.clone());
                job.details[i as usize].transfer_id = Some(row.transfer_id.clone());
                f.state = row.state;
                f.bytes_transferred = row.bytes;
                f.queue_position = row.queue;
                f.message = None;
            } else if job.details[i as usize].transfer_id.is_some() {
                job.job.message=Some("Uma transferência conhecida não aparece mais no lote. Confira o slskd antes de tentar novamente.".into());
            } else {
                f.state = DownloadFileState::Failed;
                f.message=Some("O backend não aceitou este arquivo no lote; os demais arquivos são independentes.".into());
            }
        }
    }
    pub(crate) async fn refresh(&self, id: String) -> CoreResult<DownloadTransferJob> {
        let _guard = self.operations.lock().await;
        let mut job = self.repository.get(id).await?;
        self.reconcile(&mut job).await?;
        if job.job.cancel_requested {
            self.cancel_inner(&mut job).await?;
        }
        Ok(job.job)
    }
    async fn reconcile(&self, job: &mut StoredJob) -> CoreResult<()> {
        job.job.message = None;
        for index in 0..job.attempts.len() {
            let attempt = job.attempts[index].clone();
            if attempt.not_submitted {
                continue;
            }
            let relevant = attempt.indices.iter().any(|i| {
                let f = &job.job.files[*i as usize];
                !matches!(
                    f.state,
                    DownloadFileState::Completed
                        | DownloadFileState::Imported
                        | DownloadFileState::Importing
                ) && job.details[*i as usize]
                    .batch_id
                    .as_ref()
                    .is_none_or(|b| b == &attempt.id)
            });
            if !relevant {
                continue;
            }
            let action = TransferAction::Inspect {
                batch_id: attempt.id.clone(),
                peer: job.job.peer.clone(),
                destination: job.job.relative_destination.clone(),
                files: Self::specs(job, &attempt),
            };
            match self.remote(job, action).await {
                Ok(receipt) => Self::apply(job, index, receipt),
                Err(e) => {
                    job.job.message = Some(transfer_error(e));
                    break;
                }
            }
        }
        self.repository.save(job.clone()).await
    }
    pub(crate) async fn cancel(&self, id: String) -> CoreResult<DownloadTransferJob> {
        self.repository.get(id.clone()).await?;
        let control = self.control(&id);
        control.cancel.store(true, Ordering::SeqCst);
        control.scope.begin().cancel();
        let _guard = self.operations.lock().await;
        let mut job = self.repository.get(id).await?;
        job.job.cancel_requested = true;
        self.repository.save(job.clone()).await?;
        self.reconcile(&mut job).await?;
        self.cancel_inner(&mut job).await?;
        Ok(job.job)
    }
    async fn cancel_inner(&self, job: &mut StoredJob) -> CoreResult<()> {
        let deadline = Instant::now() + Duration::from_secs(20);
        for i in 0..job.job.files.len() {
            if matches!(
                job.job.files[i].state,
                DownloadFileState::Completed
                    | DownloadFileState::Imported
                    | DownloadFileState::Importing
                    | DownloadFileState::Failed
                    | DownloadFileState::Cancelled
            ) {
                continue;
            }
            let d = &job.details[i];
            let (Some(batch), Some(transfer)) = (&d.batch_id, &d.transfer_id) else {
                job.job.message=Some("Cancelamento pendente: o recebimento do lote ainda não foi confirmado. Atualize quando a conexão voltar.".into());
                continue;
            };
            let f = &job.job.files[i];
            let action = TransferAction::Cancel {
                identity: TransferIdentity {
                    batch_id: batch.clone(),
                    transfer_id: transfer.clone(),
                    file: TransferFileSpec {
                        filename: f.filename.clone(),
                        size: f.size_bytes,
                    },
                },
                peer: job.job.peer.clone(),
                destination: job.job.relative_destination.clone(),
            };
            let remaining = deadline.saturating_duration_since(Instant::now());
            match tokio::time::timeout(remaining, self.remote(job, action)).await {
                Ok(Ok(receipt)) => {
                    if let Some(row) = receipt.rows.first() {
                        if matches!(
                            row.state,
                            DownloadFileState::Completed
                                | DownloadFileState::Cancelled
                                | DownloadFileState::Failed
                        ) {
                            job.job.files[i].state = row.state;
                            job.job.files[i].bytes_transferred = row.bytes;
                        } else {
                            job.job.files[i].message = Some(
                                "Cancelamento solicitado; aguardando confirmação do backend."
                                    .into(),
                            );
                        }
                    }
                }
                _ => {
                    job.job.message=Some("Não foi possível confirmar todos os cancelamentos no slskd. A solicitação foi salva; atualize o lote para verificar novamente.".into());
                    break;
                }
            }
        }
        self.repository.save(job.clone()).await
    }
    pub(crate) async fn retry(&self, id: String) -> CoreResult<DownloadTransferJob> {
        let _guard = self.operations.lock().await;
        let mut job = self.repository.get(id).await?;
        if !self.settings().await?.enabled {
            return Err(invalid("Habilite as transferências nos Ajustes."));
        }
        self.reconcile(&mut job).await?;
        if let Some(index) = job.attempts.iter().position(|a| {
            a.indices
                .iter()
                .any(|i| job.job.files[*i as usize].state == DownloadFileState::Prepared)
        }) {
            job.job.cancel_requested = false;
            self.control(&job.job.job_id)
                .cancel
                .store(false, Ordering::SeqCst);
            self.submit(&mut job, index).await?;
            return Ok(job.job);
        }
        if job
            .job
            .files
            .iter()
            .any(|f| matches!(f.state, DownloadFileState::SubmissionUnknown))
        {
            return Err(invalid(
                "O envio de um lote ainda não foi confirmado. Atualize e confira o UUID no slskd; não será criado outro download sem conhecer o resultado anterior.",
            ));
        }
        let indices: Vec<_> = job
            .job
            .files
            .iter()
            .filter(|f| {
                matches!(
                    f.state,
                    DownloadFileState::Failed | DownloadFileState::Cancelled
                )
            })
            .map(|f| f.index)
            .collect();
        job.job.cancel_requested = false;
        self.control(&job.job.job_id)
            .cancel
            .store(false, Ordering::SeqCst);
        if !indices.is_empty() {
            if job.attempts.len() >= 20 {
                return Err(invalid("O limite de tentativas deste lote foi atingido."));
            }
            let previous = indices
                .iter()
                .filter_map(|i| {
                    let d = &job.details[*i as usize];
                    Some(SavedIdentity {
                        batch_id: d.batch_id.clone()?,
                        transfer_id: d.transfer_id.clone()?,
                        filename: job.job.files[*i as usize].filename.clone(),
                        size: job.job.files[*i as usize].size_bytes,
                    })
                })
                .collect();
            job.attempts.push(Attempt {
                not_submitted: false,
                id: crate::infrastructure::slskd_search::search_id()
                    .map_err(|_| invalid("Não foi possível criar a tentativa."))?,
                indices: indices.clone(),
                receipt_seen: false,
                previous,
            });
            for i in indices {
                job.details[i as usize].batch_id = None;
                job.details[i as usize].transfer_id = None;
                job.details[i as usize].review = None;
            }
            let index = job.attempts.len() - 1;
            self.submit(&mut job, index).await?;
        } else {
            self.repository.save(job.clone()).await?;
        }
        Ok(job.job)
    }
    pub(crate) async fn pending_import(
        &self,
        id: String,
        index: u32,
    ) -> CoreResult<DownloadImportPreview> {
        let job = self.repository.get(id).await?;
        let i = index as usize;
        let file = job
            .job
            .files
            .get(i)
            .filter(|f| f.state == DownloadFileState::Importing)
            .ok_or_else(|| invalid("Não há uma importação pendente para este arquivo."))?;
        let review = job.details[i]
            .review
            .as_ref()
            .ok_or_else(|| invalid("A revisão não está disponível."))?;
        let journal = job.details[i]
            .import
            .as_ref()
            .ok_or_else(|| invalid("O registro da importação não está disponível."))?;
        self.control(&job.job.job_id)
            .cancel
            .store(false, Ordering::SeqCst);
        Ok(DownloadImportPreview {
            target_track_id: journal.target,
            resuming: true,
            review_token: review.token.clone(),
            job_id: job.job.job_id,
            file_index: index,
            title: review.metadata.title.clone().unwrap_or_default(),
            artist: review
                .metadata
                .artist
                .clone()
                .unwrap_or_else(|| "Artista não informado".into()),
            release: review
                .metadata
                .release
                .clone()
                .unwrap_or_else(|| "Álbum não informado".into()),
            duration_seconds: review.metadata.duration,
            size_bytes: file.size_bytes,
            destination: journal.destination.clone(),
        })
    }
    pub(crate) async fn inspect_file(
        &self,
        id: String,
        index: u32,
        path: String,
    ) -> CoreResult<DownloadImportPreview> {
        let _guard = self.operations.lock().await;
        let mut job = self.repository.get(id).await?;
        let i = index as usize;
        if job.job.files.get(i).is_none_or(|f| {
            !matches!(
                f.state,
                DownloadFileState::Completed | DownloadFileState::Importing
            )
        }) {
            return Err(invalid(
                "Somente arquivos com conclusão confirmada podem ser revisados. Arquivos incompletos não podem ser importados.",
            ));
        }
        let control = self.control(&job.job.job_id);
        control.cancel.store(false, Ordering::SeqCst);
        let (review, preview) = acquisition_files::inspect(
            job.job.clone(),
            index,
            path,
            self.covers.clone(),
            control.cancel.clone(),
        )
        .await?;
        job.details[i].review = Some(review);
        job.details[i].import = None;
        job.job.files[i].state = DownloadFileState::Completed;
        self.repository.save(job).await?;
        Ok(preview)
    }
    pub(crate) async fn import_file(
        &self,
        id: String,
        index: u32,
        token: String,
        target: Option<i64>,
        confirmed: bool,
    ) -> CoreResult<DownloadTransferJob> {
        let _guard = self.operations.lock().await;
        let _lane = self.metadata_lane.lock().await;
        let mut job = self.repository.get(id).await?;
        let i = index as usize;
        if !confirmed || target.is_some_and(|n| n < 0) || i >= job.job.files.len() {
            return Err(invalid(
                "Revise a gravação, o arquivo e o destino da associação antes de confirmar.",
            ));
        }
        let review = job.details[i]
            .review
            .clone()
            .filter(|r| r.token == token)
            .ok_or_else(|| invalid("A revisão expirou; localize e confira novamente o arquivo."))?;
        if let Some(journal) = &job.details[i].import {
            if journal.target != target || journal.token != token || journal.digest != review.digest
            {
                return Err(invalid(
                    "Esta importação já possui outro destino confirmado.",
                ));
            }
            if job.job.files[i].state == DownloadFileState::Imported {
                return Ok(job.job);
            }
        }
        if !matches!(
            job.job.files[i].state,
            DownloadFileState::Completed | DownloadFileState::Importing
        ) {
            return Err(invalid("O arquivo ainda não foi concluído."));
        }
        let destination =
            acquisition_files::destination(&job.job, &job.job.files[i], &review.extension)?;
        job.details[i].import = Some(ImportJournal {
            target,
            destination: destination.clone(),
            digest: review.digest.clone(),
            token,
        });
        job.job.files[i].state = DownloadFileState::Importing;
        self.repository.save(job.clone()).await?;
        let cancel = self.control(&job.job.job_id).cancel.clone();
        let result = acquisition_files::materialize(
            job.job.clone(),
            index,
            review,
            destination.clone(),
            self.covers.clone(),
            cancel.clone(),
        )
        .await;
        let metadata = match result {
            Ok(md) => md,
            Err(e) => {
                job.job.files[i].message=Some("A importação não foi concluída. O arquivo não foi adicionado à biblioteca; confira o mapeamento e tente novamente.".into());
                self.repository.save(job).await?;
                return Err(e);
            }
        };
        match self
            .repository
            .commit_import(job.clone(), index, metadata, cancel)
            .await
        {
            Ok(saved) => Ok(saved.job),
            Err(error) => {
                job.details[i].import = None;
                job.job.files[i].state = DownloadFileState::Completed;
                job.job.files[i].message = Some(
                    "A associação não foi confirmada. Confira o destino e tente novamente.".into(),
                );
                self.repository.save(job).await?;
                Err(error)
            }
        }
    }
}
fn transfer_error(error: crate::domain::music::plugins::PluginError) -> String {
    use crate::domain::music::{IntegrationError as E, plugins::PluginError as P};
    match error {
        P::Disabled|P::NotRegistered=>"A integração slskd está desativada. Os registros locais foram preservados.",
        P::Adapter(E::AuthenticationRequired)=>"A chave slskd foi recusada. Confira os Ajustes; nenhum outro backend será usado.",
        P::Adapter(E::AccessDenied)=>"A configuração da instância mudou ou já existe um download que não pertence a este lote. Confira o slskd antes de prosseguir.",
        P::Timeout|P::Adapter(E::Timeout)=>"A conexão excedeu o tempo de espera. A rede pode limitar o slskd. Atualize para reconciliar o mesmo lote; o envio não será repetido automaticamente.",
        P::Adapter(E::NotFound)=>"O lote não foi encontrado no slskd. O registro local foi preservado e nenhum envio foi repetido.",
        P::Adapter(E::RateLimited{..})=>"O slskd pediu para aguardar. Atualize mais tarde.",
        P::Cancelled|P::Adapter(E::Cancelled)=>"Operação interrompida. Atualize para verificar o estado do lote no slskd.",
        _=>"Não foi possível confirmar o estado do lote. Confira a instância, a compatibilidade da API e as restrições da rede.",
    }.into()
}
