//! Explicit source discovery/adoption. No library writes during a search.
use crate::{
    api::*,
    application::music_plugins::{PluginRuntime, context::RequestScope},
    domain::{
        ids::TrackId,
        music::{
            identity::*,
            sources::{
                PlaybackMode, SourceAvailability, SourceCandidate as DomainCandidate,
                SourceSearchRequest,
            },
        },
    },
    infrastructure::sqlite::sources::SqliteSources,
};
use std::{collections::HashMap, sync::Arc};
use tokio::sync::Mutex;
pub(crate) struct SourcesApplication {
    repository: SqliteSources,
    runtime: Arc<PluginRuntime>,
}
#[derive(Default)]
pub(crate) struct SourceSession {
    state: Mutex<State>,
}
#[derive(Default)]
struct State {
    generation: u64,
    signature: String,
    scope: RequestScope,
    ticket: Option<crate::application::music_plugins::RequestTicket>,
    closed: bool,
    serial: u64,
    pending: HashMap<String, u64>,
    candidates: HashMap<String, (SourceCandidate, String)>,
    entry: Option<CatalogEntry>,
}
impl SourceSession {
    pub(crate) async fn close(&self) {
        let mut s = self.state.lock().await;
        s.closed = true;
        s.candidates.clear();
        if let Some(t) = s.ticket.take() {
            t.cancel();
        }
    }
}
impl SourcesApplication {
    pub(crate) async fn new(repository: SqliteSources, runtime: Arc<PluginRuntime>) -> Self {
        let _ = runtime
            .register_builtin_with_default(
                Arc::new(crate::infrastructure::service_links::ServiceLinks),
                true,
            )
            .await;
        Self {
            repository,
            runtime,
        }
    }
    pub(crate) async fn resolve_soundcloud_link_entry(
        &self,
        url: String,
        title: String,
        artist: Option<String>,
    ) -> CoreResult<CatalogEntry> {
        if title.trim().is_empty() {
            return Err(invalid("Informe o nome da faixa."));
        }
        if title.trim().len() > 500
            || title.chars().any(char::is_control)
            || artist
                .as_ref()
                .is_some_and(|a| a.len() > 2000 || a.chars().any(char::is_control))
        {
            return Err(invalid(
                "O nome ou artista contém caracteres inválidos ou é muito longo.",
            ));
        }
        let url = url.trim().to_owned();
        if !crate::infrastructure::soundcloud_links::is_short_link(&url) {
            return self.soundcloud_link_entry(url, title, artist);
        }
        let scope = RequestScope::default();
        // A user-supplied URL is a provisional reference only for this request.
        // The resolver supplies the real permalink identity before any save.
        let target = CatalogEntityRef::External(
            ExternalEntityRef::new(
                ProviderId::new("soundcloud").unwrap(),
                ExternalEntityKind::AudioTrack,
                &url,
            )
            .map_err(|_| invalid("Link SoundCloud inválido."))?,
        );
        let candidates = self.runtime.find_sources(&ProviderId::new("service-links").unwrap(), scope.begin(), SourceSearchRequest {target, link:Some(url)}).await.map_err(|e| {
            use crate::domain::music::{plugins::PluginError as P, IntegrationError as I};
            match e {
                P::Disabled | P::NotRegistered => invalid("A busca por links está desativada. Ative-a nas origens da faixa."),
                P::Adapter(I::InvalidInput(_)) => invalid("O link compartilhado não aponta para uma faixa individual SoundCloud. Links de perfis e álbuns não são aceitos."),
                P::Adapter(I::NotFound) => invalid("O link compartilhado não foi encontrado ou expirou. Copie novamente o link da faixa."),
                P::Timeout | P::Adapter(I::Timeout) => CoreError::Network {message:"O SoundCloud demorou para resolver o link curto. Tente novamente ou copie o endereço completo da faixa.".into()},
                P::Adapter(I::RateLimited {..}) => CoreError::Network {message:"O SoundCloud pediu para aguardar. Tente novamente mais tarde.".into()},
                _ => CoreError::Network {message:"Não foi possível expandir o link curto SoundCloud. Verifique a conexão ou abra o link no navegador e copie o endereço completo da faixa.".into()},
            }
        })?;
        let candidate = candidates
            .into_iter()
            .find(|c| c.reference.entity().provider().as_str() == "soundcloud")
            .ok_or_else(|| invalid("O link não aponta para uma faixa SoundCloud."))?;
        self.soundcloud_link_entry(
            candidate.reference.canonical_url().as_str().into(),
            title,
            artist,
        )
    }
    pub(crate) fn soundcloud_link_entry(
        &self,
        url: String,
        title: String,
        artist: Option<String>,
    ) -> CoreResult<CatalogEntry> {
        let media = crate::infrastructure::service_links::canonical_link(url.trim())
            .filter(|m| m.entity().provider().as_str() == "soundcloud")
            .ok_or_else(|| invalid("Informe um link de faixa individual SoundCloud."))?;
        let mut entry = CatalogEntry {
            reference: CatalogReference {
                provider: "soundcloud".into(),
                kind: CatalogItemKind::AudioTrack,
                id: media.entity().external_id().into(),
            },
            title: title.trim().into(),
            artist_credit: artist
                .map(|a| a.trim().to_owned())
                .filter(|a| !a.is_empty()),
            version_label: None,
            duration_seconds: None,
            canonical_url: Some(media.canonical_url().as_str().into()),
        };
        validate_entry(&mut entry)?;
        Ok(entry)
    }
    pub(crate) async fn list(&self, track: i64) -> CoreResult<Vec<TrackSource>> {
        self.repository.list(track).await
    }
    pub(crate) async fn enabled(
        &self,
        track: i64,
        source: i64,
        value: bool,
    ) -> CoreResult<TrackSource> {
        self.repository.enabled(track, source, value).await
    }
    pub(crate) async fn remove(&self, track: i64, source: i64) -> CoreResult<()> {
        self.repository.remove(track, source).await
    }
    pub(crate) async fn prefer(&self, track: i64, source: Option<i64>) -> CoreResult<()> {
        self.repository.prefer(track, source).await
    }
    pub(crate) async fn providers(&self) -> CoreResult<Vec<SourceProvider>> {
        Ok(self
            .runtime
            .list()
            .await
            .map_err(|_| storage())?
            .into_iter()
            .filter(|s| {
                s.manifest
                    .capabilities
                    .contains(&crate::domain::music::plugins::PluginCapability::SourceSearch)
            })
            .map(|s| SourceProvider {
                name: match s.manifest.id.as_str() {
                    "musicbrainz" => "MusicBrainz — links da gravação".into(),
                    "service-links" => "Links SoundCloud, YouTube e Bandcamp".into(),
                    id => id.into(),
                },
                id: s.manifest.id.as_str().into(),
                enabled: s.enabled,
            })
            .collect())
    }
    pub(crate) async fn set_enabled(&self, id: String, enabled: bool) -> CoreResult<()> {
        if !self.providers().await?.iter().any(|p| p.id == id) {
            return Err(invalid("Unknown source provider"));
        }
        self.runtime
            .set_enabled(
                &ProviderId::new(id).map_err(|_| invalid("Invalid provider"))?,
                enabled,
            )
            .await
            .map_err(|_| storage())?;
        Ok(())
    }
    pub(crate) async fn search(
        &self,
        session: &SourceSession,
        provider: String,
        mut entry: CatalogEntry,
        link: Option<String>,
        generation: u64,
    ) -> CoreResult<SourceSearchPage> {
        validate_entry(&mut entry)?;
        if generation == 0 || link.as_ref().is_some_and(|u| u.len() > 2048) {
            return Err(invalid("Invalid source search"));
        }
        if !self.providers().await?.iter().any(|p| p.id == provider) {
            return Ok(failed(provider, generation, CatalogFailure::Disabled));
        }
        let id = ProviderId::new(&provider).map_err(|_| invalid("Invalid provider"))?;
        let signature = serde_json::to_string(&(&entry, &link))
            .map_err(|_| invalid("Invalid source search"))?;
        let (ticket, serial) = {
            let mut s = session.state.lock().await;
            if s.closed || generation < s.generation {
                return Ok(failed(provider, generation, CatalogFailure::Cancelled));
            }
            if generation > s.generation {
                s.generation = generation;
                s.signature = signature.clone();
                s.candidates.clear();
                s.pending.clear();
                s.entry = Some(entry.clone());
                s.ticket = Some(s.scope.begin());
            } else if signature != s.signature {
                return Err(invalid("Generation belongs to another selected item"));
            }
            s.serial += 1;
            let serial = s.serial;
            s.pending.insert(provider.clone(), serial);
            s.candidates.retain(|_, (_, p)| p != &provider);
            (
                s.ticket.clone().ok_or_else(|| invalid("Closed search"))?,
                serial,
            )
        };
        let mut reference = entry.reference.clone();
        if reference.provider == "library" {
            let track = reference
                .id
                .parse::<i64>()
                .map_err(|_| invalid("Invalid track"))?;
            if let Some(external) = self.repository.target(track).await? {
                reference = external;
            }
        }
        let target = if reference.provider == "library" {
            CatalogEntityRef::Local(LocalEntityRef::Track(
                TrackId::try_from(
                    reference
                        .id
                        .parse::<i64>()
                        .map_err(|_| invalid("Invalid track"))?,
                )
                .map_err(|_| invalid("Invalid track"))?,
            ))
        } else {
            CatalogEntityRef::External(
                ExternalEntityRef::new(
                    ProviderId::new(&reference.provider)
                        .map_err(|_| invalid("Invalid provider"))?,
                    match reference.kind {
                        CatalogItemKind::Recording => ExternalEntityKind::Recording,
                        CatalogItemKind::ReleaseTrack => ExternalEntityKind::ReleaseTrack,
                        CatalogItemKind::AudioTrack => ExternalEntityKind::AudioTrack,
                        CatalogItemKind::Video => ExternalEntityKind::Video,
                        _ => return Err(invalid("Select an individual track")),
                    },
                    reference.id,
                )
                .map_err(|_| invalid("Invalid reference"))?,
            )
        };
        let link = link.or_else(|| {
            matches!(
                entry.reference.kind,
                CatalogItemKind::AudioTrack | CatalogItemKind::Video
            )
            .then(|| entry.canonical_url.clone())
            .flatten()
        });
        let result = self
            .runtime
            .find_sources(&id, ticket.clone(), SourceSearchRequest { target, link })
            .await;
        let mut s = session.state.lock().await;
        if s.closed
            || s.generation != generation
            || s.pending.get(&provider) != Some(&serial)
            || !ticket.is_current()
        {
            return Ok(failed(provider, generation, CatalogFailure::Cancelled));
        }
        let candidates = match result {
            Ok(c) => c,
            Err(e) => {
                return Ok(failed(
                    provider,
                    generation,
                    crate::application::catalog_search::failure(e).0,
                ));
            }
        };
        let mut output = Vec::new();
        for (i, c) in candidates.into_iter().take(50).enumerate() {
            if let Some(c) = public_candidate(c, format!("{provider}:{generation}:{serial}:{i}")) {
                s.candidates
                    .insert(c.candidate_id.clone(), (c.clone(), provider.clone()));
                output.push(c);
            }
        }
        Ok(SourceSearchPage {
            provider,
            generation,
            candidates: output,
            failure: None,
        })
    }
    pub(crate) async fn listening_candidate(
        &self,
        session: &SourceSession,
        id: String,
    ) -> CoreResult<(CatalogEntry, SourceCandidate)> {
        let (entry, candidate, provider) = {
            let s = session.state.lock().await;
            if s.closed {
                return Err(invalid("Closed source search"));
            }
            let (c, p) = s
                .candidates
                .get(&id)
                .ok_or_else(|| invalid("Candidate expired; search again"))?;
            (
                s.entry.clone().ok_or_else(|| invalid("No selected item"))?,
                c.clone(),
                p.clone(),
            )
        };
        if !self
            .providers()
            .await?
            .iter()
            .any(|p| p.id == provider && p.enabled)
        {
            return Err(invalid("Source provider is disabled"));
        }
        if candidate.provider != "soundcloud" {
            return Err(invalid("This source supports external open only"));
        }
        Ok((entry, candidate))
    }
    pub(crate) async fn attach(
        &self,
        session: &SourceSession,
        candidate: String,
        track: Option<i64>,
        confirmed: bool,
    ) -> CoreResult<TrackSource> {
        if !confirmed {
            return Err(invalid(
                "Review the track, edition and source before confirming the association",
            ));
        }
        let (candidate, provider, entry) = {
            let s = session.state.lock().await;
            if s.closed {
                return Err(invalid("Closed source search"));
            }
            let (c, p) = s
                .candidates
                .get(&candidate)
                .ok_or_else(|| invalid("Candidate expired; search the selected item again"))?;
            (
                c.clone(),
                p.clone(),
                s.entry.clone().ok_or_else(|| invalid("No selected item"))?,
            )
        };
        if !self
            .providers()
            .await?
            .iter()
            .any(|p| p.id == provider && p.enabled)
        {
            return Err(invalid("Source provider is disabled"));
        }
        let track = track.or_else(|| {
            (entry.reference.provider == "library")
                .then(|| entry.reference.id.parse().ok())
                .flatten()
        });
        self.repository
            .attach(
                track,
                entry,
                candidate,
                format!("user_confirmed:{provider}"),
            )
            .await
    }
    pub(crate) async fn test(&self, track: i64, source: i64) -> CoreResult<SourceTestResult> {
        let saved = self.repository.get(track, source).await?;
        let (capability, state, message) = if let Some(path) = saved.local_path.clone() {
            let result = crate::audio::AudioPlayer::verify_local_file(path).await;
            if result.is_ok() {
                (
                    SourceCapability::FullAudio,
                    "available",
                    "Arquivo local aberto e decodificado. A reprodução interna está disponível.",
                )
            } else {
                (
                    SourceCapability::Unavailable,
                    "unavailable",
                    "Não foi possível abrir ou decodificar o arquivo local.",
                )
            }
        } else if saved
            .canonical_url
            .as_deref()
            .and_then(crate::infrastructure::service_links::canonical_link)
            .is_some()
        {
            (
                SourceCapability::ExternalOpen,
                "unknown",
                "Link de serviço reconhecido. Este teste não acessa o serviço nem comprova áudio completo, prévia ou disponibilidade; confira o acesso abrindo o link.",
            )
        } else {
            (
                SourceCapability::Unknown,
                "unknown",
                "Não há adaptador para verificar esta origem. Sua disponibilidade permanece desconhecida.",
            )
        };
        Ok(SourceTestResult {
            source: self
                .repository
                .tested(track, source, saved.local_path, capability, state)
                .await?,
            message: message.into(),
        })
    }
    pub(crate) async fn open_url(&self, track: i64, source: i64) -> CoreResult<String> {
        let s = self.repository.get(track, source).await?;
        s.canonical_url
            .as_deref()
            .and_then(crate::infrastructure::service_links::canonical_link)
            .map(|m| m.canonical_url().as_str().to_owned())
            .ok_or_else(|| invalid("This source has no supported service page"))
    }
    pub(crate) async fn attach_local(&self, track: i64, path: String) -> CoreResult<TrackSource> {
        crate::domain::music::sources::LocalMediaPath::new(std::path::PathBuf::from(&path))
            .map_err(|_| invalid("Invalid local file path"))?;
        if !tokio::fs::metadata(&path)
            .await
            .map(|m| m.is_file())
            .unwrap_or(false)
        {
            return Err(invalid("Choose an existing local file"));
        }
        self.repository.attach_local(track, path).await
    }
}
fn public_candidate(c: DomainCandidate, id: String) -> Option<SourceCandidate> {
    let safe =
        crate::infrastructure::service_links::canonical_link(c.reference.canonical_url().as_str())?;
    if safe.entity() != c.reference.entity()
        || c.title.len() > 1000
        || c.title.chars().any(char::is_control)
        || [&c.uploader, &c.version_label]
            .into_iter()
            .flatten()
            .any(|s| s.len() > 1000 || s.chars().any(char::is_control))
    {
        return None;
    }
    let capability = if c.availability == SourceAvailability::Unavailable {
        SourceCapability::Unavailable
    } else if c.availability == SourceAvailability::PreviewOnly {
        SourceCapability::Preview
    } else if c
        .capabilities
        .playback
        .iter()
        .any(|p| p.mode == PlaybackMode::ExternalOpen)
    {
        SourceCapability::ExternalOpen
    } else {
        SourceCapability::Unknown
    };
    Some(SourceCandidate {
        candidate_id: id,
        provider: c.reference.entity().provider().as_str().into(),
        external_id: c.reference.entity().external_id().into(),
        canonical_url: safe.canonical_url().as_str().into(),
        title: c.title,
        uploader: c.uploader,
        version_label: c.version_label,
        duration_seconds: c.duration_seconds,
        capability,
    })
}
fn validate_entry(entry: &mut CatalogEntry) -> CoreResult<()> {
    if entry.reference.provider == "library" && entry.reference.kind == CatalogItemKind::Track {
        TrackId::try_from(
            entry
                .reference
                .id
                .parse::<i64>()
                .map_err(|_| invalid("Invalid track"))?,
        )
        .map_err(|_| invalid("Invalid track"))?;
    } else {
        if entry.reference.provider == "library" || entry.reference.provider == "local" {
            return Err(invalid("Invalid remote catalog reference"));
        }
        entry.reference =
            crate::application::catalog_details::validate_reference(entry.reference.clone())?;
    }
    if let Some(url) = &entry.canonical_url {
        if url.len() > 2048 {
            return Err(invalid("Invalid catalog URL"));
        }
        crate::domain::music::sources::CanonicalMediaUrl::new(url)
            .map_err(|_| invalid("Invalid catalog URL"))?;
    }
    if !matches!(
        entry.reference.kind,
        CatalogItemKind::Track
            | CatalogItemKind::Recording
            | CatalogItemKind::ReleaseTrack
            | CatalogItemKind::AudioTrack
            | CatalogItemKind::Video
    ) || entry.title.trim().is_empty()
        || entry.title.len() > 500
        || entry.title.chars().any(char::is_control)
        || entry
            .artist_credit
            .as_ref()
            .is_some_and(|a| a.len() > 2000 || a.chars().any(char::is_control))
        || entry.duration_seconds.is_some_and(|s| s > i64::MAX as u64)
    {
        return Err(invalid("Select an individual catalog track"));
    }
    Ok(())
}
fn failed(provider: String, generation: u64, failure: CatalogFailure) -> SourceSearchPage {
    SourceSearchPage {
        provider,
        generation,
        candidates: vec![],
        failure: Some(failure),
    }
}
fn invalid(s: &str) -> CoreError {
    CoreError::InvalidInput { message: s.into() }
}
fn storage() -> CoreError {
    CoreError::Storage {
        message: "Source provider preferences unavailable".into(),
    }
}
