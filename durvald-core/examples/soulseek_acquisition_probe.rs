//! Opt-in production acquisition probe. No media selected automatically.
//! Each invocation is one real process; the driver preserves an isolated journal.
use durvald_core::*;
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    path::{Path, PathBuf},
    sync::Arc,
    time::{Duration, Instant},
};
type ProbeResult<T> = Result<T, Box<dyn std::error::Error + Send + Sync>>;
#[derive(Deserialize)]
struct Selection {
    query: String,
    peer: String,
    filename: String,
    size_bytes: u64,
    remote_download_root: String,
    mapped_download_root: String,
}
#[derive(Deserialize)]
struct Input {
    root: PathBuf,
    endpoint: String,
    selection: Selection,
    transfer_timeout_seconds: u64,
}
fn verify(condition: bool, reason: &'static str) -> ProbeResult<()> {
    if condition {
        Ok(())
    } else {
        Err(reason.into())
    }
}
fn config(root: &Path) -> CoreConfig {
    CoreConfig {
        database_path: root.join("library.sqlite").to_string_lossy().into(),
        app_support_dir: root.join("app-support").to_string_lossy().into(),
        covers_dir: root.join("covers").to_string_lossy().into(),
        keychain_service: format!(
            "durvald-live-acquisition-{}",
            root.file_name().unwrap().to_string_lossy()
        ),
    }
}
async fn select(
    core: &Arc<DurvaldCore>,
    selection: &Selection,
) -> ProbeResult<DownloadTransferJob> {
    let session = core.download_search_session();
    let result = async {
        let mut page = session
            .search(
                DownloadSearchRequest {
                    query: selection.query.clone(),
                    expected_tracks: vec![],
                },
                1,
            )
            .await?;
        let deadline = Instant::now() + Duration::from_secs(45);
        loop {
            if let Some(group) = page.groups.iter().find(|g| {
                g.peer == selection.peer
                    && g.files.iter().any(|f| {
                        f.filename == selection.filename && f.size_bytes == selection.size_bytes
                    })
            }) {
                return Ok(session
                    .enqueue_download(
                        group.offer_id.clone(),
                        vec![selection.filename.clone()],
                        true,
                    )
                    .await?);
            }
            if let Some(failure) = page.failure {
                return Err(format!("search_failed:{failure:?}").into());
            }
            verify(
                page.state == DownloadSearchState::Searching && Instant::now() < deadline,
                "selected_file_not_observed",
            )?;
            tokio::time::sleep(Duration::from_secs(1)).await;
            page = session.poll(1).await?;
        }
    }
    .await;
    session.close().await;
    result
}
async fn wait_for_file(
    core: &Arc<DurvaldCore>,
    job_id: &str,
    seconds: u64,
) -> ProbeResult<DownloadTransferJob> {
    let deadline = Instant::now() + Duration::from_secs(seconds);
    loop {
        let job = core.refresh_download_transfer(job_id.into()).await?;
        let file = job.files.first().ok_or("missing_transfer_file")?;
        if matches!(
            file.state,
            DownloadFileState::Completed | DownloadFileState::Imported
        ) {
            return Ok(job);
        }
        verify(
            !matches!(
                file.state,
                DownloadFileState::Failed | DownloadFileState::Cancelled
            ),
            "transfer_failed",
        )?;
        verify(Instant::now() < deadline, "transfer_deadline")?;
        tokio::time::sleep(Duration::from_secs(2)).await;
    }
}
fn locate(job: &DownloadTransferJob) -> ProbeResult<PathBuf> {
    let file = job.files.first().ok_or("missing_transfer_file")?;
    let mapped = Path::new(&job.mapped_download_root).canonicalize()?;
    let directory = mapped.join(&job.relative_destination).canonicalize()?;
    verify(
        directory.starts_with(&mapped),
        "mapped_directory_outside_root",
    )?;
    let mut pending = vec![directory.clone()];
    let mut matches = vec![];
    let mut visited = 0;
    let filename = file.filename.replace('\\', "/");
    let basename = Path::new(&filename)
        .file_name()
        .ok_or("invalid_selected_name")?;
    while let Some(folder) = pending.pop() {
        for entry in std::fs::read_dir(folder)? {
            visited += 1;
            verify(visited <= 2000, "mapped_directory_limit")?;
            let entry = entry?;
            let kind = entry.file_type()?;
            if kind.is_symlink() {
                continue;
            }
            if kind.is_dir() {
                pending.push(entry.path());
            } else if kind.is_file()
                && entry.file_name() == basename
                && entry.metadata()?.len() == file.size_bytes
            {
                matches.push(entry.path());
            }
        }
    }
    verify(matches.len() == 1, "mapped_file_missing_or_ambiguous")?;
    Ok(matches.remove(0))
}
async fn phase(core: &Arc<DurvaldCore>, input: &Input, name: &str) -> ProbeResult<Value> {
    if name == "cleanup" {
        let mut requested = 0;
        let mut confirmed = true;
        for job in core.download_transfers().await? {
            if job.files.iter().all(|f| {
                matches!(
                    f.state,
                    DownloadFileState::Completed
                        | DownloadFileState::Imported
                        | DownloadFileState::Cancelled
                        | DownloadFileState::Failed
                )
            }) {
                continue;
            }
            requested += 1;
            let result = core.cancel_download_transfer(job.job_id).await?;
            confirmed &= result.files.iter().all(|f| {
                matches!(
                    f.state,
                    DownloadFileState::Completed
                        | DownloadFileState::Imported
                        | DownloadFileState::Cancelled
                        | DownloadFileState::Failed
                )
            });
        }
        return Ok(
            json!({"owned_jobs_cancel_requested": requested, "cancel_confirmed": confirmed}),
        );
    }
    let checkpoint = input.root.join("checkpoint.json");
    if name == "transfer" {
        verify(
            core.tracks_page(1, 0).await?.items.is_empty(),
            "probe_library_not_empty",
        )?;
        std::fs::create_dir_all(input.root.join("library"))?;
        core.configure_download_transfers(DownloadTransferSettings {
            enabled: true,
            remote_download_root: input.selection.remote_download_root.clone(),
            mapped_download_root: input.selection.mapped_download_root.clone(),
            library_destination: input.root.join("library").to_string_lossy().into(),
            mapping_confirmed: true,
        })
        .await?;
        let job = select(core, &input.selection).await?;
        // Persist immediately: timeout/restart must reconcile this exact job.
        std::fs::write(
            &checkpoint,
            serde_json::to_vec(&json!({"job_id":job.job_id}))?,
        )?;
        let job = wait_for_file(core, &job.job_id, input.transfer_timeout_seconds).await?;
        verify(
            job.files.len() == 1 && job.files[0].state == DownloadFileState::Completed,
            "completion_not_confirmed",
        )?;
        verify(
            core.tracks_page(1, 0).await?.items.is_empty(),
            "download_imported_implicitly",
        )?;
        return Ok(
            json!({"explicit_file_found":true,"backend_completion_confirmed":true,"no_implicit_library_import":true,"bytes":job.files[0].size_bytes}),
        );
    }
    let saved: Value = serde_json::from_slice(&std::fs::read(&checkpoint)?)?;
    let id = saved["job_id"].as_str().ok_or("missing_job_checkpoint")?;
    let jobs = core.download_transfers().await?;
    let job = jobs
        .iter()
        .find(|j| j.job_id == id)
        .ok_or("persisted_job_missing")?;
    if name == "import" {
        verify(
            job.files[0].state == DownloadFileState::Completed,
            "completion_not_restored",
        )?;
        let path = locate(job)?;
        let preview = core
            .inspect_download_file(id.into(), 0, path.to_string_lossy().into())
            .await?;
        verify(preview.duration_seconds > 0., "audio_not_validated")?;
        let imported = core
            .import_download_file(id.into(), 0, preview.review_token.clone(), None, true)
            .await?;
        let track = imported.files[0]
            .imported_track_id
            .ok_or("imported_track_missing")?;
        verify(
            imported.files[0].state == DownloadFileState::Imported,
            "import_not_committed",
        )?;
        core.set_track_favorite(track, true).await?;
        // Keep the reviewed receipt privately for re-delivery in another process.
        std::fs::write(
            &checkpoint,
            serde_json::to_vec(
                &json!({"job_id":id,"track_id":track,"review_token":preview.review_token}),
            )?,
        )?;
        return Ok(
            json!({"job_restored_in_new_process":true,"mapped_audio_decoded":true,"reviewed_import_committed":true}),
        );
    }
    verify(name == "verify", "unsupported_phase")?;
    let track = saved["track_id"]
        .as_i64()
        .ok_or("missing_track_checkpoint")?;
    let token = saved["review_token"]
        .as_str()
        .ok_or("missing_review_checkpoint")?;
    verify(
        job.files[0].state == DownloadFileState::Imported
            && job.files[0].imported_track_id == Some(track),
        "import_receipt_not_restored",
    )?;
    let before = core.track_sources(track).await?;
    let imported = core
        .import_download_file(id.into(), 0, token.into(), None, true)
        .await?;
    verify(
        imported.files[0].imported_track_id == Some(track),
        "reimport_changed_track",
    )?;
    verify(
        core.tracks_page(2, 0).await?.items.len() == 1,
        "duplicate_track",
    )?;
    verify(
        core.track_sources(track).await? == before,
        "duplicate_or_changed_source",
    )?;
    verify(core.track(track).await?.is_favorite, "personal_value_lost")?;
    Ok(
        json!({"import_restored_in_new_process":true,"reimport_idempotent":true,"one_canonical_track":true,"sources_unchanged":true,"personal_value_preserved":true}),
    )
}
#[tokio::main]
async fn main() {
    let result = run().await;
    // Never print provider identities, paths, query, credentials or external errors.
    if result.is_err() {
        eprintln!("Acquisition probe failed; inspect the private journal, not shared logs.");
        std::process::exit(1);
    }
}
async fn run() -> ProbeResult<()> {
    let args: Vec<_> = std::env::args().collect();
    verify(
        args.len() == 3 && ["transfer", "import", "verify", "cleanup"].contains(&args[2].as_str()),
        "expected_config_and_phase",
    )?;
    let input: Input = serde_json::from_slice(&std::fs::read(&args[1])?)?;
    verify(
        input.root.is_absolute() && input.root.is_dir(),
        "isolated_root_required",
    )?;
    verify(
        (10..=600).contains(&input.transfer_timeout_seconds),
        "invalid_timeout",
    )?;
    let key = std::env::var("SLSKD_API_KEY")?;
    let core = DurvaldCore::open(config(&input.root)).await?;
    let result = async {
        core.configure_download_search(input.endpoint.clone(), Some(key), true, true)
            .await?;
        phase(&core, &input, &args[2]).await
    }
    .await;
    let mut cancellation = json!({"needed":false});
    if result.is_err() && args[2] == "transfer" {
        cancellation = json!({"needed":true,"requested":false,"confirmed":false});
        if let Ok(jobs) = core.download_transfers().await {
            for job in jobs {
                if let Ok(cancelled) = core.cancel_download_transfer(job.job_id).await {
                    cancellation = json!({"needed":true,"requested":true,"confirmed":cancelled.files.iter().all(|f|matches!(f.state,DownloadFileState::Completed|DownloadFileState::Imported|DownloadFileState::Cancelled|DownloadFileState::Failed))});
                }
            }
        }
    }
    // Every phase removes its isolated credential, including phase failure.
    let cleanup = core
        .configure_download_search(input.endpoint.clone(), Some(String::new()), false, true)
        .await;
    let checks = match result {
        Ok(checks) => checks,
        Err(error) => {
            // Diagnostic stays inside the private probe workspace, never exported.
            std::fs::write(input.root.join("private-error.txt"), error.to_string())?;
            std::fs::write(
                input.root.join(format!("{}-result.json", args[2])),
                serde_json::to_vec(
                    &json!({"status":"limited","credential_cleanup_confirmed":cleanup.is_ok(),"transfer_cleanup":cancellation}),
                )?,
            )?;
            return Err(error);
        }
    };
    cleanup?;
    std::fs::write(
        input.root.join(format!("{}-result.json", args[2])),
        serde_json::to_vec(
            &json!({"status":"passed","checks":checks,"credential_cleanup_confirmed":true}),
        )?,
    )?;
    Ok(())
}
