use crate::api::*;
use crate::enrichment::{identity::normalize_mbid, models::CacheValidators, transport::*};
use serde::Deserialize;

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
struct ReleaseGroups {
    #[serde(rename = "release-groups")]
    groups: Vec<ReleaseGroup>,
}
#[derive(Deserialize)]
struct ReleaseGroup {
    title: String,
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
                    .get_json::<ReleaseGroups>(
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
}
