//! Search sessions are temporary and have no library/player/transfer dependency.
use crate::{
    api::*,
    application::{
        music_catalog::DownloadSearchHandle,
        music_plugins::{PluginRuntime, PluginSecret, RequestTicket, context::RequestScope},
    },
    domain::music::{IntegrationError as E, identity::ProviderId, plugins::PluginError as P},
};
use std::{
    sync::Arc,
    time::{Duration, Instant},
};
use tokio::sync::Mutex;
pub(crate) struct DownloadSearchApplication {
    pub(crate) runtime: Arc<PluginRuntime>,
    configuration: Mutex<()>,
}
impl DownloadSearchApplication {
    pub(crate) async fn new(runtime: Arc<PluginRuntime>) -> Self {
        let _ = runtime
            .register_builtin_with_default(
                Arc::new(crate::infrastructure::slskd_search::SlskdSearch),
                false,
            )
            .await;
        Self {
            runtime,
            configuration: Mutex::new(()),
        }
    }
    pub(crate) async fn settings(&self) -> CoreResult<DownloadSearchSettings> {
        let status = self
            .runtime
            .list()
            .await
            .map_err(configuration_error)?
            .into_iter()
            .find(|s| s.manifest.id.as_str() == "slskd")
            .ok_or_else(|| configuration_error(P::NotRegistered))?;
        Ok(DownloadSearchSettings {
            enabled: status.enabled,
            endpoint: status
                .configuration
                .values
                .get("endpoint")
                .cloned()
                .unwrap_or_default(),
            has_api_key: self
                .runtime
                .has_credential(&id(), "api_key")
                .await
                .map_err(configuration_error)?,
            sharing_acknowledged: status
                .configuration
                .flags
                .get("sharing_acknowledged")
                .copied()
                .unwrap_or(false),
        })
    }
    pub(crate) async fn configure(
        &self,
        endpoint: String,
        api_key: Option<String>,
        enabled: bool,
        sharing_acknowledged: bool,
    ) -> CoreResult<DownloadSearchSettings> {
        let _guard = self.configuration.lock().await;
        crate::infrastructure::slskd_search::endpoint(&endpoint).map_err(|_|invalid("Informe o endereço slskd. Use HTTPS fora de localhost; não inclua credenciais, parâmetros ou fragmentos na URL."))?;
        if enabled && !sharing_acknowledged {
            return Err(invalid(
                "Confirme que revisou os compartilhamentos na sua instância slskd.",
            ));
        }
        if let Some(key) = api_key.as_ref()
            && (!key.is_empty()
                && (key.len() < 16
                    || key.len() > 255
                    || !key.bytes().all(|b| (33..=126).contains(&b))))
        {
            return Err(invalid(
                "A chave da API deve ter de 16 a 255 caracteres, sem espaços.",
            ));
        }
        self.runtime
            .set_enabled(&id(), false)
            .await
            .map_err(configuration_error)?;
        if let Some(key) = api_key {
            let secret = (!key.is_empty()).then(|| PluginSecret::new(key));
            self.runtime
                .set_credential(&id(), "api_key", secret)
                .await
                .map_err(configuration_error)?;
        }
        let mut c = crate::domain::music::plugins::PluginConfiguration::default();
        c.values.insert("endpoint".into(), endpoint.trim().into());
        c.flags
            .insert("sharing_acknowledged".into(), sharing_acknowledged);
        self.runtime
            .configure(&id(), c)
            .await
            .map_err(configuration_error)?;
        if enabled
            && !self
                .runtime
                .has_credential(&id(), "api_key")
                .await
                .map_err(configuration_error)?
        {
            return Err(invalid(
                "Informe a chave da API slskd antes de habilitar a pesquisa.",
            ));
        }
        self.runtime
            .set_enabled(&id(), enabled)
            .await
            .map_err(configuration_error)?;
        self.settings().await
    }
}
fn id() -> ProviderId {
    ProviderId::new("slskd").unwrap()
}
fn invalid(message: &str) -> CoreError {
    CoreError::InvalidInput {
        message: message.into(),
    }
}
fn configuration_error(_: P) -> CoreError {
    CoreError::Storage {message:"Não foi possível acessar a configuração ou a chave protegida do slskd. A pesquisa permanece desativada se a configuração falhar.".into()}
}
fn failure(error: P) -> DownloadSearchFailure {
    match error {
        P::Disabled | P::NotRegistered => DownloadSearchFailure::Disabled,
        P::MissingCredential | P::Adapter(E::AuthenticationRequired | E::AccessDenied) => {
            DownloadSearchFailure::Authentication
        }
        P::InvalidConfiguration | P::PermissionDenied => DownloadSearchFailure::Configuration,
        P::Timeout | P::Adapter(E::Timeout) => DownloadSearchFailure::TimedOut,
        P::Adapter(E::RateLimited { .. }) => DownloadSearchFailure::RateLimited,
        P::Cancelled | P::Adapter(E::Cancelled) => DownloadSearchFailure::Cancelled,
        P::Adapter(E::InvalidResponse) => DownloadSearchFailure::InvalidResponse,
        _ => DownloadSearchFailure::Unavailable,
    }
}
fn empty(generation: u64, state: DownloadSearchState) -> DownloadSearchPage {
    DownloadSearchPage {
        generation,
        state,
        groups: vec![],
        failure: None,
        truncated: false,
        cleanup_pending: false,
    }
}
fn fail(page: &mut DownloadSearchPage, error: P) {
    let f = failure(error);
    page.state = match f {
        DownloadSearchFailure::TimedOut => DownloadSearchState::TimedOut,
        DownloadSearchFailure::Cancelled => DownloadSearchState::Cancelled,
        _ => DownloadSearchState::Failed,
    };
    page.failure = Some(f);
}
struct Active {
    handle: Arc<dyn DownloadSearchHandle>,
    provider_generation: u64,
    ticket: RequestTicket,
    deadline: Instant,
}
struct State {
    endpoint: Option<String>,
    serial: u64,
    closed: bool,
    page: DownloadSearchPage,
    active: Option<Active>,
    request: DownloadSearchRequest,
    ticket: Option<RequestTicket>,
}
pub(crate) struct SearchSession {
    application: Arc<DownloadSearchApplication>,
    state: Mutex<State>,
    operations: Mutex<()>,
    scope: RequestScope,
}
impl SearchSession {
    pub(crate) fn new(application: Arc<DownloadSearchApplication>) -> Self {
        Self {
            application,
            state: Mutex::new(State {
                endpoint: None,
                serial: 0,
                closed: false,
                page: empty(0, DownloadSearchState::Cancelled),
                active: None,
                request: DownloadSearchRequest {
                    query: String::new(),
                    expected_tracks: vec![],
                },
                ticket: None,
            }),
            operations: Mutex::new(()),
            scope: RequestScope::default(),
        }
    }
    pub(crate) async fn selected_offer(
        &self,
        offer_id: String,
        filenames: Vec<String>,
        confirmed: bool,
    ) -> CoreResult<(String, DownloadOfferGroup)> {
        let s = self.state.lock().await;
        if s.closed || !confirmed || filenames.is_empty() || filenames.len() > 500 {
            return Err(invalid(
                "Revise os arquivos e confirme o download nesta busca.",
            ));
        }
        let mut group = s
            .page
            .groups
            .iter()
            .find(|g| g.offer_id == offer_id)
            .cloned()
            .ok_or_else(|| invalid("A oferta expirou ou pertence a outra busca."))?;
        let selected: std::collections::HashSet<_> = filenames.into_iter().collect();
        if !selected
            .iter()
            .all(|name| group.files.iter().any(|f| &f.filename == name))
        {
            return Err(invalid("Selecione somente arquivos desta oferta."));
        }
        group.files.retain(|f| selected.contains(&f.filename));
        Ok((
            s.endpoint
                .clone()
                .ok_or_else(|| invalid("A instância da oferta não está disponível."))?,
            group,
        ))
    }
    pub(crate) async fn start(
        &self,
        mut request: DownloadSearchRequest,
        generation: u64,
    ) -> CoreResult<DownloadSearchPage> {
        request.query = request.query.trim().into();
        if generation == 0
            || request.query.chars().count() < 2
            || request.query.len() > 500
            || request.query.chars().any(char::is_control)
            || request.expected_tracks.len() > 500
            || request.expected_tracks.iter().any(|t| {
                t.title.trim().is_empty()
                    || t.title.len() > 500
                    || t.title.chars().any(char::is_control)
                    || t.disc == 0
                    || t.position == 0
            })
        {
            return Err(invalid(
                "Informe uma consulta de 2 a 500 caracteres e uma referência de faixas válida.",
            ));
        }
        // Immediately supersede/cancel any old publication, even while an HTTP call is pending.
        let (serial, ticket, old) = {
            let mut s = self.state.lock().await;
            if s.closed || generation <= s.page.generation {
                return Err(invalid("Esta busca foi encerrada ou substituída."));
            }
            s.serial += 1;
            let ticket = self.scope.begin();
            s.ticket = Some(ticket.clone());
            s.page = empty(generation, DownloadSearchState::Searching);
            s.request = request.clone();
            (s.serial, ticket, s.active.take())
        };
        if let Some(old) = old {
            let pending = old.handle.cancel().await.is_err();
            let mut s = self.state.lock().await;
            if s.serial == serial {
                s.page.cleanup_pending = pending;
            }
        }
        let _operation = self.operations.lock().await;
        let result = self
            .application
            .runtime
            .begin_download_search(ticket.clone(), request)
            .await;
        let mut s = self.state.lock().await;
        if s.serial != serial || s.closed || !ticket.is_current() {
            return Ok(empty(generation, DownloadSearchState::Cancelled));
        }
        match result {
            Ok((provider_generation, handle)) => {
                s.endpoint = Some(handle.endpoint());
                s.active = Some(Active {
                    handle,
                    provider_generation,
                    ticket,
                    deadline: Instant::now() + Duration::from_secs(25),
                })
            }
            Err(e) => {
                s.page.cleanup_pending |= matches!(
                    e,
                    P::Timeout | P::Adapter(E::Timeout | E::TemporarilyUnavailable)
                );
                fail(&mut s.page, e);
            }
        }
        Ok(s.page.clone())
    }
    pub(crate) async fn poll(&self, generation: u64) -> CoreResult<DownloadSearchPage> {
        let _operation = self.operations.lock().await;
        let (serial, handle, provider_generation, ticket, remaining) = {
            let s = self.state.lock().await;
            if s.closed || s.page.generation != generation {
                return Ok(empty(generation, DownloadSearchState::Cancelled));
            }
            let Some(a) = &s.active else {
                return Ok(s.page.clone());
            };
            (
                s.serial,
                a.handle.clone(),
                a.provider_generation,
                a.ticket.clone(),
                a.deadline.saturating_duration_since(Instant::now()),
            )
        };
        let result = if remaining.is_zero() {
            Err(P::Timeout)
        } else {
            tokio::time::timeout(
                remaining,
                self.application.runtime.poll_download_search(
                    ticket,
                    provider_generation,
                    handle.clone(),
                ),
            )
            .await
            .unwrap_or(Err(P::Timeout))
        };
        let mut s = self.state.lock().await;
        if s.closed || s.serial != serial {
            return Ok(empty(generation, DownloadSearchState::Cancelled));
        }
        match result {
            Ok(mut page) => {
                page.generation = generation;
                page.cleanup_pending = s.page.cleanup_pending;
                for g in page.groups.iter_mut() {
                    use sha2::{Digest, Sha256};
                    let digest = Sha256::digest(format!("{}\0{}", g.peer, g.folder).as_bytes());
                    g.offer_id = format!("{generation}:{digest:x}");
                    compare(g, &s.request.expected_tracks);
                }
                page.groups.sort_by(|a, b| {
                    b.matched_tracks
                        .cmp(&a.matched_tracks)
                        .then_with(|| a.peer.cmp(&b.peer))
                        .then_with(|| a.folder.cmp(&b.folder))
                });
                s.page = page;
            }
            Err(e) => fail(&mut s.page, e),
        }
        if s.page.state != DownloadSearchState::Searching {
            s.active = None;
            drop(s);
            let pending = handle.cancel().await.is_err();
            s = self.state.lock().await;
            if s.serial != serial {
                return Ok(empty(generation, DownloadSearchState::Cancelled));
            }
            s.page.cleanup_pending |= pending;
        }
        Ok(s.page.clone())
    }
    pub(crate) async fn cancel(&self, close: bool) -> DownloadSearchPage {
        let (serial, active) = {
            let mut s = self.state.lock().await;
            s.serial += 1;
            s.closed |= close;
            if let Some(t) = s.ticket.take() {
                t.cancel();
            }
            s.page.state = DownloadSearchState::Cancelled;
            s.page.failure = None;
            (s.serial, s.active.take())
        };
        let pending = if let Some(a) = active {
            a.handle.cancel().await.is_err()
        } else {
            false
        };
        let mut s = self.state.lock().await;
        if s.serial == serial {
            s.page.cleanup_pending |= pending;
        }
        s.page.clone()
    }
}
fn normalized(value: &str) -> String {
    crate::enrichment::identity::normalized_match_text(value)
        .chars()
        .filter(|c| c.is_alphanumeric())
        .collect()
}
pub(crate) fn disc_folder(folder: &str) -> Option<u32> {
    let tail = folder.rsplit('/').next()?.to_ascii_lowercase();
    ["cd", "disc", "disk"]
        .into_iter()
        .find_map(|p| tail.strip_prefix(p)?.trim().parse::<u32>().ok())
        .filter(|d| *d > 0)
}
fn file_identity(file: &DownloadOfferFile) -> (Option<u32>, Option<u32>, String) {
    let path = file.filename.replace('\\', "/");
    let (folder, name) = path.rsplit_once('/').unwrap_or(("", &path));
    let stem = name.rsplit_once('.').map(|(n, _)| n).unwrap_or(name);
    let n = stem.chars().take_while(|c| c.is_ascii_digit()).count();
    let position = stem[..n].parse::<u32>().ok();
    let title =
        stem[n..].trim_start_matches(|c: char| c.is_whitespace() || matches!(c, '-' | '.' | '_'));
    (disc_folder(folder), position, normalized(title))
}
pub(crate) fn compare(group: &mut DownloadOfferGroup, expected: &[DownloadExpectedTrack]) {
    group.expected_tracks = expected.len() as u32;
    group.matched_tracks = 0;
    group.duration_matches = 0;
    if expected.is_empty() {
        group.comparison = "Sem tracklist de referência; edição não verificada.".into();
        return;
    }
    let mut used = std::collections::HashSet::new();
    let multi = expected.iter().any(|t| t.disc > 1);
    for track in expected {
        let name = normalized(&track.title);
        let found = group.files.iter().enumerate().find(|(i, f)| {
            if used.contains(i) {
                return false;
            }
            let (disc, position, title) = file_identity(f);
            !name.is_empty()
                && title == name
                && position == Some(track.position)
                && disc.unwrap_or(1) == track.disc
                && (!multi || disc.is_some())
                && match (track.duration_seconds, f.duration_seconds) {
                    (Some(a), Some(b)) => a.abs_diff(b) <= 3,
                    _ => true,
                }
        });
        if let Some((i, f)) = found {
            used.insert(i);
            group.matched_tracks += 1;
            if track.duration_seconds.is_some() && f.duration_seconds.is_some() {
                group.duration_matches += 1;
            }
        }
    }
    group.comparison = format!(
        "{}/{} títulos, posições e discos compatíveis; {}/{} durações confirmadas. {} arquivos ofertados. Sugestão para revisão, sem garantia de edição ou áudio sem perdas.",
        group.matched_tracks,
        group.expected_tracks,
        group.duration_matches,
        group.expected_tracks,
        group.files.len()
    );
}

#[cfg(test)]
mod tests;
