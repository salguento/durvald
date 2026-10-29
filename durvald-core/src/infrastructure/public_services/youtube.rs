use super::*;
use serde_json::Value;
// Google reports quota exhaustion as 403 and invalid keys as 400. Classify
// structured reason codes only; messages can contain account or key details.
async fn json(http: &dyn ServiceHttp, url: Url, headers: HeaderMap) -> Result<Value, E> {
    let response = http.get(url, headers).await?;
    if matches!(response.status, 400 | 403) {
        if let Ok(body) = serde_json::from_slice::<Value>(&response.body) {
            let legacy = body["error"]["errors"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|v| v["reason"].as_str());
            let details = body["error"]["details"]
                .as_array()
                .into_iter()
                .flatten()
                .filter(|v| {
                    v["@type"] == "type.googleapis.com/google.rpc.ErrorInfo"
                        && v["domain"] == "googleapis.com"
                })
                .filter_map(|v| v["reason"].as_str());
            let reasons: Vec<_> = legacy.chain(details).collect();
            if reasons
                .iter()
                .any(|r| matches!(*r, "keyInvalid" | "keyExpired" | "API_KEY_INVALID"))
            {
                return Err(E::AuthenticationRequired);
            }
            if reasons.iter().any(|r| {
                matches!(
                    *r,
                    "quotaExceeded"
                        | "dailyLimitExceeded"
                        | "rateLimitExceeded"
                        | "userRateLimitExceeded"
                        | "RATE_LIMIT_EXCEEDED"
                        | "RESOURCE_QUOTA_EXCEEDED"
                )
            }) {
                return Err(E::RateLimited {
                    retry_after_seconds: response.retry,
                });
            }
        }
    }
    status(&response)?;
    serde_json::from_slice(&response.body).map_err(|_| E::InvalidResponse)
}
fn api(path: &str) -> Url {
    Url::parse(&format!("https://www.googleapis.com/youtube/v3/{path}")).unwrap()
}
fn duration(value: &str) -> Option<u64> {
    let rest = value.strip_prefix("PT")?;
    let mut total = 0u64;
    let mut n = String::new();
    for c in rest.chars() {
        if c.is_ascii_digit() {
            n.push(c);
        } else {
            let part = n.parse::<u64>().ok()?;
            n.clear();
            total = total.checked_add(part.checked_mul(match c {
                'H' => 3600,
                'M' => 60,
                'S' => 1,
                _ => return None,
            })?)?;
        }
    }
    (n.is_empty() && total > 0 && total <= 86400).then_some(total)
}
fn video_id(v: &str) -> bool {
    v.len() == 11
        && v.bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_'))
}
fn video(v: &Value) -> (Option<CatalogEntry>, ServiceMediaAccess) {
    let Some(id) = text(v, "id").filter(|v| video_id(v)) else {
        return (None, ServiceMediaAccess::Unavailable);
    };
    let snippet = &v["snippet"];
    let status = &v["status"];
    let live = text(snippet, "liveBroadcastContent").is_some_and(|s| s != "none")
        || v.get("liveStreamingDetails").is_some();
    let restricted = status.get("embeddable").and_then(Value::as_bool) != Some(true)
        || status.get("privacyStatus").and_then(Value::as_str) == Some("private");
    let access = if live {
        ServiceMediaAccess::UnsupportedLive
    } else if restricted {
        ServiceMediaAccess::Restricted
    } else {
        ServiceMediaAccess::Unknown
    };
    (
        text(snippet, "title").and_then(|title| {
            entry(
                &format!("https://www.youtube.com/watch?v={id}"),
                title,
                text(snippet, "channelTitle"),
                v.get("contentDetails")
                    .and_then(|v| text(v, "duration"))
                    .as_deref()
                    .and_then(duration),
            )
        }),
        access,
    )
}
pub(super) async fn read(
    http: &dyn ServiceHttp,
    context: PluginContext,
    location: Location,
    cursor: Option<String>,
) -> Result<ServicePage, E> {
    let headers = headers(&context, ServiceProvider::YouTube)?;
    if !location.collection {
        if cursor.is_some() {
            return Err(invalid());
        }
        let mut u = api("videos");
        u.query_pairs_mut()
            .append_pair("part", "snippet,contentDetails,status,liveStreamingDetails")
            .append_pair("id", &location.id);
        let body = json(http, u, headers).await?;
        let raw = body
            .get("items")
            .and_then(Value::as_array)
            .ok_or(E::InvalidResponse)?
            .first()
            .ok_or(E::NotFound)?;
        if raw.get("id").and_then(Value::as_str) != Some(&location.id) {
            return Err(E::InvalidResponse);
        }
        let (entry, access) = video(raw);
        let title = entry
            .as_ref()
            .map(|e| e.title.clone())
            .unwrap_or_else(|| "Vídeo YouTube".into());
        return Ok(ServicePage {
            title,
            is_collection: false,
            items: vec![item(0, location.id, entry, access)],
            next_cursor: None,
            truncated: false,
        });
    }
    let mut u = api("playlistItems");
    u.query_pairs_mut()
        .append_pair("part", "snippet,contentDetails,status")
        .append_pair("playlistId", &location.id)
        .append_pair("maxResults", "50");
    if let Some(cursor) = cursor {
        if cursor.is_empty() || cursor.len() > 2048 || cursor.chars().any(char::is_control) {
            return Err(invalid());
        }
        u.query_pairs_mut().append_pair("pageToken", &cursor);
    }
    let body = json(http, u, headers.clone()).await?;
    let rows = body
        .get("items")
        .and_then(Value::as_array)
        .filter(|v| v.len() <= 50)
        .ok_or(E::InvalidResponse)?;
    let ids: Vec<_> = rows
        .iter()
        .filter_map(|v| {
            v.get("contentDetails")
                .and_then(|v| text(v, "videoId"))
                .or_else(|| {
                    v.get("snippet")
                        .and_then(|s| s.get("resourceId"))
                        .and_then(|r| text(r, "videoId"))
                })
        })
        .filter(|id| video_id(id))
        .collect();
    let mut videos = vec![];
    if !ids.is_empty() {
        let mut u = api("videos");
        u.query_pairs_mut()
            .append_pair("part", "snippet,contentDetails,status,liveStreamingDetails")
            .append_pair("id", &ids.join(","));
        let v = json(http, u, headers).await?;
        videos = v
            .get("items")
            .and_then(Value::as_array)
            .cloned()
            .ok_or(E::InvalidResponse)?;
    }
    let mut items = vec![];
    for row in rows {
        let occurrence = text(row, "id").ok_or(E::InvalidResponse)?;
        let position = row
            .get("snippet")
            .and_then(|s| s.get("position"))
            .and_then(Value::as_u64)
            .and_then(|v| u32::try_from(v).ok())
            .ok_or(E::InvalidResponse)?;
        let id = row
            .get("contentDetails")
            .and_then(|v| text(v, "videoId"))
            .or_else(|| {
                row.get("snippet")
                    .and_then(|s| s.get("resourceId"))
                    .and_then(|r| text(r, "videoId"))
            });
        let (entry, access) = videos
            .iter()
            .find(|v| v.get("id").and_then(Value::as_str) == id.as_deref())
            .map(video)
            .unwrap_or((None, ServiceMediaAccess::Unavailable));
        items.push(item(position, occurrence, entry, access));
    }
    let next = text(&body, "nextPageToken");
    Ok(ServicePage {
        title: format!("Playlist YouTube {}", location.id),
        is_collection: true,
        items,
        next_cursor: next,
        truncated: false,
    })
}
