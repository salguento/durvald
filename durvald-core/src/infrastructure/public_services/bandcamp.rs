use super::*;
use scraper::{Html, Selector};
pub(super) async fn read(
    http: &dyn ServiceHttp,
    location: Location,
    cursor: Option<String>,
) -> Result<ServicePage, E> {
    let response = http
        .get(
            Url::parse(&location.url).map_err(|_| invalid())?,
            HeaderMap::new(),
        )
        .await?;
    status(&response)?;
    parse(&location, &response.body, cursor)
}
fn parse(location: &Location, bytes: &[u8], cursor: Option<String>) -> Result<ServicePage, E> {
    let document =
        Html::parse_document(std::str::from_utf8(bytes).map_err(|_| E::InvalidResponse)?);
    let selector = Selector::parse("[data-tralbum]").unwrap();
    let raw = document
        .select(&selector)
        .next()
        .and_then(|n| n.value().attr("data-tralbum"))
        .ok_or(E::InvalidResponse)?;
    let album: serde_json::Value = serde_json::from_str(raw).map_err(|_| E::InvalidResponse)?;
    let tracks = album
        .get("trackinfo")
        .and_then(|v| v.as_array())
        .ok_or(E::InvalidResponse)?;
    if tracks.is_empty() || (!location.collection && tracks.len() != 1) {
        return Err(E::InvalidResponse);
    }
    let base = Url::parse(&location.url).unwrap();
    let artist = text(&album, "artist");
    let mut all = vec![];
    let mut ids = vec![];
    for (index, track) in tracks.iter().take(1000).enumerate() {
        let link = text(track, "title_link")
            .and_then(|u| base.join(&u).ok())
            .filter(|u| u.host_str() == base.host_str())
            .or_else(|| (!location.collection).then(|| base.clone()));
        let entry = link.and_then(|u| {
            entry(
                u.as_str(),
                text(track, "title")?,
                text(track, "artist").or_else(|| artist.clone()),
                track
                    .get("duration")
                    .and_then(|v| v.as_f64())
                    .filter(|v| v.is_finite() && *v > 0.0 && *v < 86400.0)
                    .map(|s| s as u64),
            )
        });
        let observed = track
            .get("file")
            .and_then(|v| v.as_object())
            .is_some_and(|files| {
                files.values().any(|v| {
                    v.as_str()
                        .is_some_and(|s| s.starts_with("https://") || s.starts_with("http://"))
                })
            });
        let access = if entry.is_none() {
            ServiceMediaAccess::Unavailable
        } else if observed {
            ServiceMediaAccess::StreamObserved
        } else {
            ServiceMediaAccess::Unknown
        };
        let id = entry
            .as_ref()
            .map(|e| e.reference.id.clone())
            .unwrap_or_else(|| format!("missing:{index}"));
        ids.push(id.clone());
        all.push(item(index as u32, format!("{index}:{id}"), entry, access));
    }
    let revision = revision(&ids);
    let start = snapshot_cursor(cursor, &revision)?;
    if start > all.len() {
        return Err(E::InvalidResponse);
    }
    let end = (start + 50).min(all.len());
    let items = all[start..end].to_vec();
    Ok(ServicePage {
        title: album
            .get("current")
            .and_then(|v| text(v, "title"))
            .unwrap_or_else(|| location.id.clone()),
        is_collection: location.collection,
        items,
        next_cursor: (end < all.len()).then(|| format!("{end}:{revision}")),
        truncated: tracks.len() > 1000,
    })
}
