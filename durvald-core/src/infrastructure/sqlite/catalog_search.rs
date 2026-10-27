//! SQLite-backed catalog search.

use crate::domain::music::{
    ContractError, IntegrationError,
    catalog::*,
    identity::{CatalogEntityRef, LocalEntityRef},
};
use std::sync::Arc;

use crate::{
    domain::catalog::{CatalogArtist, CatalogRelease, CatalogTrack},
    domain::playlist::PlaylistDetails,
    infrastructure::sqlite::catalog_artist::artist_from_row,
    infrastructure::sqlite::catalog_release::release_from_row,
    infrastructure::sqlite::catalog_track::track_from_row,
    infrastructure::sqlite::playlists::playlist_from_row,
};

type DatabasePool = r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>;

pub(crate) struct CatalogSearchResults {
    pub(crate) tracks: Vec<CatalogTrack>,
    pub(crate) releases: Vec<CatalogRelease>,
    pub(crate) artists: Vec<CatalogArtist>,
    pub(crate) playlists: Vec<PlaylistDetails>,
}

pub(crate) struct SqliteCatalogSearchQuery {
    db_pool: Arc<DatabasePool>,
}

impl SqliteCatalogSearchQuery {
    pub(crate) fn new(db_pool: Arc<DatabasePool>) -> Self {
        Self { db_pool }
    }

    pub(crate) async fn search(&self, query: String) -> Result<CatalogSearchResults, String> {
        let db_pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = db_pool.get().map_err(|error| error.to_string())?;
            crate::database::operations::search_library(&conn, &query)
                .map(|results| CatalogSearchResults {
                    tracks: results.tracks.into_iter().map(track_from_row).collect(),
                    releases: results.releases.into_iter().map(release_from_row).collect(),
                    artists: results.artists.into_iter().map(artist_from_row).collect(),
                    playlists: results
                        .playlists
                        .into_iter()
                        .map(playlist_from_row)
                        .collect(),
                })
                .map_err(|error| error.to_string())
        })
        .await
        .map_err(|error| format!("Blocking database task failed: {error}"))?
    }

    pub(crate) async fn catalog_page(
        &self,
        request: CatalogSearchRequest,
    ) -> Result<CatalogSearchPage, IntegrationError> {
        if request.page_size() > 50 {
            return Err(IntegrationError::InvalidInput(ContractError::InvalidSearch));
        }
        let offsets =
            SearchCursor::read(&request, "library", 1).map_err(IntegrationError::InvalidInput)?;
        let Some(offset) = offsets[0] else {
            return Ok(CatalogSearchPage {
                items: vec![],
                next_cursor: None,
                from_cache: false,
            });
        };
        let pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = pool
                .get()
                .map_err(|_| IntegrationError::TemporarilyUnavailable)?;
            let mut result = crate::database::operations::search_library_page(
                &conn,
                &normalized_query(request.query()),
                request.page_size() as usize + 1,
                offset as usize,
            )
            .map_err(|_| IntegrationError::TemporarilyUnavailable)?;
            let limit = request.page_size() as usize;
            let mut more = false;
            let mut items = Vec::new();
            let all = request.filter == SearchEntityFilter::All;
            if all || request.filter == SearchEntityFilter::Artists {
                more |= result.artists.len() > limit;
                result.artists.truncate(limit);
                items.extend(
                    result
                        .artists
                        .into_iter()
                        .map(|artist| CatalogEntitySummary {
                            identity: CatalogEntityRef::Local(LocalEntityRef::Artist(
                                crate::domain::ids::ArtistId::from_persisted(artist.artist_id),
                            )),
                            title: artist.artist_name,
                            artist_credit: None,
                            version_label: None,
                            duration_seconds: None,
                        }),
                );
            }
            if all || request.filter == SearchEntityFilter::Releases {
                more |= result.releases.len() > limit;
                result.releases.truncate(limit);
                items.extend(
                    result
                        .releases
                        .into_iter()
                        .map(|release| CatalogEntitySummary {
                            identity: CatalogEntityRef::Local(LocalEntityRef::Release(
                                crate::domain::ids::ReleaseId::from_persisted(release.release_id),
                            )),
                            title: release.title,
                            artist_credit: Some(release.artist_name),
                            version_label: None,
                            duration_seconds: Some(release.duration),
                        }),
                );
            }
            if all || request.filter == SearchEntityFilter::Tracks {
                more |= result.tracks.len() > limit;
                result.tracks.truncate(limit);
                items.extend(result.tracks.into_iter().map(|track| CatalogEntitySummary {
                    identity: CatalogEntityRef::Local(LocalEntityRef::Track(
                        crate::domain::ids::TrackId::from_persisted(track.song_id),
                    )),
                    title: track.title,
                    artist_credit: Some(track.artist_name),
                    version_label: Some(track.release_title),
                    duration_seconds: Some(track.duration),
                }));
            }
            if all {
                more |= result.playlists.len() > limit;
                result.playlists.truncate(limit);
                items.extend(
                    result
                        .playlists
                        .into_iter()
                        .map(|playlist| CatalogEntitySummary {
                            identity: CatalogEntityRef::Local(LocalEntityRef::Playlist(
                                crate::domain::ids::PlaylistId::from_persisted(playlist.id),
                            )),
                            title: playlist.name,
                            artist_credit: None,
                            version_label: None,
                            duration_seconds: None,
                        }),
                );
            }
            Ok(CatalogSearchPage {
                items,
                next_cursor: SearchCursor::encode(
                    &request,
                    "library",
                    vec![more.then_some(offset + limit as u64)],
                ),
                from_cache: false,
            })
        })
        .await
        .map_err(|_| IntegrationError::TemporarilyUnavailable)?
    }
}
