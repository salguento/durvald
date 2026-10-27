use super::{ContractError, identity::CatalogEntityRef};
use md5::{Digest, Md5};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum SearchScope {
    Library,
    Explore,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum SearchEntityFilter {
    All,
    Artists,
    Releases,
    Tracks,
}

/// One provider page per request. Cursors are opaque and never shared across providers.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct CatalogSearchRequest {
    query: String,
    pub(crate) scope: SearchScope,
    pub(crate) filter: SearchEntityFilter,
    page_size: u16,
    cursor: Option<String>,
    language: String,
    cache_only: bool,
}

impl CatalogSearchRequest {
    pub(crate) fn new(
        query: &str,
        scope: SearchScope,
        filter: SearchEntityFilter,
        page_size: u16,
        cursor: Option<String>,
    ) -> Result<Self, ContractError> {
        let query = query.trim();
        if query.is_empty()
            || query.chars().count() > 512
            || query.chars().any(char::is_control)
            || !(1..=200).contains(&page_size)
            || cursor.as_ref().is_some_and(|value| {
                value.is_empty() || value.len() > 2048 || value.chars().any(char::is_control)
            })
        {
            return Err(ContractError::InvalidSearch);
        }
        Ok(Self {
            query: query.to_owned(),
            scope,
            filter,
            page_size,
            cursor,
            language: "und".into(),
            cache_only: false,
        })
    }

    pub(crate) fn query(&self) -> &str {
        &self.query
    }

    pub(crate) fn page_size(&self) -> u16 {
        self.page_size
    }

    pub(crate) fn cursor(&self) -> Option<&str> {
        self.cursor.as_deref()
    }
    pub(crate) fn with_language(mut self, value: &str) -> Result<Self, ContractError> {
        let value = value.trim();
        let mut parts = value.split('-');
        let first = parts.next().unwrap_or_default();
        if value.len() > 35
            || !(2..=8).contains(&first.len())
            || !first.bytes().all(|c| c.is_ascii_alphabetic())
            || !parts.all(|part| {
                (1..=8).contains(&part.len()) && part.bytes().all(|c| c.is_ascii_alphanumeric())
            })
        {
            return Err(ContractError::InvalidSearch);
        }
        self.language = value.to_ascii_lowercase();
        Ok(self)
    }
    pub(crate) fn language(&self) -> &str {
        &self.language
    }
    pub(crate) fn cached_only(mut self, value: bool) -> Self {
        self.cache_only = value;
        self
    }
    pub(crate) fn is_cache_only(&self) -> bool {
        self.cache_only
    }
}

/// A display/cache value, never an instruction to materialize a library record.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct CatalogEntitySummary {
    pub(crate) identity: CatalogEntityRef,
    pub(crate) title: String,
    pub(crate) artist_credit: Option<String>,
    pub(crate) version_label: Option<String>,
    pub(crate) duration_seconds: Option<u64>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct CatalogSearchPage {
    pub(crate) items: Vec<CatalogEntitySummary>,
    pub(crate) next_cursor: Option<String>,
    pub(crate) from_cache: bool,
}

/// Basic detail and related entities can arrive separately. Incomplete is not failure.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct CatalogEntityDetails {
    pub(crate) summary: CatalogEntitySummary,
    pub(crate) related: Vec<CatalogEntitySummary>,
    pub(crate) completeness: DetailCompleteness,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum DetailCompleteness {
    Basic,
    Complete,
}

pub(crate) fn normalized_query(value: &str) -> String {
    value
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase()
}

pub(crate) fn query_fingerprint(request: &CatalogSearchRequest, provider: &str) -> String {
    let key = serde_json::to_string(&(
        1u8,
        provider,
        normalized_query(request.query()),
        format!("{:?}", request.scope),
        format!("{:?}", request.filter),
        request.language(),
        request.page_size(),
    ))
    .expect("primitive query key");
    format!("{:x}", Md5::digest(key.as_bytes()))
}

/// Explicit versioned wire value; never a raw offset shared across queries/providers.
#[derive(serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct SearchCursor {
    version: u8,
    fingerprint: String,
    pub(crate) offsets: Vec<Option<u64>>,
}
impl SearchCursor {
    pub(crate) fn read(
        request: &CatalogSearchRequest,
        provider: &str,
        parts: usize,
    ) -> Result<Vec<Option<u64>>, ContractError> {
        let Some(cursor) = request.cursor() else {
            return Ok(vec![Some(0); parts]);
        };
        let cursor: Self =
            serde_json::from_str(cursor).map_err(|_| ContractError::InvalidSearch)?;
        if cursor.version != 1
            || cursor.fingerprint != query_fingerprint(request, provider)
            || cursor.offsets.len() != parts
            || cursor
                .offsets
                .iter()
                .flatten()
                .any(|n| *n > u32::MAX as u64)
        {
            return Err(ContractError::InvalidSearch);
        }
        Ok(cursor.offsets)
    }
    pub(crate) fn encode(
        request: &CatalogSearchRequest,
        provider: &str,
        offsets: Vec<Option<u64>>,
    ) -> Option<String> {
        if offsets.iter().all(Option::is_none) {
            return None;
        }
        Some(
            serde_json::to_string(&Self {
                version: 1,
                fingerprint: query_fingerprint(request, provider),
                offsets,
            })
            .expect("primitive cursor"),
        )
    }
}
