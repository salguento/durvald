//! Read-only detail blocks and explicit, identity-scoped persistence actions.
use crate::{
    api::*,
    application::{
        catalog_search::CatalogSearchApplication,
        music_plugins::{RequestTicket, context::RequestScope},
    },
    domain::music::{identity::ProviderId, sources::CanonicalMediaUrl},
};
use tokio::sync::Mutex;
#[derive(Default)]
pub(crate) struct CatalogDetailSessionState(Mutex<State>);
#[derive(Default)]
struct State {
    generation: u64,
    reference: Option<CatalogReference>,
    language: String,
    scope: RequestScope,
    ticket: Option<RequestTicket>,
    closed: bool,
}
impl CatalogDetailSessionState {
    pub(crate) async fn cancel(&self, generation: u64) {
        let s = self.0.lock().await;
        if s.generation == generation {
            if let Some(t) = &s.ticket {
                t.cancel();
            }
        }
    }
    pub(crate) async fn close(&self) {
        let mut s = self.0.lock().await;
        s.closed = true;
        if let Some(t) = &s.ticket {
            t.cancel();
        }
    }
}
impl CatalogSearchApplication {
    pub(crate) async fn detail_section(
        &self,
        state: &CatalogDetailSessionState,
        mut request: CatalogDetailRequest,
    ) -> CoreResult<CatalogDetailPage> {
        request.reference = validate_reference(request.reference)?;
        if request.generation == 0 || request.cursor.as_ref().is_some_and(|v| v.len() > 2048) {
            return Err(invalid());
        }
        let language = crate::domain::music::catalog::CatalogSearchRequest::new(
            "details",
            crate::domain::music::catalog::SearchScope::Explore,
            crate::domain::music::catalog::SearchEntityFilter::All,
            20,
            None,
        )
        .and_then(|r| r.with_language(&request.language))
        .map_err(|_| invalid())?;
        request.language = language.language().to_string();
        let ticket = {
            let mut s = state.0.lock().await;
            if s.closed || request.generation < s.generation {
                return Ok(detail_failure(&request, CatalogFailure::Cancelled, None));
            }
            if request.generation > s.generation {
                s.generation = request.generation;
                s.reference = Some(request.reference.clone());
                s.language = request.language.clone();
                s.ticket = Some(s.scope.begin());
            } else if s.reference.as_ref() != Some(&request.reference)
                || s.language != request.language
            {
                return Err(invalid());
            }
            s.ticket.clone().filter(RequestTicket::is_current)
        };
        let Some(ticket) = ticket else {
            return Ok(detail_failure(&request, CatalogFailure::Cancelled, None));
        };
        let result = self
            .plugins
            .detail_section(
                &ProviderId::new(&request.reference.provider).map_err(|_| invalid())?,
                ticket.clone(),
                request.clone(),
            )
            .await;
        let s = state.0.lock().await;
        if s.closed || s.generation != request.generation || !ticket.is_current() {
            return Ok(detail_failure(&request, CatalogFailure::Cancelled, None));
        }
        Ok(match result {
            Ok(page)
                if page.reference == request.reference
                    && page.section == request.section
                    && page.generation == request.generation =>
            {
                page
            }
            Ok(_) => detail_failure(&request, CatalogFailure::Unavailable, None),
            Err(e) => {
                let (failure, retry) = super::catalog_search::failure(e);
                detail_failure(&request, failure, retry)
            }
        })
    }
    pub(crate) async fn saved_selection(
        &self,
        reference: CatalogReference,
    ) -> CoreResult<Option<CatalogSelection>> {
        self.selections.get(validate_reference(reference)?).await
    }
    pub(crate) async fn saved_selections(&self) -> CoreResult<Vec<CatalogSelection>> {
        self.selections.list().await
    }
    pub(crate) async fn save_selection(
        &self,
        mut entry: CatalogEntry,
    ) -> CoreResult<CatalogSelection> {
        entry.reference = validate_reference(entry.reference)?;
        entry.title = entry.title.trim().to_owned();
        if entry.title.is_empty()
            || entry.title.len() > 500
            || entry.title.chars().any(char::is_control)
            || [&entry.artist_credit, &entry.version_label]
                .into_iter()
                .flatten()
                .any(|v| v.len() > 2000 || v.chars().any(char::is_control))
        {
            return Err(invalid());
        }
        if let Some(url) = &entry.canonical_url {
            if url.len() > 2048 {
                return Err(invalid());
            }
            CanonicalMediaUrl::new(url).map_err(|_| invalid())?;
        }
        self.selections.save(entry).await
    }
    pub(crate) async fn follow_selection(
        &self,
        entry: CatalogEntry,
        followed: bool,
    ) -> CoreResult<CatalogSelection> {
        if entry.reference.kind != CatalogItemKind::Artist {
            return Err(invalid());
        }
        let saved = self.save_selection(entry).await?;
        self.library
            .set_artist_followed(saved.local_artist_id.ok_or_else(invalid)?, followed)
            .await?;
        Ok(saved)
    }
    pub(crate) async fn listen_selection(
        &self,
        entry: CatalogEntry,
        artist: CatalogEntry,
    ) -> CoreResult<ListenListEntry> {
        let reference = validate_reference(entry.reference.clone())?;
        let artist_reference = validate_reference(artist.reference.clone())?;
        if entry.title.trim().is_empty()
            || entry.title.chars().count() > 1000
            || entry.title.chars().any(char::is_control)
            || reference.provider != "musicbrainz"
            || reference.kind != CatalogItemKind::ReleaseGroup
            || artist_reference.provider != "musicbrainz"
            || artist_reference.kind != CatalogItemKind::Artist
        {
            return Err(invalid());
        }
        let saved = self.save_selection(artist).await?;
        self.library
            .add_external_to_listen_list(
                saved.local_artist_id.ok_or_else(invalid)?,
                ExternalReleaseGroup {
                    primary_artist_mbid: Some(artist_reference.id),
                    musicbrainz_id: reference.id.clone(),
                    title: entry.title,
                    primary_type: None,
                    secondary_types: vec![],
                    first_release_date: None,
                    local_release_id: None,
                    artwork: None,
                    attribution: EnrichmentAttribution {
                        source_url: format!(
                            "https://musicbrainz.org/release-group/{}",
                            reference.id
                        ),
                        author: None,
                        license_name: Some("CC0".into()),
                        license_url: Some(
                            "https://creativecommons.org/publicdomain/zero/1.0/".into(),
                        ),
                        revision: None,
                    },
                },
            )
            .await
    }
}
pub(crate) fn validate_reference(mut r: CatalogReference) -> CoreResult<CatalogReference> {
    ProviderId::new(&r.provider).map_err(|_| invalid())?;
    if r.provider.len() > 64
        || r.id.is_empty()
        || r.id.len() > 500
        || r.id.trim() != r.id
        || r.id.chars().any(char::is_control)
        || matches!(r.kind, CatalogItemKind::Track | CatalogItemKind::Playlist)
    {
        return Err(invalid());
    }
    if r.provider == "musicbrainz" {
        if !matches!(
            r.kind,
            CatalogItemKind::Artist
                | CatalogItemKind::ReleaseGroup
                | CatalogItemKind::ReleaseEdition
                | CatalogItemKind::Recording
                | CatalogItemKind::ReleaseTrack
        ) {
            return Err(invalid());
        }
        r.id = crate::enrichment::identity::normalize_mbid(&r.id).ok_or_else(invalid)?;
    }
    Ok(r)
}
pub(crate) fn detail_failure(
    r: &CatalogDetailRequest,
    failure: CatalogFailure,
    retry_after_seconds: Option<u64>,
) -> CatalogDetailPage {
    CatalogDetailPage {
        reference: r.reference.clone(),
        section: r.section,
        generation: r.generation,
        items: vec![],
        profile: None,
        image: None,
        attribution: None,
        next_cursor: None,
        failure: Some(failure),
        retry_after_seconds,
        from_cache: false,
    }
}
fn invalid() -> CoreError {
    CoreError::InvalidInput {
        message: "Invalid catalog reference, selection or detail request".into(),
    }
}
