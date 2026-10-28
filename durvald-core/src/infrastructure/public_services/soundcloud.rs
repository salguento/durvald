use super::*;
use serde_json::Value;
fn api() -> Url {
    Url::parse("https://api.soundcloud.com/").unwrap()
}
fn reference(v: &Value) -> Option<String> {
    text(v, "urn")
        .filter(|s| s.starts_with("soundcloud:tracks:"))
        .or_else(|| {
            v.get("id")
                .and_then(|v| v.as_u64())
                .map(|n| format!("soundcloud:tracks:{n}"))
        })
}
async fn resolve(
    http: &dyn ServiceHttp,
    headers: HeaderMap,
    location: &Location,
) -> Result<Value, E> {
    let mut u = api().join("resolve").unwrap();
    u.query_pairs_mut().append_pair("url", &location.url);
    let response = http.get(u, headers.clone()).await?;
    if response.status == 302 {
        let next = api()
            .join(response.location.as_deref().ok_or(E::InvalidResponse)?)
            .map_err(|_| E::InvalidResponse)?;
        let parts: Vec<_> = next.path_segments().ok_or(E::InvalidResponse)?.collect();
        if next.scheme() != "https"
            || next.host_str() != Some("api.soundcloud.com")
            || next.port().is_some()
            || !next.username().is_empty()
            || next.password().is_some()
            || parts.len() != 2
            || parts[0]
                != if location.collection {
                    "playlists"
                } else {
                    "tracks"
                }
            || parts[1].len() > 128
            || !parts[1]
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b':' | b'%' | b'-' | b'_'))
        {
            return Err(E::InvalidResponse);
        }
        let mut safe = api();
        safe.set_path(next.path());
        safe.query_pairs_mut()
            .append_pair("access", "playable,preview,blocked");
        if location.collection {
            safe.query_pairs_mut().append_pair("show_tracks", "true");
        }
        json(http, safe, headers).await
    } else {
        status(&response)?;
        serde_json::from_slice(&response.body).map_err(|_| E::InvalidResponse)
    }
}
fn track_entry(v: &Value) -> Option<CatalogEntry> {
    let url = text(v, "permalink_url")?;
    entry(
        &url,
        text(v, "title")?,
        text(v, "metadata_artist").or_else(|| v.get("user").and_then(|u| text(u, "username"))),
        v.get("duration")
            .and_then(Value::as_u64)
            .map(|ms| ms / 1000),
    )
}
fn access(v: &Value) -> ServiceMediaAccess {
    match v.get("access").and_then(Value::as_str) {
        Some("preview") => ServiceMediaAccess::Preview,
        Some("blocked") => ServiceMediaAccess::Restricted,
        Some("playable") => ServiceMediaAccess::StreamObserved,
        _ => ServiceMediaAccess::Unknown,
    }
}
pub(super) async fn read(
    http: &dyn ServiceHttp,
    context: PluginContext,
    location: Location,
    cursor: Option<String>,
) -> Result<ServicePage, E> {
    let headers = headers(&context, ServiceProvider::SoundCloud)?;
    let data = resolve(http, headers.clone(), &location).await?;
    if data
        .get("sharing")
        .and_then(Value::as_str)
        .is_some_and(|s| s != "public")
    {
        return Err(E::AccessDenied);
    }
    if !location.collection {
        if cursor.is_some() {
            return Err(invalid());
        }
        let entry = track_entry(&data).ok_or(E::InvalidResponse)?;
        return Ok(ServicePage {
            title: entry.title.clone(),
            is_collection: false,
            items: vec![item(0, "track".into(), Some(entry), access(&data))],
            next_cursor: None,
            truncated: false,
        });
    }
    let tracks = data
        .get("tracks")
        .and_then(Value::as_array)
        .ok_or(E::InvalidResponse)?;
    let ids: Vec<_> = tracks
        .iter()
        .take(1000)
        .enumerate()
        .map(|(i, v)| reference(v).unwrap_or_else(|| format!("missing:{i}")))
        .collect();
    let revision = revision(&ids);
    let start = snapshot_cursor(cursor, &revision)?;
    if start > ids.len() {
        return Err(E::InvalidResponse);
    }
    let end = (start + 50).min(ids.len());
    let missing: Vec<_> = tracks[start..end]
        .iter()
        .filter(|v| track_entry(v).is_none())
        .filter_map(reference)
        .collect();
    let mut hydrated = vec![];
    if !missing.is_empty() {
        let mut u = api().join("tracks").unwrap();
        u.query_pairs_mut()
            .append_pair("urns", &missing.join(","))
            .append_pair("access", "playable,preview,blocked");
        match json(http, u, headers).await {
            Ok(v) => {
                hydrated = v
                    .as_array()
                    .cloned()
                    .or_else(|| v.get("collection").and_then(Value::as_array).cloned())
                    .ok_or(E::InvalidResponse)?
            }
            Err(E::NotFound) => {}
            Err(e) => return Err(e),
        }
    }
    let mut items = vec![];
    for i in start..end {
        let raw = &tracks[i];
        let observed = if track_entry(raw).is_some() {
            raw
        } else {
            hydrated
                .iter()
                .find(|v| reference(v).as_ref() == Some(&ids[i]))
                .unwrap_or(&Value::Null)
        };
        let entry = track_entry(observed);
        let access = if entry.is_some() {
            access(observed)
        } else {
            ServiceMediaAccess::Unavailable
        };
        items.push(item(i as u32, format!("{i}:{}", ids[i]), entry, access));
    }
    let total = data
        .get("track_count")
        .and_then(Value::as_u64)
        .unwrap_or(tracks.len() as u64);
    Ok(ServicePage {
        title: text(&data, "title").unwrap_or_else(|| "Playlist SoundCloud".into()),
        is_collection: true,
        items,
        next_cursor: (end < ids.len()).then(|| format!("{end}:{revision}")),
        truncated: tracks.len() > 1000 || total != tracks.len() as u64,
    })
}
