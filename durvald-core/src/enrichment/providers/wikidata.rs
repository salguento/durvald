use crate::api::*;
use crate::enrichment::{
    models::{CacheValidators, ProviderResponse},
    transport::*,
};
use serde::Deserialize;
use serde_json::Value;
use std::collections::HashMap;

pub struct Wikidata {
    pub(crate) http: EnrichmentHttpClient,
}

#[derive(Debug)]
pub struct WikidataProfile {
    pub profile: ArtistProfile,
    pub article_title: Option<String>,
    pub article_language: Option<String>,
    pub commons_file: Option<String>,
}

#[derive(Deserialize)]
struct EntityResponse {
    entities: HashMap<String, Entity>,
}

#[derive(Deserialize)]
struct Entity {
    #[serde(default)]
    claims: HashMap<String, Vec<Statement>>,
    #[serde(default)]
    sitelinks: HashMap<String, Sitelink>,
    #[serde(default)]
    labels: HashMap<String, Label>,
    #[serde(default)]
    lastrevid: Option<u64>,
}

#[derive(Deserialize)]
struct Statement {
    mainsnak: Snak,
    #[serde(default)]
    rank: String,
}

#[derive(Deserialize)]
struct Snak {
    #[serde(default)]
    datavalue: Option<DataValue>,
}

#[derive(Deserialize)]
struct DataValue {
    value: Value,
}

#[derive(Deserialize)]
struct Sitelink {
    title: String,
}

#[derive(Deserialize)]
struct Label {
    value: String,
}

impl Wikidata {
    pub fn new() -> Result<Self, TransportError> {
        Ok(Self {
            http: EnrichmentHttpClient::new(
                EnrichmentProvider::Wikidata,
                None,
                concat!(
                    "Durvald/",
                    env!("CARGO_PKG_VERSION"),
                    " (https://github.com/salguento/durvald)"
                ),
            )?,
        })
    }

    pub async fn profile(
        &self,
        id: &str,
        requested_language: &str,
        validators: &CacheValidators,
    ) -> Result<ProviderResponse<WikidataProfile>, TransportError> {
        if !valid_id(id) {
            return Err(TransportError::InvalidRequest);
        }
        let languages = format!("{requested_language}|en");
        let response = self
            .http
            .get_json::<EntityResponse>(
                "w/api.php",
                &[
                    ("action", "wbgetentities"),
                    ("ids", id),
                    ("props", "claims|sitelinks|labels|info"),
                    ("languages", &languages),
                    ("format", "json"),
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
        let entity = body.entities.get(id).ok_or(TransportError::InvalidJson)?;
        let kind = entity_kind(entity);
        let (article_language, article_title) = article(entity, requested_language);
        let birth_date = (kind == ArtistEntityKind::Person)
            .then(|| date_claim(entity, "P569"))
            .flatten();
        let formation_date = (kind == ArtistEntityKind::Group)
            .then(|| date_claim(entity, "P571"))
            .flatten();
        let place_ids = [
            entity_claim(entity, "P19"),
            entity_claim(entity, "P740"),
            entity_claim(entity, "P495"),
        ];
        let labels = self
            .labels(
                place_ids.iter().flatten().map(String::as_str).collect(),
                requested_language,
            )
            .await
            .unwrap_or_default();
        let label = |id: &Option<String>| id.as_ref().and_then(|id| labels.get(id)).cloned();
        Ok(ProviderResponse::Modified {
            value: WikidataProfile {
                article_language,
                article_title,
                commons_file: string_claim(entity, "P18"),
                profile: ArtistProfile {
                    entity_kind: kind,
                    birth_date,
                    birth_place: label(&place_ids[0]),
                    formation_date,
                    formation_place: label(&place_ids[1]),
                    origin_place: label(&place_ids[2]),
                    biography: None,
                    attribution: EnrichmentAttribution {
                        source_url: format!("https://www.wikidata.org/wiki/{id}"),
                        author: Some("Wikidata contributors".into()),
                        license_name: Some("CC0 1.0".into()),
                        license_url: Some(
                            "https://creativecommons.org/publicdomain/zero/1.0/".into(),
                        ),
                        revision: entity.lastrevid.map(|value| value.to_string()),
                    },
                },
            },
            validators,
        })
    }

    async fn labels(
        &self,
        ids: Vec<&str>,
        language: &str,
    ) -> Result<HashMap<String, String>, TransportError> {
        if ids.is_empty() {
            return Ok(HashMap::new());
        }
        let joined = ids.join("|");
        let languages = format!("{language}|en");
        let JsonResponse::Modified { body, .. } = self
            .http
            .get_json::<EntityResponse>(
                "w/api.php",
                &[
                    ("action", "wbgetentities"),
                    ("ids", &joined),
                    ("props", "labels"),
                    ("languages", &languages),
                    ("format", "json"),
                ],
                &CacheValidators::default(),
            )
            .await?
        else {
            return Err(TransportError::InvalidJson);
        };
        Ok(body
            .entities
            .into_iter()
            .filter_map(|(id, entity)| {
                entity
                    .labels
                    .get(language)
                    .or_else(|| entity.labels.get("en"))
                    .or_else(|| entity.labels.values().next())
                    .map(|label| (id, label.value.clone()))
            })
            .collect())
    }
}

fn valid_id(value: &str) -> bool {
    value
        .strip_prefix('Q')
        .is_some_and(|v| !v.is_empty() && v.bytes().all(|b| b.is_ascii_digit()))
}

fn best_statement<'a>(entity: &'a Entity, property: &str) -> Option<&'a Statement> {
    let values = entity.claims.get(property)?;
    values
        .iter()
        .find(|s| s.rank == "preferred")
        .or_else(|| values.iter().find(|s| s.rank != "deprecated"))
}

fn entity_claim(entity: &Entity, property: &str) -> Option<String> {
    best_statement(entity, property)?
        .mainsnak
        .datavalue
        .as_ref()?
        .value
        .get("id")?
        .as_str()
        .filter(|v| valid_id(v))
        .map(str::to_owned)
}

fn string_claim(entity: &Entity, property: &str) -> Option<String> {
    best_statement(entity, property)?
        .mainsnak
        .datavalue
        .as_ref()?
        .value
        .as_str()
        .map(str::to_owned)
}

fn entity_kind(entity: &Entity) -> ArtistEntityKind {
    match entity_claim(entity, "P31").as_deref() {
        Some("Q5") => ArtistEntityKind::Person,
        Some("Q215380") | Some("Q5741069") | Some("Q2088357") => ArtistEntityKind::Group,
        Some(_) => ArtistEntityKind::Other,
        None => ArtistEntityKind::Unknown,
    }
}

fn date_claim(entity: &Entity, property: &str) -> Option<ArtistPartialDate> {
    let value = best_statement(entity, property)?
        .mainsnak
        .datavalue
        .as_ref()?
        .value
        .as_object()?;
    let time = value.get("time")?.as_str()?;
    let precision = value.get("precision")?.as_u64()?;
    let (negative, date) = if let Some(date) = time.strip_prefix('+') {
        (false, date)
    } else {
        (true, time.strip_prefix('-')?)
    };
    let mut fields = date.split('T').next()?.split('-');
    let mut year = fields.next()?.parse::<i32>().ok()?;
    if negative {
        year = -year;
    }
    let month = fields
        .next()?
        .parse::<u8>()
        .ok()
        .filter(|_| precision >= 10);
    let day = fields
        .next()?
        .parse::<u8>()
        .ok()
        .filter(|_| precision >= 11);
    Some(ArtistPartialDate { year, month, day })
}

fn article(entity: &Entity, requested: &str) -> (Option<String>, Option<String>) {
    let base = requested.split('-').next().unwrap_or(requested);
    for language in [requested, base, "en"] {
        let key = format!("{language}wiki");
        if let Some(link) = entity.sitelinks.get(&key) {
            return (Some(language.to_owned()), Some(link.title.clone()));
        }
    }
    (None, None)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::enrichment::transport::tests::{client, response};

    #[tokio::test(start_paused = true)]
    async fn preserves_partial_date_kind_sitelink_and_place_label() {
        let entity = r#"{"entities":{"Q1":{"lastrevid":42,"labels":{},"claims":{"P31":[{"rank":"normal","mainsnak":{"datavalue":{"value":{"id":"Q5"}}}}],"P569":[{"rank":"normal","mainsnak":{"datavalue":{"value":{"time":"+1965-00-00T00:00:00Z","precision":9}}}}],"P19":[{"rank":"normal","mainsnak":{"datavalue":{"value":{"id":"Q2"}}}}],"P18":[{"rank":"normal","mainsnak":{"datavalue":{"value":"Portrait.jpg"}}}]},"sitelinks":{"ptwiki":{"title":"Artista"}}}}}"#;
        let labels = r#"{"entities":{"Q2":{"claims":{},"sitelinks":{},"labels":{"pt":{"value":"Cidade"}}}}}"#;
        let (http, mock) = client(vec![
            response(200, &[], &[entity], None),
            response(200, &[], &[labels], None),
        ]);
        let ProviderResponse::Modified { value: result, .. } = Wikidata { http }
            .profile("Q1", "pt", &CacheValidators::default())
            .await
            .unwrap()
        else {
            panic!("expected modified response")
        };
        assert_eq!(result.profile.entity_kind, ArtistEntityKind::Person);
        assert_eq!(
            result.profile.birth_date.unwrap(),
            ArtistPartialDate {
                year: 1965,
                month: None,
                day: None
            }
        );
        assert_eq!(result.profile.birth_place.as_deref(), Some("Cidade"));
        assert_eq!(result.article_title.as_deref(), Some("Artista"));
        assert_eq!(result.commons_file.as_deref(), Some("Portrait.jpg"));
        assert_eq!(mock.calls(), 2);
    }
}
