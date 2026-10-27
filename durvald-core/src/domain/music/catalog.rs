use super::{ContractError, identity::CatalogEntityRef};

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
            || query.chars().any(char::is_control)
            || !(1..=200).contains(&page_size)
            || cursor
                .as_ref()
                .is_some_and(|value| value.is_empty() || value.chars().any(char::is_control))
        {
            return Err(ContractError::InvalidSearch);
        }
        Ok(Self {
            query: query.to_owned(),
            scope,
            filter,
            page_size,
            cursor,
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
