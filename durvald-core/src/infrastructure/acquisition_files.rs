//! Validated, bounded file access for explicitly reviewed acquisition imports.
use crate::{
    api::*,
    application::download_transfers::{ReviewedFile, invalid},
};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
};
pub(crate) fn supported(path: &str) -> bool {
    Path::new(path)
        .extension()
        .and_then(|s| s.to_str())
        .is_some_and(|s| {
            crate::audio::SUPPORTED_AUDIO_EXTENSIONS.contains(&s.to_ascii_lowercase().as_str())
        })
}
fn check(cancel: &AtomicBool) -> CoreResult<()> {
    if cancel.load(Ordering::SeqCst) {
        Err(invalid("Importação cancelada."))
    } else {
        Ok(())
    }
}
fn directory(path: &str) -> CoreResult<PathBuf> {
    let p = Path::new(path);
    if !p.is_absolute() {
        return Err(invalid("Escolha uma pasta absoluta existente."));
    }
    let p = p
        .canonicalize()
        .map_err(|_| invalid("A pasta não está acessível. Confira a montagem e as permissões."))?;
    if !p.is_dir() {
        return Err(invalid("Escolha uma pasta existente."));
    }
    Ok(p)
}
pub(crate) async fn validate_settings(
    mut settings: DownloadTransferSettings,
) -> CoreResult<DownloadTransferSettings> {
    tokio::task::spawn_blocking(move||{
        if !settings.enabled||!settings.mapping_confirmed {return Err(invalid("Habilite as transferências e confirme o mapeamento da pasta de arquivos concluídos."));}
        let root=&settings.remote_download_root;
        let absolute=root.starts_with('/')||(root.len()>2&&root.as_bytes()[0].is_ascii_alphabetic()&&root.as_bytes()[1]==b':'&&matches!(root.as_bytes()[2],b'/'|b'\\'));
        if !absolute||root.len()>2048||root.chars().any(char::is_control)||root.replace('\\',"/").split('/').any(|c|c=="..") {return Err(invalid("Informe o diretório absoluto de downloads configurado no slskd."));}
        settings.mapped_download_root=directory(&settings.mapped_download_root)?.to_string_lossy().into();
        settings.library_destination=directory(&settings.library_destination)?.to_string_lossy().into();
        Ok(settings)
    }).await.map_err(|_|invalid("Não foi possível verificar as pastas."))?
}
fn mapped_file(job: &DownloadTransferJob, path: &str) -> CoreResult<PathBuf> {
    let root = directory(&job.mapped_download_root)?;
    let batch=root.join(&job.relative_destination).canonicalize().map_err(|_|invalid("A pasta deste lote ainda não está disponível no mapeamento. Localize os arquivos concluídos na pasta indicada pelo slskd."))?;
    let file = Path::new(path)
        .canonicalize()
        .map_err(|_| invalid("O arquivo concluído não está acessível neste computador."))?;
    if !batch.starts_with(&root) || !file.starts_with(&batch) || !file.is_file() {
        return Err(invalid(
            "Escolha um arquivo concluído dentro da pasta mapeada deste lote; caminhos do peer não são caminhos locais.",
        ));
    }
    Ok(file)
}
fn digest(path: &Path, cancel: &AtomicBool) -> CoreResult<String> {
    let mut file = fs::File::open(path).map_err(|_| invalid("Não foi possível ler o arquivo."))?;
    let mut h = Sha256::new();
    let mut block = [0u8; 65536];
    loop {
        check(cancel)?;
        let n = file
            .read(&mut block)
            .map_err(|_| invalid("Falha ao ler o arquivo."))?;
        if n == 0 {
            break;
        }
        h.update(&block[..n]);
    }
    Ok(format!("{:x}", h.finalize()))
}
pub(crate) fn destination(
    job: &DownloadTransferJob,
    file: &DownloadTransferFile,
    extension: &str,
) -> CoreResult<String> {
    if !super::slskd_transfers::uuid(&job.job_id)
        || !crate::audio::SUPPORTED_AUDIO_EXTENSIONS.contains(&extension)
    {
        return Err(invalid("Destino de importação inválido."));
    }
    let original = file.filename.replace('\\', "/");
    let stem = Path::new(&original)
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("audio");
    let name: String = stem
        .chars()
        .map(|c| {
            if c.is_alphanumeric() || matches!(c, ' ' | '-' | '_') {
                c
            } else {
                '_'
            }
        })
        .take(100)
        .collect();
    Ok(Path::new(&job.library_destination)
        .join(&job.job_id)
        .join(format!("{:04}-{}.{}", file.index, name.trim(), extension))
        .to_string_lossy()
        .into())
}
pub(crate) async fn inspect(
    job: DownloadTransferJob,
    index: u32,
    path: String,
    covers: String,
    cancel: Arc<AtomicBool>,
) -> CoreResult<(ReviewedFile, DownloadImportPreview)> {
    tokio::task::spawn_blocking(move || {
        check(&cancel)?;
        let file = job
            .files
            .get(index as usize)
            .ok_or_else(|| invalid("Arquivo não encontrado."))?;
        let path = mapped_file(&job, &path)?;
        let before = fs::metadata(&path).map_err(|_| invalid("Arquivo inacessível."))?;
        if before.len() != file.size_bytes || !supported(&path.to_string_lossy()) {
            return Err(invalid(
                "O tamanho ou formato do arquivo não corresponde ao download concluído.",
            ));
        }
        let extension = path
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("")
            .to_ascii_lowercase();
        let peer = file.filename.replace('\\', "/");
        if Path::new(&peer)
            .extension()
            .and_then(|e| e.to_str())
            .map(str::to_ascii_lowercase)
            != Some(extension.clone())
        {
            return Err(invalid(
                "A extensão do arquivo não corresponde à oferta escolhida.",
            ));
        }
        crate::audio::validate_acquired_audio(&path.to_string_lossy(), &cancel)
            .map_err(|m| invalid(&m))?;
        let mut metadata = crate::metadata::extract_metadata_blocking_with_cancel(
            &path.to_string_lossy(),
            Path::new(&covers),
            Some(&cancel),
        )
        .map_err(|_| invalid("Não foi possível ler os metadados do áudio."))?;
        let hash = digest(&path, &cancel)?;
        let after = fs::metadata(&path).map_err(|_| invalid("Arquivo inacessível."))?;
        if before.len() != after.len() || before.modified().ok() != after.modified().ok() {
            return Err(invalid(
                "O arquivo mudou durante a revisão. Aguarde sua conclusão e tente novamente.",
            ));
        }
        metadata.title = metadata
            .title
            .or_else(|| path.file_stem().map(|s| s.to_string_lossy().into()));
        let token = super::slskd_search::search_id()
            .map_err(|_| invalid("Não foi possível criar a revisão."))?;
        let preview = DownloadImportPreview {
            target_track_id: None,
            resuming: false,
            review_token: token.clone(),
            job_id: job.job_id.clone(),
            file_index: index,
            title: metadata.title.clone().unwrap_or_default(),
            artist: metadata
                .artist
                .clone()
                .unwrap_or_else(|| "Artista não informado".into()),
            release: metadata
                .release
                .clone()
                .unwrap_or_else(|| "Álbum não informado".into()),
            duration_seconds: metadata.duration,
            size_bytes: file.size_bytes,
            destination: destination(&job, file, &extension)?,
        };
        Ok((
            ReviewedFile {
                token,
                path: path.to_string_lossy().into(),
                digest: hash,
                extension,
                metadata,
            },
            preview,
        ))
    })
    .await
    .map_err(|_| invalid("Não foi possível validar o arquivo de áudio."))?
}
struct Pending(PathBuf);
impl Drop for Pending {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}
pub(crate) async fn materialize(
    job: DownloadTransferJob,
    index: u32,
    review: ReviewedFile,
    destination: String,
    covers: String,
    cancel: Arc<AtomicBool>,
) -> CoreResult<crate::metadata::AudioMetadata> {
    tokio::task::spawn_blocking(move||{
        check(&cancel)?;let file=&job.files[index as usize];let root=directory(&job.library_destination)?;
        let folder=root.join(&job.job_id);fs::create_dir_all(&folder).map_err(|_|invalid("Não foi possível criar a pasta de destino."))?;
        let folder=folder.canonicalize().map_err(|_|invalid("Pasta de destino inacessível."))?;
        if !folder.starts_with(&root){return Err(invalid("O destino aponta para fora da pasta escolhida."));}
        let destination=PathBuf::from(destination);if destination.parent()!=Some(folder.as_path()){return Err(invalid("O destino da importação mudou."));}
        if !destination.exists() {
            let source=mapped_file(&job,&review.path)?;
            if fs::metadata(&source).map_err(|_|invalid("Arquivo inacessível."))?.len()!=file.size_bytes{return Err(invalid("O arquivo mudou após a revisão."));}
            let temp=folder.join(format!(".durvald-{}.part",super::slskd_search::search_id().map_err(|_|invalid("Falha ao preparar a cópia."))?));
            let mut output=OpenOptions::new().write(true).create_new(true).open(&temp).map_err(|_|invalid("Não foi possível preparar uma cópia segura."))?;
            let pending=Pending(temp.clone());
            let mut input=fs::File::open(&source).map_err(|_|invalid("Arquivo inacessível."))?;let mut buffer=[0;65536];let mut copied=0u64;
            loop {check(&cancel)?;let n=input.read(&mut buffer).map_err(|_|invalid("Falha ao copiar o arquivo."))?;if n==0 {break;}copied+=n as u64;if copied>file.size_bytes{return Err(invalid("O arquivo mudou durante a cópia."));}output.write_all(&buffer[..n]).map_err(|_|invalid("Não foi possível gravar no destino."))?;}
            output.sync_all().map_err(|_|invalid("Não foi possível concluir a gravação."))?;drop(output);
            if copied!=file.size_bytes||digest(&temp,&cancel)?!=review.digest{return Err(invalid("A cópia não corresponde ao arquivo revisado."));}
            check(&cancel)?;
            match fs::hard_link(&temp,&destination) {Ok(())=>{},Err(e) if e.kind()==std::io::ErrorKind::AlreadyExists=>{},Err(_)=>return Err(invalid("O destino não permite publicar a cópia de forma segura. Escolha uma pasta local compatível."))}
            drop(pending);
        }
        let actual=destination.canonicalize().map_err(|_|invalid("O destino não está acessível."))?;
        if actual!=destination||!actual.starts_with(&folder)||fs::metadata(&actual).map_err(|_|invalid("Destino inacessível."))?.len()!=file.size_bytes||digest(&actual,&cancel)?!=review.digest {return Err(invalid("Já existe outro arquivo no destino ou a cópia foi alterada. Nada foi substituído."));}
        crate::audio::validate_acquired_audio(&actual.to_string_lossy(),&cancel).map_err(|m|invalid(&m))?;
        let mut md=crate::metadata::extract_metadata_blocking_with_cancel(&actual.to_string_lossy(),Path::new(&covers),Some(&cancel)).map_err(|_|invalid("Não foi possível validar os metadados da cópia."))?;
        md.title=md.title.or(review.metadata.title);check(&cancel)?;Ok(md)
    }).await.map_err(|_|invalid("A importação foi interrompida."))?
}
