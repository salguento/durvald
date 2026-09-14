use crate::api::*;
use crate::enrichment::{
    identity::{normalize_mbid, normalized_match_text},
    models::{
        CacheValidators, DiscographyBatch, LocalReleaseMatchContext, MatchedReleaseMetadata,
        ProviderResponse, ReleaseGroupPage, ReleaseGroupSnapshot,
    },
    policy::MAX_JSON_BYTES,
    transport::*,
};
use serde::Deserialize;
use std::collections::HashSet;
use std::time::Duration;
use tokio::time::{Instant, timeout_at};

const RELEASE_GROUP_PAGE_SIZE: u64 = 100;
const MAX_DISCOGRAPHY_PAGES_PER_REFRESH: usize = 10;
const DISCOGRAPHY_REFRESH_BUDGET: Duration = Duration::from_secs(20);

pub struct MusicBrainz {
    pub(crate) http: EnrichmentHttpClient,
}

#[derive(Deserialize)]
struct Search {
    artists: Vec<RemoteArtist>,
    count: u64,
    offset: u64,
}
#[derive(Deserialize)]
struct Alias {
    name: String,
}
#[derive(Deserialize)]
struct RemoteArtist {
    id: String,
    name: String,
    #[serde(default)]
    aliases: Vec<Alias>,
    #[serde(rename = "type")]
    kind: Option<String>,
    #[serde(default)]
    disambiguation: String,
}
#[derive(Deserialize)]
struct ReleaseGroupTitles {
    #[serde(rename = "release-groups")]
    groups: Vec<ReleaseGroupTitle>,
}
#[derive(Deserialize)]
struct ReleaseGroupTitle {
    title: String,
}

#[derive(Deserialize)]
struct RemoteReleaseGroupsPage {
    #[serde(rename = "release-group-count")]
    count: u64,
    #[serde(rename = "release-group-offset")]
    offset: u64,
    #[serde(rename = "release-groups")]
    groups: Vec<RemoteReleaseGroup>,
}

#[derive(Deserialize)]
struct RemoteReleaseGroup {
    id: String,
    title: String,
    #[serde(rename = "primary-type")]
    primary_type: Option<String>,
    #[serde(default, rename = "secondary-types")]
    secondary_types: Vec<String>,
    #[serde(rename = "first-release-date")]
    first_release_date: Option<String>,
    #[serde(default)]
    genres: Vec<RemoteGenre>,
    #[serde(default)]
    relations: Vec<RemoteArtistRelation>,
}

#[derive(Deserialize)]
struct RemoteGenre {
    name: String,
    #[serde(default)]
    count: i64,
}

#[derive(Deserialize)]
struct RemoteArtistRelation {
    #[serde(rename = "type")]
    kind: String,
    artist: Option<RemoteRelatedArtist>,
}

#[derive(Deserialize)]
struct RemoteRelatedArtist {
    name: String,
}

#[derive(Deserialize)]
struct RemoteReleasesPage {
    #[serde(rename = "release-count")]
    count: u64,
    #[serde(rename = "release-offset")]
    offset: u64,
    releases: Vec<RemoteRelease>,
}

#[derive(Deserialize)]
struct RemoteRelease {
    id: String,
    title: String,
    date: Option<String>,
    #[serde(default, rename = "artist-credit")]
    artist_credit: Vec<RemoteArtistCredit>,
    #[serde(default)]
    media: Vec<RemoteMedium>,
    #[serde(default)]
    genres: Vec<RemoteGenre>,
    #[serde(default)]
    relations: Vec<RemoteArtistRelation>,
}

#[derive(Deserialize)]
struct RemoteArtistCredit {
    name: Option<String>,
    artist: RemoteCreditArtist,
}

#[derive(Deserialize)]
struct RemoteCreditArtist {
    id: String,
    name: String,
}

#[derive(Deserialize)]
struct RemoteMedium {
    position: u32,
    #[serde(default)]
    tracks: Vec<RemoteTrack>,
}

#[derive(Deserialize)]
struct RemoteTrack {
    position: u32,
    title: String,
    length: Option<u64>,
    recording: Option<RemoteRecording>,
}

#[derive(Deserialize)]
struct RemoteRecording {
    title: String,
    length: Option<u64>,
    #[serde(default)]
    relations: Vec<RemoteRelation>,
}

#[derive(Deserialize)]
struct RemoteRelation {
    #[serde(rename = "type")]
    kind: String,
    artist: Option<RemoteRelatedArtist>,
    work: Option<RemoteWork>,
}

#[derive(Deserialize)]
struct RemoteWork {
    #[serde(default)]
    relations: Vec<RemoteArtistRelation>,
}

#[derive(Deserialize)]
struct ArtistLookup {
    #[serde(default)]
    relations: Vec<UrlRelation>,
}
#[derive(Deserialize)]
struct UrlRelation {
    #[serde(rename = "type")]
    kind: String,
    url: RelationUrl,
}
#[derive(Deserialize)]
struct RelationUrl {
    resource: String,
}

/// Quote a Lucene phrase separately from URL query encoding.
fn phrase(value: &str) -> String {
    let escaped: String = value
        .chars()
        .flat_map(|c| {
            if "+-!(){}[]^\"~*?:\\/|&".contains(c) {
                vec!['\\', c]
            } else {
                vec![c]
            }
        })
        .collect();
    format!("\"{escaped}\"")
}

impl MusicBrainz {
    pub fn new() -> Result<Self, TransportError> {
        Ok(Self {
            http: EnrichmentHttpClient::new(
                EnrichmentProvider::MusicBrainz,
                None,
                concat!(
                    "Durvald/",
                    env!("CARGO_PKG_VERSION"),
                    " (https://github.com/salguento/durvald)"
                ),
            )?,
        })
    }

    pub async fn search(
        &self,
        name: &str,
        local_releases: &[String],
    ) -> Result<(Vec<ArtistIdentityCandidate>, bool), TransportError> {
        let query = format!("artist:{}", phrase(name));
        let JsonResponse::Modified { body, .. } = self
            .http
            .get_json::<Search>(
                "ws/2/artist/",
                &[("query", &query), ("fmt", "json"), ("limit", "10")],
                &CacheValidators::default(),
            )
            .await?
        else {
            return Err(TransportError::InvalidJson);
        };
        let truncated = body.count > body.offset.saturating_add(body.artists.len() as u64);
        let mut candidates = Vec::new();
        for artist in body.artists.into_iter().take(10) {
            let mut candidate = artist.normalize(name)?;
            // A bounded sample supplies supporting evidence, never proof of absence.
            // Only inspect three candidates; the whole lookup has a service deadline.
            if candidates.len() < 3 && !local_releases.is_empty() {
                match self
                    .http
                    .get_json::<ReleaseGroupTitles>(
                        "ws/2/release-group/",
                        &[
                            ("artist", &candidate.musicbrainz_id),
                            ("fmt", "json"),
                            ("limit", "100"),
                        ],
                        &CacheValidators::default(),
                    )
                    .await
                {
                    Ok(JsonResponse::Modified { body, .. }) => {
                        for local in local_releases {
                            if body
                                .groups
                                .iter()
                                .any(|g| g.title.to_lowercase() == local.to_lowercase())
                            {
                                candidate
                                    .evidence
                                    .push(format!("local_release_title:{local}"));
                            }
                        }
                    }
                    // Preserve candidates on a partial failure, but stop on cooldown.
                    Err(
                        TransportError::RateLimited { .. }
                        | TransportError::HttpStatus { status: 503, .. },
                    ) => {
                        candidate
                            .evidence
                            .push("release_comparison_unavailable".into());
                        candidates.push(candidate);
                        return Ok((candidates, true));
                    }
                    _ => candidate
                        .evidence
                        .push("release_comparison_unavailable".into()),
                }
            }
            candidates.push(candidate);
        }
        Ok((candidates, truncated))
    }

    /// Follow the curated MusicBrainz URL relationship. Text search is never
    /// used to guess a Wikidata entity.
    pub async fn wikidata_id(&self, mbid: &str) -> Result<Option<String>, TransportError> {
        let mbid = normalize_mbid(mbid).ok_or(TransportError::InvalidRequest)?;
        let path = format!("ws/2/artist/{mbid}");
        let JsonResponse::Modified { body, .. } = self
            .http
            .get_json::<ArtistLookup>(
                &path,
                &[("fmt", "json"), ("inc", "url-rels")],
                &CacheValidators::default(),
            )
            .await?
        else {
            return Err(TransportError::InvalidJson);
        };
        Ok(body.relations.into_iter().find_map(|relation| {
            if relation.kind != "wikidata" {
                return None;
            }
            relation
                .url
                .resource
                .trim_end_matches('/')
                .rsplit('/')
                .next()
                .filter(|id| valid_wikidata_id(id))
                .map(str::to_owned)
        }))
    }

    /// Fetches a bounded sequence of release-group pages. A partial batch
    /// carries the exact remote cursor so a later refresh can continue it.
    pub async fn discography(
        &self,
        mbid: &str,
        start_offset: u64,
        validators: &CacheValidators,
    ) -> Result<ProviderResponse<DiscographyBatch>, TransportError> {
        self.discography_with_limits(
            mbid,
            start_offset,
            validators,
            MAX_DISCOGRAPHY_PAGES_PER_REFRESH,
            DISCOGRAPHY_REFRESH_BUDGET,
        )
        .await
    }

    pub async fn match_local_release(
        &self,
        local: &LocalReleaseMatchContext,
        release_group_mbid: &str,
        identity_generation: u64,
        fetched_at: i64,
    ) -> Result<Option<MatchedReleaseMetadata>, TransportError> {
        let release_group_mbid =
            normalize_mbid(release_group_mbid).ok_or(TransportError::InvalidRequest)?;
        let response = self
            .http
            .get_json::<RemoteReleasesPage>(
                "ws/2/release/",
                &[
                    ("release-group", &release_group_mbid),
                    ("fmt", "json"),
                    (
                        "inc",
                        "recordings+artist-credits+media+genres+artist-rels+recording-level-rels+work-rels+work-level-rels",
                    ),
                    ("limit", "100"),
                ],
                &CacheValidators::default(),
            )
            .await?;
        let JsonResponse::Modified { body, .. } = response else {
            return Err(TransportError::InvalidJson);
        };
        if body.offset != 0 || body.count != body.releases.len() as u64 {
            // An incomplete edition list cannot prove that a match is unique.
            return Ok(None);
        }
        let mut matches = body
            .releases
            .into_iter()
            .filter(|release| release.matches(local))
            .collect::<Vec<_>>();
        if let Some(tagged) = local.tagged_release_mbid.as_deref() {
            matches.retain(|release| release.id.eq_ignore_ascii_case(tagged));
        }
        if matches.len() != 1 {
            return Ok(None);
        }
        matches
            .pop()
            .unwrap()
            .metadata(local, release_group_mbid, identity_generation, fetched_at)
    }

    async fn discography_with_limits(
        &self,
        mbid: &str,
        start_offset: u64,
        validators: &CacheValidators,
        max_pages: usize,
        budget: Duration,
    ) -> Result<ProviderResponse<DiscographyBatch>, TransportError> {
        let mbid = normalize_mbid(mbid).ok_or(TransportError::InvalidRequest)?;
        if start_offset > i64::MAX as u64
            || max_pages == 0
            || budget.is_zero()
            || (start_offset != 0
                && (validators.etag.is_some() || validators.last_modified.is_some()))
        {
            return Err(TransportError::InvalidRequest);
        }
        let deadline = Instant::now() + budget;
        let mut offset = start_offset;
        let mut pages = Vec::new();
        let mut identifiers = HashSet::new();
        let mut response_validators = CacheValidators::default();
        let mut remote_total = 0;
        let mut remote_exhausted = false;
        let mut time_budget_reached = false;
        let no_validators = CacheValidators::default();

        while pages.len() < max_pages && !remote_exhausted {
            let request_validators = if pages.is_empty() {
                validators
            } else {
                &no_validators
            };
            let response = match timeout_at(
                deadline,
                self.release_groups_page(&mbid, offset, request_validators),
            )
            .await
            {
                Ok(response) => response?,
                Err(_) if pages.is_empty() => return Err(TransportError::Timeout),
                Err(_) => {
                    time_budget_reached = true;
                    break;
                }
            };
            match response {
                ProviderResponse::NotModified { validators } if pages.is_empty() => {
                    return Ok(ProviderResponse::NotModified { validators });
                }
                ProviderResponse::NotModified { .. } => return Err(TransportError::InvalidJson),
                ProviderResponse::Modified {
                    value: page,
                    validators,
                } => {
                    for group in &page.groups {
                        if !identifiers.insert(group.musicbrainz_id.clone()) {
                            return Err(TransportError::InvalidJson);
                        }
                    }
                    if pages.is_empty() {
                        response_validators = validators;
                    }
                    remote_total = page.remote_total;
                    remote_exhausted = page.remote_exhausted;
                    offset = page.remote_next_offset.unwrap_or(offset);
                    pages.push(page);
                }
            }
        }

        Ok(ProviderResponse::Modified {
            value: DiscographyBatch {
                remote_next_offset: (!remote_exhausted).then_some(offset),
                remote_total,
                remote_exhausted,
                page_limit_reached: !remote_exhausted
                    && !time_budget_reached
                    && pages.len() == max_pages,
                time_budget_reached,
                pages,
            },
            validators: response_validators,
        })
    }

    async fn release_groups_page(
        &self,
        mbid: &str,
        offset: u64,
        validators: &CacheValidators,
    ) -> Result<ProviderResponse<ReleaseGroupPage>, TransportError> {
        let offset_text = offset.to_string();
        let limit_text = RELEASE_GROUP_PAGE_SIZE.to_string();
        let response = self
            .http
            .get_json::<RemoteReleaseGroupsPage>(
                "ws/2/release-group/",
                &[
                    ("artist", mbid),
                    ("fmt", "json"),
                    ("inc", "genres+artist-rels"),
                    ("limit", &limit_text),
                    ("offset", &offset_text),
                ],
                validators,
            )
            .await?;
        let (body, validators) = match response {
            JsonResponse::Modified { body, validators } => (body, validators),
            JsonResponse::NotModified { validators } => {
                return Ok(ProviderResponse::NotModified { validators });
            }
        };
        if body.offset != offset
            || body.count > i64::MAX as u64
            || body.groups.len() > RELEASE_GROUP_PAGE_SIZE as usize
        {
            return Err(TransportError::InvalidJson);
        }
        let end = offset
            .checked_add(body.groups.len() as u64)
            .ok_or(TransportError::InvalidJson)?;
        if end > body.count || (end < body.count && body.groups.is_empty()) {
            return Err(TransportError::InvalidJson);
        }
        let remote_exhausted = end >= body.count;
        let groups = body
            .groups
            .into_iter()
            .map(RemoteReleaseGroup::normalize)
            .collect::<Result<Vec<_>, _>>()?;
        Ok(ProviderResponse::Modified {
            value: ReleaseGroupPage {
                provider_offset: offset,
                remote_total: body.count,
                groups,
                remote_next_offset: (!remote_exhausted).then_some(end),
                remote_exhausted,
            },
            validators,
        })
    }
}

impl RemoteRelease {
    fn matches(&self, local: &LocalReleaseMatchContext) -> bool {
        if normalized_match_text(&self.title) != normalized_match_text(&local.title)
            || !self.artist_credit.iter().any(|credit| {
                normalize_mbid(&credit.artist.id).as_deref() == Some(local.artist_mbid.as_str())
                    && [credit.name.as_deref(), Some(credit.artist.name.as_str())]
                        .into_iter()
                        .flatten()
                        .any(|name| {
                            normalized_match_text(name) == normalized_match_text(&local.artist_name)
                        })
            })
        {
            return false;
        }
        let mut remote_tracks = self
            .media
            .iter()
            .flat_map(|medium| {
                medium.tracks.iter().map(move |track| {
                    (
                        medium.position,
                        track.position,
                        track
                            .recording
                            .as_ref()
                            .map_or(track.title.as_str(), |recording| recording.title.as_str()),
                        track.length.or_else(|| {
                            track
                                .recording
                                .as_ref()
                                .and_then(|recording| recording.length)
                        }),
                    )
                })
            })
            .collect::<Vec<_>>();
        remote_tracks.sort_by_key(|track| (track.0, track.1));
        if remote_tracks.len() != local.tracks.len() {
            return false;
        }
        local
            .tracks
            .iter()
            .zip(remote_tracks)
            .all(|(local, remote)| {
                u32::from(local.disc_number) == remote.0
                    && u32::from(local.track_number) == remote.1
                    && normalized_match_text(&local.title) == normalized_match_text(remote.2)
                    && remote.3.is_some_and(|milliseconds| {
                        let remote_seconds = milliseconds.div_ceil(1_000);
                        let difference = local.duration_seconds.abs_diff(remote_seconds);
                        difference <= 3
                            || difference.saturating_mul(100)
                                <= local.duration_seconds.max(1).saturating_mul(2)
                    })
            })
    }

    fn metadata(
        self,
        local: &LocalReleaseMatchContext,
        release_group_mbid: String,
        identity_generation: u64,
        fetched_at: i64,
    ) -> Result<Option<MatchedReleaseMetadata>, TransportError> {
        let release_mbid = normalize_mbid(&self.id).ok_or(TransportError::InvalidJson)?;
        let release_date = self
            .date
            .as_deref()
            .map(|date| normalize_partial_date(Some(date)))
            .transpose()?
            .flatten()
            .map(|date| match (date.month, date.day) {
                (Some(month), Some(day)) => format!("{:04}-{month:02}-{day:02}", date.year),
                (Some(month), None) => format!("{:04}-{month:02}", date.year),
                _ => format!("{:04}", date.year),
            });
        let genres = normalize_genres(self.genres)?;
        let mut composers = Vec::new();
        let mut producers = Vec::new();
        collect_artist_relations(&self.relations, &mut composers, &mut producers)?;
        for recording in self
            .media
            .iter()
            .flat_map(|medium| medium.tracks.iter())
            .filter_map(|track| track.recording.as_ref())
        {
            collect_recording_relations(recording, &mut composers, &mut producers)?;
        }
        Ok(Some(MatchedReleaseMetadata {
            release_id: local.release_id,
            artist_id: local.artist_id,
            identity_generation,
            release_group_mbid,
            release_mbid: Some(release_mbid),
            release_date,
            genres,
            composers,
            producers,
            source_url: format!("https://musicbrainz.org/release/{}", self.id),
            fetched_at,
        }))
    }
}

fn collect_recording_relations(
    recording: &RemoteRecording,
    composers: &mut Vec<String>,
    producers: &mut Vec<String>,
) -> Result<(), TransportError> {
    for relation in &recording.relations {
        collect_relation(
            &relation.kind,
            relation.artist.as_ref(),
            composers,
            producers,
        )?;
        if let Some(work) = &relation.work {
            collect_artist_relations(&work.relations, composers, producers)?;
        }
    }
    Ok(())
}

fn collect_artist_relations(
    relations: &[RemoteArtistRelation],
    composers: &mut Vec<String>,
    producers: &mut Vec<String>,
) -> Result<(), TransportError> {
    for relation in relations {
        collect_relation(
            &relation.kind,
            relation.artist.as_ref(),
            composers,
            producers,
        )?;
    }
    Ok(())
}

fn collect_relation(
    kind: &str,
    artist: Option<&RemoteRelatedArtist>,
    composers: &mut Vec<String>,
    producers: &mut Vec<String>,
) -> Result<(), TransportError> {
    let Some(artist) = artist else { return Ok(()) };
    let Some(name) = normalize_text(&artist.name, 500)? else {
        return Ok(());
    };
    let kind = kind.to_lowercase();
    if matches!(kind.as_str(), "composer" | "writer") {
        push_unique(composers, name);
    } else if kind.contains("producer") {
        push_unique(producers, name);
    }
    Ok(())
}

impl RemoteReleaseGroup {
    fn normalize(self) -> Result<ReleaseGroupSnapshot, TransportError> {
        let musicbrainz_id = normalize_mbid(&self.id).ok_or(TransportError::InvalidJson)?;
        let title =
            normalize_text(&self.title, MAX_JSON_BYTES)?.ok_or(TransportError::InvalidJson)?;
        let primary_type = self
            .primary_type
            .as_deref()
            .map(|value| normalize_text(value, 100))
            .transpose()?
            .flatten();
        let mut seen_types = HashSet::new();
        let mut secondary_types = Vec::new();
        for value in self.secondary_types {
            let Some(value) = normalize_text(&value, 100)? else {
                continue;
            };
            if seen_types.insert(value.to_lowercase()) {
                secondary_types.push(value);
            }
        }
        let genres = normalize_genres(self.genres)?;
        let mut composers = Vec::new();
        let mut producers = Vec::new();
        for relation in self.relations {
            let Some(artist) = relation.artist else {
                continue;
            };
            let Some(name) = normalize_text(&artist.name, 500)? else {
                continue;
            };
            let kind = relation.kind.to_lowercase();
            if kind == "composer" {
                push_unique(&mut composers, name);
            } else if kind.contains("producer") {
                push_unique(&mut producers, name);
            }
        }
        Ok(ReleaseGroupSnapshot {
            attribution: EnrichmentAttribution {
                source_url: format!("https://musicbrainz.org/release-group/{musicbrainz_id}"),
                author: Some("MusicBrainz contributors".into()),
                // Genres are MusicBrainz tags (supplementary data), so use the
                // more restrictive attribution for the combined snapshot.
                license_name: Some("CC BY-SA 3.0".into()),
                license_url: Some("https://creativecommons.org/licenses/by-sa/3.0/".into()),
                revision: None,
            },
            musicbrainz_id,
            title,
            primary_type,
            secondary_types,
            first_release_date: normalize_partial_date(self.first_release_date.as_deref())?,
            genres,
            composers,
            producers,
        })
    }
}

fn normalize_genres(mut genres: Vec<RemoteGenre>) -> Result<Vec<String>, TransportError> {
    genres.sort_by(|left, right| {
        right
            .count
            .cmp(&left.count)
            .then_with(|| left.name.cmp(&right.name))
    });
    let mut normalized = Vec::new();
    for genre in genres.into_iter().take(20) {
        let Some(name) = normalize_text(&genre.name, 100)? else {
            continue;
        };
        push_unique(&mut normalized, name);
    }
    Ok(normalized)
}

fn push_unique(values: &mut Vec<String>, value: String) {
    if !values
        .iter()
        .any(|existing| existing.eq_ignore_ascii_case(&value))
    {
        values.push(value);
    }
}

fn normalize_text(value: &str, max_bytes: usize) -> Result<Option<String>, TransportError> {
    let value = value.split_whitespace().collect::<Vec<_>>().join(" ");
    if value.len() > max_bytes {
        return Err(TransportError::InvalidJson);
    }
    Ok((!value.is_empty()).then_some(value))
}

fn normalize_partial_date(
    value: Option<&str>,
) -> Result<Option<ArtistPartialDate>, TransportError> {
    let Some(value) = value.map(str::trim).filter(|value| !value.is_empty()) else {
        return Ok(None);
    };
    let fields = value.split('-').collect::<Vec<_>>();
    if !(1..=3).contains(&fields.len()) {
        return Err(TransportError::InvalidJson);
    }
    let year = fields[0]
        .parse::<i32>()
        .map_err(|_| TransportError::InvalidJson)?;
    let month = fields
        .get(1)
        .map(|value| value.parse::<u8>())
        .transpose()
        .map_err(|_| TransportError::InvalidJson)?;
    let day = fields
        .get(2)
        .map(|value| value.parse::<u8>())
        .transpose()
        .map_err(|_| TransportError::InvalidJson)?;
    if chrono::NaiveDate::from_ymd_opt(
        year,
        u32::from(month.unwrap_or(1)),
        u32::from(day.unwrap_or(1)),
    )
    .is_none()
    {
        return Err(TransportError::InvalidJson);
    }
    Ok(Some(ArtistPartialDate { year, month, day }))
}

fn valid_wikidata_id(value: &str) -> bool {
    value
        .strip_prefix('Q')
        .is_some_and(|digits| !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit()))
}

impl RemoteArtist {
    fn normalize(self, local_name: &str) -> Result<ArtistIdentityCandidate, TransportError> {
        let id = normalize_mbid(&self.id).ok_or(TransportError::InvalidJson)?;
        if self.name.trim().is_empty() {
            return Err(TransportError::InvalidJson);
        }
        let aliases: Vec<_> = self.aliases.into_iter().map(|a| a.name).collect();
        let mut evidence = vec!["musicbrainz_search_candidate".into()];
        if self.name.to_lowercase() == local_name.to_lowercase() {
            evidence.push("exact_name".into());
        }
        if aliases
            .iter()
            .any(|a| a.to_lowercase() == local_name.to_lowercase())
        {
            evidence.push("exact_alias".into());
        }
        Ok(ArtistIdentityCandidate {
            musicbrainz_id: id,
            name: self.name,
            aliases,
            entity_kind: match self.kind.as_deref() {
                Some("Person") => ArtistEntityKind::Person,
                Some("Group") => ArtistEntityKind::Group,
                None => ArtistEntityKind::Unknown,
                _ => ArtistEntityKind::Other,
            },
            disambiguation: self.disambiguation,
            evidence,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::enrichment::transport::tests::{client, response};
    const HOMONYMS: &str = include_str!("../../../tests/fixtures/musicbrainz-homonyms.json");

    #[tokio::test(start_paused = true)]
    async fn homonyms_keep_types_aliases_and_release_evidence_without_auto_confirmation() {
        let (http, mock) = client(vec![
            response(200, &[], &[HOMONYMS], None),
            response(
                200,
                &[],
                &[r#"{"release-groups":[{"title":"Local Album"}]}"#],
                None,
            ),
            response(200, &[], &[r#"{"release-groups":[]}"#], None),
        ]);
        let (candidates, truncated) = MusicBrainz { http }
            .search("Same Name", &["Local Album".into()])
            .await
            .unwrap();
        assert_eq!(candidates.len(), 2);
        assert!(!truncated);
        assert_eq!(candidates[0].entity_kind, ArtistEntityKind::Person);
        assert_eq!(candidates[1].entity_kind, ArtistEntityKind::Group);
        assert_eq!(candidates[0].aliases, vec!["Alias"]);
        assert!(
            candidates[0]
                .evidence
                .contains(&"local_release_title:Local Album".into())
        );
        assert!(
            !candidates[1]
                .evidence
                .contains(&"local_release_title:Local Album".into())
        );
        assert_eq!(mock.calls(), 3);
        assert!(mock.urls()[0].contains("limit=10"));
    }
    #[tokio::test(start_paused = true)]
    async fn empty_is_not_found_but_malformed_and_rate_limited_are_errors() {
        for (status, json) in [(200, "{}"), (404, "{}"), (429, "{}")] {
            let (http, mock) = client(vec![response(status, &[], &[json], None)]);
            assert!(MusicBrainz { http }.search("Name", &[]).await.is_err());
            assert_eq!(mock.calls(), 1);
        }
        let (http, _) = client(vec![response(
            200,
            &[],
            &[r#"{"count":0,"offset":0,"artists":[]}"#],
            None,
        )]);
        assert!(
            MusicBrainz { http }
                .search("Name", &[])
                .await
                .unwrap()
                .0
                .is_empty()
        );
    }
    #[test]
    fn lucene_and_path_inputs_cannot_inject_query_syntax() {
        assert_eq!(
            phrase("AC/DC \"x\" OR artist:*"),
            "\"AC\\/DC \\\"x\\\" OR artist\\:\\*\""
        );
        for invalid in [
            "../../foo",
            "00000000-0000-0000-0000-000000000000",
            "11111111-1111-4111-8111-11111111111Z",
        ] {
            assert!(normalize_mbid(invalid).is_none());
        }
    }

    #[tokio::test(start_paused = true)]
    async fn wikidata_relation_is_curated_and_validated() {
        let (http, _) = client(vec![response(
            200,
            &[],
            &[
                r#"{"relations":[{"type":"official homepage","url":{"resource":"https://example.test"}},{"type":"wikidata","url":{"resource":"https://www.wikidata.org/wiki/Q123"}}]}"#,
            ],
            None,
        )]);
        assert_eq!(
            MusicBrainz { http }
                .wikidata_id("11111111-1111-4111-8111-111111111111")
                .await
                .unwrap(),
            Some("Q123".into())
        );
    }

    #[tokio::test(start_paused = true)]
    async fn discography_paginates_and_normalizes_release_groups() {
        let (http, mock) = client(vec![
            response(
                200,
                &[("etag", "\"catalog-v1\"")],
                &[r#"{
                    "release-group-count":3,
                    "release-group-offset":0,
                    "release-groups":[
                        {"id":"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA","title":"  First   Album  ","primary-type":" Album ","secondary-types":[" Compilation ","compilation",""],"first-release-date":"1999"},
                        {"id":"BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB","title":"Second","primary-type":null,"secondary-types":[],"first-release-date":"2001-02"}
                    ]
                }"#],
                None,
            ),
            response(
                200,
                &[],
                &[r#"{
                    "release-group-count":3,
                    "release-group-offset":2,
                    "release-groups":[
                        {"id":"CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC","title":"Third","primary-type":"EP","secondary-types":["Live"],"first-release-date":"2003-04-05"}
                    ]
                }"#],
                None,
            ),
        ]);
        let ProviderResponse::Modified {
            value: batch,
            validators,
        } = MusicBrainz { http }
            .discography(
                "11111111-1111-4111-8111-111111111111",
                0,
                &CacheValidators::default(),
            )
            .await
            .unwrap()
        else {
            panic!("unconditional catalog request returned 304")
        };
        assert_eq!(batch.pages.len(), 2);
        assert_eq!(batch.remote_total, 3);
        assert!(batch.remote_exhausted);
        assert_eq!(batch.remote_next_offset, None);
        assert!(!batch.page_limit_reached);
        assert!(!batch.time_budget_reached);
        assert_eq!(validators.etag.as_deref(), Some("\"catalog-v1\""));
        let first = &batch.pages[0].groups[0];
        assert_eq!(first.musicbrainz_id, "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa");
        assert_eq!(first.title, "First Album");
        assert_eq!(first.primary_type.as_deref(), Some("Album"));
        assert_eq!(first.secondary_types, vec!["Compilation"]);
        assert_eq!(
            first.first_release_date,
            Some(ArtistPartialDate {
                year: 1999,
                month: None,
                day: None
            })
        );
        assert_eq!(first.attribution.license_name.as_deref(), Some("CC0 1.0"));
        assert!(mock.urls()[0].contains("limit=100"));
        assert!(mock.urls()[0].contains("offset=0"));
        assert!(mock.urls()[1].contains("offset=2"));
    }

    #[tokio::test(start_paused = true)]
    async fn discography_returns_a_cursor_at_page_and_time_budgets() {
        let page = r#"{
            "release-group-count":2,
            "release-group-offset":0,
            "release-groups":[
                {"id":"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA","title":"First","primary-type":"Album","secondary-types":[],"first-release-date":null}
            ]
        }"#;
        let (http, mock) = client(vec![response(200, &[], &[page], None)]);
        let ProviderResponse::Modified { value: capped, .. } = MusicBrainz { http }
            .discography_with_limits(
                "11111111-1111-4111-8111-111111111111",
                0,
                &CacheValidators::default(),
                1,
                Duration::from_secs(20),
            )
            .await
            .unwrap()
        else {
            panic!("unconditional catalog request returned 304")
        };
        assert!(capped.page_limit_reached);
        assert!(!capped.time_budget_reached);
        assert_eq!(capped.remote_next_offset, Some(1));
        assert_eq!(mock.calls(), 1);

        let mut delayed = response(
            200,
            &[],
            &[r#"{
            "release-group-count":2,
            "release-group-offset":1,
            "release-groups":[
                {"id":"BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB","title":"Second","primary-type":"Album","secondary-types":[],"first-release-date":null}
            ]
        }"#],
            None,
        );
        delayed.delay = Duration::from_secs(30);
        let (http, mock) = client(vec![response(200, &[], &[page], None), delayed]);
        let ProviderResponse::Modified { value: timed, .. } = MusicBrainz { http }
            .discography_with_limits(
                "11111111-1111-4111-8111-111111111111",
                0,
                &CacheValidators::default(),
                10,
                Duration::from_secs(1),
            )
            .await
            .unwrap()
        else {
            panic!("unconditional catalog request returned 304")
        };
        assert!(timed.time_budget_reached);
        assert!(!timed.page_limit_reached);
        assert_eq!(timed.remote_next_offset, Some(1));
        assert_eq!(mock.calls(), 2);
    }

    #[tokio::test(start_paused = true)]
    async fn discography_rejects_malformed_pages_and_honors_revalidation() {
        for json in [
            r#"{"release-group-count":1,"release-group-offset":1,"release-groups":[]}"#,
            r#"{"release-group-count":2,"release-group-offset":0,"release-groups":[]}"#,
            r#"{"release-group-count":1,"release-group-offset":0,"release-groups":[{"id":"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA","title":"Album","primary-type":"Album","secondary-types":[],"first-release-date":"2023-02-29"}]}"#,
        ] {
            let (http, _) = client(vec![response(200, &[], &[json], None)]);
            assert!(matches!(
                MusicBrainz { http }
                    .discography_with_limits(
                        "11111111-1111-4111-8111-111111111111",
                        0,
                        &CacheValidators::default(),
                        1,
                        Duration::from_secs(20),
                    )
                    .await,
                Err(TransportError::InvalidJson)
            ));
        }

        let validators = CacheValidators {
            etag: Some("\"catalog-v1\"".into()),
            last_modified: None,
        };
        let (http, _) = client(vec![response(304, &[], &[], None)]);
        assert!(matches!(
            MusicBrainz { http }.discography(
                "11111111-1111-4111-8111-111111111111",
                0,
                &validators
            ).await,
            Ok(ProviderResponse::NotModified { validators: received }) if received == validators
        ));
    }
}
