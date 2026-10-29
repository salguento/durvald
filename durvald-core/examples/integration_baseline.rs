//! Isolated release baseline: synthetic library, muted native WAV, no remote calls.
use durvald_core::*;
use serde_json::json;
use std::{
    path::PathBuf,
    time::{Duration, Instant},
};

fn emit(value: serde_json::Value) {
    println!("DURVALD_BASELINE {}", value);
}
fn summary(name: &str, mut samples: Vec<f64>, budget: f64) -> serde_json::Value {
    samples.sort_by(f64::total_cmp);
    let p95 = samples[(samples.len() * 95).div_ceil(100) - 1];
    json!({"metric":name,"samples":samples.len(),"p95_ms":p95,"budget_ms":budget,"passed":p95<=budget})
}
#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let dir = PathBuf::from(
        std::env::args()
            .nth(1)
            .ok_or("isolated directory required")?,
    );
    if !dir.join("baseline-fixture.wav").is_file() || dir.join("library.sqlite").exists() {
        return Err("use a fresh fixture directory".into());
    }
    let dir = dir.canonicalize()?;
    let wav = dir.join("baseline-fixture.wav");
    let config = CoreConfig {
        database_path: dir.join("library.sqlite").to_string_lossy().into(),
        app_support_dir: dir.to_string_lossy().into(),
        covers_dir: dir.join("covers").to_string_lossy().into(),
        keychain_service: "durvald-isolated-baseline".into(),
    };
    let start = Instant::now();
    let core = DurvaldCore::open(config).await?;
    let startup = start.elapsed().as_secs_f64() * 1000.;
    // All integrations are optional; no request/credential probe is made here.
    let mut db = rusqlite::Connection::open(dir.join("library.sqlite"))?;
    // Every fixture path is constructed under the canonical absolute temp root.
    // Identity is therefore already normalized, matching the core's SQLite key.
    db.create_scalar_function("durvald_local_path_key", 1, rusqlite::functions::FunctionFlags::SQLITE_UTF8 | rusqlite::functions::FunctionFlags::SQLITE_DETERMINISTIC | rusqlite::functions::FunctionFlags::SQLITE_INNOCUOUS, |ctx| ctx.get::<String>(0))?;
    let tx = db.transaction()?;
    tx.execute(
        "INSERT INTO artists(artist_id,name) VALUES(1,'Baseline Artist')",
        [],
    )?;
    tx.execute("INSERT INTO releases(release_id,title,artist_id,artist_name) VALUES(1,'Baseline Album',1,'Baseline Artist')",[])?;
    for id in 1..=5000 {
        tx.execute("INSERT INTO songs(song_id,title,artist_id,artist_name,release_id,release_title,track_number,disc_number,duration,file_path) VALUES(?1,?2,1,'Baseline Artist',1,'Baseline Album',?1,1,60,?3)",rusqlite::params![id,format!("Fixture {id:05}"),if id==1 { wav.to_string_lossy().to_string() } else {dir.join(format!("unopened-{id}.wav")).to_string_lossy().to_string()}])?;
    }
    tx.commit()?;
    drop(db);
    let mut metrics = vec![json!({"metric":"core_startup","samples":1,"elapsed_ms":startup})];
    for (name, budget) in [
        ("local_list_warm", 200.),
        ("local_detail_warm", 300.),
        ("local_search_warm", 200.),
    ] {
        let mut values = Vec::new();
        for index in 0..51 {
            let start = Instant::now();
            match name {
                "local_list_warm" => {
                    assert_eq!(core.tracks_page(100, 0).await?.items.len(), 100);
                }
                "local_detail_warm" => {
                    assert_eq!(core.track_info(1).await?.track.id, 1);
                }
                _ => {
                    let _ = core.search("Fixture 00001".into()).await?;
                }
            }
            let ms = start.elapsed().as_secs_f64() * 1000.;
            if index == 0 {
                metrics.push(
                    json!({"metric":name.replace("warm","first"),"samples":1,"elapsed_ms":ms}),
                );
            } else {
                values.push(ms);
            }
        }
        metrics.push(summary(name, values, budget));
    }
    core.set_volume(0.).await?;
    let mut preparation = Vec::new();
    let mut buffering = Vec::new();
    let mut click = Vec::new();
    for _ in 0..20 {
        let start = Instant::now();
        core.play(1).await?;
        preparation.push(start.elapsed().as_secs_f64() * 1000.);
        let prepared = Instant::now();
        loop {
            let state = core.playback().await;
            if state.position_seconds > 0. {
                break;
            }
            if start.elapsed() > Duration::from_secs(3) {
                return Err("native playback did not advance".into());
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        buffering.push(prepared.elapsed().as_secs_f64() * 1000.);
        click.push(start.elapsed().as_secs_f64() * 1000.);
        core.stop().await?;
    }
    metrics.push(summary("native_prepare", preparation, 3000.));
    metrics.push(summary("native_buffer_observation", buffering, 3000.));
    metrics.push(summary("native_click_to_advancing_position", click, 3000.));
    emit(json!({"phase":"idle"}));
    tokio::time::sleep(Duration::from_secs(10)).await;
    emit(json!({"phase":"playback"}));
    core.play(1).await?;
    tokio::time::sleep(Duration::from_secs(10)).await;
    core.stop().await?;
    emit(
        json!({"phase":"result","metrics":metrics,"diagnostics":core.integration_diagnostics().await,"native_audio":"real renderer; silent PCM WAV 44.1 kHz stereo; volume 0","library_tracks":5000,"remote_requests_issued":0,"limitations":["core only; excludes SwiftUI and WebKit","no claim about remote latency, bandwidth or SDK buffering","first access is not a flushed OS disk cache"]}),
    );
    Ok(())
}
