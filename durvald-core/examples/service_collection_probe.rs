//! Opt-in metadata API proof. Every phase runs in a separate process and uses
//! an exclusively created library. Never plays media or writes remote accounts.
use durvald_core::*;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{collections::BTreeMap, path::Path, sync::Arc};
type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;

#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
struct Target {
    provider: ServiceProvider,
    single_url: String,
    collection_url: String,
    max_pages: u32,
}
#[derive(Deserialize, Serialize)]
struct Owner {
    target: Target,
    keychain_service: String,
}
#[derive(Deserialize, Serialize)]
struct Checkpoint {
    single: String,
    collection: String,
    selected: Vec<String>,
    imported: Vec<(String, i64)>,
}
fn check(ok: bool) -> Result<()> {
    if ok {
        Ok(())
    } else {
        Err("probe_assertion_failed".into())
    }
}
fn write(root: &Path, name: &str, value: &impl Serialize) -> Result<()> {
    let pending = root.join(format!("{name}.pending"));
    std::fs::write(&pending, serde_json::to_vec_pretty(value)?)?;
    std::fs::rename(pending, root.join(name))?;
    Ok(())
}
fn credential_name(provider: ServiceProvider) -> Result<&'static str> {
    match provider {
        ServiceProvider::SoundCloud => Ok("SOUNDCLOUD_ACCESS_TOKEN"),
        ServiceProvider::YouTube => Ok("YOUTUBE_API_KEY"),
        ServiceProvider::Bandcamp => Err("unsupported_probe_provider".into()),
    }
}
fn isolated(root: &Path, target: &Target, fresh: bool) -> Result<CoreConfig> {
    check(root.is_absolute())?;
    if fresh {
        // create_dir refuses existing directories, including the user's library.
        let mut builder = std::fs::DirBuilder::new();
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            builder.mode(0o700);
        }
        builder.create(root)?;
        let nonce = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)?
            .as_nanos();
        let id = format!(
            "{:x}",
            Sha256::digest(format!("{}:{nonce}", root.display()))
        );
        write(
            root,
            "owner.json",
            &Owner {
                target: target.clone(),
                keychain_service: format!("durvald-collection-proof-{id}"),
            },
        )?;
    }
    check(!root.symlink_metadata()?.file_type().is_symlink())?;
    let owner: Owner = serde_json::from_slice(&std::fs::read(root.join("owner.json"))?)?;
    check(
        owner.target == *target
            && owner
                .keychain_service
                .starts_with("durvald-collection-proof-"),
    )?;
    for name in ["library.sqlite", "app-support", "covers"] {
        if let Ok(meta) = root.join(name).symlink_metadata() {
            check(!meta.file_type().is_symlink())?;
        }
    }
    Ok(CoreConfig {
        database_path: root.join("library.sqlite").to_string_lossy().into(),
        app_support_dir: root.join("app-support").to_string_lossy().into(),
        covers_dir: root.join("covers").to_string_lossy().into(),
        keychain_service: owner.keychain_service,
    })
}
fn healthy(job: &ServiceCollectionJob) -> Result<()> {
    check(job.failure.is_none())
}
fn receipts(job: &ServiceCollectionJob) -> Vec<(String, i64)> {
    job.items
        .iter()
        .filter_map(|i| i.saved_track_id.map(|id| (i.occurrence_id.clone(), id)))
        .collect()
}
async fn phase(
    core: &Arc<DurvaldCore>,
    target: &Target,
    root: &Path,
    name: &str,
    positions: &[u32],
) -> Result<Value> {
    if name == "capture" {
        let single = core
            .begin_service_collection_import(target.single_url.clone())
            .await?;
        let collection = core
            .begin_service_collection_import(target.collection_url.clone())
            .await?;
        check(
            single.provider == target.provider
                && !single.is_collection
                && collection.provider == target.provider
                && collection.is_collection,
        )?;
        write(
            root,
            "checkpoint.json",
            &Checkpoint {
                single: single.job_id.clone(),
                collection: collection.job_id.clone(),
                selected: vec![],
                imported: vec![],
            },
        )?;
        let single = core
            .load_service_collection_page(single.job_id, true)
            .await?;
        write(root, "single.json", &single)?;
        healthy(&single)?;
        check(single.complete && single.items.len() == 1 && single.items[0].entry.is_some())?;
        let first = core
            .load_service_collection_page(collection.job_id.clone(), true)
            .await?;
        write(root, "review.json", &first)?;
        healthy(&first)?;
        check(first.loaded_pages == 1 && !first.items.is_empty())?;
        let cancelled = core
            .cancel_service_collection_import(collection.job_id)
            .await?;
        check(cancelled.cancelled && cancelled.items == first.items)?;
        check(core.tracks_page(1, 0).await?.items.is_empty())?;
        return Ok(
            json!({"single_observed":true,"first_page_items":first.items.len(),"cancelled_without_import":true}),
        );
    }
    let mut saved: Checkpoint =
        serde_json::from_slice(&std::fs::read(root.join("checkpoint.json"))?)?;
    let mut job = core
        .service_collection_import(saved.collection.clone())
        .await?;
    if name == "resume" {
        let captured: ServiceCollectionJob =
            serde_json::from_slice(&std::fs::read(root.join("review.json"))?)?;
        check(job.items == captured.items && job.loaded_pages == captured.loaded_pages)?;
        let before = job.items.clone();
        job = core.resume_service_collection_import(job.job_id).await?;
        check(!job.cancelled && job.items == before)?;
        while !job.complete && job.loaded_pages < target.max_pages {
            job = core.load_service_collection_page(job.job_id, true).await?;
            write(root, "review.json", &job)?;
            healthy(&job)?;
        }
        check(job.items.starts_with(&before))?;
        check(job.items.windows(2).all(|w| w[0].position < w[1].position))?;
        check(core.tracks_page(1, 0).await?.items.is_empty())?;
        return Ok(
            json!({"restart_preserved_capture":true,"pages":job.loaded_pages,"pagination_observed":job.loaded_pages>1,"items":job.items.len(),"complete":job.complete,"truncated":job.truncated,"bounded_partial":!job.complete,"unavailable_observed":job.items.iter().any(|i|i.access==ServiceMediaAccess::Unavailable)}),
        );
    }
    healthy(&job)?;
    if name == "import" {
        let resumed: Value =
            serde_json::from_slice(&std::fs::read(root.join("resume-result.json"))?)?;
        check(resumed["status"] == "passed")?;
        check(!positions.is_empty() && saved.imported.is_empty())?;
        saved.selected = positions
            .iter()
            .map(|p| {
                job.items
                    .iter()
                    .find(|i| {
                        i.position == *p
                            && i.entry.is_some()
                            && matches!(
                                i.access,
                                ServiceMediaAccess::Unknown
                                    | ServiceMediaAccess::StreamObserved
                                    | ServiceMediaAccess::Preview
                            )
                    })
                    .map(|i| i.occurrence_id.clone())
                    .ok_or("unimportable_position")
            })
            .collect::<std::result::Result<_, _>>()?;
        write(root, "checkpoint.json", &saved)?;
        job = core
            .import_service_collection_items(job.job_id, saved.selected.clone(), true)
            .await?;
        healthy(&job)?;
        saved.imported = receipts(&job);
        check(
            saved
                .selected
                .iter()
                .all(|id| saved.imported.iter().any(|(occ, _)| occ == id)),
        )?;
        for (_, id) in &saved.imported {
            core.set_track_favorite(*id, true).await?;
        }
        write(root, "checkpoint.json", &saved)?;
        return Ok(
            json!({"reviewed_occurrences_imported":saved.imported.len(),"isolated_library":true}),
        );
    }
    check(name == "verify" && !saved.imported.is_empty() && receipts(&job) == saved.imported)?;
    let tracks = core.tracks_page(200, 0).await?;
    let playlist = job.playlist_id.ok_or("missing_playlist")?;
    let before_playlist = core.playlist_tracks(playlist).await?;
    let mut sources = vec![];
    for (_, id) in &saved.imported {
        sources.push((*id, core.track_sources(*id).await?));
    }
    let repeated = core
        .import_service_collection_items(job.job_id, saved.selected, true)
        .await?;
    check(receipts(&repeated) == saved.imported && repeated.playlist_id == Some(playlist))?;
    check(
        core.tracks_page(200, 0).await?.items == tracks.items
            && core.playlist_tracks(playlist).await? == before_playlist,
    )?;
    for (id, before) in sources {
        check(core.track_sources(id).await? == before && core.track(id).await?.is_favorite)?;
    }
    Ok(
        json!({"restart_restored_receipts":true,"reimport_idempotent":true,"sources_and_playlist_preserved":true,"personal_favorites_preserved":true}),
    )
}
#[tokio::main]
async fn main() {
    if run().await.is_err() {
        eprintln!(
            "Collection proof failed. Inspect the isolated result; credentials and external messages are never printed."
        );
        std::process::exit(1);
    }
}
async fn run() -> Result<()> {
    let args: Vec<_> = std::env::args().collect();
    check((5..=6).contains(&args.len()))?;
    let name = args[3].as_str();
    check(["capture", "resume", "import", "verify", "cleanup"].contains(&name))?;
    let targets: BTreeMap<String, Target> = serde_json::from_slice(&std::fs::read(&args[1])?)?;
    let target = targets.get(&args[2]).ok_or("unknown_target")?;
    check((2..=5).contains(&target.max_pages))?;
    let env = credential_name(target.provider)?;
    let credential = std::env::var(env).ok().filter(|s| !s.is_empty());
    if credential.is_none() && name != "cleanup" {
        println!(
            "{}",
            json!({"status":"blocked","reason":"missing_credential","required_environment":env,"network_attempted":false,"library_opened":false})
        );
        return Ok(());
    }
    let positions: Vec<u32> = args
        .get(5)
        .map(|s| s.split(',').map(str::parse).collect())
        .transpose()?
        .unwrap_or_default();
    check((name == "import") == !positions.is_empty())?;
    let root = Path::new(&args[4]);
    let core = DurvaldCore::open(isolated(root, target, name == "capture")?).await?;
    let result = async {
        if name == "cleanup" {
            return Ok(json!({"cleanup_requested":true}));
        }
        core.configure_service_import(target.provider, true, credential)
            .await?;
        phase(&core, target, root, name, &positions).await
    }
    .await;
    // Executed even after configuration, request or assertion failure. Only the
    // proof's unique Keychain service is touched, never the real app's key.
    let cleanup = core
        .configure_service_import(target.provider, false, Some(String::new()))
        .await;
    let cleanup_confirmed = cleanup.as_ref().is_ok_and(|s| {
        s.iter()
            .any(|s| s.provider == target.provider && !s.enabled && !s.has_credential)
    });
    let report = match &result {
        Ok(checks) => {
            json!({"status":"passed","checks":checks,"credential_cleanup_confirmed":cleanup_confirmed})
        }
        Err(_) => {
            json!({"status":"failed","credential_cleanup_confirmed":cleanup_confirmed,"external_error_omitted":true})
        }
    };
    write(root, &format!("{name}-result.json"), &report)?;
    println!("{report}");
    cleanup?;
    check(cleanup_confirmed)?;
    result?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn target() -> Target {
        Target {
            provider: ServiceProvider::YouTube,
            single_url: "https://www.youtube.com/watch?v=nlUHDmSf_WY".into(),
            collection_url:
                "https://www.youtube.com/playlist?list=PLgf-8GQFjABq2XqYIaYD4C_uIZ4jLL4x-".into(),
            max_pages: 3,
        }
    }
    #[test]
    fn refuses_existing_library_and_cross_target_reuse() {
        let parent = tempfile::tempdir().unwrap();
        assert!(isolated(parent.path(), &target(), true).is_err());
        let root = parent.path().join("proof");
        let first = isolated(&root, &target(), true).unwrap();
        let reopened = isolated(&root, &target(), false).unwrap();
        assert_eq!(first.database_path, reopened.database_path);
        assert_eq!(first.keychain_service, reopened.keychain_service);
        let mut changed = target();
        changed.provider = ServiceProvider::SoundCloud;
        assert!(isolated(&root, &changed, false).is_err());
    }
    #[test]
    fn checked_in_targets_have_no_tracking_parameters() {
        let targets: BTreeMap<String, Target> = serde_json::from_str(include_str!(
            "../../tools/provider-probes/fixtures/service-collection-targets.json"
        ))
        .unwrap();
        assert_eq!(targets.len(), 2);
        for target in targets.values() {
            credential_name(target.provider).unwrap();
            for raw in [&target.single_url, &target.collection_url] {
                let url = url::Url::parse(raw).unwrap();
                assert!(
                    url.query_pairs()
                        .all(|(key, _)| ["v", "list"].contains(&key.as_ref()))
                );
            }
        }
    }
}
