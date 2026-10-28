use super::*;
use crate::{
    application::music_catalog::SourceFinder,
    domain::music::sources::{SourceCandidate, SourceSearchRequest},
};
#[derive(Deserialize)]
struct Recording {
    id: String,
    #[serde(default)]
    relations: Vec<Relation>,
}
#[derive(Deserialize)]
struct Relation {
    #[serde(rename = "type")]
    kind: String,
    #[serde(default)]
    ended: bool,
    url: Option<Link>,
}
#[derive(Deserialize)]
struct Link {
    resource: String,
}
impl SourceFinder for MusicBrainzCatalog {
    fn find_sources(
        &self,
        _context: PluginContext,
        request: SourceSearchRequest,
    ) -> IntegrationFuture<'_, Vec<SourceCandidate>> {
        Box::pin(async move {
            let CatalogEntityRef::External(target) = request.target else {
                return Ok(vec![]);
            };
            if target.provider().as_str() != "musicbrainz"
                || target.kind() != ExternalEntityKind::Recording
            {
                return Ok(vec![]);
            }
            let id = normalize_mbid(target.external_id()).ok_or_else(invalid)?;
            let key = cache::key("source-links:v1", &id);
            let _lock = cache::request_lock(&key).await.map_err(map_error)?;
            let body = if let Some(saved) = cache::load(&key)
                .await
                .map_err(map_error)?
                .filter(|s| s.fresh())
            {
                serde_json::from_slice::<serde_json::Value>(&saved.body)
                    .map_err(|_| IntegrationError::InvalidResponse)?
            } else {
                let client = self
                    .client
                    .get_or_init(MusicBrainz::new)
                    .as_ref()
                    .map_err(|e| map_error(e.clone()))?;
                let body = match client
                    .http
                    .get_json::<serde_json::Value>(
                        &format!("ws/2/recording/{id}"),
                        &[("fmt", "json"), ("inc", "url-rels")],
                        &CacheValidators::default(),
                    )
                    .await
                    .map_err(map_error)?
                {
                    JsonResponse::Modified { body, .. } => body,
                    _ => return Err(IntegrationError::InvalidResponse),
                };
                if body.get("id").and_then(|v| v.as_str()) != Some(id.as_str()) {
                    return Err(IntegrationError::InvalidResponse);
                }
                cache::store(
                    &key,
                    &cache::Entry {
                        body: serde_json::to_vec(&body)
                            .map_err(|_| IntegrationError::InvalidResponse)?,
                        validators: CacheValidators::default(),
                        expires_at: chrono::Utc::now().timestamp() + 3600,
                        failure: None,
                    },
                )
                .await
                .map_err(map_error)?;
                body
            };
            let recording: Recording =
                serde_json::from_value(body).map_err(|_| IntegrationError::InvalidResponse)?;
            if recording.id != id {
                return Err(IntegrationError::InvalidResponse);
            }
            let mut seen = std::collections::HashSet::new();
            Ok(recording
                .relations
                .into_iter()
                .filter(|r| {
                    !r.ended
                        && matches!(
                            r.kind.as_str(),
                            "streaming" | "free streaming" | "paid streaming" | "video"
                        )
                })
                .filter_map(|r| {
                    crate::infrastructure::service_links::canonical_link(&r.url?.resource)
                })
                .filter(|m| {
                    seen.insert((
                        m.entity().provider().as_str().to_owned(),
                        m.entity().external_id().to_owned(),
                    ))
                })
                .take(50)
                .map(crate::infrastructure::service_links::candidate)
                .collect())
        })
    }
}
